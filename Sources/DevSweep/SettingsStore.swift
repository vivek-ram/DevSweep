import DevSweepCore
import Foundation
import Observation
import ServiceManagement

enum AutomationMode: String, CaseIterable, Identifiable {
    case off, notify, autoClean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .notify: "Tell me when space can be freed"
        case .autoClean: "Clean idle projects automatically"
        }
    }
}

enum AutoCleanFrequency: String, CaseIterable, Identifiable {
    case daily, weekly, monthly

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var interval: TimeInterval {
        switch self {
        case .daily: 86_400
        case .weekly: 7 * 86_400
        case .monthly: 30 * 86_400
        }
    }
}

/// One Auto-Clean run, for the log on the Auto-Clean page.
struct AutoCleanRun: Codable, Identifiable, Hashable {
    enum Reason: String, Codable { case schedule, lowSpace, manual }
    var id = UUID()
    var date: Date
    var reason: Reason
    var freed: Int64
    var items: Int
}

enum StorageScope: String, CaseIterable, Identifiable {
    case home, wholeDisk

    var id: String { rawValue }
    var title: String { self == .home ? "My home folder" : "The whole disk" }
}

/// User preferences, persisted to UserDefaults.
@Observable @MainActor
final class SettingsStore {
    @ObservationIgnored private let defaults = UserDefaults.standard

    var roots: [String] { didSet { defaults.set(roots, forKey: "roots") } }
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    var enabledKinds: Set<ArtifactKind> { didSet { defaults.set(enabledKinds.map(\.rawValue), forKey: "enabledKinds") } }
    var removalMode: RemovalMode { didSet { defaults.set(removalMode.rawValue, forKey: "removalMode") } }
    var automation: AutomationMode { didSet { defaults.set(automation.rawValue, forKey: "automation") } }
    var smartLowSpace: Bool { didSet { defaults.set(smartLowSpace, forKey: "smartLowSpace") } }
    var protectedPaths: [String] { didSet { defaults.set(protectedPaths, forKey: "protectedPaths") } }
    var snapshotPython: Bool { didSet { defaults.set(snapshotPython, forKey: "snapshotPython") } }
    var snapshotNode: Bool { didSet { defaults.set(snapshotNode, forKey: "snapshotNode") } }
    /// Virtual environments are never removed without an explicit OK for each one.
    var askBeforeVenvs: Bool { didSet { defaults.set(askBeforeVenvs, forKey: "askBeforeVenvs") } }
    var lastAutomaticRun: Date? { didSet { defaults.set(lastAutomaticRun, forKey: "lastAutomaticRun") } }
    var storageScope: StorageScope { didSet { defaults.set(storageScope.rawValue, forKey: "storageScope") } }

    // Auto-Clean
    var autoCleanEnabled: Bool { didSet { defaults.set(autoCleanEnabled, forKey: "autoCleanEnabled") } }
    var autoCleanFrequency: AutoCleanFrequency { didSet { defaults.set(autoCleanFrequency.rawValue, forKey: "autoCleanFrequency") } }
    var autoCleanRules: AutoCleanRules { didSet { defaults.set(try? JSONEncoder().encode(autoCleanRules), forKey: "autoCleanRules") } }
    var lowSpaceAutoClean: Bool { didSet { defaults.set(lowSpaceAutoClean, forKey: "lowSpaceAutoClean") } }
    var lowSpaceThresholdGB: Int { didSet { defaults.set(lowSpaceThresholdGB, forKey: "lowSpaceThresholdGB") } }
    var lastAutoClean: Date? { didSet { defaults.set(lastAutoClean, forKey: "lastAutoClean") } }
    var lastLowSpaceAlert: Date? { didSet { defaults.set(lastLowSpaceAlert, forKey: "lastLowSpaceAlert") } }
    var autoCleanRuns: [AutoCleanRun] { didSet { defaults.set(try? JSONEncoder().encode(autoCleanRuns), forKey: "autoCleanRuns") } }

    // Space history and the menu bar
    var trackSpaceHistory: Bool { didSet { defaults.set(trackSpaceHistory, forKey: "trackSpaceHistory") } }
    var growthAlerts: Bool { didSet { defaults.set(growthAlerts, forKey: "growthAlerts") } }
    var menuBarShowsFreeSpace: Bool { didSet { defaults.set(menuBarShowsFreeSpace, forKey: "menuBarShowsFreeSpace") } }
    var duplicateFolders: [String] { didSet { defaults.set(duplicateFolders, forKey: "duplicateFolders") } }
    var launchAtLogin: Bool
    var launchAtLoginError: String?

    static let retentionChoices = [7, 14, 30, 45, 60, 90, 180]

    init() {
        let d = UserDefaults.standard
        roots = d.stringArray(forKey: "roots") ?? []
        retentionDays = d.object(forKey: "retentionDays") as? Int ?? 30
        enabledKinds = d.stringArray(forKey: "enabledKinds").map { Set($0.compactMap(ArtifactKind.init(rawValue:))) }
            ?? Set(ArtifactKind.allCases)
        removalMode = d.string(forKey: "removalMode").flatMap(RemovalMode.init(rawValue:)) ?? .trash
        automation = d.string(forKey: "automation").flatMap(AutomationMode.init(rawValue:)) ?? .notify
        smartLowSpace = d.object(forKey: "smartLowSpace") as? Bool ?? true
        protectedPaths = d.stringArray(forKey: "protectedPaths") ?? []
        snapshotPython = d.object(forKey: "snapshotPython") as? Bool ?? true
        snapshotNode = d.object(forKey: "snapshotNode") as? Bool ?? true
        askBeforeVenvs = d.object(forKey: "askBeforeVenvs") as? Bool ?? true
        lastAutomaticRun = d.object(forKey: "lastAutomaticRun") as? Date
        storageScope = d.string(forKey: "storageScope").flatMap(StorageScope.init(rawValue:)) ?? .home
        autoCleanEnabled = d.object(forKey: "autoCleanEnabled") as? Bool ?? true
        autoCleanFrequency = d.string(forKey: "autoCleanFrequency").flatMap(AutoCleanFrequency.init(rawValue:)) ?? .weekly
        autoCleanRules = d.data(forKey: "autoCleanRules").flatMap { try? JSONDecoder().decode(AutoCleanRules.self, from: $0) } ?? AutoCleanRules()
        lowSpaceAutoClean = d.object(forKey: "lowSpaceAutoClean") as? Bool ?? true
        lowSpaceThresholdGB = d.object(forKey: "lowSpaceThresholdGB") as? Int ?? 15
        lastAutoClean = d.object(forKey: "lastAutoClean") as? Date
        lastLowSpaceAlert = d.object(forKey: "lastLowSpaceAlert") as? Date
        autoCleanRuns = d.data(forKey: "autoCleanRuns").flatMap { try? JSONDecoder().decode([AutoCleanRun].self, from: $0) } ?? []
        trackSpaceHistory = d.object(forKey: "trackSpaceHistory") as? Bool ?? true
        growthAlerts = d.object(forKey: "growthAlerts") as? Bool ?? true
        menuBarShowsFreeSpace = d.object(forKey: "menuBarShowsFreeSpace") as? Bool ?? false
        duplicateFolders = d.stringArray(forKey: "duplicateFolders") ?? DuplicateFinder.defaultFolders()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var policy: RetentionPolicy {
        RetentionPolicy(days: retentionDays, enabledKinds: enabledKinds, protectedPaths: Set(protectedPaths),
                        lowSpaceBoost: smartLowSpace)
    }

    func cleanOptions(automatic: Bool) -> CleanOptions {
        CleanOptions(mode: removalMode, snapshotPython: snapshotPython, snapshotNode: snapshotNode, automatic: automatic)
    }

    func addRoots(_ paths: [String]) {
        for path in paths.map(Paths.normalize) where !roots.contains(path) {
            roots.append(path)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func toggleProtection(_ path: String) {
        if let index = protectedPaths.firstIndex(of: path) {
            protectedPaths.remove(at: index)
        } else {
            protectedPaths.append(path)
        }
    }
}
