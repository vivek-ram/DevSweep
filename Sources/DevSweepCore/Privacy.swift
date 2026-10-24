import Foundation
import SQLite3

/// A browser whose local data can be cleared.
public enum Browser: String, CaseIterable, Codable, Sendable, Identifiable {
    case safari, chrome, edge, brave, arc, vivaldi, opera, firefox

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .arc: "Arc"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .firefox: "Firefox"
        }
    }

    public var bundleIDs: [String] {
        switch self {
        case .safari: ["com.apple.Safari"]
        case .chrome: ["com.google.Chrome"]
        case .edge: ["com.microsoft.edgemac"]
        case .brave: ["com.brave.Browser"]
        case .arc: ["company.thebrowser.Browser"]
        case .vivaldi: ["com.vivaldi.Vivaldi"]
        case .opera: ["com.operasoftware.Opera"]
        case .firefox: ["org.mozilla.firefox"]
        }
    }

    /// Where Chromium-based browsers keep their profiles, under Application Support.
    var chromiumRoot: String? {
        switch self {
        case .chrome: "Google/Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "BraveSoftware/Brave-Browser"
        case .arc: "Arc/User Data"
        case .vivaldi: "Vivaldi"
        case .opera: "com.operasoftware.Opera"
        case .safari, .firefox: nil
        }
    }
}

/// Kinds of browsing traces.
public enum PrivacyKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case history, cookies, sessions, siteData, autofill

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .history: "Browsing & download history"
        case .cookies: "Cookies"
        case .sessions: "Tabs from last session"
        case .siteData: "Website data"
        case .autofill: "Autofill form entries"
        }
    }

    public var detail: String {
        switch self {
        case .history: "Pages you visited, searches you typed and files you downloaded."
        case .cookies: "Signs you out of websites."
        case .sessions: "The tabs the browser would reopen."
        case .siteData: "Local storage and offline data of web apps. Signs you out of some."
        case .autofill: "Things you typed into web forms. Saved passwords and cards are kept."
        }
    }

    /// Ticked when the review opens.
    public var suggested: Bool { self == .history || self == .sessions }
}

public struct PrivacyItem: Identifiable, Hashable, Sendable {
    public var id: String { "\(browser.rawValue)|\(profile)|\(kind.rawValue)" }
    public let browser: Browser
    /// Profile folder (several Chromium/Firefox profiles can exist).
    public let profile: String
    public let profileName: String
    public let kind: PrivacyKind
    /// Files and folders that hold this kind of data (moved to the Trash).
    public let paths: [String]
    /// For data stored inside a shared database: the database and the SQL that clears it.
    public let database: String?
    public let bytes: Int64
}

/// A "recent items" list macOS keeps (Apple menu → Recent Items).
public struct RecentItemsList: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let title: String
    public let path: String
}

public enum PrivacyScanner {
    /// Every clearable trace in installed browsers' profiles. Safari needs Full Disk Access.
    public static func scan(home: String = NSHomeDirectory()) -> [PrivacyItem] {
        var items: [PrivacyItem] = []
        let support = home + "/Library/Application Support"
        for browser in Browser.allCases {
            if let root = browser.chromiumRoot {
                for (profile, name) in chromiumProfiles(support + "/" + root, browser: browser) {
                    items += chromiumItems(browser, profile: profile, name: name)
                }
            }
        }
        for (profile, name) in firefoxProfiles(support + "/Firefox") {
            items += firefoxItems(profile: profile, name: name)
        }
        items += safariItems(home: home)
        return items.filter { $0.bytes > 0 }
    }

    static func chromiumProfiles(_ root: String, browser: Browser) -> [(String, String)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        if browser == .opera { return [(root, "Default")] }
        // Profile display names live in "Local State".
        let localState = fm.contents(atPath: root + "/Local State")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let infoCache = ((localState?["profile"] as? [String: Any])?["info_cache"] as? [String: Any]) ?? [:]
        return ((try? fm.contentsOfDirectory(atPath: root)) ?? []).compactMap { entry in
            guard entry == "Default" || entry.hasPrefix("Profile ") else { return nil }
            let name = (infoCache[entry] as? [String: Any])?["name"] as? String ?? entry
            return (root + "/" + entry, name)
        }.sorted { $0.0 < $1.0 }
    }

    static func chromiumItems(_ browser: Browser, profile: String, name: String) -> [PrivacyItem] {
        let files: [PrivacyKind: [String]] = [
            .history: ["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal"],
            .cookies: ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal", "Extension Cookies", "Extension Cookies-journal"],
            .sessions: ["Sessions", "Current Session", "Current Tabs", "Last Session", "Last Tabs"],
            .siteData: ["Local Storage", "Session Storage", "IndexedDB", "Service Worker/CacheStorage"],
        ]
        var items = files.compactMap { kind, names -> PrivacyItem? in
            let paths = names.map { profile + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
            guard !paths.isEmpty else { return nil }
            return PrivacyItem(browser: browser, profile: profile, profileName: name, kind: kind, paths: paths,
                               database: nil, bytes: paths.reduce(0) { $0 + size(of: $1) })
        }
        // Autofill shares "Web Data" with saved cards and search engines: clear just its table.
        let webData = profile + "/Web Data"
        if FileManager.default.fileExists(atPath: webData), let count = SQLiteFile.count(webData, table: "autofill"), count > 0 {
            items.append(PrivacyItem(browser: browser, profile: profile, profileName: name, kind: .autofill, paths: [],
                                     database: webData, bytes: Int64(count) * 100))
        }
        return items
    }

    static func firefoxProfiles(_ root: String) -> [(String, String)] {
        let dir = root + "/Profiles"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).compactMap { entry in
            let path = dir + "/" + entry
            guard FileManager.default.fileExists(atPath: path + "/prefs.js") else { return nil }
            return (path, entry.split(separator: ".").dropFirst().joined(separator: ".").nonEmpty ?? entry)
        }
    }

    static func firefoxItems(profile: String, name: String) -> [PrivacyItem] {
        var items: [PrivacyItem] = []
        func add(_ kind: PrivacyKind, _ names: [String]) {
            let paths = names.map { profile + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
            guard !paths.isEmpty else { return }
            items.append(PrivacyItem(browser: .firefox, profile: profile, profileName: name, kind: kind, paths: paths,
                                     database: nil, bytes: paths.reduce(0) { $0 + size(of: $1) }))
        }
        add(.cookies, ["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"])
        add(.sessions, ["sessionstore.jsonlz4", "sessionstore-backups"])
        add(.siteData, ["storage", "webappsstore.sqlite"])
        add(.autofill, ["formhistory.sqlite", "formhistory.sqlite-wal", "formhistory.sqlite-shm"])
        // History shares places.sqlite with bookmarks: clear only visits and unbookmarked pages.
        let places = profile + "/places.sqlite"
        if let visits = SQLiteFile.count(places, table: "moz_historyvisits"), visits > 0 {
            items.append(PrivacyItem(browser: .firefox, profile: profile, profileName: name, kind: .history, paths: [],
                                     database: places, bytes: Int64(visits) * 120))
        }
        return items
    }

    static func safariItems(home: String) -> [PrivacyItem] {
        var items: [PrivacyItem] = []
        func add(_ kind: PrivacyKind, _ paths: [String]) {
            let existing = paths.filter { FileManager.default.isReadableFile(atPath: $0) }
            guard !existing.isEmpty else { return }
            items.append(PrivacyItem(browser: .safari, profile: home + "/Library/Safari", profileName: "Safari", kind: kind,
                                     paths: existing, database: nil, bytes: existing.reduce(0) { $0 + size(of: $1) }))
        }
        let safari = home + "/Library/Safari"
        add(.history, [safari + "/History.db", safari + "/History.db-wal", safari + "/History.db-shm", safari + "/Downloads.plist"])
        add(.sessions, [safari + "/LastSession.plist"])
        add(.cookies, [home + "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"])
        return items
    }

    /// Clears one item. The browser must be closed (its files are in use otherwise).
    public static func clean(_ item: PrivacyItem, browserIsRunning: Bool) -> CleanupRecord {
        var record = CleanupRecord(projectPath: item.profile, itemPath: item.paths.first ?? item.database ?? item.profile,
                                   kind: "privacy:\(item.browser.rawValue).\(item.kind.rawValue)", bytes: item.bytes,
                                   mode: .trash, outcome: .removed)
        if browserIsRunning {
            record.outcome = .skipped
            record.message = "Quit \(item.browser.name) first"
            return record
        }
        do {
            if let database = item.database {
                record.mode = .permanent
                // A copy of the database goes to the Trash first, so the change can be undone.
                let backup = NSTemporaryDirectory() + "\(item.browser.rawValue)-\((database as NSString).lastPathComponent)-\(UUID().uuidString.prefix(6))"
                try FileManager.default.copyItem(atPath: database, toPath: backup)
                record.trashPath = try Cleaner.remove(backup, mode: .trash)
                let sql = item.browser == .firefox
                    ? "DELETE FROM moz_historyvisits; DELETE FROM moz_inputhistory; DELETE FROM moz_places WHERE foreign_count = 0; VACUUM;"
                    : "DELETE FROM autofill; VACUUM;"
                try SQLiteFile.execute(database, sql)
            } else {
                for path in item.paths where FileManager.default.fileExists(atPath: path) {
                    guard Paths.isInside(path, item.profile) || path.contains("/Containers/com.apple.Safari/") else { continue }
                    record.trashPath = try Cleaner.remove(path, mode: .trash)
                }
            }
        } catch {
            record.outcome = .failed
            record.message = error.localizedDescription
        }
        return record
    }

    // MARK: Recent Items

    public static func recentItemsLists(home: String = NSHomeDirectory()) -> [RecentItemsList] {
        let dir = home + "/Library/Application Support/com.apple.sharedfilelist"
        let names: [(String, String)] = [
            ("com.apple.LSSharedFileList.RecentApplications", "Recently opened apps"),
            ("com.apple.LSSharedFileList.RecentDocuments", "Recently opened documents"),
            ("com.apple.LSSharedFileList.RecentServers", "Recently used servers"),
        ]
        var lists: [RecentItemsList] = []
        for (base, title) in names {
            for ext in ["sfl3", "sfl2"] where FileManager.default.fileExists(atPath: "\(dir)/\(base).\(ext)") {
                lists.append(RecentItemsList(title: title, path: "\(dir)/\(base).\(ext)"))
            }
        }
        let perApp = dir + "/com.apple.LSSharedFileList.ApplicationRecentDocuments"
        if ((try? FileManager.default.contentsOfDirectory(atPath: perApp)) ?? []).isEmpty == false {
            lists.append(RecentItemsList(title: "Recent documents of each app", path: perApp))
        }
        return lists
    }

    /// Moves the list to the Trash and restarts the service that keeps it, so the menu empties.
    public static func clear(_ list: RecentItemsList, home: String = NSHomeDirectory()) -> CleanupRecord {
        var record = CleanupRecord(projectPath: Paths.parent(list.path), itemPath: list.path, kind: "privacy:recent",
                                   bytes: size(of: list.path), mode: .trash, outcome: .removed)
        guard Paths.parent(list.path) == home + "/Library/Application Support/com.apple.sharedfilelist" else {
            record.outcome = .skipped
            record.message = "Not a Recent Items list"
            return record
        }
        do {
            record.trashPath = try Cleaner.remove(list.path, mode: .trash)
            _ = DevTools.shell("/usr/bin/killall", ["sharedfilelistd"], environment: [:], timeout: 5)
        } catch {
            record.outcome = .failed
            record.message = error.localizedDescription
        }
        return record
    }

    static func size(of path: String) -> Int64 { AppInventory.size(of: path) }
}

/// A grant you gave an app in Privacy & Security.
public struct AppPermission: Identifiable, Hashable, Sendable {
    public var id: String { "\(service)|\(client)" }
    public let service: String
    public let client: String
    /// Bundle id (client type 0) or a path.
    public let isBundleID: Bool
    public let allowed: Bool
    public let lastModified: Date?
    /// Granted in the system-wide database (Accessibility, Screen Recording, Full Disk Access…).
    public let systemWide: Bool

    public var serviceTitle: String { Permissions.title(for: service) }
    public var symbol: String { Permissions.symbol(for: service) }
}

public enum Permissions {
    static let titles: [String: (String, String)] = [
        "kTCCServiceCamera": ("Camera", "camera.fill"),
        "kTCCServiceMicrophone": ("Microphone", "mic.fill"),
        "kTCCServiceScreenCapture": ("Screen Recording", "rectangle.dashed.badge.record"),
        "kTCCServiceAccessibility": ("Accessibility", "accessibility"),
        "kTCCServiceListenEvent": ("Input Monitoring", "keyboard"),
        "kTCCServicePostEvent": ("Control your Mac", "cursorarrow.click.2"),
        "kTCCServiceSystemPolicyAllFiles": ("Full Disk Access", "internaldrive.fill"),
        "kTCCServiceAppleEvents": ("Automation", "gearshape.2.fill"),
        "kTCCServiceAddressBook": ("Contacts", "person.crop.circle.fill"),
        "kTCCServiceCalendar": ("Calendars", "calendar"),
        "kTCCServiceReminders": ("Reminders", "checklist"),
        "kTCCServicePhotos": ("Photos", "photo.fill"),
        "kTCCServiceSystemPolicyDesktopFolder": ("Desktop Folder", "menubar.dock.rectangle"),
        "kTCCServiceSystemPolicyDocumentsFolder": ("Documents Folder", "doc.fill"),
        "kTCCServiceSystemPolicyDownloadsFolder": ("Downloads Folder", "arrow.down.circle.fill"),
        "kTCCServiceSystemPolicyRemovableVolumes": ("Removable Volumes", "externaldrive.fill"),
        "kTCCServiceSystemPolicyNetworkVolumes": ("Network Volumes", "network"),
        "kTCCServiceSpeechRecognition": ("Speech Recognition", "waveform"),
        "kTCCServiceMediaLibrary": ("Media & Apple Music", "music.note"),
        "kTCCServiceBluetoothAlways": ("Bluetooth", "dot.radiowaves.left.and.right"),
        "kTCCServiceSystemPolicyAppBundles": ("App Management", "app.badge.checkmark"),
    ]

    /// The names `tccutil reset` understands.
    static let resetNames: [String: String] = [
        "kTCCServiceCamera": "Camera", "kTCCServiceMicrophone": "Microphone", "kTCCServiceScreenCapture": "ScreenCapture",
        "kTCCServiceAccessibility": "Accessibility", "kTCCServiceListenEvent": "ListenEvent", "kTCCServicePostEvent": "PostEvent",
        "kTCCServiceSystemPolicyAllFiles": "SystemPolicyAllFiles", "kTCCServiceAppleEvents": "AppleEvents",
        "kTCCServiceAddressBook": "AddressBook", "kTCCServiceCalendar": "Calendar", "kTCCServiceReminders": "Reminders",
        "kTCCServicePhotos": "Photos", "kTCCServiceSystemPolicyDesktopFolder": "SystemPolicyDesktopFolder",
        "kTCCServiceSystemPolicyDocumentsFolder": "SystemPolicyDocumentsFolder", "kTCCServiceSystemPolicyDownloadsFolder": "SystemPolicyDownloadsFolder",
        "kTCCServiceSystemPolicyRemovableVolumes": "SystemPolicyRemovableVolumes", "kTCCServiceSystemPolicyNetworkVolumes": "SystemPolicyNetworkVolumes",
        "kTCCServiceSpeechRecognition": "SpeechRecognition", "kTCCServiceMediaLibrary": "MediaLibrary",
        "kTCCServiceBluetoothAlways": "BluetoothAlways", "kTCCServiceSystemPolicyAppBundles": "SystemPolicyAppBundles",
    ]

    /// System Settings anchors for each pane.
    static let settingsAnchors: [String: String] = [
        "kTCCServiceCamera": "Privacy_Camera", "kTCCServiceMicrophone": "Privacy_Microphone", "kTCCServiceScreenCapture": "Privacy_ScreenCapture",
        "kTCCServiceAccessibility": "Privacy_Accessibility", "kTCCServiceListenEvent": "Privacy_ListenEvent",
        "kTCCServiceSystemPolicyAllFiles": "Privacy_AllFiles", "kTCCServiceAppleEvents": "Privacy_Automation",
        "kTCCServiceAddressBook": "Privacy_Contacts", "kTCCServiceCalendar": "Privacy_Calendars", "kTCCServiceReminders": "Privacy_Reminders",
        "kTCCServicePhotos": "Privacy_Photos", "kTCCServiceSystemPolicyDesktopFolder": "Privacy_FilesAndFolders",
        "kTCCServiceSystemPolicyDocumentsFolder": "Privacy_FilesAndFolders", "kTCCServiceSystemPolicyDownloadsFolder": "Privacy_FilesAndFolders",
        "kTCCServiceSpeechRecognition": "Privacy_SpeechRecognition", "kTCCServiceBluetoothAlways": "Privacy_Bluetooth",
        "kTCCServiceSystemPolicyAppBundles": "Privacy_AppBundles",
    ]

    public static func title(for service: String) -> String { titles[service]?.0 ?? service.replacingOccurrences(of: "kTCCService", with: "") }
    public static func symbol(for service: String) -> String { titles[service]?.1 ?? "lock.fill" }

    public static func settingsURL(for service: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchors[service] ?? "Privacy")")!
    }

    /// Grants recorded in the user and system permission databases. Needs Full Disk Access;
    /// returns nil without it.
    public static func list(home: String = NSHomeDirectory()) -> [AppPermission]? {
        let user = read(home + "/Library/Application Support/com.apple.TCC/TCC.db", systemWide: false)
        let system = read("/Library/Application Support/com.apple.TCC/TCC.db", systemWide: true)
        guard user != nil || system != nil else { return nil }
        let all = (user ?? []) + (system ?? [])
        // The same grant can appear once per database; keep the newest.
        var newest: [String: AppPermission] = [:]
        for permission in all where titles[permission.service] != nil {
            if let existing = newest[permission.id], (existing.lastModified ?? .distantPast) >= (permission.lastModified ?? .distantPast) { continue }
            newest[permission.id] = permission
        }
        return newest.values.sorted { ($0.service, $0.client) < ($1.service, $1.client) }
    }

    static func read(_ path: String, systemWide: Bool) -> [AppPermission]? {
        let rows = SQLiteFile.query(path, "SELECT service, client, client_type, auth_value, last_modified FROM access")
        return rows?.compactMap { row in
            guard row.count >= 5, let service = row[0], let client = row[1] else { return nil }
            return AppPermission(service: service, client: client, isBundleID: row[2] == "0", allowed: row[3] == "2",
                                 lastModified: row[4].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) },
                                 systemWide: systemWide)
        }
    }

    /// Withdraws a grant with `tccutil`. System-wide grants usually need System Settings.
    public static func revoke(_ permission: AppPermission) -> String? {
        guard permission.isBundleID, let name = resetNames[permission.service] else {
            return "This one can only be changed in System Settings."
        }
        let result = DevTools.shell("/usr/bin/tccutil", ["reset", name, permission.client], environment: [:], timeout: 15)
        return result.status == 0 ? nil : "macOS didn't allow it. Change it in System Settings instead."
    }
}

/// Minimal read/write access to SQLite files.
enum SQLiteFile {
    static func count(_ path: String, table: String) -> Int? {
        guard let cell = query(path, "SELECT COUNT(*) FROM \(table)")?.first?.first, let text = cell else { return nil }
        return Int(text)
    }

    /// Opens read-only (immutable, so a database the browser has open is read safely).
    static func query(_ path: String, _ sql: String) -> [[String?]]? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        var db: OpaquePointer?
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columns = sqlite3_column_count(statement)
            rows.append((0..<columns).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
        }
        return rows
    }

    static func execute(_ path: String, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3_000)
        var message: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &message) != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(message)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: text])
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
