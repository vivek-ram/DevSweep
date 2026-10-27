import Foundation

public struct CleanOptions: Sendable {
    public var mode: RemovalMode
    /// Save a venv's packages to requirements.txt before removing it.
    public var snapshotPython: Bool
    /// Save node_modules versions when the project has no lockfile.
    public var snapshotNode: Bool
    /// Report what would happen without touching anything.
    public var dryRun: Bool
    public var automatic: Bool

    public init(mode: RemovalMode = .trash, snapshotPython: Bool = true, snapshotNode: Bool = true,
                dryRun: Bool = false, automatic: Bool = false) {
        self.mode = mode
        self.snapshotPython = snapshotPython
        self.snapshotNode = snapshotNode
        self.dryRun = dryRun
        self.automatic = automatic
    }
}

public enum Cleaner {
    /// Removes the given artifacts of one project. Every item is re-validated against the disk
    /// first, and a virtual environment is only removed once its packages were saved.
    /// Blocking; call it off the main thread.
    public static func clean(_ artifacts: [Artifact], in project: Project, options: CleanOptions) -> [CleanupRecord] {
        // Snapshots keep the project's last-activity date so writing them doesn't reset the clock.
        let preserveDate = project.lastActivity == .distantPast ? nil : project.lastActivity
        return artifacts.map { artifact in
            var record = CleanupRecord(projectPath: project.path, itemPath: artifact.path, kind: artifact.kind.rawValue,
                                       bytes: artifact.bytes, mode: options.mode, outcome: .removed,
                                       automatic: options.automatic)
            if let problem = validate(artifact, in: project) {
                record.outcome = .skipped
                record.message = problem
                return record
            }
            if options.dryRun {
                record.outcome = .skipped
                record.message = "Dry run"
                return record
            }

            switch artifact.kind {
            case .pythonVenv where options.snapshotPython:
                do {
                    switch try PythonSnapshot.save(venv: artifact.path, preserveDate: preserveDate) {
                    case .written(let path): record.snapshotPath = path
                    case .alreadyCovered(let path):
                        record.snapshotPath = path
                        record.message = "Existing \((path as NSString).lastPathComponent) already pins these packages"
                    case .empty: record.message = "Environment had no packages to save"
                    }
                } catch {
                    record.outcome = .skipped
                    record.message = "Couldn't save its packages, so it was kept: \(error.localizedDescription)"
                    return record
                }
            case .nodeModules where options.snapshotNode:
                // Lockfile-less projects only; a failure here isn't worth keeping node_modules for.
                record.snapshotPath = try? NodeSnapshot.saveIfNeeded(nodeModules: artifact.path, projectRoot: project.path,
                                                                     preserveDate: preserveDate)
            default:
                break
            }

            do {
                record.trashPath = try remove(artifact.path, mode: options.mode)
            } catch {
                record.outcome = .failed
                record.message = error.localizedDescription
            }
            return record
        }
    }

    /// Virtual environments are only removed with the user's explicit OK: when `askBeforeVenvs` is
    /// set, a venv is kept unless its path is in `approvedVenvs`. Everything else passes through.
    public static func applyingVenvApproval(_ artifacts: [Artifact], askBeforeVenvs: Bool,
                                            approvedVenvs: Set<String>) -> [Artifact] {
        guard askBeforeVenvs else { return artifacts }
        return artifacts.filter { $0.kind != .pythonVenv || approvedVenvs.contains($0.path) }
    }

    /// Why an artifact must not be removed, or nil if it's safe.
    public static func validate(_ artifact: Artifact, in project: Project) -> String? {
        let path = artifact.path
        guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/.."),
              path.hasPrefix(project.path + "/") else {
            return "Not inside the project folder"
        }
        if path == Paths.home || Paths.isInside(Paths.home, path) { return "Refusing to remove a home folder" }

        var st = stat()
        guard lstat(path, &st) == 0 else { return "No longer exists" }
        if (st.st_mode & S_IFMT) == S_IFLNK { return "Is a symbolic link" }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return "Not a folder" }

        // The folder must still be what the scan thought it was.
        guard ArtifactRules.classify(name: artifact.name, path: path) == artifact.kind else {
            return "No longer looks like \(artifact.kind.displayName)"
        }
        // A keep marker may have been added since the scan.
        var dir = project.path
        while dir.count > 1 {
            if ArtifactRules.exists(dir, ArtifactRules.keepMarker) { return "Protected by \(ArtifactRules.keepMarker)" }
            if dir == project.root { break }
            dir = Paths.parent(dir)
        }
        return nil
    }

    /// Moves `path` to the Trash or deletes it. Returns the item's location in the Trash.
    @discardableResult
    public static func remove(_ path: String, mode: RemovalMode) throws -> String? {
        // The last check before anything goes: a protected folder is never touched, whichever
        // page asked. (Emptying the Trash is the one exception: what's in it was already removed.)
        if !isInTrash(path), Protection.isProtected(path) { throw Protection.Refused(path: path) }
        let url = URL(fileURLWithPath: path)
        switch mode {
        case .trash:
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting?.path
        case .permanent:
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // Some packages ship read-only folders (Go modules, a few npm tarballs).
                makeWritable(path)
                try FileManager.default.removeItem(at: url)
            }
            return nil
        }
    }

    static func makeWritable(_ path: String) {
        DiskUsage.walk(path) { entry in
            guard Int32(entry.pointee.fts_info) == FTS_D, let st = entry.pointee.fts_statp?.pointee else { return }
            if st.st_mode & S_IWUSR == 0 { chmod(entry.pointee.fts_path, st.st_mode | S_IWUSR | S_IXUSR) }
        }
    }

    // MARK: Global caches

    public static func clean(_ cache: DevCache, options: CleanOptions) -> CleanupRecord {
        var record = CleanupRecord(projectPath: cache.path, itemPath: cache.path, kind: "cache:\(cache.id)",
                                   bytes: cache.bytes ?? 0, mode: options.mode, outcome: .removed,
                                   automatic: options.automatic)
        guard CacheCatalog.knownPaths().contains(cache.path) else {
            record.outcome = .skipped
            record.message = "Not a known cache location"
            return record
        }
        var st = stat()
        guard lstat(cache.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            record.outcome = .skipped
            record.message = "No longer exists"
            return record
        }
        if options.dryRun {
            record.outcome = .skipped
            record.message = "Dry run"
            return record
        }
        do {
            record.trashPath = try remove(cache.path, mode: options.mode)
        } catch {
            record.outcome = .failed
            record.message = error.localizedDescription
        }
        return record
    }

    // MARK: System junk and your own files

    public static func clean(_ item: JunkItem, mode: RemovalMode, home: String = NSHomeDirectory()) -> CleanupRecord {
        var record = CleanupRecord(projectPath: Paths.parent(item.path), itemPath: item.path, kind: "junk:\(item.category.rawValue)",
                                   bytes: item.bytes, mode: item.category == .trash || item.category == .mailAttachments ? .permanent : mode,
                                   outcome: .removed)
        if let problem = JunkScanner.validate(item, home: home) {
            record.outcome = .skipped
            record.message = problem
            return record
        }
        do {
            if item.category == .trash || item.category == .mailAttachments {
                // Emptying the Trash or Mail's downloads: delete what's inside, keep the folder.
                for name in try FileManager.default.contentsOfDirectory(atPath: item.path) {
                    try remove(item.path + "/" + name, mode: .permanent)
                }
            } else {
                record.trashPath = try remove(item.path, mode: mode)
            }
        } catch {
            record.outcome = .failed
            record.message = error.localizedDescription
        }
        return record
    }

    /// Moves something you picked in the storage map or large-files list to the Trash. Your own
    /// files always go to the Trash, whatever the removal setting.
    public static func trashUserItem(_ path: String, bytes: Int64, home: String = NSHomeDirectory()) -> CleanupRecord {
        var record = CleanupRecord(projectPath: Paths.parent(path), itemPath: path, kind: "file", bytes: bytes,
                                   mode: .trash, outcome: .removed)
        if let problem = RemovalRules.problem(removing: path, home: home) {
            record.outcome = .skipped
            record.message = problem
            return record
        }
        var st = stat()
        guard lstat(path, &st) == 0 else {
            record.outcome = .skipped
            record.message = "No longer exists"
            return record
        }
        do {
            record.trashPath = try remove(path, mode: .trash)
        } catch {
            record.outcome = .failed
            record.message = error.localizedDescription
        }
        return record
    }

    // MARK: Apps

    /// Moves an app bundle to the Trash. Apps installed by an installer package are owned by the
    /// system; that fails with a permission error and the caller can hand the app to Finder.
    public static func trashApp(_ app: InstalledApp, home: String = NSHomeDirectory()) -> CleanupRecord {
        var record = CleanupRecord(projectPath: app.path, itemPath: app.path, kind: "app", bytes: app.appBytes,
                                   mode: .trash, outcome: .removed)
        var st = stat()
        guard app.path.hasSuffix(".app"), AppInventory.appFolders(home: home).contains(Paths.parent(app.path)),
              lstat(app.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            record.outcome = .skipped
            record.message = "Not an app in an Applications folder"
            return record
        }
        if app.bundleID == "app.devsweep.DevSweep" || app.bundleID == Bundle.main.bundleIdentifier {
            record.outcome = .skipped
            record.message = "DevSweep can't uninstall itself"
            return record
        }
        do {
            record.trashPath = try remove(app.path, mode: .trash)
        } catch {
            record.outcome = .failed
            record.message = error.localizedDescription
        }
        return record
    }

    // MARK: Trash

    /// Items DevSweep moved to the Trash that are still there.
    public static func itemsStillInTrash(_ records: [CleanupRecord]) -> [CleanupRecord] {
        records.filter { record in
            guard record.outcome == .removed, record.mode == .trash, let trash = record.trashPath else { return false }
            return isInTrash(trash) && FileManager.default.fileExists(atPath: trash)
        }
    }

    /// The user's Trash, or a volume's per-user .Trashes folder.
    static func isInTrash(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        guard !path.contains("/../"), let index = components.firstIndex(where: { $0 == ".Trash" || $0 == ".Trashes" }) else {
            return false
        }
        return components.count > index + 1
    }

    /// Permanently deletes only the items DevSweep itself put in the Trash (never the rest of it).
    public enum PutBackError: LocalizedError {
        case notInTrash, pathTaken(String)

        public var errorDescription: String? {
            switch self {
            case .notInTrash: "It's no longer in the Trash."
            case .pathTaken(let path): "Something else is already at \(Paths.display(path))."
            }
        }
    }

    /// Moves an item DevSweep put in the Trash back to where it was.
    public static func putBack(_ record: CleanupRecord) throws {
        guard let trash = record.trashPath, !itemsStillInTrash([record]).isEmpty else { throw PutBackError.notInTrash }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: record.itemPath) else { throw PutBackError.pathTaken(record.itemPath) }
        try fm.createDirectory(atPath: Paths.parent(record.itemPath), withIntermediateDirectories: true)
        try fm.moveItem(atPath: trash, toPath: record.itemPath)
    }

    public static func purgeFromTrash(_ records: [CleanupRecord]) -> (freed: Int64, failures: Int) {
        var freed: Int64 = 0
        var failures = 0
        for record in itemsStillInTrash(records) {
            guard let trash = record.trashPath else { continue }
            do {
                try remove(trash, mode: .permanent)
                freed += record.bytes
            } catch {
                failures += 1
            }
        }
        return (freed, failures)
    }
}
