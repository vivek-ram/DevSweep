import CryptoKit
import Foundation

public struct DuplicateFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let modified: Date

    public var name: String { (path as NSString).lastPathComponent }
    public var folderDisplayPath: String { Paths.display(Paths.parent(path)) }
}

/// Files with identical contents.
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let size: Int64
    public var files: [DuplicateFile]

    /// Space freed by keeping just one copy.
    public var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
}

public struct DuplicateProgress: Sendable, Equatable {
    public enum Phase: Sendable { case listing, comparing }
    public var phase: Phase = .listing
    public var filesSeen = 0
    public var candidates = 0
    public var hashed = 0
    public var currentPath = ""
    public init() {}
}

/// Finds identical files: same size, then same first/last 64 KB, then same SHA-256 of the whole
/// file. Hard links (one file, two names) and cloud-only files aren't reported.
public struct DuplicateFinder: Sendable {
    public var minimumSize: Int64 = 1_000_000

    public init(minimumSize: Int64 = 1_000_000) {
        self.minimumSize = minimumSize
    }

    /// Folders worth searching by default.
    public static func defaultFolders(home: String = NSHomeDirectory()) -> [String] {
        ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    private struct Candidate: Sendable {
        let path: String
        let size: Int64
        let modified: Date
    }

    public func find(in roots: [String], progress: @escaping @Sendable (DuplicateProgress) -> Void = { _ in }) async throws -> [DuplicateGroup] {
        DiskUsage.avoidDownloadingCloudFiles()
        var state = DuplicateProgress()
        var bySize: [Int64: [Candidate]] = [:]
        var seenInodes = Set<String>()
        var lastReport = Date.distantPast

        for root in ProjectScanner.minimalRoots(roots) {
            try list(root) { candidate, inode in
                guard seenInodes.insert(inode).inserted else { return }
                bySize[candidate.size, default: []].append(candidate)
                state.filesSeen += 1
                if Date().timeIntervalSince(lastReport) > 0.15 {
                    lastReport = Date()
                    state.currentPath = candidate.path
                    progress(state)
                }
            }
        }

        let sameSize = bySize.values.filter { $0.count > 1 }
        state.phase = .comparing
        state.candidates = sameSize.reduce(0) { $0 + $1.count }
        progress(state)

        // Partial hash first: most same-size files differ in their first or last bytes.
        let reporter = HashReporter(state: state, sink: progress)
        var narrowed: [[Candidate]] = []
        for group in sameSize {
            try Task.checkCancellation()
            let hashed = try await hashAll(group, reporter: reporter) { Self.partialHash($0.path, size: $0.size) }
            narrowed += Dictionary(grouping: hashed, by: \.1).values.filter { $0.count > 1 }.map { $0.map(\.0) }
        }

        var groups: [DuplicateGroup] = []
        for group in narrowed {
            try Task.checkCancellation()
            let hashed = try await hashAll(group, reporter: reporter) { Self.fullHash($0.path) }
            for (hash, members) in Dictionary(grouping: hashed, by: \.1) where members.count > 1 && !hash.isEmpty {
                let files = members.map { DuplicateFile(path: $0.0.path, modified: $0.0.modified) }
                groups.append(DuplicateGroup(id: hash, size: members[0].0.size, files: files))
            }
        }
        reporter.flush()
        return groups.sorted { $0.wasted > $1.wasted }
    }

    private func hashAll(_ group: [Candidate], reporter: HashReporter,
                         _ hash: @escaping @Sendable (Candidate) -> String) async throws -> [(Candidate, String)] {
        try await withThrowingTaskGroup(of: (Candidate, String).self) { tasks in
            var pending = group.makeIterator()
            func enqueue() {
                guard let next = pending.next() else { return }
                tasks.addTask {
                    try Task.checkCancellation()
                    return (next, hash(next))
                }
            }
            for _ in 0..<4 { enqueue() }
            var results: [(Candidate, String)] = []
            while let result = try await tasks.next() {
                results.append(result)
                reporter.hashed(result.0.path)
                enqueue()
            }
            return results.filter { !$0.1.isEmpty }
        }
    }

    /// Regular files of at least `minimumSize` under `root`, skipping hidden folders, app and
    /// photo-library bundles, rebuildable dev folders and files that only live in the cloud.
    private func list(_ root: String, _ visit: (Candidate, String) throws -> Void) throws {
        guard let cRoot = strdup(root) else { return }
        defer { free(cRoot) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }
        var count = 0
        while let entry = fts_read(fts) {
            count += 1
            if count & 0x3FF == 0 { try Task.checkCancellation() }
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                guard entry.pointee.fts_level > 0 else { continue }
                let path = String(cString: entry.pointee.fts_path)
                let name = (path as NSString).lastPathComponent
                if name.hasPrefix(".") || ArtifactRules.opaqueSuffixes.contains(where: { name.hasSuffix($0) })
                    || ArtifactRules.classify(name: name, path: path) != nil || name == "Library" && Paths.parent(path) == Paths.home {
                    fts_set(fts, entry, FTS_SKIP)
                }
            case FTS_F:
                guard let st = entry.pointee.fts_statp?.pointee else { continue }
                let size = Int64(st.st_size)
                // Dataless (cloud-only) files have far fewer blocks than bytes; reading them would download.
                guard size >= minimumSize, Int64(st.st_blocks) * 512 >= size / 2 else { continue }
                let path = String(cString: entry.pointee.fts_path)
                if (path as NSString).lastPathComponent.hasPrefix(".") { continue }
                try visit(Candidate(path: path, size: size, modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))),
                          "\(st.st_dev):\(st.st_ino)")
            default:
                continue
            }
        }
    }

    static func partialHash(_ path: String, size: Int64) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 64 * 1024
        guard let head = try? handle.read(upToCount: chunk) else { return "" }
        hasher.update(data: head)
        if size > Int64(chunk * 2) {
            try? handle.seek(toOffset: UInt64(size) - UInt64(chunk))
            guard let tail = try? handle.read(upToCount: chunk) else { return "" }
            hasher.update(data: tail)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done = autoreleasepool { () -> Bool in
                guard let data = try? handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if done { break }
            if Task.isCancelled { return "" }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies to suggest removing: all but the keeper, except copies inside a code project
    /// (a data file copied between project versions is usually needed by each of them).
    public static func suggestedRemovals(_ group: DuplicateGroup, home: String = NSHomeDirectory()) -> [String] {
        let keeper = suggestedKeeper(group, home: home)
        return group.files.map(\.path).filter { $0 != keeper && !isInsideProject($0, home: home) }
    }

    static func isInsideProject(_ path: String, home: String) -> Bool {
        var dir = Paths.parent(path)
        while dir.count > home.count, dir.hasPrefix(home + "/") {
            if FolderSuggestions.isProject(dir) { return true }
            dir = Paths.parent(dir)
        }
        return false
    }

    /// Which copy to keep: one outside Downloads if possible, then the oldest (likely the
    /// original), then the one with the shortest path.
    public static func suggestedKeeper(_ group: DuplicateGroup, home: String = NSHomeDirectory()) -> String {
        func rank(_ file: DuplicateFile) -> (Int, Date, Int) {
            let inDownloads = Paths.isInside(file.path, home + "/Downloads") ? 1 : 0
            return (inDownloads, file.modified, file.path.count)
        }
        return group.files.min { rank($0) < rank($1) }?.path ?? group.files[0].path
    }
}

private final class HashReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var state: DuplicateProgress
    private var lastSent = Date.distantPast
    private let sink: @Sendable (DuplicateProgress) -> Void

    init(state: DuplicateProgress, sink: @escaping @Sendable (DuplicateProgress) -> Void) {
        self.state = state
        self.sink = sink
    }

    func hashed(_ path: String) {
        lock.lock()
        state.hashed += 1
        state.currentPath = path
        let send = Date().timeIntervalSince(lastSent) > 0.15
        if send { lastSent = Date() }
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

