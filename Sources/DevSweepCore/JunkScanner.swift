import Foundation

public enum JunkCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case appCaches, aiClutter, logs, brokenPreferences, installers, deviceUpdates, deviceBackups, mailAttachments, archives, trash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appCaches: "App caches"
        case .aiClutter: "AI clutter"
        case .logs: "Logs & crash reports"
        case .brokenPreferences: "Broken preferences"
        case .deviceBackups: "iPhone & iPad backups"
        case .mailAttachments: "Mail attachments"
        case .installers: "Installers in Downloads"
        case .deviceUpdates: "iPhone & iPad updates"
        case .archives: "Archives in Downloads"
        case .trash: "Trash"
        }
    }

    public var detail: String {
        switch self {
        case .appCaches: "Files apps keep to load faster. Only caches DevSweep knows the app rebuilds are ticked."
        case .aiClutter: "Caches and logs left by AI apps and command-line tools. Your chats and projects aren't touched."
        case .logs: "Diagnostic logs and crash reports apps have written."
        case .brokenPreferences: "Settings files that can't be read anymore. The app makes a fresh one next time it starts."
        case .deviceBackups: "Full backups of your iPhone or iPad. Keep the latest one for each device."
        case .mailAttachments: "Copies of attachments Mail saved when you opened them. They stay in your mailbox."
        case .installers: "Disk images and packages you've probably already installed."
        case .deviceUpdates: "Downloaded iOS and iPadOS update files."
        case .archives: "Zip and other archives you downloaded. Check before removing — they may be the only copy."
        case .trash: "Files already in your Trash. Emptying it deletes them for good."
        }
    }

    public var icon: String {
        switch self {
        case .appCaches: "square.stack.3d.up.fill"
        case .aiClutter: "brain.head.profile"
        case .logs: "doc.text.fill"
        case .brokenPreferences: "gearshape.2.fill"
        case .deviceBackups: "externaldrive.fill.badge.timemachine"
        case .mailAttachments: "paperclip"
        case .installers: "shippingbox.fill"
        case .deviceUpdates: "iphone"
        case .archives: "doc.zipper"
        case .trash: "trash.fill"
        }
    }
}

public struct JunkItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let category: JunkCategory
    public let path: String
    public let bytes: Int64
    public let modified: Date
    /// Ticked when the review opens.
    public var suggested: Bool
    /// A friendlier name than the file name ("Cursor · Code Cache", "Alex's iPhone").
    public var label: String? = nil
    /// Shown when removing it has a cost.
    public var caution: String? = nil
    /// Why it isn't ticked, when that's not obvious.
    public var note: String? = nil

    public var name: String { (path as NSString).lastPathComponent }
}

/// Finds files macOS and apps leave behind that are safe to clear.
public enum JunkScanner {
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "img"]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z"]
    /// Apple's own caches (iCloud, Siri, Maps, …) and anything on the Developer Caches page.
    static let keptCacheNames: Set<String> = ["CloudKit", "FamilyCircle", "GeoServices", "PassKit", "com.apple.bird"]

    /// Blocking; measures every item (in parallel). Reading Downloads can make macOS ask the
    /// user for permission (and wait for the answer), so it can be left out. Protected folders
    /// (see Protection) aren't listed.
    public static func scan(home: String = NSHomeDirectory(), now: Date = Date(), includeDownloads: Bool = true) -> [JunkItem] {
        DiskUsage.avoidDownloadingCloudFiles()
        let fm = FileManager.default
        let devCaches = CacheCatalog.knownPaths(home: home)
        var candidates: [(category: JunkCategory, path: String, suggested: Bool)] = []

        let caches = home + "/Library/Caches"
        for name in (try? fm.contentsOfDirectory(atPath: caches)) ?? [] where isClearableCache(name, path: caches + "/" + name, devCaches: devCaches) {
            candidates.append((.appCaches, caches + "/" + name, true))
        }
        let logs = home + "/Library/Logs"
        for name in (try? fm.contentsOfDirectory(atPath: logs)) ?? [] where !name.hasPrefix(".") {
            candidates.append((.logs, logs + "/" + name, true))
        }
        for name in ["iPhone Software Updates", "iPad Software Updates", "iPod Software Updates"] {
            let dir = home + "/Library/iTunes/" + name
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".ipsw") {
                candidates.append((.deviceUpdates, dir + "/" + file, true))
            }
        }
        for path in includeDownloads ? downloadsFiles(home: home) : [] {
            let ext = (path as NSString).pathExtension.lowercased()
            let age = now.timeIntervalSince(modificationDate(path) ?? now)
            if installerExtensions.contains(ext) {
                candidates.append((.installers, path, age > 14 * 86_400))
            } else if archiveExtensions.contains(ext) {
                candidates.append((.archives, path, false))
            }
        }
        // The Trash can only be read with Full Disk Access.
        let trash = home + "/.Trash"
        if (try? fm.contentsOfDirectory(atPath: trash)) != nil {
            candidates.append((.trash, trash, false))
        }
        // External drives keep their own Trash per user.
        for volume in externalTrashes() {
            candidates.append((.trash, volume, false))
        }
        for (path, _) in aiClutterFolders(home: home) {
            candidates.append((.aiClutter, path, true))
        }
        for path in brokenPreferences(home: home) {
            candidates.append((.brokenPreferences, path, true))
        }
        let mailDownloads = home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
        if (try? fm.contentsOfDirectory(atPath: mailDownloads)) != nil {
            candidates.append((.mailAttachments, mailDownloads, true))
        }
        let backups = deviceBackups(home: home)
        for backup in backups {
            candidates.append((.deviceBackups, backup.path, false))
        }
        let deviceLogs = home + "/Library/Developer/Xcode/iOS Device Logs"
        if fm.fileExists(atPath: deviceLogs) {
            candidates.append((.logs, deviceLogs, true))
        }
        candidates.removeAll { Protection.isProtected($0.path) }
        let aiLabels = Dictionary(uniqueKeysWithValues: aiClutterFolders(home: home))
        let backupInfo = Dictionary(uniqueKeysWithValues: backups.map { ($0.path, $0) })

        var results = [JunkItem?](repeating: nil, count: candidates.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let candidate = candidates[i]
            var st = stat()
            guard lstat(candidate.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            let bytes = isDir ? DiskUsage.freeableBytes(at: candidate.path) : Int64(st.st_blocks) * 512
            guard bytes >= (candidate.category == .brokenPreferences ? 0 : 100_000) else { return }
            var item = JunkItem(category: candidate.category, path: candidate.path, bytes: bytes,
                                modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                                suggested: candidate.suggested)
            if candidate.category == .appCaches {
                switch CacheSafety.verdict(name: item.name, path: candidate.path) {
                case .known: break
                case .yourApp: return
                case .unknown:
                    item.suggested = false
                    item.note = "Not ticked: DevSweep doesn't know whether this app can rebuild what it keeps here."
                case .holdsMedia(let count):
                    item.suggested = false
                    item.caution = "Holds \(count) pictures, videos or sounds. Some apps keep artwork or downloads in their cache."
                }
            }
            if candidate.category == .aiClutter { item.label = aiLabels[candidate.path] }
            if candidate.category == .trash, candidate.path.hasPrefix("/Volumes/") {
                item.label = "Trash on " + (candidate.path.split(separator: "/").dropFirst().first.map(String.init) ?? "drive")
            }
            if let backup = backupInfo[candidate.path] {
                item.label = backup.label
                item.caution = backup.isLatest ? "This is the most recent backup of this device. Without it you can't restore the device to how it is now." : nil
            }
            lock.lock()
            results[i] = item
            lock.unlock()
        }
        return results.compactMap { $0 }.sorted { $0.bytes > $1.bytes }
    }

    static func isClearableCache(_ name: String, path: String, devCaches: Set<String>) -> Bool {
        !name.hasPrefix(".") && !name.hasPrefix("com.apple.") && !keptCacheNames.contains(name) && !devCaches.contains(path)
    }

    /// Files at the top of Downloads and one folder down.
    static func downloadsFiles(home: String) -> [String] {
        let fm = FileManager.default
        let downloads = home + "/Downloads"
        var result: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: downloads)) ?? [] where !name.hasPrefix(".") {
            let path = downloads + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                result.append(path)
            } else if !(name as NSString).pathExtension.isEmpty || FolderSuggestions.isProject(path) {
                continue   // bundles and code folders are left alone
            } else {
                for inner in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where !inner.hasPrefix(".") {
                    let innerPath = path + "/" + inner
                    var innerIsDir: ObjCBool = false
                    if fm.fileExists(atPath: innerPath, isDirectory: &innerIsDir), !innerIsDir.boolValue { result.append(innerPath) }
                }
            }
        }
        return result
    }

    /// AI apps built on Electron keep big, disposable browser caches. Only those folders are listed;
    /// chats, settings, projects and models stay.
    static let aiApps: [(folder: String, name: String)] = [
        ("Claude", "Claude"), ("Cursor", "Cursor"), ("Windsurf", "Windsurf"), ("ChatGPT", "ChatGPT"),
        ("Perplexity", "Perplexity"), ("Msty", "Msty"), ("Jan", "Jan"), ("LM Studio", "LM Studio"), ("Ollama", "Ollama"),
    ]
    static let electronCacheFolders: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs", "DawnCache", "DawnGraphiteCache",
        "DawnWebGPUCache", "ShaderCache", "GrShaderCache", "logs",
    ]
    /// Command-line AI tools: (folder under home, label).
    static let aiToolFolders: [(relative: String, name: String)] = [
        (".codex/log", "Codex · Logs"), (".gemini/tmp", "Gemini CLI · Temporary files"), (".cursor/logs", "Cursor · Logs"),
    ]

    static func aiClutterFolders(home: String) -> [(String, String)] {
        var found: [(String, String)] = []
        let support = home + "/Library/Application Support"
        for (folder, name) in aiApps {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: support + "/" + folder)) ?? [] where electronCacheFolders.contains(entry) {
                found.append((support + "/" + folder + "/" + entry, "\(name) · \(entry == "logs" ? "Logs" : entry)"))
            }
        }
        for (relative, name) in aiToolFolders where FileManager.default.fileExists(atPath: home + "/" + relative) {
            found.append((home + "/" + relative, name))
        }
        return found
    }

    /// Preference files in ~/Library/Preferences that macOS can no longer read. Apple's are left alone.
    static func brokenPreferences(home: String) -> [String] {
        let dir = home + "/Library/Preferences"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).compactMap { name in
            guard name.hasSuffix(".plist"), !name.hasPrefix("com.apple."), !name.hasPrefix(".") else { return nil }
            let path = dir + "/" + name
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            if data.isEmpty { return path }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil ? path : nil
        }
    }

    struct Backup {
        let path: String
        let label: String
        let isLatest: Bool
    }

    /// iPhone and iPad backups (readable with Full Disk Access), newest per device marked.
    static func deviceBackups(home: String) -> [Backup] {
        let root = home + "/Library/Application Support/MobileSync/Backup"
        var entries: [(path: String, device: String, date: Date)] = []
        for id in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where !id.hasPrefix(".") {
            let path = root + "/" + id
            let info = FileManager.default.contents(atPath: path + "/Info.plist")
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
            let device = info["Device Name"] as? String ?? info["Display Name"] as? String ?? "Unknown device"
            let date = info["Last Backup Date"] as? Date ?? modificationDate(path) ?? .distantPast
            entries.append((path, device, date))
        }
        let newest = Dictionary(grouping: entries, by: \.device).compactMapValues { $0.max { $0.date < $1.date }?.path }
        return entries.map { entry in
            Backup(path: entry.path, label: "\(entry.device) · \(entry.date.formatted(date: .abbreviated, time: .omitted))",
                   isLatest: newest[entry.device] == entry.path)
        }
    }

    /// /Volumes/<drive>/.Trashes/<uid> on mounted drives that have one.
    static func externalTrashes() -> [String] {
        let uid = getuid()
        return ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []).compactMap { volume in
            let path = "/Volumes/\(volume)/.Trashes/\(uid)"
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
                  ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).contains(where: { !$0.hasPrefix(".") }) else { return nil }
            return path
        }
    }

    /// Re-checks right before removal that `item` still is what the scan said it was.
    public static func validate(_ item: JunkItem, home: String = NSHomeDirectory()) -> String? {
        var st = stat()
        guard lstat(item.path, &st) == 0 else { return "No longer exists" }
        if (st.st_mode & S_IFMT) == S_IFLNK { return "Is a symbolic link" }
        let parent = Paths.parent(item.path)
        let ext = (item.path as NSString).pathExtension.lowercased()
        let downloads = home + "/Downloads"
        let ok: Bool
        switch item.category {
        case .appCaches:
            ok = parent == home + "/Library/Caches"
                && isClearableCache(item.name, path: item.path, devCaches: CacheCatalog.knownPaths(home: home))
        case .logs:
            ok = parent == home + "/Library/Logs" || item.path == home + "/Library/Developer/Xcode/iOS Device Logs"
        case .aiClutter:
            ok = aiClutterFolders(home: home).contains { $0.0 == item.path }
        case .brokenPreferences:
            ok = parent == home + "/Library/Preferences" && item.name.hasSuffix(".plist") && !item.name.hasPrefix("com.apple.")
                && (st.st_mode & S_IFMT) == S_IFREG
        case .deviceBackups:
            ok = parent == home + "/Library/Application Support/MobileSync/Backup"
        case .mailAttachments:
            ok = item.path == home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
        case .deviceUpdates:
            ok = Paths.parent(parent) == home + "/Library/iTunes" && ext == "ipsw"
        case .installers, .archives:
            let extensions = item.category == .installers ? installerExtensions : archiveExtensions
            ok = (parent == downloads || Paths.parent(parent) == downloads) && extensions.contains(ext)
                && (st.st_mode & S_IFMT) == S_IFREG
        case .trash:
            ok = item.path == home + "/.Trash" || externalTrashes().contains(item.path)
        }
        return ok ? nil : "Not a recognised junk location"
    }
}

/// Which items in the storage map and large-files list may be moved to the Trash.
public enum RemovalRules {
    /// Why `path` must not be removed by hand from the storage map, or nil if it may.
    public static func problem(removing path: String, home: String = NSHomeDirectory()) -> String? {
        var path = path
        if path.hasPrefix(StorageScanner.wholeDisk + "/") { path = String(path.dropFirst(StorageScanner.wholeDisk.count)) }
        if path.contains("/../") { return "Invalid path" }
        if path.hasPrefix("/Applications/"), Paths.parent(path) == "/Applications", path.hasSuffix(".app") { return nil }
        guard path.hasPrefix(home + "/") else { return "Only items in your home folder (or apps in /Applications) can be removed here." }
        let relative = path.dropFirst(home.count + 1).split(separator: "/")
        if relative.count < 2 { return "\(relative.first ?? "") is a standard folder of your account." }
        if relative.first == "Library", relative.count < 3 { return "This is a system folder of your account." }
        return nil
    }

    /// Folders of app data where removing things can reset or break the app.
    public static func isAppData(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        Paths.isInside(path, home + "/Library") || Paths.isInside(path, StorageScanner.wholeDisk + home + "/Library")
    }
}
