import Foundation

/// What an unattended clean may touch. Only things that are disposable by definition: caches
/// DevSweep knows the app rebuilds (never one it doesn't recognise), logs and old installers.
/// Archives, device updates, the Trash and virtual environments are never cleaned on their own.
public struct AutoCleanRules: Codable, Hashable, Sendable {
    public var appCaches = true
    public var logs = true
    public var oldInstallers = true
    public var installerAgeDays = 30
    /// Permanently delete installers Auto-Clean moved to the Trash once they've sat there a while.
    /// Anything you cleaned yourself stays in the Trash until you empty it.
    public var emptyTrashedItems = true
    public var trashedItemAgeDays = 7
    /// pip, npm, Homebrew downloads and the like (re-downloaded when needed).
    public var developerCaches = false

    public init() {}
}

public struct RunningApp: Sendable, Hashable {
    public let bundleID: String?
    public let name: String

    public init(bundleID: String?, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum AutoClean {
    /// Junk an unattended clean may remove. Caches of apps that are open right now are left alone.
    public static func select(_ items: [JunkItem], rules: AutoCleanRules, running: [RunningApp],
                              now: Date = Date()) -> [JunkItem] {
        items.filter { item in
            switch item.category {
            // Only caches ticked by default: ones DevSweep knows (see CacheSafety).
            case .appCaches: rules.appCaches && item.suggested && !isInUse(cacheName: item.name, running: running)
            case .aiClutter: rules.appCaches && !isInUse(cacheName: aiAppName(item), running: running)
            case .logs: rules.logs
            case .installers: rules.oldInstallers && now.timeIntervalSince(item.modified) > Double(rules.installerAgeDays) * 86_400
            case .deviceUpdates, .archives, .trash, .brokenPreferences, .deviceBackups, .mailAttachments: false
            }
        }
    }

    /// "…/Application Support/Cursor/Cache" → "Cursor" (matched against running apps by name).
    static func aiAppName(_ item: JunkItem) -> String {
        item.label?.components(separatedBy: " · ").first ?? (Paths.parent(item.path) as NSString).lastPathComponent
    }

    /// Cache folders are named after a bundle id (com.vendor.App, com.vendor.App.ShipIt) or
    /// loosely after the app ("Google" for Chrome, "Firefox"). Either way, match it to running apps.
    static func isInUse(cacheName: String, running: [RunningApp]) -> Bool {
        let cache = cacheName.lowercased()
        for app in running {
            if let id = app.bundleID?.lowercased(),
               cache == id || cache.hasPrefix(id + ".") || id.hasPrefix(cache + ".") {
                return true
            }
            // Loose folder names ("Google", "Firefox") are matched against app names; names that
            // are bundle ids only by id, or "App" would match "com.idle.app".
            let name = app.name.lowercased()
            if !cache.contains("."), cache.count >= 3, name.count >= 3, name.contains(cache) || cache.contains(name) {
                return true
            }
        }
        return false
    }

    /// Developer caches that are safe to clear without asking (no caution attached).
    public static func developerCaches(home: String = NSHomeDirectory()) -> [DevCache] {
        CacheCatalog.installed(home: home).filter { $0.caution == nil }
    }

    /// Items Auto-Clean put in the Trash more than `days` ago that are still there. What you
    /// cleaned yourself is never emptied for you: the Trash is where you'd look for a mistake.
    public static func trashedItemsToEmpty(_ history: [CleanupRecord], olderThanDays days: Int, now: Date = Date()) -> [CleanupRecord] {
        Cleaner.itemsStillInTrash(history).filter { $0.automatic && now.timeIntervalSince($0.date) > Double(days) * 86_400 }
    }
}
