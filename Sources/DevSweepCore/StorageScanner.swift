import Foundation

/// A folder (or a large file) in the storage map.
public final class StorageNode: Identifiable, @unchecked Sendable {
    public enum Note: Sendable {
        /// Skipped because reading it needs Full Disk Access (and would otherwise prompt).
        case needsFullDiskAccess
        /// macOS refused to list it.
        case unreadable
    }

    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    /// An app or library bundle; shown as a single item.
    public let isPackage: Bool
    public internal(set) var size: Int64 = 0
    public internal(set) var fileCount = 0
    /// Biggest children, largest first. Folders under ~1 MB and files under 1 MB are folded
    /// into `size` without a node of their own.
    public internal(set) var children: [StorageNode] = []
    public internal(set) var note: Note?
    /// Set when the folder is something a developer tool rebuilds (node_modules, a venv, …).
    public internal(set) var artifactKind: ArtifactKind?
    public internal(set) var modified: Date
    public internal(set) weak var parent: StorageNode?

    init(name: String, path: String, isDirectory: Bool, isPackage: Bool = false, size: Int64 = 0, modified: Date) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.modified = modified
    }

    /// Bytes in items too small to list individually.
    public var smallItemsSize: Int64 { max(0, size - children.reduce(0) { $0 + $1.size }) }

    public var displayPath: String { Paths.display(path) }

    func add(_ child: StorageNode) {
        attach(child)
        size += child.size
        fileCount += child.fileCount
    }

    /// Links a child without touching sizes (they're totalled later).
    func attach(_ child: StorageNode) {
        child.parent = self
        children.append(child)
    }

    /// Keeps the biggest children so the tree stays small.
    func finalize() {
        if isPackage {
            children = []
            return
        }
        children.sort { $0.size > $1.size }
        let minimum = max(1_000_000, size / 5_000)
        var kept: [StorageNode] = []
        // Notes (like "needs Full Disk Access") stay visible even though nothing was measured.
        for child in children where kept.count < 120 && (child.size >= minimum || child.note != nil) {
            kept.append(child)
        }
        children = kept
    }

    /// Removes a child (after it was moved to the Trash) and updates sizes up the tree.
    public func remove(_ child: StorageNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        var node: StorageNode? = self
        while let current = node {
            current.size -= child.size
            current.fileCount -= child.fileCount
            node = current.parent
        }
    }

    public func descendant(at path: String) -> StorageNode? {
        if path == self.path { return self }
        guard Paths.isInside(path, self.path) else { return nil }
        for child in children where child.isDirectory {
            if let found = child.descendant(at: path) { return found }
        }
        return nil
    }
}

public struct LargeFile: Identifiable, Hashable, Sendable {
    public enum Place: String, CaseIterable, Sendable {
        case downloads, documents, media, appData, other

        public var title: String {
            switch self {
            case .downloads: "Downloads"
            case .documents: "Documents & Desktop"
            case .media: "Movies, Music & Pictures"
            case .appData: "App data (Library)"
            case .other: "Elsewhere"
            }
        }
    }

    public var id: String { path }
    public let path: String
    public let size: Int64
    public let modified: Date
    public let place: Place

    public var name: String { (path as NSString).lastPathComponent }
    public var folderDisplayPath: String { Paths.display(Paths.parent(path)) }
}

public struct StorageProgress: Sendable, Equatable {
    public var files = 0
    public var bytes: Int64 = 0
    public var currentPath = ""
    public init() {}
}

public struct StorageScanResult: @unchecked Sendable {
    public let root: StorageNode
    public let largeFiles: [LargeFile]
    public let date: Date
    public let duration: TimeInterval
    /// Folders skipped because they need Full Disk Access.
    public let restricted: [String]
}

/// Measures everything under a folder (the home folder, or the whole data volume) in parallel.
public struct StorageScanner: Sendable {
    public static let wholeDisk = "/System/Volumes/Data"
    public var largeFileThreshold: Int64 = 50_000_000
    public var hasFullDiskAccess: Bool

    public init(hasFullDiskAccess: Bool = FullDiskAccess.isGranted) {
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    public func scan(root: String, progress: @escaping @Sendable (StorageProgress) -> Void = { _ in }) async throws -> StorageScanResult {
        DiskUsage.avoidDownloadingCloudFiles()
        let started = Date()
        let root = Paths.normalize(root)
        let reporter = StorageReporter(progress)
        let rootNode = StorageNode(name: root == Self.wholeDisk ? "Macintosh HD" : (root as NSString).lastPathComponent,
                                   path: root, isDirectory: true, modified: modificationDate(root) ?? Date())

        // Split the work so walks run in parallel: every child of the root is its own job, and
        // the big containers (Library, Users, your home) are opened one level further.
        var containers: [StorageNode] = [rootNode]
        var loose: [ObjectIdentifier: (bytes: Int64, files: Int)] = [:]
        var jobs: [(parent: StorageNode, path: String)] = []
        var restricted: [String] = []
        var index = 0
        while index < containers.count {
            let container = containers[index]
            index += 1
            var looseBytes: Int64 = 0
            var looseFiles = 0
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: container.path)) ?? [] {
                let path = container.path + "/" + entry
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let modified = date(st.st_mtimespec)
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    if isRestricted(path) {
                        let node = StorageNode(name: entry, path: path, isDirectory: true, modified: modified)
                        node.note = .needsFullDiskAccess
                        container.attach(node)
                        restricted.append(path)
                    } else if shouldOpen(path, root: root) {
                        let node = StorageNode(name: entry, path: path, isDirectory: true, modified: modified)
                        container.attach(node)
                        containers.append(node)
                    } else {
                        jobs.append((container, path))
                    }
                } else {
                    let bytes = Int64(st.st_blocks) * 512
                    if bytes >= 1_000_000 {
                        let file = StorageNode(name: entry, path: path, isDirectory: false, size: bytes, modified: modified)
                        file.fileCount = 1
                        container.attach(file)
                    } else {
                        looseBytes += bytes
                        looseFiles += 1
                    }
                }
            }
            loose[ObjectIdentifier(container)] = (looseBytes, looseFiles)
        }

        var largeFiles: [LargeFile] = []
        let threshold = largeFileThreshold
        let fullAccess = hasFullDiskAccess
        try await withThrowingTaskGroup(of: (Int, StorageNode?, [LargeFile]).self) { group in
            var next = 0
            func enqueue() {
                guard next < jobs.count else { return }
                let i = next
                let path = jobs[i].path
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let started = Date()
                    let walk = SubtreeWalk(threshold: threshold, hasFullDiskAccess: fullAccess, reporter: reporter)
                    let node = try walk.run(path)
                    if ProcessInfo.processInfo.environment["DEVSWEEP_TIMING"] != nil {
                        let seconds = Date().timeIntervalSince(started)
                        if seconds > 2 { FileHandle.standardError.write(Data(String(format: "%6.1fs  %@\n", seconds, path).utf8)) }
                    }
                    return (i, node, walk.largeFiles)
                }
            }
            for _ in 0..<8 { enqueue() }
            while let (i, node, large) = try await group.next() {
                if let node { jobs[i].parent.attach(node) }
                largeFiles += large
                enqueue()
            }
        }

        // Containers were opened top-down; total them bottom-up.
        for container in containers.reversed() {
            let own = loose[ObjectIdentifier(container)] ?? (0, 0)
            container.size = own.bytes + container.children.reduce(0) { $0 + $1.size }
            container.fileCount = own.files + container.children.reduce(0) { $0 + $1.fileCount }
            container.finalize()
        }
        reporter.flush()

        largeFiles.sort { $0.size > $1.size }
        return StorageScanResult(root: rootNode, largeFiles: largeFiles, date: Date(),
                                 duration: Date().timeIntervalSince(started), restricted: restricted)
    }

    private func shouldOpen(_ path: String, root: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let home = root == Self.wholeDisk ? Self.wholeDisk + Paths.home : Paths.home
        let parent = Paths.parent(path)
        return name == "Library" && (parent == root || parent == home)
            || name == "Users" && parent == root
            || path == home
            || ["Caches", "Application Support"].contains(name) && parent == home + "/Library"
    }

    /// Reading these needs Full Disk Access; without it macOS asks the user once per app.
    func isRestricted(_ path: String) -> Bool {
        guard !hasFullDiskAccess else { return false }
        return path.hasSuffix("/Library/Containers") || path.hasSuffix("/Library/Group Containers")
            || path.hasSuffix("/Library/Daemon Containers")
    }
}

/// One fts walk of a subtree, building StorageNodes bottom-up.
private final class SubtreeWalk {
    let threshold: Int64
    let hasFullDiskAccess: Bool
    let reporter: StorageReporter
    var largeFiles: [LargeFile] = []
    private var seenLinks = Set<UInt64>()

    init(threshold: Int64, hasFullDiskAccess: Bool, reporter: StorageReporter) {
        self.threshold = threshold
        self.hasFullDiskAccess = hasFullDiskAccess
        self.reporter = reporter
    }

    static let packageSuffixes = [".app", ".photoslibrary", ".musiclibrary", ".tvlibrary", ".imovielibrary", ".fcpbundle",
                                  ".logicx", ".band", ".xcarchive", ".framework", ".bundle", ".plugin", ".kext",
                                  ".pkg", ".mpkg", ".sparsebundle", ".vmwarevm", ".pvm", ".utm", ".lrlibrary", ".lrdata"]

    func run(_ path: String) throws -> StorageNode? {
        guard let cPath = strdup(path) else { return nil }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(fts) }

        var stack: [StorageNode] = []
        var result: StorageNode?
        // fts levels at which a package / rebuildable folder began.
        var packageLevel: Int?
        var artifactLevel: Int?
        var files = 0
        var bytesSinceReport: Int64 = 0

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            let level = Int(entry.pointee.fts_level)
            switch info {
            case FTS_D:
                let path = String(cString: entry.pointee.fts_path)
                let name = (path as NSString).lastPathComponent
                let st = entry.pointee.fts_statp?.pointee
                if level > 0, !hasFullDiskAccess,
                   path.hasSuffix("/Library/Containers") || path.hasSuffix("/Library/Group Containers") {
                    let node = StorageNode(name: name, path: path, isDirectory: true, modified: st.map { date($0.st_mtimespec) } ?? Date())
                    node.note = .needsFullDiskAccess
                    stack.last?.add(node)
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }
                let isPackage = packageLevel == nil && Self.packageSuffixes.contains { name.hasSuffix($0) }
                let node = StorageNode(name: name, path: path, isDirectory: true, isPackage: isPackage,
                                       modified: st.map { date($0.st_mtimespec) } ?? Date())
                if isPackage { packageLevel = level }
                if artifactLevel == nil, packageLevel == nil, let kind = ArtifactRules.classify(name: name, path: path) {
                    node.artifactKind = kind
                    artifactLevel = level
                }
                stack.append(node)

            case FTS_DP, FTS_DNR:
                guard let top = stack.last, top.path.utf8.count == Int(entry.pointee.fts_pathlen),
                      top.path == String(cString: entry.pointee.fts_path) else { continue }
                stack.removeLast()
                if info == FTS_DNR { top.note = .unreadable }
                top.finalize()
                if let parent = stack.last { parent.add(top) } else { result = top }
                if packageLevel == level { packageLevel = nil }
                if artifactLevel == level { artifactLevel = nil }
                if files > 2_000 {
                    try Task.checkCancellation()
                    let reportedFiles = files, reportedBytes = bytesSinceReport, current = top.path
                    reporter.update {
                        $0.files += reportedFiles
                        $0.bytes += reportedBytes
                        $0.currentPath = current
                    }
                    files = 0
                    bytesSinceReport = 0
                }

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = entry.pointee.fts_statp?.pointee, let dir = stack.last else { continue }
                if st.st_nlink > 1, !seenLinks.insert(UInt64(st.st_ino)).inserted { continue }
                let bytes = Int64(st.st_blocks) * 512
                files += 1
                bytesSinceReport += bytes
                if bytes >= 1_000_000, packageLevel == nil {
                    let path = String(cString: entry.pointee.fts_path)
                    let file = StorageNode(name: (path as NSString).lastPathComponent, path: path, isDirectory: false,
                                           size: bytes, modified: date(st.st_mtimespec))
                    file.fileCount = 1
                    dir.add(file)
                    if bytes >= threshold, artifactLevel == nil {
                        largeFiles.append(LargeFile(path: path, size: bytes, modified: date(st.st_mtimespec), place: place(of: path)))
                    }
                } else {
                    dir.size += bytes
                    dir.fileCount += 1
                }

            default:
                continue
            }
        }
        reporter.update {
            $0.files += files
            $0.bytes += bytesSinceReport
        }
        return result
    }

    private func place(of path: String) -> LargeFile.Place {
        let home = Paths.home
        let relative: Substring
        if path.hasPrefix(home + "/") {
            relative = path.dropFirst(home.count + 1)
        } else if path.hasPrefix(StorageScanner.wholeDisk + home + "/") {
            relative = path.dropFirst(StorageScanner.wholeDisk.count + home.count + 1)
        } else {
            return .other
        }
        let top = relative.split(separator: "/").first.map(String.init) ?? ""
        switch top {
        case "Downloads": return .downloads
        case "Documents", "Desktop": return .documents
        case "Movies", "Music", "Pictures": return .media
        case "Library": return .appData
        default: return .other
        }
    }
}

@inline(__always)
private func date(_ spec: timespec) -> Date {
    Date(timeIntervalSince1970: TimeInterval(spec.tv_sec))
}

final class StorageReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var state = StorageProgress()
    private var lastSent = Date.distantPast
    private let sink: @Sendable (StorageProgress) -> Void

    init(_ sink: @escaping @Sendable (StorageProgress) -> Void) {
        self.sink = sink
    }

    func update(_ change: (inout StorageProgress) -> Void) {
        lock.lock()
        change(&state)
        let now = Date()
        let send = now.timeIntervalSince(lastSent) > 0.25
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

public enum FullDiskAccess {
    /// The TCC database can only be opened with Full Disk Access; trying doesn't prompt.
    public static var isGranted: Bool {
        let fd = open(NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
