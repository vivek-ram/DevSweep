import CoreServices
import Foundation

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String
    /// CFBundleName, which apps often use for their support folders ("Code" for VS Code).
    public let bundleName: String?
    public let version: String?
    /// CFBundleVersion, which Sparkle feeds compare against.
    public var buildVersion: String? = nil
    /// Installed from the Mac App Store (has a store receipt).
    public var isAppStore = false
    /// Sparkle update feed, if the app has one.
    public var feedURL: String? = nil
    public var appBytes: Int64 = 0
    public var lastUsed: Date?

    public var isApple: Bool { bundleID.hasPrefix("com.apple.") }

    /// Who made it, for filtering (bundle id vendor, e.g. "com.google").
    public var vendor: String { bundleID.split(separator: ".").prefix(2).joined(separator: ".").lowercased() }
}

/// A file or folder an app keeps in ~/Library.
public struct AppFile: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case appSupport, caches, preferences, containers, groupContainers, savedState, logs, webData, launchAgents, scripts

        public var title: String {
            switch self {
            case .appSupport: "Application Support"
            case .caches: "Caches"
            case .preferences: "Preferences"
            case .containers: "Container"
            case .groupContainers: "Group Container"
            case .savedState: "Saved State"
            case .logs: "Logs"
            case .webData: "Web data & cookies"
            case .launchAgents: "Launch Agent"
            case .scripts: "App Scripts"
            }
        }
    }

    public var id: String { path }
    public let path: String
    public let kind: Kind
    public var bytes: Int64

    public var name: String { (path as NSString).lastPathComponent }
}

/// Support files whose app is no longer installed.
public struct Leftover: Identifiable, Hashable, Sendable {
    public var id: String { identifier }
    /// The bundle id the files are named after.
    public let identifier: String
    public let files: [AppFile]
    /// Another app from the same developer is still installed, so these may still be in use.
    public let vendorStillInstalled: Bool

    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    public init(identifier: String, files: [AppFile], vendorStillInstalled: Bool) {
        self.identifier = identifier
        self.files = files
        self.vendorStillInstalled = vendorStillInstalled
    }
}

public enum AppInventory {
    public static func appFolders(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", "/Applications/Utilities", home + "/Applications"]
    }

    /// Apps in /Applications and ~/Applications (not macOS's own apps in /System).
    public static func installedApps(home: String = NSHomeDirectory(), folders: [String]? = nil) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for folder in folders ?? appFolders(home: home) {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where entry.hasSuffix(".app") {
                if let app = readApp(folder + "/" + entry) { apps.append(app) }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func readApp(_ path: String) -> InstalledApp? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var app = InstalledApp(path: path, name: name, bundleID: bundleID, bundleName: info["CFBundleName"] as? String,
                               version: info["CFBundleShortVersionString"] as? String)
        app.buildVersion = info["CFBundleVersion"] as? String
        app.isAppStore = FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
        app.feedURL = info["SUFeedURL"] as? String
        return app
    }

    /// When the app was last opened: Spotlight's record if it has one, otherwise the newest
    /// change to the preferences and window state the app writes while it runs.
    public static func lastUsed(_ app: InstalledApp, files: [AppFile]) -> Date? {
        if let date = Spotlight.date(app.path, kMDItemLastUsedDate) {
            return date
        }
        return files.filter { [.preferences, .savedState, .caches, .appSupport].contains($0.kind) }
            .compactMap { modificationDate($0.path) }
            .max()
    }

    /// Where apps keep things in ~/Library. App containers are only included with Full Disk
    /// Access: without it, reading inside another app's container makes macOS ask the user.
    static func locations(home: String, fullDiskAccess: Bool) -> [(dir: String, kind: AppFile.Kind)] {
        let lib = home + "/Library"
        let all: [(dir: String, kind: AppFile.Kind)] = [
            (lib + "/Application Support", .appSupport), (lib + "/Caches", .caches), (lib + "/Preferences", .preferences),
            (lib + "/Containers", .containers), (lib + "/Group Containers", .groupContainers),
            (lib + "/Saved Application State", .savedState), (lib + "/Logs", .logs), (lib + "/HTTPStorages", .webData),
            (lib + "/WebKit", .webData), (lib + "/Cookies", .webData), (lib + "/LaunchAgents", .launchAgents),
            (lib + "/Application Scripts", .scripts),
        ]
        return fullDiskAccess ? all : all.filter { ![.containers, .groupContainers, .scripts].contains($0.kind) }
    }

    /// Everything in ~/Library that belongs to `app`, matched by bundle id (and, for a few
    /// folders, by the app's exact name). Sizes are measured.
    public static func files(for app: InstalledApp, home: String = NSHomeDirectory(),
                             fullDiskAccess: Bool = FullDiskAccess.isGranted) -> [AppFile] {
        let id = app.bundleID.lowercased()
        let names = Set([app.name, app.bundleName].compactMap { $0?.lowercased() }.filter { $0.count >= 3 })
        var result: [AppFile] = []
        for (dir, kind) in locations(home: home, fullDiskAccess: fullDiskAccess) {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                let lower = entry.lowercased()
                let byID = lower == id || lower.hasPrefix(id + ".")
                    || kind == .groupContainers && (lower.hasSuffix("." + id) || lower == "group." + id)
                let byName = [.appSupport, .caches, .logs].contains(kind) && names.contains(lower)
                if byID || byName {
                    let path = dir + "/" + entry
                    result.append(AppFile(path: path, kind: kind, bytes: size(of: path)))
                }
            }
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    /// Support files named after bundle ids that no installed app owns. Only reverse-DNS names
    /// are considered (a folder called "Google" can't be attributed safely), Apple's are skipped,
    /// and helpers of installed apps (com.vendor.App.Helper) count as installed.
    public static func leftovers(installed: [InstalledApp], isInstalled: (String) -> Bool,
                                 home: String = NSHomeDirectory(), fullDiskAccess: Bool = FullDiskAccess.isGranted) -> [Leftover] {
        let installedIDs = installed.map { $0.bundleID.lowercased() }
        let vendors = Set(installedIDs.map(vendor))
        var grouped: [String: [AppFile]] = [:]

        for (dir, kind) in locations(home: home, fullDiskAccess: fullDiskAccess) {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                guard let identifier = bundleIdentifier(fromFileName: entry, kind: kind) else { continue }
                let lower = identifier.lowercased()
                if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") { continue }
                // Command-line toolchains keep caches under bundle-style names but aren't apps.
                if ["org.swift.", "org.llvm.", "org.python.", "org.nodejs.", "com.github.cli"].contains(where: lower.hasPrefix) { continue }
                if installedIDs.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }) { continue }
                let root = lower.split(separator: ".").prefix(3).joined(separator: ".")
                if isInstalled(identifier) || isInstalled(root) { continue }
                let path = dir + "/" + entry
                grouped[root, default: []].append(AppFile(path: path, kind: kind, bytes: size(of: path)))
            }
        }
        return grouped.map { root, files in
            Leftover(identifier: root, files: files.sorted { $0.bytes > $1.bytes }, vendorStillInstalled: vendors.contains(vendor(root)))
        }
        .filter { $0.bytes > 0 }
        .sorted { $0.bytes > $1.bytes }
    }

    /// "com.vendor.app.plist" → "com.vendor.app"; nil unless the name looks like a bundle id.
    static func bundleIdentifier(fromFileName name: String, kind: AppFile.Kind) -> String? {
        var base = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        if kind == .groupContainers {
            // TEAMID.com.vendor.app or group.com.vendor.app
            let parts = base.split(separator: ".")
            if parts.first == "group" || parts.first.map({ $0.count == 10 && $0.uppercased() == $0 }) == true {
                base = parts.dropFirst().joined(separator: ".")
            }
        }
        let parts = base.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }),
              ["com", "org", "net", "io", "app", "dev", "co", "us", "de", "uk", "me", "tv", "ai", "jp", "fr"].contains(parts[0].lowercased()),
              base.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) })
        else { return nil }
        return base
    }

    static func vendor(_ id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    static func size(of path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        return (st.st_mode & S_IFMT) == S_IFDIR ? DiskUsage.freeableBytes(at: path) : Int64(st.st_blocks) * 512
    }
}
