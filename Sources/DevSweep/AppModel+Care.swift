import AppKit
import DevSweepCore
import SwiftUI

/// Routine care: Auto-Clean, low-space handling and space history.
extension AppModel {
    /// Runs every 30 minutes while DevSweep is open (including from the menu bar).
    func periodicCheck() async {
        refreshDisk()
        recordSpaceSample()
        guard !isCleaning else { return }

        if !isScanning, !settings.roots.isEmpty, lastScan.map({ Date().timeIntervalSince($0) > 6 * 3_600 }) ?? true {
            scan()
        }
        // A daily measurement keeps space history and growth alerts current.
        if settings.trackSpaceHistory, !isScanningStorage,
           spaceHistory.lastSnapshotDate.map({ Date().timeIntervalSince($0) > 20 * 3_600 }) ?? true {
            scanStorage()
        }

        if isLowOnSpace {
            await handleLowSpace()
        } else if autoCleanDue {
            await runAutoClean(reason: .schedule, showProgress: isWindowVisible)
        }
    }

    // MARK: Auto-Clean

    /// When the window is open, routine cleans show their progress panel instead of a notification.
    private var isWindowVisible: Bool { mainWindow?.isVisible == true && NSApp.isActive }

    var autoCleanDue: Bool {
        settings.autoCleanEnabled
            && (settings.lastAutoClean.map { Date().timeIntervalSince($0) >= settings.autoCleanFrequency.interval } ?? true)
    }

    var nextAutoClean: Date? {
        guard settings.autoCleanEnabled else { return nil }
        return (settings.lastAutoClean ?? Date()).addingTimeInterval(settings.lastAutoClean == nil ? 0 : settings.autoCleanFrequency.interval)
    }

    var isLowOnSpace: Bool {
        guard let free = disk?.available else { return false }
        return free < Int64(settings.lowSpaceThresholdGB) * 1_000_000_000
    }

    private func handleLowSpace() async {
        // At most every six hours, so a nearly full disk doesn't mean constant cleaning.
        if let last = settings.lastLowSpaceAlert, Date().timeIntervalSince(last) < 6 * 3_600 { return }
        settings.lastLowSpaceAlert = Date()
        if settings.lowSpaceAutoClean {
            await runAutoClean(reason: .lowSpace, showProgress: isWindowVisible)
        } else {
            notify(title: "Your Mac is low on space",
                   body: "Only \(Format.bytes(disk?.available ?? 0)) free. Open DevSweep to see what can go.")
        }
    }

    private enum AutoStep: Sendable {
        case junk(JunkItem)
        case cache(DevCache)
        case trashed(CleanupRecord)
    }

    /// Cleans what the Auto-Clean rules allow. Caches and logs are deleted outright (they're
    /// disposable); installers go to the Trash and are emptied later like everything else.
    func runAutoClean(reason: AutoCleanRun.Reason, showProgress: Bool) async {
        guard !isCleaning else { return }
        let rules = settings.autoCleanRules
        let running = NSWorkspace.shared.runningApplications.map {
            RunningApp(bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "")
        }
        // Caches and logs first. Downloads only if it answers quickly: while macOS is waiting
        // for the user to allow access, reading it blocks, and that mustn't stall the clean.
        var found = await Task.detached(priority: .utility) { JunkScanner.scan(includeDownloads: false) }.value
        if rules.oldInstallers, let downloads = await withTimeout(10, { JunkScanner.scan().filter { $0.category == .installers } }) {
            found += downloads
        }
        var steps = AutoClean.select(found, rules: rules, running: running).map(AutoStep.junk)
        if rules.developerCaches {
            steps += AutoClean.developerCaches().map(AutoStep.cache)
        }
        if rules.emptyTrashedItems {
            steps += AutoClean.trashedItemsToEmpty(history, olderThanDays: rules.trashedItemAgeDays).map(AutoStep.trashed)
        }
        settings.lastAutoClean = Date()
        guard !steps.isEmpty else {
            logAutoClean(reason: reason, freed: 0, items: 0)
            return
        }

        let records = await runCleaning("Auto-Clean", movedToTrash: false, items: steps, showProgress: showProgress, label: { step in
            switch step {
            case .junk(let item): item.category == .appCaches ? "\(JunkNames.appName(forBundleID: item.name) ?? item.name) cache" : item.name
            case .cache(let cache): cache.name
            case .trashed(let record): "Emptying \((record.itemPath as NSString).lastPathComponent) from the Trash"
            }
        }) { step in
            switch step {
            case .junk(let item):
                return [Cleaner.clean(item, mode: item.category == .installers ? .trash : .permanent)]
            case .cache(var cache):
                cache.bytes = DiskUsage.freeableBytes(at: cache.path)
                return [Cleaner.clean(cache, options: CleanOptions(mode: .permanent, automatic: true))]
            case .trashed(let record):
                let result = Cleaner.purgeFromTrash([record])
                return [CleanupRecord(projectPath: record.projectPath, itemPath: record.trashPath ?? record.itemPath, kind: "purge",
                                      bytes: record.bytes, mode: .permanent, outcome: result.failures == 0 ? .removed : .failed)]
            }
        }

        // Trash emptying isn't new space in the log (it was counted when the item was trashed).
        record(records.filter { $0.kind != "purge" }.map { var r = $0; r.automatic = true; return r })
        refreshTrash()
        let removed = Set(records.filter { $0.outcome == .removed }.map(\.itemPath))
        withAnimation { junk.removeAll { removed.contains($0.path) } }
        refreshDisk()

        let freed = records.filter { $0.outcome == .removed }.reduce(0) { $0 + $1.bytes }
        let count = records.filter { $0.outcome == .removed }.count
        logAutoClean(reason: reason, freed: freed, items: count)
        if showProgress {
            finishCleaning(records, movedToTrash: false)
        } else if freed > 0 {
            notify(title: reason == .lowSpace ? "Low on space: freed \(Format.bytes(freed))" : "Auto-Clean freed \(Format.bytes(freed))",
                   body: "Cleared \(count) item\(count == 1 ? "" : "s"): caches, logs and old downloads. Your files weren't touched.")
        }
    }

    /// Runs blocking `work` off the main thread; nil if it hasn't finished within `seconds`
    /// (the work keeps going in the background and its result is dropped).
    private func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            DispatchQueue.global(qos: .utility).async {
                let result = work()
                if gate.open() { continuation.resume(returning: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if gate.open() { continuation.resume(returning: nil) }
            }
        }
    }

    private func logAutoClean(reason: AutoCleanRun.Reason, freed: Int64, items: Int) {
        settings.autoCleanRuns.insert(AutoCleanRun(date: Date(), reason: reason, freed: freed, items: items), at: 0)
        if settings.autoCleanRuns.count > 30 { settings.autoCleanRuns.removeLast(settings.autoCleanRuns.count - 30) }
    }

    // MARK: Space history

    func recordSpaceSample() {
        guard let disk else { return }
        spaceHistory.record(free: disk.available, total: disk.total)
        saveSpaceHistory()
    }

    /// After a storage scan: remember folder sizes and warn about sudden growth.
    func didMeasureStorage(_ result: StorageScanResult) {
        spaceHistory.record(result.root)
        if settings.growthAlerts {
            for growth in spaceHistory.newAlerts().prefix(2) {
                notify(title: "\(growth.name) grew by \(Format.bytes(growth.delta))",
                       body: "\(Paths.display(growth.path)) is now \(Format.bytes(growth.after)), up from \(Format.bytes(growth.before)) \(Format.idle(since: growth.since).lowercased()).")
            }
        }
        saveSpaceHistory()
    }

    /// Folders that grew noticeably over the last few days.
    var recentGrowth: [Growth] { spaceHistory.growth(minimum: 500_000_000, overAtLeast: 1) }
}

/// Lets exactly one of several racers resume a continuation.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    func open() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if opened { return false }
        opened = true
        return true
    }
}
