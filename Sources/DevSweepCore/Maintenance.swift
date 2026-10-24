import Foundation
import SQLite3

/// Routine macOS maintenance. Tasks that need an administrator run together behind one
/// macOS password prompt (the user types the password into macOS, never into DevSweep).
public enum MaintenanceTask: String, CaseIterable, Codable, Sendable, Identifiable {
    case freeRAM, freePurgeable, thinSnapshots, flushDNS, reindexSpotlight, periodicScripts, speedUpMail,
         rebuildLaunchServices, clearFontCaches, resetQuickLook

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .freeRAM: "Free up memory"
        case .freePurgeable: "Free up purgeable space"
        case .thinSnapshots: "Remove local Time Machine snapshots"
        case .flushDNS: "Flush DNS cache"
        case .reindexSpotlight: "Reindex Spotlight"
        case .periodicScripts: "Run maintenance scripts"
        case .speedUpMail: "Speed up Mail"
        case .rebuildLaunchServices: "Rebuild \u{201C}Open With\u{201D} menu"
        case .clearFontCaches: "Clear font caches"
        case .resetQuickLook: "Reset Quick Look"
        }
    }

    public var detail: String {
        switch self {
        case .freeRAM: "Asks macOS to drop cached memory so apps that need room get it. Handy before something heavy."
        case .freePurgeable: "Space macOS has set aside for caches and snapshots, released now instead of when the disk fills."
        case .thinSnapshots: "Local snapshots Time Machine keeps between backups. Backups on your backup drive stay."
        case .flushDNS: "Forgets cached website addresses. Fixes sites that moved or won't load."
        case .reindexSpotlight: "Rebuilds the search index from scratch. Search is slow for a while afterwards."
        case .periodicScripts: "The daily, weekly and monthly housekeeping macOS runs: rotates logs and clears temporary files."
        case .speedUpMail: "Compacts Mail's message index so searching and opening mailboxes is quicker. Mail must be closed."
        case .rebuildLaunchServices: "Clears duplicate and missing apps from \u{201C}Open With\u{201D} menus."
        case .clearFontCaches: "Fixes garbled or missing fonts. Takes effect after you log out."
        case .resetQuickLook: "Clears Quick Look previews and thumbnails that show the wrong thing."
        }
    }

    public var symbol: String {
        switch self {
        case .freeRAM: "memorychip.fill"
        case .freePurgeable: "internaldrive.fill"
        case .thinSnapshots: "clock.arrow.circlepath"
        case .flushDNS: "network"
        case .reindexSpotlight: "magnifyingglass"
        case .periodicScripts: "calendar.badge.clock"
        case .speedUpMail: "envelope.fill"
        case .rebuildLaunchServices: "square.grid.2x2.fill"
        case .clearFontCaches: "textformat"
        case .resetQuickLook: "eye.fill"
        }
    }

    /// Needs the administrator password (one prompt covers every such task in a run).
    public var needsAdmin: Bool {
        switch self {
        case .freeRAM, .freePurgeable, .thinSnapshots, .flushDNS, .reindexSpotlight, .periodicScripts: true
        default: false
        }
    }

    /// Part of the recommended weekly set.
    public var recommended: Bool {
        switch self {
        case .freeRAM, .flushDNS, .periodicScripts, .resetQuickLook: true
        default: false
        }
    }

    /// The shell command run as administrator.
    var adminCommand: String? {
        switch self {
        case .freeRAM: "/usr/sbin/purge"
        case .freePurgeable: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4"
        case .thinSnapshots: "/usr/bin/tmutil deletelocalsnapshots /"
        case .flushDNS: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        case .reindexSpotlight: "/usr/bin/mdutil -E /"
        case .periodicScripts: "/usr/sbin/periodic daily weekly monthly"
        default: nil
        }
    }
}

public struct MaintenanceOutcome: Sendable, Equatable {
    public let task: MaintenanceTask
    public let succeeded: Bool
    public let message: String?

    public init(task: MaintenanceTask, succeeded: Bool, message: String?) {
        self.task = task
        self.succeeded = succeeded
        self.message = message
    }
}

public enum Maintenance {
    /// Space macOS reports as purgeable on the startup disk.
    public static func purgeableBytes() -> Int64? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
              let important = values.volumeAvailableCapacityForImportantUsage, let plain = values.volumeAvailableCapacity else { return nil }
        return max(0, important - Int64(plain))
    }

    /// Local Time Machine snapshot names on the startup disk.
    public static func localSnapshots() -> [String] {
        let result = DevTools.shell("/usr/bin/tmutil", ["listlocalsnapshots", "/"], environment: [:], timeout: 20)
        return result.output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("com.apple.TimeMachine") }
    }

    /// Runs the tasks. Admin tasks go first, in one prompt; if the prompt is cancelled they're
    /// reported as not run.
    public static func run(_ tasks: [MaintenanceTask], home: String = NSHomeDirectory(), mailIsRunning: Bool = false) -> [MaintenanceOutcome] {
        var outcomes: [MaintenanceOutcome] = []
        let admin = tasks.filter(\.needsAdmin)
        if !admin.isEmpty {
            outcomes += runAsAdmin(admin)
        }
        for task in tasks where !task.needsAdmin {
            outcomes.append(runAsUser(task, home: home, mailIsRunning: mailIsRunning))
        }
        return outcomes
    }

    static func runAsAdmin(_ tasks: [MaintenanceTask]) -> [MaintenanceOutcome] {
        // Each command reports its own result with a marker line.
        let script = tasks.compactMap { task in
            task.adminCommand.map { "(\($0)) >/dev/null 2>&1 && echo OK:\(task.rawValue) || echo FAIL:\(task.rawValue)" }
        }.joined(separator: "; ")
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "do shell script \"\(escaped)\" with prompt \"DevSweep needs your password to run maintenance tasks.\" with administrator privileges"
        let result = DevTools.shell("/usr/bin/osascript", ["-e", apple], environment: [:], timeout: 1_800)
        return adminOutcomes(tasks, status: result.status, output: result.output)
    }

    /// Reads the OK:/FAIL: marker lines the admin script prints for each task.
    static func adminOutcomes(_ tasks: [MaintenanceTask], status: Int32, output: String) -> [MaintenanceOutcome] {
        if status != 0 {
            let cancelled = output.contains("-128") || output.lowercased().contains("cancel")
            return tasks.map { MaintenanceOutcome(task: $0, succeeded: false, message: cancelled ? "Password prompt was cancelled" : "Couldn't run") }
        }
        let lines = Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return tasks.map { task in
            let ok = lines.contains("OK:\(task.rawValue)")
            return MaintenanceOutcome(task: task, succeeded: ok, message: ok ? nil : "macOS reported an error")
        }
    }

    static func runAsUser(_ task: MaintenanceTask, home: String, mailIsRunning: Bool) -> MaintenanceOutcome {
        switch task {
        case .speedUpMail:
            if mailIsRunning { return MaintenanceOutcome(task: task, succeeded: false, message: "Quit Mail first") }
            let indexes = mailEnvelopeIndexes(home: home)
            guard !indexes.isEmpty else {
                return MaintenanceOutcome(task: task, succeeded: false, message: "Mail's data isn't readable (allow Full Disk Access) or Mail isn't set up")
            }
            do {
                for index in indexes { try SQLiteFile.execute(index, "VACUUM;") }
                return MaintenanceOutcome(task: task, succeeded: true, message: nil)
            } catch {
                return MaintenanceOutcome(task: task, succeeded: false, message: error.localizedDescription)
            }
        case .rebuildLaunchServices:
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            let result = DevTools.shell(lsregister, ["-r", "-domain", "local", "-domain", "system", "-domain", "user"], environment: [:], timeout: 600)
            return MaintenanceOutcome(task: task, succeeded: result.status == 0, message: result.status == 0 ? nil : "lsregister reported an error")
        case .clearFontCaches:
            let result = DevTools.shell("/usr/bin/atsutil", ["databases", "-removeUser"], environment: [:], timeout: 60)
            return MaintenanceOutcome(task: task, succeeded: result.status == 0, message: result.status == 0 ? nil : "atsutil reported an error")
        case .resetQuickLook:
            let cache = DevTools.shell("/usr/bin/qlmanage", ["-r", "cache"], environment: [:], timeout: 60)
            let reset = DevTools.shell("/usr/bin/qlmanage", ["-r"], environment: [:], timeout: 60)
            let ok = cache.status == 0 && reset.status == 0
            return MaintenanceOutcome(task: task, succeeded: ok, message: ok ? nil : "qlmanage reported an error")
        default:
            return MaintenanceOutcome(task: task, succeeded: false, message: "Needs an administrator")
        }
    }

    /// ~/Library/Mail/V*/MailData/Envelope Index (readable with Full Disk Access).
    static func mailEnvelopeIndexes(home: String) -> [String] {
        let mail = home + "/Library/Mail"
        return ((try? FileManager.default.contentsOfDirectory(atPath: mail)) ?? [])
            .filter { $0.hasPrefix("V") }
            .map { "\(mail)/\($0)/MailData/Envelope Index" }
            .filter { FileManager.default.isWritableFile(atPath: $0) }
    }
}
