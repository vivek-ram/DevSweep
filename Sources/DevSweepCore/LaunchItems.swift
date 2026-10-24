import Foundation

/// A launchd job: something macOS starts at login or keeps running in the background.
public struct LaunchItem: Identifiable, Hashable, Sendable {
    public enum Scope: String, Sendable, CaseIterable {
        /// ~/Library/LaunchAgents: yours, and changeable without a password.
        case user
        /// /Library/LaunchAgents: runs for every user.
        case allUsers
        /// /Library/LaunchDaemons: runs as root, without anyone logged in.
        case system

        public var title: String {
            switch self {
            case .user: "Your background items"
            case .allUsers: "For all users"
            case .system: "System helpers"
            }
        }
    }

    public var id: String { plistPath }
    public let label: String
    public let plistPath: String
    public let scope: Scope
    /// The executable it runs.
    public let program: String?
    public let runsAtLoad: Bool
    public let keepsAlive: Bool
    public let modified: Date
    public var programExists: Bool
    /// Turned off with `launchctl disable` (or `Disabled` in the plist).
    public var isDisabled: Bool
    /// Loaded into launchd right now (user items only).
    public var isLoaded: Bool?

    public var isBroken: Bool { program != nil && !programExists }

    /// The app a job most likely belongs to, by its label (com.vendor.app.helper).
    public var vendorID: String { label.split(separator: ".").prefix(3).joined(separator: ".") }
}

public enum LaunchItems {
    public static func list(home: String = NSHomeDirectory()) -> [LaunchItem] {
        let disabled = disabledLabels()
        let loaded = loadedLabels()
        var items: [LaunchItem] = []
        for (dir, scope) in [(home + "/Library/LaunchAgents", LaunchItem.Scope.user),
                             ("/Library/LaunchAgents", .allUsers), ("/Library/LaunchDaemons", .system)] {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".plist") {
                if let item = read(dir + "/" + entry, scope: scope, disabled: disabled, loaded: scope == .user ? loaded : nil) {
                    items.append(item)
                }
            }
        }
        return items.sorted { ($0.scope.rawValue, $0.label.lowercased()) < ($1.scope.rawValue, $1.label.lowercased()) }
    }

    static func read(_ path: String, scope: LaunchItem.Scope, disabled: Set<String>, loaded: Set<String>?) -> LaunchItem? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let label = plist["Label"] as? String ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
        let keepAlive: Bool = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
        let exists = program.map { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) } ?? true
        return LaunchItem(label: label, plistPath: path, scope: scope, program: program,
                          runsAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepsAlive: keepAlive,
                          modified: modificationDate(path) ?? Date(), programExists: exists,
                          isDisabled: disabled.contains(label) || plist["Disabled"] as? Bool == true,
                          isLoaded: loaded.map { $0.contains(label) })
    }

    static var guiDomain: String { "gui/\(getuid())" }

    /// Labels launchd has been told not to start, from `launchctl print-disabled`.
    static func disabledLabels() -> Set<String> {
        let result = DevTools.shell("/bin/launchctl", ["print-disabled", guiDomain], environment: [:], timeout: 10)
        return parseDisabled(result.output)
    }

    /// `"com.vendor.agent" => disabled` (older) or `=> true` (newer macOS).
    static func parseDisabled(_ output: String) -> Set<String> {
        var labels = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard state == "disabled" || state == "true" else { continue }
            labels.insert(parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return labels
    }

    static func loadedLabels() -> Set<String> {
        let result = DevTools.shell("/bin/launchctl", ["list"], environment: [:], timeout: 10)
        return Set(result.output.split(separator: "\n").dropFirst().compactMap { $0.split(separator: "\t").last.map(String.init) })
    }

    /// Stops a user item and keeps it from starting again. Reversible with `enable`.
    public static func disable(_ item: LaunchItem) -> String? {
        guard item.scope == .user else { return "Only your own background items can be changed here." }
        _ = DevTools.shell("/bin/launchctl", ["bootout", guiDomain, item.plistPath], environment: [:], timeout: 15)
        let result = DevTools.shell("/bin/launchctl", ["disable", "\(guiDomain)/\(item.label)"], environment: [:], timeout: 15)
        return result.status == 0 ? nil : result.output
    }

    public static func enable(_ item: LaunchItem) -> String? {
        guard item.scope == .user else { return "Only your own background items can be changed here." }
        let result = DevTools.shell("/bin/launchctl", ["enable", "\(guiDomain)/\(item.label)"], environment: [:], timeout: 15)
        _ = DevTools.shell("/bin/launchctl", ["bootstrap", guiDomain, item.plistPath], environment: [:], timeout: 15)
        return result.status == 0 ? nil : result.output
    }

    /// Stops a user item and moves its plist to the Trash.
    public static func remove(_ item: LaunchItem) -> CleanupRecord {
        var record = CleanupRecord(projectPath: Paths.parent(item.plistPath), itemPath: item.plistPath, kind: "launch",
                                   bytes: 0, mode: .trash, outcome: .removed)
        guard item.scope == .user, Paths.parent(item.plistPath) == NSHomeDirectory() + "/Library/LaunchAgents" else {
            record.outcome = .skipped
            record.message = "Only your own background items can be removed here."
            return record
        }
        _ = DevTools.shell("/bin/launchctl", ["bootout", guiDomain, item.plistPath], environment: [:], timeout: 15)
        do {
            record.trashPath = try Cleaner.remove(item.plistPath, mode: .trash)
        } catch {
            record.outcome = .failed
            record.message = error.localizedDescription
        }
        return record
    }
}
