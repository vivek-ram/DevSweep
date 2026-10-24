import Foundation

public struct VolumeSpace: Sendable, Equatable {
    public var total: Int64
    public var available: Int64
    public var used: Int64 { max(0, total - available) }
}

public enum DiskUsage {
    /// Bytes that removing `path` would free. Uses allocated blocks (like `du`), does not follow
    /// symlinks or cross volumes, and only counts a hard-linked file when every link to it lives
    /// inside `path` (pnpm and uv hard-link packages out of a shared store).
    public static func freeableBytes(at path: String) -> Int64 {
        var total: Int64 = 0
        var shared: [UInt64: (seen: Int, links: Int, bytes: Int64)] = [:]

        walk(path) { entry in
            guard let st = entry.pointee.fts_statp?.pointee else { return }
            let bytes = Int64(st.st_blocks) * 512
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                total += bytes
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if st.st_nlink > 1 {
                    let key = UInt64(st.st_ino)
                    var record = shared[key] ?? (0, Int(st.st_nlink), bytes)
                    record.seen += 1
                    shared[key] = record
                } else {
                    total += bytes
                }
            default:
                break
            }
        }
        for record in shared.values where record.seen >= record.links {
            total += record.bytes
        }
        return total
    }

    /// iCloud Drive and File Provider folders (Dropbox, Google Drive, OneDrive) keep files and
    /// folders "dataless" until opened. Listing them would download them; this makes listings of
    /// such folders fail fast instead, for the whole process.
    public static func avoidDownloadingCloudFiles() {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    public static func volumeSpace(for path: String = NSHomeDirectory()) -> VolumeSpace? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]), let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeSpace(total: Int64(total), available: available)
    }

    /// Like `walk`, but `visit` returns false for a directory whose contents should be skipped.
    static func walk(_ path: String, descending visit: (UnsafeMutablePointer<FTSENT>) -> Bool) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }
        var count = 0
        while let entry = fts_read(fts) {
            if !visit(entry), Int32(entry.pointee.fts_info) == FTS_D { fts_set(fts, entry, FTS_SKIP) }
            count += 1
            if count & 0xFFF == 0, Task.isCancelled { return }
        }
    }

    /// Physical, same-volume traversal of `path`. Stops early if the current task is cancelled.
    static func walk(_ path: String, _ visit: (UnsafeMutablePointer<FTSENT>) -> Void) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }
        var count = 0
        while let entry = fts_read(fts) {
            visit(entry)
            count += 1
            if count & 0xFFF == 0, Task.isCancelled { return }
        }
    }
}
