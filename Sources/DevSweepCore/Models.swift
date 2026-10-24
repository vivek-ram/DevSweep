import Foundation

/// A regenerable folder inside a project (a venv, node_modules, target/, …).
public struct Artifact: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let kind: ArtifactKind
    /// Bytes that would actually be freed by removing the folder.
    public var bytes: Int64
    /// Modification date of the folder itself (changes when deps are installed or a build runs).
    public var modified: Date

    public init(path: String, kind: ArtifactKind, bytes: Int64 = 0, modified: Date) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.modified = modified
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// A folder of code that owns one or more artifacts.
public struct Project: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    /// The scan folder this project was found in.
    public let root: String
    public var artifacts: [Artifact]
    /// Newest change to the project's own files (regenerable folders excluded).
    public var lastEdited: Date?
    /// Last time the project was opened in an editor we know about.
    public var lastOpened: Date?
    /// Which editor `lastOpened` came from.
    public var openedWith: String?
    /// Newest change to one of the artifact folders (an install or a build).
    public var lastBuilt: Date?
    public var isGitRepo: Bool
    /// The project (or a folder above it) contains a `.devsweep-keep` file.
    public var hasKeepMarker: Bool

    public init(path: String, root: String, artifacts: [Artifact], lastEdited: Date? = nil, lastOpened: Date? = nil,
                openedWith: String? = nil, lastBuilt: Date? = nil, isGitRepo: Bool = false, hasKeepMarker: Bool = false) {
        self.path = path
        self.root = root
        self.artifacts = artifacts
        self.lastEdited = lastEdited
        self.lastOpened = lastOpened
        self.openedWith = openedWith
        self.lastBuilt = lastBuilt
        self.isGitRepo = isGitRepo
        self.hasKeepMarker = hasKeepMarker
    }

    public var name: String { (path as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces) }

    public var displayPath: String { Paths.abbreviate(path) }

    public var lastActivity: Date {
        [lastEdited, lastOpened, lastBuilt].compactMap { $0 }.max() ?? .distantPast
    }

    public var totalBytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }

    public var ecosystems: [Ecosystem] {
        var seen: [Ecosystem] = []
        for a in artifacts.sorted(by: { $0.bytes > $1.bytes }) where !seen.contains(a.kind.ecosystem) {
            seen.append(a.kind.ecosystem)
        }
        return seen
    }

    public func relativePath(of artifact: Artifact) -> String { relativePath(artifact.path) }

    public func relativePath(_ child: String) -> String {
        child.hasPrefix(path + "/") ? String(child.dropFirst(path.count + 1)) : child
    }
}

public struct ScanResult: Codable, Sendable {
    public var projects: [Project]
    public var roots: [String]
    public var date: Date
    public var duration: TimeInterval
    public var foldersVisited: Int

    public init(projects: [Project], roots: [String], date: Date, duration: TimeInterval, foldersVisited: Int) {
        self.projects = projects
        self.roots = roots
        self.date = date
        self.duration = duration
        self.foldersVisited = foldersVisited
    }
}

public enum ProjectStatus: Hashable, Sendable {
    case protected
    case active(staleInDays: Int)
    case stale(idleDays: Int)

    public var isStale: Bool { if case .stale = self { true } else { false } }

    /// Sort key: stale first, then soonest-to-be-stale, protected last.
    public var rank: Int {
        switch self {
        case .stale(let idle): -idle
        case .active(let days): 100_000 + days
        case .protected: 1_000_000
        }
    }
}

public struct RetentionPolicy: Codable, Hashable, Sendable {
    /// Projects untouched for this many days are cleaned.
    public var days: Int
    public var enabledKinds: Set<ArtifactKind>
    public var protectedPaths: Set<String>
    /// Halve the retention period while the disk is nearly full.
    public var lowSpaceBoost: Bool
    public var lowSpaceThreshold: Int64

    public init(days: Int = 30, enabledKinds: Set<ArtifactKind> = Set(ArtifactKind.allCases),
                protectedPaths: Set<String> = [], lowSpaceBoost: Bool = true,
                lowSpaceThreshold: Int64 = 20_000_000_000) {
        self.days = days
        self.enabledKinds = enabledKinds
        self.protectedPaths = protectedPaths
        self.lowSpaceBoost = lowSpaceBoost
        self.lowSpaceThreshold = lowSpaceThreshold
    }

    public func effectiveDays(freeBytes: Int64?) -> Int {
        if lowSpaceBoost, let free = freeBytes, free < lowSpaceThreshold {
            return max(7, days / 2)
        }
        return days
    }

    public func isProtected(_ project: Project) -> Bool {
        project.hasKeepMarker || protectedPaths.contains { project.path == $0 || project.path.hasPrefix($0 + "/") }
    }

    public func status(of project: Project, now: Date = Date(), freeBytes: Int64? = nil) -> ProjectStatus {
        if isProtected(project) { return .protected }
        let idleDays = Int(now.timeIntervalSince(project.lastActivity) / 86_400)
        let limit = effectiveDays(freeBytes: freeBytes)
        return idleDays >= limit ? .stale(idleDays: idleDays) : .active(staleInDays: limit - idleDays)
    }

    public func cleanableArtifacts(of project: Project) -> [Artifact] {
        project.artifacts.filter { enabledKinds.contains($0.kind) }
    }

    public func cleanableBytes(of project: Project) -> Int64 {
        cleanableArtifacts(of: project).reduce(0) { $0 + $1.bytes }
    }
}

public enum RemovalMode: String, Codable, CaseIterable, Sendable {
    case trash
    case permanent
}

/// One entry in the cleanup history.
public struct CleanupRecord: Identifiable, Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case removed
        case skipped
        case failed
    }

    public var id = UUID()
    public var date: Date
    public var projectPath: String
    public var itemPath: String
    /// `ArtifactKind.rawValue`, or `cache:<id>` for a global cache.
    public var kind: String
    public var bytes: Int64
    public var mode: RemovalMode
    public var outcome: Outcome
    public var message: String?
    /// Where the item went when moved to the Trash.
    public var trashPath: String?
    /// The requirements / version snapshot written before removal.
    public var snapshotPath: String?
    public var automatic: Bool

    public init(date: Date = Date(), projectPath: String, itemPath: String, kind: String, bytes: Int64,
                mode: RemovalMode, outcome: Outcome, message: String? = nil, trashPath: String? = nil,
                snapshotPath: String? = nil, automatic: Bool = false) {
        self.date = date
        self.projectPath = projectPath
        self.itemPath = itemPath
        self.kind = kind
        self.bytes = bytes
        self.mode = mode
        self.outcome = outcome
        self.message = message
        self.trashPath = trashPath
        self.snapshotPath = snapshotPath
        self.automatic = automatic
    }

    public var artifactKind: ArtifactKind? { ArtifactKind(rawValue: kind) }
    public var isCache: Bool { kind.hasPrefix("cache:") }
}

public enum Paths {
    public static let home = NSHomeDirectory()

    public static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// For display: paths on the data volume shown as their usual location, home as ~.
    public static func display(_ path: String) -> String {
        let prefix = "/System/Volumes/Data"
        if path.hasPrefix(prefix + "/") { return abbreviate(String(path.dropFirst(prefix.count))) }
        return abbreviate(path)
    }

    /// Standardised absolute path without a trailing slash.
    public static func normalize(_ path: String) -> String {
        var p = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    @inline(__always)
    public static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    public static func isInside(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }
}

public enum Format {
    public static func bytes(_ count: Int64) -> String {
        count == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    public static func days(_ n: Int) -> String {
        n == 1 ? "1 day" : "\(n) days"
    }

    public static func idle(since date: Date, now: Date = Date()) -> String {
        if date == .distantPast { return "Unknown" }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2..<31: return "\(days) days ago"
        case 31..<365:
            let months = days / 30
            return months <= 1 ? "1 month ago" : "\(months) months ago"
        default:
            let years = days / 365
            return years == 1 ? "1 year ago" : "\(years) years ago"
        }
    }
}
