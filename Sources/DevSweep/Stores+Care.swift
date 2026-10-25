import AppKit
import DevSweepCore
import Observation
import SwiftUI

// MARK: Privacy

@Observable @MainActor
final class PrivacyStore {
    var items: [PrivacyItem] = []
    var recentLists: [RecentItemsList] = []
    var permissions: [AppPermission]?
    var security: SecurityStatus?
    var selection: Set<String> = []
    var isScanning = false
    var scannedAt: Date?

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let (items, lists, permissions, security) = await Task.detached(priority: .userInitiated) {
                (PrivacyScanner.scan(), PrivacyScanner.recentItemsLists(), Permissions.list(), SecurityStatus.read())
            }.value
            withAnimation(.spring(duration: 0.45)) {
                self.items = items
                self.recentLists = lists
                self.permissions = permissions
                self.security = security
            }
            selection = Set(items.filter(\.kind.suggested).map(\.id))
            scannedAt = Date()
            isScanning = false
        }
    }

    func isRunning(_ browser: Browser) -> Bool {
        #if DEBUG
        if AppModel.demo { return false }
        #endif
        return browser.bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    var selectedItems: [PrivacyItem] { items.filter { selection.contains($0.id) } }

    func clean() async {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        let running = Set(Browser.allCases.filter(isRunning))
        let model = AppModel.shared
        let records = await model.runCleaning("Clearing browsing data", movedToTrash: true, items: chosen,
                                              label: { "\($0.browser.name) · \($0.kind.title)" }) { item in
            [PrivacyScanner.clean(item, browserIsRunning: running.contains(item.browser))]
        }
        model.record(records)
        let done = Set(zip(chosen, records).filter { $0.1.outcome == .removed }.map(\.0.id))
        withAnimation(.spring(duration: 0.45)) { items.removeAll { done.contains($0.id) } }
        selection.subtract(done)
        model.finishCleaning(records, movedToTrash: true)
    }

    func clear(_ list: RecentItemsList) async {
        let model = AppModel.shared
        let records = await model.runCleaning("Clearing Recent Items", movedToTrash: true, items: [list], label: { $0.title }) {
            [PrivacyScanner.clear($0)]
        }
        model.record(records)
        if records.first?.outcome == .removed { withAnimation { recentLists.removeAll { $0.id == list.id } } }
        model.finishCleaning(records, movedToTrash: true)
    }

    func revoke(_ permission: AppPermission) {
        Task {
            let problem = await Task.detached { Permissions.revoke(permission) }.value
            if let problem {
                AppModel.shared.notice = Notice(style: .info, title: "Change it in System Settings", detail: problem)
                NSWorkspace.shared.open(Permissions.settingsURL(for: permission.service))
            } else {
                withAnimation { permissions?.removeAll { $0.id == permission.id } }
                AppModel.shared.notice = Notice(style: .success, title: "Access removed",
                                                detail: "\(appName(permission.client)) will ask again the next time it needs \(permission.serviceTitle.lowercased()).")
            }
        }
    }

    func appName(_ client: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: client)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? (client.hasPrefix("/") ? (client as NSString).lastPathComponent : client)
    }
}

// MARK: Maintenance

@Observable @MainActor
final class MaintenanceStore {
    var selection: Set<MaintenanceTask> = Set(MaintenanceTask.allCases.filter(\.recommended))
    var purgeable: Int64?
    var snapshots: [String] = []
    var lastResults: [MaintenanceTask: MaintenanceOutcome] = [:]
    var lastRun: [MaintenanceTask: Date] = [:]
    var isRunning = false

    func refresh() {
        Task {
            let (purgeable, snapshots) = await Task.detached { (Maintenance.purgeableBytes(), Maintenance.localSnapshots()) }.value
            withAnimation {
                self.purgeable = purgeable
                self.snapshots = snapshots
            }
        }
    }

    func run() async {
        let tasks = MaintenanceTask.allCases.filter { selection.contains($0) }
        guard !tasks.isEmpty, !isRunning else { return }
        isRunning = true
        let mailRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
        let model = AppModel.shared
        let before = model.disk?.available ?? 0
        // Admin tasks share one password prompt, so they run as one step.
        let admin = tasks.filter(\.needsAdmin)
        let steps: [[MaintenanceTask]] = (admin.isEmpty ? [] : [admin]) + tasks.filter { !$0.needsAdmin }.map { [$0] }
        let records = await model.runCleaning("Running maintenance", movedToTrash: false, items: steps,
                                              label: { $0.count > 1 ? "\($0.count) tasks (macOS asks for your password)" : $0[0].title }) { step in
            Maintenance.run(step, mailIsRunning: mailRunning).map { outcome in
                CleanupRecord(projectPath: "/", itemPath: outcome.task.title, kind: "maintenance:\(outcome.task.rawValue)", bytes: 0,
                              mode: .permanent, outcome: outcome.succeeded ? .removed : .failed, message: outcome.message)
            }
        }
        model.record(records)
        for record in records {
            guard let task = MaintenanceTask(rawValue: String(record.kind.dropFirst("maintenance:".count))) else { continue }
            lastResults[task] = MaintenanceOutcome(task: task, succeeded: record.outcome == .removed, message: record.message)
            if record.outcome == .removed { lastRun[task] = Date() }
        }
        model.refreshDisk()
        let gained = max(0, (model.disk?.available ?? 0) - before)
        let failed = records.filter { $0.outcome != .removed }.count
        model.finishCleaning([], movedToTrash: false,
                             extra: [failed == 0 ? "\(records.count) task\(records.count == 1 ? "" : "s") done." : "\(records.count - failed) done, \(failed) didn't run — see the list for why."]
                                + (gained > 50_000_000 ? ["\(Format.bytes(gained)) of space came back."] : []))
        isRunning = false
        refresh()
    }
}

// MARK: Updater

@Observable @MainActor
final class UpdaterStore {
    var updates: [AppUpdate] = []
    var isChecking = false
    var checkedAt: Date?
    var updating: Set<String> = []

    func check() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let apps = await Task.detached { AppInventory.installedApps() }.value
            let found = await UpdateChecker.check(apps)
            withAnimation(.spring(duration: 0.45)) { updates = found }
            checkedAt = Date()
            isChecking = false
        }
    }

    func update(_ update: AppUpdate) {
        switch update.source {
        case .appStore(let page):
            if let url = URL(string: page) { NSWorkspace.shared.open(url) }
        case .sparkle:
            // The app's own updater offers the new version when it opens.
            NSWorkspace.shared.open(URL(fileURLWithPath: update.appPath))
        case .homebrew(let token):
            updating.insert(update.id)
            Task {
                let error = await Task.detached { UpdateChecker.upgradeCask(token) }.value
                updating.remove(update.id)
                if let error {
                    AppModel.shared.notice = Notice(style: .error, title: "Couldn't update \(update.name)", detail: error)
                } else {
                    withAnimation { updates.removeAll { $0.id == update.id } }
                    AppModel.shared.notice = Notice(style: .success, title: "\(update.name) is up to date", detail: "Now on \(update.newVersion).")
                }
            }
        }
    }
}

// MARK: Cloud

@Observable @MainActor
final class CloudStore {
    var locations: [CloudLocation] = []
    var files: [CloudFile] = []
    var selection: Set<String> = []
    var isScanning = false
    var scannedAt: Date?

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let (locations, files) = await Task.detached(priority: .userInitiated) { () -> ([CloudLocation], [CloudFile]) in
                let locations = CloudCleanup.locations()
                return (locations, locations.flatMap { (try? CloudCleanup.localCopies(in: $0)) ?? [] }.sorted { $0.bytes > $1.bytes })
            }.value
            withAnimation(.spring(duration: 0.45)) {
                self.locations = locations
                self.files = files
            }
            // Suggest copies not opened for three months.
            let cutoff = Date().addingTimeInterval(-90 * 86_400)
            selection = Set(files.filter { ($0.lastOpened ?? $0.modified) < cutoff }.map(\.path))
            scannedAt = Date()
            isScanning = false
        }
    }

    var selectedFiles: [CloudFile] { files.filter { selection.contains($0.path) } }

    func freeUp() async {
        let chosen = selectedFiles
        guard !chosen.isEmpty else { return }
        let model = AppModel.shared
        let records = await model.runCleaning("Freeing local copies", movedToTrash: false, items: chosen, label: { $0.name }) {
            [CloudCleanup.removeLocalCopy($0)]
        }
        model.record(records)
        let done = Set(records.filter { $0.outcome == .removed }.map(\.itemPath))
        withAnimation(.spring(duration: 0.45)) { files.removeAll { done.contains($0.path) } }
        selection.subtract(done)
        model.refreshDisk()
        model.finishCleaning(records, movedToTrash: false, extra: ["The files are still in the cloud and download again when you open them."])
    }
}

// MARK: Similar images

@Observable @MainActor
final class SimilarImagesStore {
    var groups: [SimilarGroup] = []
    var marked: Set<String> = []
    var isScanning = false
    var progress = SimilarProgress()
    var scannedAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    static func defaultFolders(home: String = NSHomeDirectory()) -> [String] {
        ["Pictures", "Desktop", "Documents", "Downloads"].map { home + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        progress = SimilarProgress()
        task = Task {
            do {
                let found = try await SimilarImageFinder().find(in: Self.defaultFolders()) { progress in
                    Task { @MainActor in
                        let store = AppModel.shared.similar
                        if store.isScanning { store.progress = progress }
                    }
                }
                withAnimation(.spring(duration: 0.45)) { groups = found }
                // Similar isn't identical, so nothing is marked until you choose.
                marked = []
                scannedAt = Date()
            } catch {}
            isScanning = false
        }
    }

    func cancel() { task?.cancel() }

    func toggle(_ path: String, in group: SimilarGroup) {
        if marked.contains(path) {
            marked.remove(path)
        } else if group.images.filter({ !marked.contains($0.path) }).count > 1 {
            marked.insert(path)
        }
    }

    /// Marks everything except the sharpest, largest shot in each group.
    func markAllButBest() {
        marked = Set(groups.flatMap { group in group.images.map(\.path).filter { $0 != group.best } })
    }

    var reclaimable: Int64 { groups.flatMap(\.images).filter { marked.contains($0.path) }.reduce(0) { $0 + $1.bytes } }
    var markedCount: Int { groups.flatMap(\.images).filter { marked.contains($0.path) }.count }

    func trashMarked() async {
        var items: [(path: String, bytes: Int64)] = []
        for group in groups {
            let doomed = group.images.filter { marked.contains($0.path) }
            guard doomed.count < group.images.count else { continue }
            items += doomed.map { ($0.path, $0.bytes) }
        }
        guard !items.isEmpty else { return }
        await AppModel.shared.trashItems(items)
        let removed = Set(items.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) })
        withAnimation(.spring(duration: 0.45)) {
            groups = groups.compactMap { group in
                var group = group
                group.images.removeAll { removed.contains($0.path) }
                return group.images.count > 1 ? group : nil
            }
        }
        marked.subtract(removed)
    }
}

// MARK: Downloads

@Observable @MainActor
final class DownloadsStore {
    var items: [DownloadItem] = []
    var selection: Set<String> = []
    var isScanning = false
    var scannedAt: Date?

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let excluded = AppModel.shared.settings.roots
        Task {
            let found = await Task.detached(priority: .userInitiated) { DownloadsAnalyzer.scan(excluding: excluded) }.value
            withAnimation(.spring(duration: 0.45)) { items = found }
            scannedAt = Date()
            isScanning = false
        }
    }

    var bySource: [(source: String, items: [DownloadItem])] {
        Dictionary(grouping: items, by: \.source)
            .map { ($0.key, $0.value.sorted { $0.bytes > $1.bytes }) }
            .sorted { $0.items.reduce(0) { $0 + $1.bytes } > $1.items.reduce(0) { $0 + $1.bytes } }
    }

    func trashSelected() async {
        let chosen = items.filter { selection.contains($0.path) }.map { (path: $0.path, bytes: $0.bytes) }
        guard !chosen.isEmpty else { return }
        await AppModel.shared.trashItems(chosen)
        let removed = Set(chosen.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) })
        withAnimation(.spring(duration: 0.45)) { items.removeAll { removed.contains($0.path) } }
        selection.subtract(removed)
    }
}

// MARK: Health

extension AppModel {
    /// The Mac Health score from what's been measured so far.
    var health: MacHealth? {
        guard let disk else { return nil }
        var input = MacHealth.Input(freeBytes: disk.available, totalBytes: disk.total)
        input.junkBytes = junkScannedAt == nil ? 0 : suggestedJunkBytes
        input.idleProjectBytes = idleBytes
        if monitor.current.memoryTotal > 0 {
            input.memoryPressure = monitor.current.pressure
            input.swapBytes = monitor.current.swapUsed
        }
        input.batteryHealth = monitor.current.battery?.health
        input.brokenLaunchItems = loginItems.items.filter(\.isBroken).count
        input.trashedBytes = trashedBytes
        return MacHealth.evaluate(input)
    }
}

// MARK: Memory

/// Which apps use the most memory and CPU, sampled every two seconds while something shows it.
@Observable @MainActor
final class ProcessMonitorStore {
    var apps: [AppUsage] = []
    var isFreeing = false
    /// Apps that can be quit like any other (worked out once per sample, not per row).
    private(set) var quittablePIDs: Set<Int32> = []
    /// How many samples have landed (for the CPU harness).
    @ObservationIgnored private(set) var refreshCount = 0
    @ObservationIgnored private let sampler = ProcessSampler()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watchers = 0

    func start() {
        watchers += 1
        guard timer == nil else { return }
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.processes.refreshNow() }
        }
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    #if DEBUG
    /// Shows fixed apps instead of measuring (demo screenshots).
    @ObservationIgnored private var demo = false

    func showDemo(_ apps: [AppUsage], quittable: Set<Int32>) {
        demo = true
        self.apps = apps
        quittablePIDs = quittable
    }
    #endif

    func refreshNow() {
        #if DEBUG
        if demo { return }
        #endif
        let sampler = sampler
        Task {
            let apps = await Task.detached(priority: .utility) { sampler.sample() }.value
            let me = ProcessInfo.processInfo.processIdentifier
            quittablePIDs = Set(NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && $0.bundleIdentifier != "com.apple.finder" }
                .map(\.processIdentifier))
            withAnimation(.easeOut(duration: 0.3)) { self.apps = apps }
            refreshCount += 1
        }
    }

    func top(by metric: UsageMetric, limit: Int) -> [AppUsage] {
        Array(apps.sorted { metric.value($0) > metric.value($1) }.prefix(limit))
    }

    /// The running app behind a group, if it's one that can be quit like any other app.
    /// DevSweep itself, Finder and background helpers can't.
    func canQuit(_ app: AppUsage) -> Bool { quittablePIDs.contains(app.pid) }

    func quit(_ app: AppUsage, force: Bool = false) {
        guard canQuit(app), let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        _ = force ? running.forceTerminate() : running.terminate()
        // Give it a moment to save and close, then measure again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshNow() }
    }

    /// Asks macOS to drop cached memory (needs the administrator password, asked by macOS).
    func freeMemory() async {
        guard !isFreeing else { return }
        isFreeing = true
        let model = AppModel.shared
        let before = SystemSampler().sample().memoryUsed
        let outcome = await Task.detached(priority: .userInitiated) { Maintenance.run([.freeRAM]).first }.value
        try? await Task.sleep(for: .seconds(1.5))
        let after = SystemSampler().sample().memoryUsed
        isFreeing = false
        refreshNow()
        if outcome?.succeeded == true {
            model.maintenance.lastRun[.freeRAM] = Date()
            let freed = before - after
            model.notice = Notice(style: .success, title: freed > 50_000_000 ? "Freed \(Format.bytes(freed)) of memory" : "Memory is already in good shape",
                                  detail: freed > 50_000_000 ? "macOS dropped cached data apps weren't using." : "There wasn't much cached data to drop.")
        } else if let message = outcome?.message {
            model.notice = Notice(style: .error, title: "Couldn't free memory", detail: message)
        }
    }
}
