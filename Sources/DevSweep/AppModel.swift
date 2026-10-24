import AppKit
import DevSweepCore
import SwiftUI
import Observation
@preconcurrency import UserNotifications

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case junk, cloud
    case privacy
    case maintenance, memory, loginItems
    case uninstaller, updater
    case storageMap, largeFiles, duplicates
    case projects, caches, devTools
    case autoClean, screenCleaning, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Smart Scan"
        case .junk: "System Junk"
        case .cloud: "Cloud Cleanup"
        case .privacy: "Privacy"
        case .maintenance: "Maintenance"
        case .memory: "Memory"
        case .loginItems: "Login Items"
        case .uninstaller: "Uninstaller"
        case .updater: "Updater"
        case .storageMap: "Storage Map"
        case .largeFiles: "Large Files"
        case .duplicates: "Duplicates"
        case .projects: "Projects"
        case .caches: "Developer Caches"
        case .devTools: "Toolchains & Models"
        case .autoClean: "Auto-Clean"
        case .screenCleaning: "Screen Cleaning"
        case .history: "My Activity"
        }
    }

    /// Sidebar groups, in order. The first has no heading.
    static let groups: [(title: String?, sections: [SidebarSection])] = [
        (nil, [.overview]),
        ("Cleanup", [.junk, .cloud]),
        ("Protection", [.privacy]),
        ("Performance", [.maintenance, .memory, .loginItems]),
        ("Applications", [.uninstaller, .updater]),
        ("My Clutter", [.storageMap, .largeFiles, .duplicates]),
        ("Developer", [.projects, .caches, .devTools]),
        ("Care", [.autoClean, .screenCleaning, .history]),
    ]
}

enum ProjectFilter: String, CaseIterable, Identifiable {
    case idle, active, protected, all

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// A pending request to clean some projects, shown as a review sheet first.
struct CleanReview: Identifiable {
    let id = UUID()
    var projects: [Project]
}

/// Live state of a clean in progress, shown as an animated panel.
struct CleaningSession: Equatable {
    struct Step: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let bytes: Int64
        let removed: Bool
    }

    let id = UUID()
    var title: String
    var total: Int
    var movedToTrash: Bool
    var done = 0
    var freed: Int64 = 0
    var current = ""
    var recent: [Step] = []
    var kept = 0
    var finishedAt: Date?
    var detail: String?

    var progress: Double { total == 0 ? 1 : Double(done) / Double(total) }
    var isFinished: Bool { finishedAt != nil }
}

struct Notice: Identifiable, Equatable {
    enum Style { case success, info, error }
    let id = UUID()
    var style: Style
    var title: String
    var detail: String?
}

@Observable @MainActor
final class AppModel {
    static let shared = AppModel()
    #if DEBUG
    /// Showing demo data for screenshots: nothing on this Mac (like which apps are open) leaks in.
    nonisolated(unsafe) static var demo = false
    #endif

    let settings = SettingsStore()
    let uninstaller = UninstallerStore()
    let duplicates = DuplicatesStore()
    let devTools = DevToolsStore()
    let loginItems = LoginItemsStore()
    let monitor = SystemMonitor()
    let privacy = PrivacyStore()
    let maintenance = MaintenanceStore()
    let processes = ProcessMonitorStore()
    let updater = UpdaterStore()
    let cloud = CloudStore()
    let similar = SimilarImagesStore()
    let downloads = DownloadsStore()
    var spaceHistory = SpaceHistory()
    @ObservationIgnored private let store = Storage()

    // Scanning
    var projects: [Project] = []
    var lastScan: Date?
    var lastScanDuration: TimeInterval?
    var isScanning = false
    var progress = ScanProgress()
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    // Caches
    var caches: [DevCache] = []
    var isMeasuringCaches = false

    // Cleaning
    var isCleaning = false
    var history: [CleanupRecord] = []
    var trashedItems: [CleanupRecord] = []
    var notice: Notice?
    var cleanReview: CleanReview?
    var cleaning: CleaningSession?

    // Whole-Mac storage
    var storage: StorageScanResult?
    var isScanningStorage = false
    var storageProgress = StorageProgress()
    var largeFiles: [LargeFile] = []
    /// Folder shown in the storage map (nil = the scanned root).
    var mapPath: String?
    /// Bumped when the (non-observable) storage tree changes in place.
    var storageVersion = 0
    var hasFullDiskAccess = FullDiskAccess.isGranted
    @ObservationIgnored private var storageTask: Task<Void, Never>?

    // System junk
    var junk: [JunkItem] = []
    var junkSelection: Set<String> = []
    var isScanningJunk = false
    var junkScannedAt: Date?

    // UI state shared between windows
    var disk: VolumeSpace?
    var section: SidebarSection? = .overview
    var projectFilter: ProjectFilter = .idle
    var selectedProjects: Set<Project.ID> = []
    var launchedAtLogin = false

    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        history = store.loadHistory()
        spaceHistory = store.loadSpaceHistory()
        refreshTrash()
        if let cached = store.loadScan() {
            projects = cached.projects
            lastScan = cached.date
            lastScanDuration = cached.duration
        }
        caches = CacheCatalog.installed()
        refreshDisk()
        scanJunk()

        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in await AppModel.shared.periodicCheck() }
        }
        if !settings.roots.isEmpty { scan() }
        // The first routine check (Auto-Clean, space history) waits for launch scans to settle.
        Task {
            try? await Task.sleep(for: .seconds(90))
            await periodicCheck()
        }
    }

    /// Persists space history (it's written to from the Care extension).
    func saveSpaceHistory() {
        store.saveSpaceHistory(spaceHistory)
    }

    // MARK: Derived state

    var policy: RetentionPolicy { settings.policy }

    var effectiveDays: Int { policy.effectiveDays(freeBytes: disk?.available) }

    var isLowSpaceMode: Bool { effectiveDays < settings.retentionDays }

    func status(of project: Project) -> ProjectStatus {
        policy.status(of: project, freeBytes: disk?.available)
    }

    func cleanableBytes(of project: Project) -> Int64 { policy.cleanableBytes(of: project) }

    var idleProjects: [Project] {
        projects.filter { status(of: $0).isStale && cleanableBytes(of: $0) > 0 }
    }

    var idleBytes: Int64 { idleProjects.reduce(0) { $0 + cleanableBytes(of: $1) } }

    /// Virtual environments in idle projects. With "ask first" on, these wait for an explicit OK.
    var idleVenvs: [Artifact] {
        idleProjects.flatMap { policy.cleanableArtifacts(of: $0) }.filter { $0.kind == .pythonVenv }
    }

    var venvsAwaitingApproval: [Artifact] { settings.askBeforeVenvs ? idleVenvs : [] }

    var totalBytes: Int64 { projects.reduce(0) { $0 + $1.totalBytes } }

    var cacheBytes: Int64? {
        let measured = caches.compactMap(\.bytes)
        return measured.isEmpty ? nil : measured.reduce(0, +)
    }

    var freedSoFar: Int64 {
        history.filter { $0.outcome == .removed }.reduce(0) { $0 + $1.bytes }
    }

    /// The active project that will become idle soonest.
    var nextToIdle: (project: Project, days: Int)? {
        projects.compactMap { project -> (Project, Int)? in
            if case .active(let days) = status(of: project), cleanableBytes(of: project) > 0 { return (project, days) }
            return nil
        }.min { $0.1 < $1.1 }
    }

    var bytesByKind: [(kind: ArtifactKind, bytes: Int64)] {
        var totals: [ArtifactKind: Int64] = [:]
        for artifact in projects.flatMap(\.artifacts) { totals[artifact.kind, default: 0] += artifact.bytes }
        return totals.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    func projects(matching filter: ProjectFilter) -> [Project] {
        projects.filter { project in
            switch (filter, status(of: project)) {
            case (.all, _), (.idle, .stale), (.active, .active), (.protected, .protected): true
            default: false
            }
        }
    }

    func isProtected(_ project: Project) -> Bool { policy.isProtected(project) }

    // MARK: Scanning

    func scan() {
        guard !isScanning, !settings.roots.isEmpty else { return }
        isScanning = true
        progress = ScanProgress()
        let roots = settings.roots
        scanTask = Task {
            do {
                let result = try await ProjectScanner().scan(roots: roots) { progress in
                    Task { @MainActor in
                        let model = AppModel.shared
                        if model.isScanning { model.progress = progress }
                    }
                }
                apply(result)
            } catch is CancellationError {
                // Keep the previous results.
            } catch {
                notice = Notice(style: .error, title: "Scan failed", detail: error.localizedDescription)
            }
            isScanning = false
            refreshDisk()
            await runAutomationIfDue()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func apply(_ result: ScanResult) {
        projects = result.projects
        lastScan = result.date
        lastScanDuration = result.duration
        selectedProjects = selectedProjects.filter { id in projects.contains { $0.id == id } }
        store.saveScan(result)
    }

    // MARK: Smart Scan

    var isSmartScanning: Bool { isScanning || isScanningJunk || isScanningStorage }

    /// Projects, junk, the whole storage map, developer caches, app updates, browser traces
    /// and login items, all at once.
    func smartScan() {
        scan()
        scanJunk()
        scanStorage()
        measureCaches()
        if !updater.isChecking { updater.check() }
        if !privacy.isScanning { privacy.scan() }
        loginItems.refresh()
    }

    func cancelSmartScan() {
        cancelScan()
        storageTask?.cancel()
    }

    func scanStorage() {
        guard !isScanningStorage else { return }
        isScanningStorage = true
        storageProgress = StorageProgress()
        hasFullDiskAccess = FullDiskAccess.isGranted
        let root = settings.storageScope == .wholeDisk ? StorageScanner.wholeDisk : Paths.home
        let scanner = StorageScanner(hasFullDiskAccess: hasFullDiskAccess)
        storageTask = Task {
            do {
                let result = try await scanner.scan(root: root) { progress in
                    Task { @MainActor in
                        let model = AppModel.shared
                        if model.isScanningStorage { model.storageProgress = progress }
                    }
                }
                storage = result
                largeFiles = result.largeFiles
                mapPath = nil
                storageVersion += 1
                didMeasureStorage(result)
            } catch is CancellationError {
            } catch {
                notice = Notice(style: .error, title: "Storage scan failed", detail: error.localizedDescription)
            }
            isScanningStorage = false
            refreshDisk()
        }
    }

    func scanJunk() {
        guard !isScanningJunk else { return }
        isScanningJunk = true
        Task {
            let items = await Task.detached(priority: .utility) { JunkScanner.scan() }.value
            junk = items
            junkSelection = Set(items.filter(\.suggested).map(\.path))
            junkScannedAt = Date()
            isScanningJunk = false
        }
    }

    var suggestedJunkBytes: Int64 { junk.filter(\.suggested).reduce(0) { $0 + $1.bytes } }

    var selectedJunk: [JunkItem] { junk.filter { junkSelection.contains($0.path) } }

    func cleanJunk(_ items: [JunkItem]) async {
        guard !isCleaning, !items.isEmpty else { return }
        let mode = settings.removalMode
        let toTrash = mode == .trash && items.contains { $0.category != .trash }
        let records = await runCleaning("Cleaning junk", movedToTrash: toTrash, items: items, label: { item in
            switch item.category {
            case .appCaches: "\(JunkNames.appName(forBundleID: item.name) ?? item.name) cache"
            case .trash: "Emptying the Trash"
            default: item.name
            }
        }) { [Cleaner.clean($0, mode: mode)] }
        record(records)
        let removed = Set(records.filter { $0.outcome == .removed }.map(\.itemPath))
        withAnimation(.spring(duration: 0.45)) {
            junk.removeAll { removed.contains($0.path) }
            junkSelection.subtract(removed)
        }
        refreshDisk()
        finishCleaning(records, movedToTrash: toTrash)
    }

    /// Moves files or folders you picked to the Trash (always the Trash, never deleted).
    func trashItems(_ items: [(path: String, bytes: Int64)]) async {
        guard !isCleaning, !items.isEmpty else { return }
        let records = await runCleaning(items.count == 1 ? "Moving to the Trash" : "Moving \(items.count) items to the Trash",
                                        movedToTrash: true, items: items, label: { ($0.path as NSString).lastPathComponent }) {
            [Cleaner.trashUserItem($0.path, bytes: $0.bytes)]
        }
        record(records)
        let removed = Set(records.filter { $0.outcome == .removed }.map(\.itemPath))
        withAnimation(.spring(duration: 0.45)) {
            largeFiles.removeAll { removed.contains($0.path) }
            if let root = storage?.root {
                for path in removed {
                    if let node = root.descendant(at: Paths.parent(path)), let child = node.children.first(where: { $0.path == path }) {
                        node.remove(child)
                    }
                }
                storageVersion += 1
            }
        }
        refreshDisk()
        finishCleaning(records, movedToTrash: true)
    }

    // MARK: Cleaning progress

    /// Runs `work` for each item off the main thread, one at a time, updating the cleaning panel
    /// as it goes. Moving to the Trash is near-instant, so quick items are paced a little to keep
    /// the progress readable (never more than ~2 s in total).
    func runCleaning<Item: Sendable>(_ title: String, movedToTrash: Bool, items: [Item], showProgress: Bool = true,
                                             label: (Item) -> String,
                                             work: @escaping @Sendable (Item) -> [CleanupRecord]) async -> [CleanupRecord] {
        isCleaning = true
        if showProgress {
            withAnimation(.spring(duration: 0.45, bounce: 0.25)) {
                cleaning = CleaningSession(title: title, total: items.count, movedToTrash: movedToTrash)
            }
        }
        let pace = showProgress ? min(0.22, 2.0 / Double(max(items.count, 1))) : 0
        var all: [CleanupRecord] = []
        for item in items {
            let name = label(item)
            if showProgress { withAnimation(.easeOut(duration: 0.2)) { cleaning?.current = name } }
            let started = Date()
            let records = await Task.detached(priority: .userInitiated) { work(item) }.value
            all += records
            guard showProgress else { continue }
            let freed = records.filter { $0.outcome == .removed }.reduce(0) { $0 + $1.bytes }
            let removed = !records.isEmpty && records.allSatisfy { $0.outcome == .removed }
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                cleaning?.done += 1
                cleaning?.freed += freed
                cleaning?.kept += records.filter { $0.outcome != .removed }.count
                cleaning?.recent.insert(.init(name: name, bytes: records.reduce(0) { $0 + $1.bytes }, removed: removed), at: 0)
                if (cleaning?.recent.count ?? 0) > 4 { cleaning?.recent.removeLast() }
            }
            let wait = pace - Date().timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        isCleaning = false
        return all
    }

    /// Ends the panel with a summary (and confetti), or shows a banner when there was no panel.
    func finishCleaning(_ records: [CleanupRecord], movedToTrash: Bool, extra: [String] = []) {
        let freed = records.filter { $0.outcome == .removed }.reduce(0) { $0 + $1.bytes }
        let problems = records.filter { $0.outcome != .removed }
        var detail = extra
        if movedToTrash, freed > 0 { detail.append("It's in the Trash: empty it, or use History → Free Trash Space, to get the space back.") }
        if !problems.isEmpty { detail.append("\(problems.count) item\(problems.count == 1 ? " was" : "s were") kept — see History for why.") }
        if cleaning != nil {
            withAnimation(.spring(duration: 0.6, bounce: 0.3)) {
                cleaning?.current = ""
                cleaning?.detail = detail.isEmpty ? nil : detail.joined(separator: " ")
                cleaning?.finishedAt = Date()
            }
        } else {
            notice = Notice(style: problems.isEmpty ? .success : .info,
                            title: freed > 0 ? "Freed \(Format.bytes(freed))" : "Nothing was removed",
                            detail: detail.isEmpty ? nil : detail.joined(separator: " "))
        }
    }

    func dismissCleaning() {
        withAnimation(.spring(duration: 0.4)) { cleaning = nil }
    }

    func openMap(at path: String?) {
        mapPath = path
        section = .storageMap
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }

    // MARK: Cleaning

    /// Opens the review sheet for `targets`; nothing is removed until it's confirmed there.
    func requestClean(_ targets: [Project]) {
        let targets = targets.filter { !isProtected($0) && cleanableBytes(of: $0) > 0 }
        guard !targets.isEmpty, !isCleaning else { return }
        showMainWindow()
        cleanReview = CleanReview(projects: targets)
    }

    /// Cleans the enabled artifact kinds of `targets`. Protected projects are always skipped.
    /// Virtual environments are removed only if listed in `approvedVenvs`; pass nil to follow the
    /// "ask first" setting (none when it's on, all when it's off).
    @discardableResult
    func clean(_ targets: [Project], approvedVenvs: Set<String>?, automatic: Bool = false) async -> Int64 {
        guard !isCleaning else { return 0 }
        let policy = policy
        let ask = approvedVenvs != nil || settings.askBeforeVenvs
        let jobs = targets
            .filter { !policy.isProtected($0) }
            .map { ($0, Cleaner.applyingVenvApproval(policy.cleanableArtifacts(of: $0), askBeforeVenvs: ask,
                                                     approvedVenvs: approvedVenvs ?? [])) }
            .filter { !$0.1.isEmpty }
        guard !jobs.isEmpty else { return 0 }

        let options = settings.cleanOptions(automatic: automatic)
        let steps = jobs.flatMap { project, artifacts in artifacts.map { (project, $0) } }
        let records = await runCleaning(jobs.count == 1 ? "Cleaning \(jobs[0].0.name)" : "Cleaning \(jobs.count) projects",
                                        movedToTrash: settings.removalMode == .trash, items: steps, showProgress: !automatic,
                                        label: { "\($0.0.name) · \($0.0.relativePath(of: $0.1))" }) {
            Cleaner.clean([$0.1], in: $0.0, options: options)
        }

        record(records)
        let removed = Set(records.filter { $0.outcome == .removed }.map(\.itemPath))
        withAnimation(.spring(duration: 0.45)) {
            projects = projects.compactMap { project in
                var project = project
                project.artifacts.removeAll { removed.contains($0.path) }
                return project.artifacts.isEmpty ? nil : project
            }
        }
        if let lastScan {
            store.saveScan(ScanResult(projects: projects, roots: settings.roots, date: lastScan,
                                        duration: lastScanDuration ?? 0, foldersVisited: 0))
        }
        refreshDisk()

        let snapshots = records.filter { $0.snapshotPath != nil && $0.outcome == .removed && $0.message == nil }.count
        finishCleaning(records, movedToTrash: settings.removalMode == .trash,
                       extra: snapshots > 0 ? ["Saved \(snapshots) package list\(snapshots == 1 ? "" : "s") before removing."] : [])
        return records.filter { $0.outcome == .removed }.reduce(0) { $0 + $1.bytes }
    }

    func clean(_ cache: DevCache) async {
        guard !isCleaning else { return }
        let options = settings.cleanOptions(automatic: false)
        let records = await runCleaning("Clearing \(cache.name)", movedToTrash: options.mode == .trash, items: [cache],
                                        label: { $0.name }) { [Cleaner.clean($0, options: options)] }
        record(records)
        if records.first?.outcome == .removed, let index = caches.firstIndex(where: { $0.id == cache.id }) {
            withAnimation(.spring(duration: 0.45)) { caches[index].bytes = 0 }
        }
        refreshDisk()
        finishCleaning(records, movedToTrash: options.mode == .trash)
    }

    func measureCaches() {
        guard !isMeasuringCaches else { return }
        isMeasuringCaches = true
        caches = CacheCatalog.installed()
        let targets = caches
        Task {
            await withTaskGroup(of: (String, Int64).self) { group in
                for cache in targets {
                    group.addTask { (cache.id, DiskUsage.freeableBytes(at: cache.path)) }
                }
                for await (id, bytes) in group {
                    if let index = caches.firstIndex(where: { $0.id == id }) { caches[index].bytes = bytes }
                }
            }
            caches.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            isMeasuringCaches = false
        }
    }

    func record(_ records: [CleanupRecord]) {
        history.insert(contentsOf: records, at: 0)
        store.saveHistory(history)
        refreshTrash()
    }

    func clearHistory() {
        history.removeAll()
        store.saveHistory(history)
        refreshTrash()
    }

    // MARK: Trash

    var trashedBytes: Int64 { trashedItems.reduce(0) { $0 + $1.bytes } }

    func refreshTrash() {
        trashedItems = Cleaner.itemsStillInTrash(history)
    }

    func purgeTrash() async {
        guard !isCleaning else { return }
        let items = trashedItems
        let records = await runCleaning("Emptying DevSweep's items from the Trash", movedToTrash: false, items: items,
                                        label: { ($0.itemPath as NSString).lastPathComponent }) { item in
            let result = Cleaner.purgeFromTrash([item])
            return [CleanupRecord(projectPath: item.projectPath, itemPath: item.trashPath ?? item.itemPath, kind: item.kind,
                                  bytes: item.bytes, mode: .permanent, outcome: result.failures == 0 ? .removed : .failed)]
        }
        refreshTrash()
        refreshDisk()
        finishCleaning(records, movedToTrash: false, extra: ["Only items DevSweep put there were deleted; the rest of your Trash is untouched."])
    }

    // MARK: Automation

    private func runAutomationIfDue() async {
        guard settings.automation != .off else { return }
        if let last = settings.lastAutomaticRun, Date().timeIntervalSince(last) < 20 * 3_600 { return }
        let idle = idleProjects
        let bytes = idleBytes
        settings.lastAutomaticRun = Date()
        guard bytes > 50_000_000 else { return }

        switch settings.automation {
        case .off:
            break
        case .notify:
            var body = "\(idle.count) project\(idle.count == 1 ? " hasn't" : "s haven't") been touched in \(effectiveDays)+ days."
            if let venvs = venvSummary(venvsAwaitingApproval) { body += " \(venvs) need\(venvsAwaitingApproval.count == 1 ? "s" : "") your OK." }
            notify(title: "\(Format.bytes(bytes)) ready to free", body: body + " Click to review.")
        case .autoClean:
            // Never removes a virtual environment on its own while "ask first" is on.
            let freed = await clean(idle, approvedVenvs: nil, automatic: true)
            let waiting = venvSummary(venvsAwaitingApproval)
            if freed > 0 {
                notify(title: "Freed \(Format.bytes(freed))",
                       body: "Cleaned idle projects; your code is untouched." + (waiting.map { " \($0) still need your OK." } ?? ""))
            } else if let waiting {
                notify(title: "Waiting for your OK", body: "\(waiting) can be removed. Click to review.")
            }
        }
    }

    private func venvSummary(_ venvs: [Artifact]) -> String? {
        guard !venvs.isEmpty else { return nil }
        let bytes = venvs.reduce(0) { $0 + $1.bytes }
        return "\(venvs.count) virtual environment\(venvs.count == 1 ? "" : "s") (\(Format.bytes(bytes)))"
    }

    func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Misc

    func refreshDisk() {
        #if DEBUG
        if AppModel.demo { return }
        #endif
        disk = DiskUsage.volumeSpace()
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func toggleProtection(_ project: Project) {
        settings.toggleProtection(project.path)
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let openMainWindow {
            openMainWindow()
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func showProjects(selecting project: Project? = nil, filter: ProjectFilter? = nil) {
        if let filter { projectFilter = filter }
        if let project {
            if !projects(matching: projectFilter).contains(where: { $0.id == project.id }) { projectFilter = .all }
            selectedProjects = [project.id]
        }
        section = .projects
    }
}
