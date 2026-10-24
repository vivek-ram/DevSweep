import Foundation

public struct ScanProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case discovering
        case measuring
    }

    public var phase: Phase = .discovering
    public var foldersVisited = 0
    public var itemsFound = 0
    public var measured = 0
    public var currentPath = ""

    public init() {}
}

/// Finds projects and their regenerable folders under a set of root folders.
///
/// One pass per root walks every directory except artifact folders (which are skipped, not
/// entered). Along the way it records project markers, git repos and the newest file
/// modification per directory, so ownership and last activity come out of the same walk.
/// Artifact sizes are then measured in parallel.
public struct ProjectScanner: Sendable {
    public var maxConcurrentMeasurements = 8

    public init() {}

    public func scan(roots: [String], editorActivity: EditorActivity? = nil,
                     progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanResult {
        DiskUsage.avoidDownloadingCloudFiles()
        let started = Date()
        let roots = Self.minimalRoots(roots)
        let reporter = ProgressReporter(progress)

        let discoveries = try await withThrowingTaskGroup(of: Discovery.self) { group in
            for root in roots {
                group.addTask { try Discovery.walk(root: root, reporter: reporter) }
            }
            var all: [Discovery] = []
            for try await discovery in group { all.append(discovery) }
            return all
        }
        try Task.checkCancellation()

        let editors = editorActivity ?? EditorActivity.collect()
        var projects = discoveries.flatMap { $0.assembleProjects(editors: editors) }

        reporter.update { $0.phase = .measuring }
        let jobs = projects.indices.flatMap { p in projects[p].artifacts.indices.map { (p, $0) } }
        try await withThrowingTaskGroup(of: (Int, Int, Int64).self) { group in
            var pending = jobs.makeIterator()
            func enqueue() {
                guard let (p, a) = pending.next() else { return }
                let path = projects[p].artifacts[a].path
                group.addTask {
                    try Task.checkCancellation()
                    return (p, a, DiskUsage.freeableBytes(at: path))
                }
            }
            for _ in 0..<maxConcurrentMeasurements { enqueue() }
            while let (p, a, bytes) = try await group.next() {
                projects[p].artifacts[a].bytes = bytes
                let path = projects[p].artifacts[a].path
                reporter.update {
                    $0.measured += 1
                    $0.currentPath = path
                }
                enqueue()
            }
        }
        try Task.checkCancellation()

        for i in projects.indices {
            projects[i].artifacts.sort { $0.bytes > $1.bytes }
        }
        projects.sort { $0.totalBytes > $1.totalBytes }
        reporter.flush()

        return ScanResult(projects: projects, roots: roots, date: Date(),
                          duration: Date().timeIntervalSince(started),
                          foldersVisited: discoveries.reduce(0) { $0 + $1.foldersVisited })
    }

    /// Drops roots nested inside other roots so nothing is scanned twice.
    static func minimalRoots(_ roots: [String]) -> [String] {
        let normalized = Array(Set(roots.map(Paths.normalize))).sorted()
        var result: [String] = []
        for root in normalized where !result.contains(where: { Paths.isInside(root, $0) }) {
            result.append(root)
        }
        return result
    }
}

/// Everything learned about one root in a single walk.
struct Discovery {
    struct Found {
        var path: String
        var kind: ArtifactKind
        var modified: Double
    }

    let root: String
    var artifacts: [Found] = []
    var gitRoots: Set<String> = []
    var markerDirs: Set<String> = []
    var keepDirs: Set<String> = []
    /// Directory → newest modification time of the files directly inside it.
    var newestFile: [String: Double] = [:]
    var foldersVisited = 0

    static func walk(root: String, reporter: ProgressReporter) throws -> Discovery {
        var d = Discovery(root: root)
        let isHome = root == Paths.normalize(NSHomeDirectory())

        guard let cRoot = strdup(root) else { return d }
        defer { free(cRoot) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR | FTS_XDEV, nil) else { return d }
        defer { fts_close(fts) }

        // Directories we descended into, innermost last, each with its newest file time.
        var stack: [(path: String, newest: Double)] = []

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                let path = String(cString: entry.pointee.fts_path)
                let level = Int(entry.pointee.fts_level)
                d.foldersVisited += 1
                if d.foldersVisited & 0x3FF == 0 {
                    try Task.checkCancellation()
                    reporter.update {
                        $0.foldersVisited += 0x400
                        $0.currentPath = path
                    }
                }
                if level > 0 {
                    let name = entryName(entry)
                    if name == ".git" {
                        d.gitRoots.insert(Paths.parent(path))
                        d.noteGitActivity(gitDir: path, newest: &stack[stack.count - 1].newest)
                        fts_set(fts, entry, FTS_SKIP)
                        continue
                    }
                    if let kind = ArtifactRules.classify(name: name, path: path) {
                        let mtime = Double(entry.pointee.fts_statp?.pointee.st_mtimespec.tv_sec ?? 0)
                        d.artifacts.append(Found(path: path, kind: kind, modified: mtime))
                        reporter.update { $0.itemsFound += 1 }
                        fts_set(fts, entry, FTS_SKIP)
                        continue
                    }
                    if ArtifactRules.isOpaque(name: name, path: path) || (isHome && level == 1 && ArtifactRules.homeOnlySkips.contains(name)) {
                        fts_set(fts, entry, FTS_SKIP)
                        continue
                    }
                }
                stack.append((path, 0))

            case FTS_DP, FTS_DNR:
                // Post-order visit (also delivered for skipped directories, which were never pushed).
                guard let top = stack.last, top.path.utf8.count == Int(entry.pointee.fts_pathlen),
                      top.path == String(cString: entry.pointee.fts_path) else { continue }
                stack.removeLast()
                if top.newest > 0 { d.newestFile[top.path] = top.newest }

            case FTS_F:
                guard !stack.isEmpty else { continue }
                let name = entryName(entry)
                if ArtifactRules.noiseFiles.contains(name) { continue }
                if let st = entry.pointee.fts_statp?.pointee {
                    let mtime = Double(st.st_mtimespec.tv_sec)
                    if mtime > stack[stack.count - 1].newest { stack[stack.count - 1].newest = mtime }
                }
                if ArtifactRules.projectMarkers.contains(name) {
                    d.markerDirs.insert(stack[stack.count - 1].path)
                } else if name == ArtifactRules.keepMarker {
                    d.keepDirs.insert(stack[stack.count - 1].path)
                } else if name == ".git" {
                    // A worktree or submodule: `.git` is a file pointing elsewhere.
                    d.gitRoots.insert(stack[stack.count - 1].path)
                }

            default:
                continue
            }
        }
        reporter.update { $0.foldersVisited += d.foldersVisited & 0x3FF }
        return d
    }

    /// Commits, checkouts and staging touch these files; background fetches don't.
    private func noteGitActivity(gitDir: String, newest: inout Double) {
        for file in ["HEAD", "index", "logs/HEAD"] {
            if let date = modificationDate(gitDir + "/" + file) {
                newest = max(newest, date.timeIntervalSince1970)
            }
        }
    }

    /// The project an artifact belongs to: the nearest enclosing git repository below the scan
    /// root, else the nearest folder with a project file (package.json, pyproject.toml, …),
    /// else the scan root if it is itself a repository, else the largest folder around the
    /// artifact that doesn't contain some other project (so stray __pycache__ folders in a plain
    /// folder of scripts group together instead of each becoming a "project").
    func owner(of artifactPath: String, containers: Set<String>) -> String {
        let start = Paths.parent(artifactPath)
        var current = start
        var nearestMarker: String?
        while true {
            if current != root, gitRoots.contains(current) { return current }
            if nearestMarker == nil, markerDirs.contains(current) { nearestMarker = current }
            if current == root || current.utf8.count <= root.utf8.count { break }
            current = Paths.parent(current)
        }
        if let nearestMarker { return nearestMarker }
        if gitRoots.contains(root) || start == root { return root }
        guard start.hasPrefix(root + "/") else { return start }
        var candidate = root
        for component in start.dropFirst(root.utf8.count + 1).split(separator: "/") {
            candidate += "/" + component
            if !containers.contains(candidate) { return candidate }
        }
        return start
    }

    /// Every folder that has a recognised project somewhere below it.
    func projectContainers() -> Set<String> {
        var containers = Set<String>()
        for dir in markerDirs.union(gitRoots) where dir != root {
            var current = Paths.parent(dir)
            while current.utf8.count >= root.utf8.count, containers.insert(current).inserted, current != root {
                current = Paths.parent(current)
            }
        }
        return containers
    }

    func assembleProjects(editors: EditorActivity) -> [Project] {
        var grouped: [String: [Artifact]] = [:]
        var lastBuilt: [String: Double] = [:]
        let containers = projectContainers()
        for found in artifacts {
            let owner = owner(of: found.path, containers: containers)
            grouped[owner, default: []].append(
                Artifact(path: found.path, kind: found.kind, modified: Date(timeIntervalSince1970: found.modified)))
            lastBuilt[owner] = max(lastBuilt[owner] ?? 0, found.modified)
        }
        guard !grouped.isEmpty else { return [] }

        // Fold each directory's newest file into every project that contains it.
        var lastEdited: [String: Double] = [:]
        for (dir, newest) in newestFile {
            var current = dir
            while true {
                if grouped[current] != nil, newest > lastEdited[current] ?? 0 {
                    lastEdited[current] = newest
                }
                if current == root || current.utf8.count <= root.utf8.count { break }
                current = Paths.parent(current)
            }
        }

        return grouped.map { path, artifacts in
            let opened = editors.lastOpened(project: path)
            return Project(
                path: path,
                root: root,
                artifacts: artifacts,
                lastEdited: lastEdited[path].map { Date(timeIntervalSince1970: $0) },
                lastOpened: opened?.date,
                openedWith: opened?.app,
                lastBuilt: lastBuilt[path].map { Date(timeIntervalSince1970: $0) },
                isGitRepo: gitRoots.contains(path),
                hasKeepMarker: keepDirs.contains { Paths.isInside(path, $0) }
            )
        }
    }
}

@inline(__always)
private func entryName(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
    withUnsafePointer(to: &entry.pointee.fts_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.fts_namelen) + 1) {
            String(cString: $0)
        }
    }
}

/// Aggregates progress from concurrent walkers and forwards it at most ~10 times a second.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var state = ScanProgress()
    private var lastSent = Date.distantPast
    private let sink: @Sendable (ScanProgress) -> Void

    init(_ sink: @escaping @Sendable (ScanProgress) -> Void) {
        self.sink = sink
    }

    func update(_ change: (inout ScanProgress) -> Void) {
        lock.lock()
        change(&state)
        let now = Date()
        let send = now.timeIntervalSince(lastSent) > 0.1
        if send { lastSent = now }
        let snapshot = state
        lock.unlock()
        if send { sink(snapshot) }
    }

    func flush() {
        lock.lock()
        let snapshot = state
        lock.unlock()
        sink(snapshot)
    }
}
