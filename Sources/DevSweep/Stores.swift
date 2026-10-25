import AppKit
import DevSweepCore
import Observation
import SwiftUI

// MARK: Uninstaller

struct AppRow: Identifiable, Hashable, Sendable {
    var app: InstalledApp
    var files: [AppFile]
    var lastUsed: Date?

    var id: String { app.path }
    var supportBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { app.appBytes + supportBytes }
}

@Observable @MainActor
final class UninstallerStore {
    var apps: [AppRow] = []
    var leftovers: [Leftover] = []
    var isScanning = false
    var scannedAt: Date?
    var selectedApp: AppRow.ID?
    /// Support files the user unticked for the selected app.
    var keptFiles: Set<String> = []
    var leftoverSelection: Set<String> = []

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let fullAccess = FullDiskAccess.isGranted
        Task {
            let (rows, leftovers) = await Task.detached(priority: .userInitiated) { () -> ([AppRow], [Leftover]) in
                let apps = AppInventory.installedApps()
                var rows = [AppRow?](repeating: nil, count: apps.count)
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: apps.count) { i in
                    var app = apps[i]
                    app.appBytes = DiskUsage.freeableBytes(at: app.path)
                    let files = AppInventory.files(for: app, fullDiskAccess: fullAccess)
                    let row = AppRow(app: app, files: files, lastUsed: AppInventory.lastUsed(app, files: files))
                    lock.lock()
                    rows[i] = row
                    lock.unlock()
                }
                let leftovers = AppInventory.leftovers(installed: apps, isInstalled: {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
                }, fullDiskAccess: fullAccess)
                return (rows.compactMap { $0 }, leftovers)
            }.value
            withAnimation(.spring(duration: 0.45)) {
                apps = rows.sorted { $0.totalBytes > $1.totalBytes }
                self.leftovers = leftovers
            }
            leftoverSelection = Set(leftovers.filter { !$0.vendorStillInstalled }.flatMap { $0.files.map(\.path) })
            scannedAt = Date()
            isScanning = false
        }
    }

    var selected: AppRow? { apps.first { $0.id == selectedApp } }

    func isRunning(_ app: InstalledApp) -> Bool {
        #if DEBUG
        if AppModel.demo { return false }
        #endif
        return !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    private enum Step: Sendable {
        case app(InstalledApp)
        case file(AppFile)
    }

    /// Quits the app if needed, then moves it and its ticked support files to the Trash.
    func uninstall(_ row: AppRow) async {
        let model = AppModel.shared
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: row.app.bundleID) {
            running.terminate()
        }
        for _ in 0..<20 where isRunning(row.app) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let files = row.files.filter { !keptFiles.contains($0.path) }
        let steps = [Step.app(row.app)] + files.map(Step.file)
        var records = await model.runCleaning("Uninstalling \(row.app.name)", movedToTrash: true, items: steps, label: { step in
            switch step {
            case .app(let app): "\(app.name).app"
            case .file(let file): "\(file.kind.title) · \(file.name)"
            }
        }) { step in
            switch step {
            case .app(let app): [Cleaner.trashApp(app)]
            case .file(let file): [Cleaner.trashUserItem(file.path, bytes: file.bytes)]
            }
        }
        // Apps installed by a package belong to the system; Finder can still trash them after
        // asking for your password.
        if let index = records.firstIndex(where: { $0.kind == "app" && $0.outcome == .failed }) {
            let url = URL(fileURLWithPath: row.app.path)
            if let moved = try? await NSWorkspace.shared.recycle([url]), let destination = moved[url] {
                records[index].outcome = .removed
                records[index].message = nil
                records[index].trashPath = destination.path
            }
        }
        model.record(records)
        if records.first(where: { $0.kind == "app" })?.outcome == .removed {
            withAnimation(.spring(duration: 0.45)) { apps.removeAll { $0.id == row.id } }
            selectedApp = nil
        }
        keptFiles.removeAll()
        model.refreshDisk()
        model.finishCleaning(records, movedToTrash: true)
    }

    var selectedLeftoverFiles: [AppFile] {
        leftovers.flatMap(\.files).filter { leftoverSelection.contains($0.path) }
    }

    func removeLeftovers() async {
        let files = selectedLeftoverFiles
        guard !files.isEmpty else { return }
        let model = AppModel.shared
        let records = await model.runCleaning("Removing leftovers", movedToTrash: true, items: files,
                                              label: { "\($0.kind.title) · \($0.name)" }) {
            [Cleaner.trashUserItem($0.path, bytes: $0.bytes)]
        }
        model.record(records)
        let removed = Set(records.filter { $0.outcome == .removed }.map(\.itemPath))
        withAnimation(.spring(duration: 0.45)) {
            leftovers = leftovers.compactMap { leftover in
                let files = leftover.files.filter { !removed.contains($0.path) }
                return files.isEmpty ? nil : Leftover(identifier: leftover.identifier, files: files,
                                                      vendorStillInstalled: leftover.vendorStillInstalled)
            }
        }
        leftoverSelection.subtract(removed)
        model.refreshDisk()
        model.finishCleaning(records, movedToTrash: true)
    }
}

// MARK: Duplicates

@Observable @MainActor
final class DuplicatesStore {
    var groups: [DuplicateGroup] = []
    var isScanning = false
    var progress = DuplicateProgress()
    var scannedAt: Date?
    /// Copies the user wants gone. A group always keeps at least one file.
    var marked: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?

    func scan(folders: [String]) {
        guard !isScanning, !folders.isEmpty else { return }
        isScanning = true
        progress = DuplicateProgress()
        task = Task {
            do {
                let found = try await DuplicateFinder().find(in: folders) { progress in
                    Task { @MainActor in
                        let store = AppModel.shared.duplicates
                        if store.isScanning { store.progress = progress }
                    }
                }
                withAnimation(.spring(duration: 0.45)) { groups = found }
                markSuggested()
                scannedAt = Date()
            } catch is CancellationError {
            } catch {
                AppModel.shared.notice = Notice(style: .error, title: "Duplicate search failed", detail: error.localizedDescription)
            }
            isScanning = false
        }
    }

    func cancel() { task?.cancel() }

    /// Marks every copy except the suggested keeper in each group, leaving copies inside code
    /// projects for the user to decide.
    func markSuggested() {
        marked = Set(groups.flatMap { DuplicateFinder.suggestedRemovals($0) })
    }

    func keepOnly(_ path: String, in group: DuplicateGroup) {
        for file in group.files {
            if file.path == path { marked.remove(file.path) } else { marked.insert(file.path) }
        }
    }

    func toggle(_ path: String, in group: DuplicateGroup) {
        if marked.contains(path) {
            marked.remove(path)
        } else if group.files.filter({ !marked.contains($0.path) }).count > 1 {
            marked.insert(path)   // never the last remaining copy
        }
    }

    var reclaimable: Int64 {
        groups.reduce(0) { total, group in total + group.size * Int64(group.files.filter { marked.contains($0.path) }.count) }
    }

    var markedCount: Int { groups.reduce(0) { $0 + $1.files.filter { marked.contains($0.path) }.count } }

    func trashMarked() async {
        // Belt and braces: never remove every copy of something.
        var items: [(path: String, bytes: Int64)] = []
        for group in groups {
            let doomed = group.files.filter { marked.contains($0.path) }
            guard doomed.count < group.files.count else { continue }
            items += doomed.map { ($0.path, group.size) }
        }
        guard !items.isEmpty else { return }
        let model = AppModel.shared
        let records = await model.runCleaning("Removing \(items.count) duplicate\(items.count == 1 ? "" : "s")", movedToTrash: true, items: items,
                                              label: { ($0.path as NSString).lastPathComponent }) {
            [Cleaner.trashUserItem($0.path, bytes: $0.bytes)]
        }
        model.record(records)
        let removed = Set(records.filter { $0.outcome == .removed }.map(\.itemPath))
        withAnimation(.spring(duration: 0.45)) {
            groups = groups.compactMap { group in
                var group = group
                group.files.removeAll { removed.contains($0.path) }
                return group.files.count > 1 ? group : nil
            }
        }
        marked.subtract(removed)
        model.refreshDisk()
        model.finishCleaning(records, movedToTrash: true)
    }
}

// MARK: Toolchains & models

@Observable @MainActor
final class DevToolsStore {
    var items: [ToolCleanup] = []
    var selection: Set<String> = []
    var isScanning = false
    var scannedAt: Date?

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let found = await DevTools.discover()
            withAnimation(.spring(duration: 0.45)) { items = found }
            selection = Set(found.filter(\.suggested).map(\.id))
            scannedAt = Date()
            isScanning = false
        }
    }

    var selectedItems: [ToolCleanup] { items.filter { selection.contains($0.id) } }

    func runSelected() async {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        let model = AppModel.shared
        let toTrash = chosen.contains { if case .trash = $0.action { true } else { false } }
        let records = await model.runCleaning("Cleaning up tools", movedToTrash: toTrash, items: chosen,
                                              label: { "\($0.tool) · \($0.title)" }) { [DevTools.run($0)] }
        model.record(records)
        let done = Set(records.filter { $0.outcome == .removed }.map { String($0.kind.dropFirst(5)) })
        withAnimation(.spring(duration: 0.45)) { items.removeAll { done.contains($0.id) } }
        selection.subtract(done)
        model.refreshDisk()
        model.finishCleaning(records, movedToTrash: toTrash)
    }
}

// MARK: Login items

@Observable @MainActor
final class LoginItemsStore {
    var items: [LaunchItem] = []
    var isLoading = false

    #if DEBUG
    /// Shows fixed items instead of reading launchd (demo screenshots).
    @ObservationIgnored var demo = false
    #endif

    func refresh() {
        #if DEBUG
        if demo { return }
        #endif
        guard !isLoading else { return }
        isLoading = true
        Task {
            let list = await Task.detached { LaunchItems.list() }.value
            withAnimation(.spring(duration: 0.4)) { items = list }
            isLoading = false
        }
    }

    func setEnabled(_ item: LaunchItem, _ enabled: Bool) {
        Task {
            let error = await Task.detached { enabled ? LaunchItems.enable(item) : LaunchItems.disable(item) }.value
            if let error, !error.isEmpty {
                AppModel.shared.notice = Notice(style: .error, title: "Couldn't change \(item.label)", detail: error)
            }
            isLoading = false
            refresh()
        }
    }

    func remove(_ item: LaunchItem) async {
        let model = AppModel.shared
        let records = await model.runCleaning("Removing \(item.label)", movedToTrash: true, items: [item],
                                              label: { $0.label }) { [LaunchItems.remove($0)] }
        model.record(records)
        model.finishCleaning(records, movedToTrash: true)
        refresh()
    }
}

// MARK: System monitor

@Observable @MainActor
final class SystemMonitor {
    var current = SystemSnapshot()
    var cpuHistory: [Double] = []
    var networkHistory: [Double] = []
    /// Share of memory in use, newest last (about three minutes).
    var memoryHistory: [Double] = []
    /// Temperatures and macOS's thermal state.
    var thermal = ThermalSnapshot()
    /// CPU temperature in °C, newest last (about three minutes).
    var temperatureHistory: [Double] = []
    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var slowWatchers = 0

    /// Samples every two seconds while anything is showing the numbers, or every five when only
    /// the menu bar readout is (`slow`).
    func start(slow: Bool = false) {
        if slow { slowWatchers += 1 } else { watchers += 1 }
        reschedule()
    }

    func stop(slow: Bool = false) {
        if slow { slowWatchers = max(0, slowWatchers - 1) } else { watchers = max(0, watchers - 1) }
        reschedule()
    }

    private func reschedule() {
        let interval: TimeInterval? = watchers > 0 ? 2 : slowWatchers > 0 ? 5 : nil
        guard interval != timer?.timeInterval else { return }
        timer?.invalidate()
        timer = nil
        guard let interval else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.monitor.tick() }
        }
    }

    #if DEBUG
    /// Shows a fixed snapshot instead of sampling (demo screenshots).
    @ObservationIgnored private var demo = false

    func showDemo(_ snapshot: SystemSnapshot) {
        demo = true
        current = snapshot
        // A gentle few minutes of history for the sparklines.
        let wave = (0..<60).map { sin(Double($0) / 6) }
        cpuHistory = wave.suffix(40).map { 0.14 + 0.08 * $0 }
        networkHistory = wave.suffix(40).map { 150_000 + 90_000 * $0 }
        memoryHistory = wave.map { 0.6 + 0.04 * $0 + 0.0008 * Double(wave.count) }
        thermal = DemoData.thermal()
        temperatureHistory = (0..<90).map { (i: Int) -> Double in
            let step = Double(i)
            return 64.0 + 5.0 * sin(step / 9.0) + step * 0.04
        }
    }
    #endif

    private func tick() {
        #if DEBUG
        if demo { return }
        #endif
        let sampler = sampler
        Task {
            let (snapshot, thermal) = await Task.detached(priority: .utility) { (sampler.sample(), ThermalSensors.read()) }.value
            self.thermal = thermal
            if let celsius = thermal.cpu {
                temperatureHistory.append(celsius)
                if temperatureHistory.count > 90 { temperatureHistory.removeFirst(temperatureHistory.count - 90) }
            }
            withAnimation(.easeOut(duration: 0.4)) {
                current = snapshot
                cpuHistory.append(snapshot.cpu)
                networkHistory.append(snapshot.networkIn + snapshot.networkOut)
                if snapshot.memoryTotal > 0 { memoryHistory.append(Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal)) }
                if cpuHistory.count > 40 { cpuHistory.removeFirst(cpuHistory.count - 40) }
                if memoryHistory.count > 90 { memoryHistory.removeFirst(memoryHistory.count - 90) }
                if networkHistory.count > 40 { networkHistory.removeFirst(networkHistory.count - 40) }
            }
        }
    }
}
