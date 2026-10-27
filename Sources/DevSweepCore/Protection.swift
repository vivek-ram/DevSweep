import Foundation

/// Folders DevSweep must never remove anything from: your "Never clean" list, and any folder
/// that holds a `.devsweep-keep` file (or sits inside one that does). Scans leave them out, and
/// every removal checks again just before it happens.
public enum Protection {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var neverClean: [String] = []

    /// Your "Never clean" list. The app sets it at launch and whenever it changes.
    public static var paths: [String] {
        get { lock.withLock { neverClean } }
        set { lock.withLock { neverClean = newValue.map(Paths.normalize) } }
    }

    /// Whether removing `path` would remove something protected: it is, or is inside, a
    /// protected folder, or it holds one.
    public static func isProtected(_ path: String) -> Bool {
        let path = Paths.normalize(path)
        if paths.contains(where: { Paths.isInside(path, $0) || Paths.isInside($0, path) }) { return true }
        var dir = path
        while dir.count > 1 {
            if FileManager.default.fileExists(atPath: dir + "/" + ArtifactRules.keepMarker) { return true }
            dir = Paths.parent(dir)
        }
        return false
    }

    public struct Refused: LocalizedError {
        public let path: String
        public var errorDescription: String? { "\(Paths.display(path)) is protected (Settings → Never clean), so it was left alone." }
    }
}
