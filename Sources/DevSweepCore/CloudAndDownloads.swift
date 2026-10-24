import CoreServices
import Foundation

// MARK: Cloud

public enum CloudProvider: String, CaseIterable, Sendable, Identifiable {
    case iCloud, dropbox, googleDrive, oneDrive, box, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .iCloud: "iCloud Drive"
        case .dropbox: "Dropbox"
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        case .box: "Box"
        case .other: "Cloud storage"
        }
    }

    public var symbol: String {
        switch self {
        case .iCloud: "icloud.fill"
        case .dropbox: "shippingbox.fill"
        case .googleDrive: "externaldrive.fill.badge.icloud"
        case .oneDrive: "cloud.fill"
        case .box: "cube.fill"
        case .other: "cloud.fill"
        }
    }

    static func from(folderName name: String) -> CloudProvider {
        let lower = name.lowercased()
        if lower.hasPrefix("dropbox") { return .dropbox }
        if lower.hasPrefix("googledrive") { return .googleDrive }
        if lower.hasPrefix("onedrive") { return .oneDrive }
        if lower.hasPrefix("box") { return .box }
        return .other
    }
}

/// A cloud file that's also downloaded on this Mac.
public struct CloudFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let provider: CloudProvider
    /// Space the local copy takes.
    public let bytes: Int64
    public let modified: Date
    public let lastOpened: Date?

    public var name: String { (path as NSString).lastPathComponent }
    public var folderDisplayPath: String { Paths.display(Paths.parent(path)) }
}

public struct CloudLocation: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let provider: CloudProvider
    public let path: String
    public let account: String?
}

public enum CloudCleanup {
    /// iCloud Drive and the File Provider folders in ~/Library/CloudStorage.
    public static func locations(home: String = NSHomeDirectory()) -> [CloudLocation] {
        var found: [CloudLocation] = []
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: iCloud) {
            found.append(CloudLocation(provider: .iCloud, path: iCloud, account: nil))
        }
        let storage = home + "/Library/CloudStorage"
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: storage)) ?? [] where !entry.hasPrefix(".") {
            let account = entry.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
            found.append(CloudLocation(provider: CloudProvider.from(folderName: entry), path: storage + "/" + entry, account: account))
        }
        return found
    }

    /// Downloaded files of at least `minimumSize`. Files that only live in the cloud take no
    /// space and aren't listed; nothing is downloaded to check.
    public static func localCopies(in location: CloudLocation, minimumSize: Int64 = 5_000_000) throws -> [CloudFile] {
        DiskUsage.avoidDownloadingCloudFiles()
        var files: [CloudFile] = []
        DiskUsage.walk(location.path) { entry in
            guard Int32(entry.pointee.fts_info) == FTS_F, let st = entry.pointee.fts_statp?.pointee else { return }
            let allocated = Int64(st.st_blocks) * 512
            guard allocated >= minimumSize else { return }
            let path = String(cString: entry.pointee.fts_path)
            if (path as NSString).lastPathComponent.hasPrefix(".") { return }
            files.append(CloudFile(path: path, provider: location.provider, bytes: allocated,
                                   modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                                   lastOpened: lastUsed(path)))
        }
        try Task.checkCancellation()
        return files.sorted { $0.bytes > $1.bytes }
    }

    /// Frees the local copy; the file stays in the cloud and downloads again when opened.
    public static func removeLocalCopy(_ file: CloudFile) -> CleanupRecord {
        var record = CleanupRecord(projectPath: Paths.parent(file.path), itemPath: file.path, kind: "cloud:\(file.provider.rawValue)",
                                   bytes: file.bytes, mode: .permanent, outcome: .removed)
        guard locations().contains(where: { Paths.isInside(file.path, $0.path) }) else {
            record.outcome = .skipped
            record.message = "Not in a cloud folder"
            return record
        }
        do {
            try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: file.path))
            record.message = "Still in \(file.provider.title)"
        } catch {
            record.outcome = .failed
            record.message = file.provider == .iCloud
                ? "iCloud didn't release it yet (it may still be uploading)."
                : "\(file.provider.title) didn't allow it. Use \u{201C}Remove Download\u{201D} in Finder instead."
        }
        return record
    }

    static func lastUsed(_ path: String) -> Date? {
        Spotlight.date(path, kMDItemLastUsedDate)
    }
}

// MARK: Downloads

/// A file or folder in Downloads with where it came from.
public struct DownloadItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    /// The app that downloaded it (Safari, Google Chrome, Slack…) or the website.
    public let source: String
    public let website: String?
    public let added: Date
    public let lastOpened: Date?
    public let isFolder: Bool

    public var name: String { (path as NSString).lastPathComponent }
}

public enum DownloadsAnalyzer {
    /// Top-level items in Downloads. Folders holding code projects (or the folders DevSweep
    /// scans for projects) are left out.
    public static func scan(home: String = NSHomeDirectory(), excluding: [String] = []) -> [DownloadItem] {
        DiskUsage.avoidDownloadingCloudFiles()
        let downloads = home + "/Downloads"
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: downloads)) ?? []).filter { !$0.hasPrefix(".") }
        var results = [DownloadItem?](repeating: nil, count: entries.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: entries.count) { i in
            let path = downloads + "/" + entries[i]
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return }
            let isFolder = (st.st_mode & S_IFMT) == S_IFDIR && !entries[i].hasSuffix(".app")
            if isFolder {
                if excluding.contains(where: { Paths.isInside($0, path) || Paths.isInside(path, $0) }) { return }
                if FolderSuggestions.isProject(path) || FolderSuggestions.projectChildren(of: path) > 0 { return }
            }
            let bytes = (st.st_mode & S_IFMT) == S_IFDIR ? DiskUsage.freeableBytes(at: path) : Int64(st.st_blocks) * 512
            let origin = origin(of: path)
            let item = DownloadItem(path: path, bytes: bytes, source: origin.app ?? origin.website ?? "Unknown",
                                    website: origin.website,
                                    added: dateAdded(path) ?? Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec)),
                                    lastOpened: CloudCleanup.lastUsed(path), isFolder: isFolder)
            lock.lock()
            results[i] = item
            lock.unlock()
        }
        return results.compactMap { $0 }.sorted { $0.bytes > $1.bytes }
    }

    /// The downloading app (from the quarantine flag) and site (from "Where from").
    static func origin(of path: String) -> (app: String?, website: String?) {
        var app: String?
        if let quarantine = xattr(path, "com.apple.quarantine").flatMap({ String(data: $0, encoding: .utf8) }) {
            // flags;timestamp;agent;uuid
            let parts = quarantine.split(separator: ";", omittingEmptySubsequences: false)
            if parts.count >= 3, !parts[2].isEmpty { app = String(parts[2]) }
        }
        var website: String?
        if let data = xattr(path, "com.apple.metadata:kMDItemWhereFroms"),
           let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            website = list.compactMap { URL(string: $0)?.host }.first.map { $0.replacingOccurrences(of: "www.", with: "") }
        }
        return (app, website)
    }

    static func dateAdded(_ path: String) -> Date? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
            ?? Spotlight.date(path, kMDItemDateAdded)
    }

    static func xattr(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read > 0 ? data.prefix(read) : nil
    }
}

// MARK: Drives

public struct MountedVolume: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let total: Int64
    public let available: Int64
    public let ejectable: Bool

    public var used: Int64 { max(0, total - available) }
}

public enum Volumes {
    #if DEBUG
    /// Drives to show instead of the real ones (demo screenshots).
    nonisolated(unsafe) public static var demo: [MountedVolume]?
    #endif

    /// External and disk-image volumes (not the startup disk).
    public static func external() -> [MountedVolume] {
        #if DEBUG
        if let demo { return demo }
        #endif
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsEjectableKey,
                                      .volumeIsRemovableKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsRootFileSystem != true,
                  url.path.hasPrefix("/Volumes/") else { return nil }
            return MountedVolume(path: url.path, name: values.volumeName ?? url.lastPathComponent,
                                 total: Int64(values.volumeTotalCapacity ?? 0), available: Int64(values.volumeAvailableCapacity ?? 0),
                                 ejectable: values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false)
        }
    }
}
