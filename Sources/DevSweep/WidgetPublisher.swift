import AppKit
import DevSweepCore
import WidgetKit

/// Keeps the desktop widgets' snapshot up to date. Right after launch, a scan or a clean, and every
/// five minutes while a DevSweep widget is on the desktop, it writes what the widgets show and asks
/// macOS to redraw them.
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    private let processes = ProcessSampler()
    private let system = SystemSampler()
    private var timer: Timer?
    private var pending: Task<Void, Never>?
    private var lastReload = Date.distantPast
    private var lastState: String?
    private var writtenIcons: Set<String> = []
    private var primed = false

    func start() {
        guard timer == nil, Bundle.main.bundleIdentifier != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { _ in
            Task { @MainActor in WidgetPublisher.shared.publish(soon: false) }
        }
        stopOutdatedExtension()
        publish(soon: true)
    }

    /// After an update macOS can keep the previous build's widget extension running. Everything
    /// it draws is then thrown away (its bundle version no longer matches the installed one) and
    /// the widgets stay blank. Stop it; macOS starts the new one for the next redraw.
    private func stopOutdatedExtension() {
        guard let plugIns = Bundle.main.builtInPlugInsPath else { return }
        let executable = plugIns + "/DevSweepWidgets.appex/Contents/MacOS/DevSweepWidgets"
        // The status-change time, not the modification date: copying from a disk image keeps the
        // build's modification date, but every copy gets a fresh change time.
        var info = stat()
        guard stat(executable, &info) == 0 else { return }
        let installed = Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec) + TimeInterval(info.st_ctimespec.tv_nsec) / 1e9)
        for process in ProcessSampler.running(executable: executable) where process.started < installed {
            kill(process.pid, SIGTERM)
        }
    }

    /// Writes a fresh snapshot. `soon` (after a scan or clean) also asks the widgets to redraw
    /// now; otherwise they're asked at most every 15 minutes, or when the Mac's thermal state
    /// changes, to stay within macOS's refresh budget.
    func publish(soon: Bool) {
        // Only the real app has widgets (debug tools run without a bundle).
        guard Bundle.main.bundleIdentifier != nil else { return }
        pending?.cancel()
        pending = Task {
            // Coalesce bursts (a smart scan finishes several things at once).
            try? await Task.sleep(for: .seconds(soon ? 3 : 0))
            // Launches, scans and cleans always write (cheap, so a newly added widget has data);
            // the five-minute refresh only runs while a DevSweep widget is on screen.
            guard !Task.isCancelled else { return }
            if !soon, !(await hasWidgets()) { return }
            let snapshot = await makeSnapshot()
            try? snapshot.save()
            let stateChanged = lastState != nil && lastState != snapshot.thermalState
            lastState = snapshot.thermalState
            if soon || stateChanged || Date().timeIntervalSince(lastReload) > 15 * 60 {
                lastReload = Date()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    private func hasWidgets() async -> Bool {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                continuation.resume(returning: ((try? result.get()) ?? []).contains { $0.kind.hasPrefix("DevSweep") })
            }
        }
    }

    private func makeSnapshot() async -> WidgetSnapshot {
        let model = AppModel.shared
        model.refreshDisk()
        let processes = processes, system = system, wasPrimed = primed
        primed = true
        let (apps, stats, thermal) = await Task.detached(priority: .utility) {
            // Power is measured between two samples, so the very first time take a quick pair.
            if !wasPrimed {
                _ = processes.sample()
                try? await Task.sleep(for: .seconds(2))
            }
            return (processes.sample(), system.sample(), ThermalSensors.read())
        }.value
        let hot = apps.filter { $0.watts > 0.05 || $0.cpu > 0.05 }.sorted { $0.watts > $1.watts }.prefix(5)
        let health = model.health
        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
        return WidgetSnapshot(
            healthScore: health?.score, healthStatus: health?.status.rawValue, healthReasons: health?.factors.prefix(3).map(\.title) ?? [],
            freeBytes: model.disk?.available ?? 0, totalBytes: model.disk?.total ?? 0,
            junkBytes: model.junkScannedAt == nil ? 0 : model.suggestedJunkBytes,
            idleProjectBytes: model.idleBytes, idleProjects: model.idleProjects.count, updates: model.updater.updates.count,
            memoryUsed: stats.memoryUsed, memoryTotal: stats.memoryTotal,
            cpuTemperature: thermal.cpu, thermalState: thermal.state.rawValue,
            hotApps: hot.map { app in
                WidgetSnapshot.App(name: app.name, watts: app.watts, cpu: app.cpu, memory: app.memory,
                                   iconFile: app.bundlePath.flatMap(icon(for:)))
            },
            freedThisMonth: model.history.filter { $0.outcome == .removed && $0.date >= monthStart && !$0.kind.hasPrefix("maintenance:") }
                .reduce(0) { $0 + $1.bytes })
    }

    /// A small PNG of the app's icon in the widget folder, which the sandboxed widget can read.
    private func icon(for bundlePath: String) -> String? {
        // A stable name (hashValue changes every launch): FNV-1a of the path.
        let hash = bundlePath.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let name = "icon-" + String(hash, radix: 36) + ".png"
        if writtenIcons.contains(name) { return name }
        let path = WidgetSnapshot.folder + "/" + name
        let image = NSWorkspace.shared.icon(forFile: bundlePath)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        try? FileManager.default.createDirectory(atPath: WidgetSnapshot.folder, withIntermediateDirectories: true)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
        writtenIcons.insert(name)
        return name
    }
}
