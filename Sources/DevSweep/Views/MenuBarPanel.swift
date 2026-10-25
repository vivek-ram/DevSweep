import AppKit
import DevSweepCore
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var sampling = false

    var body: some View {
        let stats = model.settings.menuBarStats
        Group {
            if stats.isEmpty {
                Image(systemName: model.idleBytes > 0 ? "sparkles" : "sparkle")
            } else {
                // The status item shows one image, so the icon and readouts are drawn into it.
                Image(nsImage: MenuBarReadout.image(icon: model.idleBytes > 0 ? "sparkles" : "sparkle",
                                                    items: stats.map { ($0.symbol, value(for: $0)) }))
            }
        }
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
            updateSampling()
        }
        .onChange(of: stats) { updateSampling() }
    }

    private func value(for stat: MenuBarStat) -> String {
        let now = model.monitor.current
        switch stat {
        case .temperature: return formatTemperature(model.monitor.thermal.cpu)
        case .cpu: return now.memoryTotal > 0 ? "\(Int((now.cpu * 100).rounded()))%" : "—"
        case .memory:
            return now.memoryTotal > 0 ? "\(Int((Double(now.memoryUsed) / Double(now.memoryTotal) * 100).rounded()))%" : "—"
        case .freeSpace: return model.disk.map { MenuBarReadout.shortBytes($0.available) } ?? "—"
        }
    }

    /// Keeps a slow sampler running while any live readout is shown.
    private func updateSampling() {
        let needed = model.settings.menuBarStats.contains(where: \.isLive)
        guard needed != sampling else { return }
        sampling = needed
        if needed { model.monitor.start(slow: true) } else { model.monitor.stop(slow: true) }
    }
}

/// Draws the menu bar's icon and readouts as one template image (it takes the menu bar's colour).
@MainActor
enum MenuBarReadout {
    static func image(icon: String, items: [(symbol: String, value: String)]) -> NSImage {
        let content = HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 2) {
                    Image(systemName: item.symbol).font(.system(size: 10, weight: .semibold))
                    Text(item.value).font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 1)
        .frame(height: 18)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: icon, accessibilityDescription: "DevSweep") ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// "61G", "980M": short enough for the menu bar.
    static func shortBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 100 { return "\(Int(gb))G" }
        if gb >= 1 { return String(format: "%.0fG", gb) }
        return "\(Int(Double(bytes) / 1_000_000))M"
    }
}

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    /// Opens with a gauge's app list already showing (for screenshots).
    var showing: SystemGauges.Detail? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppGlyph(size: 26)
                Text("DevSweep").font(.headline)
                Spacer()
                Button {
                    model.scan()
                } label: {
                    if model.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isScanning || model.settings.roots.isEmpty)
                .help("Scan now")
            }

            if let disk = model.disk {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(Format.bytes(disk.available)) free").fontWeight(.medium).monospacedDigit()
                        Spacer()
                        Text("of \(Format.bytes(disk.total))").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    CapacityBar(space: disk, devBytes: model.totalBytes, height: 7)
                }
            }

            status
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass(cornerRadius: 12)

            SystemGauges(showing: showing)

            if model.trashedBytes > 500_000_000 {
                Button {
                    model.section = .history
                    model.showMainWindow()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash.fill").foregroundStyle(ModuleTheme.activity.gradient)
                        Text("\(Format.bytes(model.trashedBytes)) still in the Trash").font(.callout)
                        Spacer()
                        Text("Free").font(.callout.weight(.semibold)).foregroundStyle(ModuleTheme.activity.primary)
                    }
                    .padding(10)
                    .glass(cornerRadius: 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            DrivesSection()

            Divider()

            HStack {
                Button("Open DevSweep") { model.showMainWindow() }
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit DevSweep")
            }
            .buttonStyle(.borderless)

            if let lastScan = model.lastScan {
                Text("Scanned \(lastScan.formatted(.relative(presentation: .named))) · idle after \(Format.days(model.effectiveDays))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 310)
        .pausesMotionWhenHidden()
    }

    @ViewBuilder private var status: some View {
        if let session = model.cleaning {
            MiniCleaningProgress(session: session)
        } else if model.isSmartScanning {
            HStack(spacing: 12) {
                ScanningOrb(size: 40, tint: ModuleTheme.smartScan.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scanning…").fontWeight(.medium)
                    Text(model.isScanningStorage ? "\(model.storageProgress.files.formatted()) files" : "\(model.progress.foldersVisited.formatted()) folders")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        } else if model.settings.roots.isEmpty {
            Text("Open DevSweep to choose your project folders.").foregroundStyle(.secondary)
        } else if model.isScanning {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scanning…").fontWeight(.medium)
                Text("\(model.progress.foldersVisited.formatted()) folders checked").font(.caption).foregroundStyle(.secondary)
            }
        } else if let notice = model.notice, notice.style == .success {
            Label(notice.title, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fontWeight(.medium)
        } else if model.idleBytes > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text(Format.bytes(model.idleBytes))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ModuleTheme.smartScan.gradient)
                Text("ready to free from \(model.idleProjects.count) idle project\(model.idleProjects.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(.secondary)
                if !model.venvsAwaitingApproval.isEmpty {
                    Label("\(model.venvsAwaitingApproval.count) virtual environment\(model.venvsAwaitingApproval.count == 1 ? "" : "s") need\(model.venvsAwaitingApproval.count == 1 ? "s" : "") your OK",
                          systemImage: "hand.raised.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button {
                    model.requestClean(model.idleProjects)
                } label: {
                    Label(model.isCleaning ? "Cleaning…" : "Review & Clean", systemImage: "sparkles")
                }
                .buttonStyle(PrimaryPillStyle(theme: .smartScan))
                .disabled(model.isCleaning)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("All tidy", systemImage: "checkmark.seal.fill").foregroundStyle(.green).fontWeight(.medium)
                if let next = model.nextToIdle {
                    Text("\(next.project.name) becomes idle in \(Format.days(next.days)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// CPU, memory, network and battery, sampled while the panel is open. Click CPU or Memory to
/// see which apps are behind the number.
struct SystemGauges: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motionHidden) private var hidden
    @State private var detail: Detail?
    @State private var watching = false

    enum Detail { case cpu, memory, heat }

    init(showing: Detail? = nil) {
        _detail = State(initialValue: showing)
    }

    var body: some View {
        let monitor = model.monitor
        let now = monitor.current
        VStack(spacing: 8) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Gauge(title: "CPU", value: "\(Int(now.cpu * 100))%", fraction: now.cpu, tint: ModuleTheme.hex(0x2DD4BF), history: monitor.cpuHistory,
                          selected: detail == .cpu) { toggle(.cpu) }
                    Gauge(title: "Memory", value: Format.bytes(now.memoryUsed), fraction: now.memoryTotal == 0 ? 0 : Double(now.memoryUsed) / Double(now.memoryTotal),
                          tint: now.pressure == .critical ? .red : now.pressure == .warning ? .orange : ModuleTheme.hex(0xA78BFA),
                          caption: now.pressure == .normal ? "of \(Format.bytes(now.memoryTotal))" : (now.pressure == .critical ? "Memory is tight" : "Under pressure"),
                          selected: detail == .memory) { toggle(.memory) }
                }
                GridRow {
                    let thermal = monitor.thermal
                    Gauge(title: "Temperature", value: thermal.cpu.map { "\(Int($0.rounded()))°C" } ?? thermal.state.title,
                          fraction: thermal.cpu.map { min(1, max(0, ($0 - 20) / 90)) } ?? 0,
                          tint: thermal.cpu.map(temperatureColor) ?? thermal.state.color,
                          history: monitor.temperatureHistory.map { min(1, max(0, ($0 - 20) / 90)) },
                          caption: thermal.state.title, selected: detail == .heat) { toggle(.heat) }
                    if let battery = now.battery {
                        Gauge(title: "Battery", value: "\(battery.percent)%", fraction: Double(battery.percent) / 100,
                              tint: battery.percent <= 10 && !battery.onPower ? .red : .green,
                              caption: [battery.charging ? "Charging" : battery.onPower ? "On power" : battery.minutesLeft.map { "\($0 / 60)h \($0 % 60)m left" },
                                        battery.health.map { "health \($0)%" }].compactMap { $0 }.joined(separator: " · "))
                    } else {
                        Gauge(title: "Swap", value: Format.bytes(now.swapUsed), fraction: 0, tint: .gray, caption: "virtual memory")
                    }
                }
                GridRow {
                    let peak = max(monitor.networkHistory.max() ?? 1, 1)
                    Gauge(title: "Network", value: "↓\(rate(now.networkIn))  ↑\(rate(now.networkOut))",
                          fraction: (now.networkIn + now.networkOut) / peak, tint: .blue,
                          history: monitor.networkHistory.map { $0 / peak })
                        .gridCellColumns(2)
                }
            }
            if let detail {
                TopAppsPanel(metric: detail == .cpu ? .cpu : detail == .heat ? .power : .memory)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Sample only while the panel is open: closing it doesn't always remove these views.
        .onAppear { setWatching(!hidden) }
        .onDisappear { setWatching(false) }
        .onChange(of: hidden) { _, isHidden in setWatching(!isHidden) }
    }

    private func setWatching(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        if on {
            model.monitor.start()
            if detail != nil { model.processes.start() }
        } else {
            // The open list stays open for next time; it just stops measuring.
            model.monitor.stop()
            if detail != nil { model.processes.stop() }
        }
    }

    private func toggle(_ choice: Detail) {
        let wasShowing = detail != nil
        withAnimation(.spring(duration: 0.35)) { detail = detail == choice ? nil : choice }
        guard watching else { return }
        if detail != nil, !wasShowing { model.processes.start() }
        if detail == nil, wasShowing { model.processes.stop() }
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        Format.bytes(Int64(bytesPerSecond)) + "/s"
    }
}

/// The five apps using the most CPU or memory, with Quit buttons.
private struct TopAppsPanel: View {
    @Environment(AppModel.self) private var model
    let metric: UsageMetric

    var body: some View {
        let apps = model.processes.top(by: metric, limit: 5)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(metric == .cpu ? "BUSIEST APPS" : metric == .power ? "HEATING YOUR MAC" : "USING THE MOST MEMORY")
                    .font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Button("Show All") {
                    model.section = metric == .power ? .heat : .memory
                    model.showMainWindow()
                }
                .buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
            if apps.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Measuring…").font(.caption).foregroundStyle(.secondary) }
                    .padding(8)
            }
            ForEach(apps) { app in
                AppUsageRow(app: app, metric: metric, fraction: 0, compact: true)
            }
        }
        .padding(.bottom, 4)
        .glass(cornerRadius: 12)
    }
}

private struct Gauge: View {
    var title: String
    var value: String
    var fraction: Double
    var tint: Color
    var history: [Double] = []
    var caption: String? = nil
    var selected = false
    var action: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(selected ? 0.8 : hovering ? 0.35 : 0), lineWidth: 1.5))
                .onHover { hovering = $0 }
                .help(selected ? "Hide the apps behind it" : "Show which apps are using it")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if action != nil {
                    Image(systemName: selected ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                Spacer()
                Text(value).font(.callout.weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .contentTransition(.numericText())
            }
            if history.count > 1 {
                Sparkline(values: history, tint: tint).frame(height: 18)
            } else {
                GrowingBar(fraction: fraction, fill: tint.gradient, height: 5).padding(.vertical, 6)
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 10)
    }
}

/// A tiny filled line chart for values in 0...1.
struct Sparkline: View {
    var values: [Double]
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let points = values.enumerated().map { index, value in
                CGPoint(x: geo.size.width * Double(index) / Double(max(values.count - 1, 1)),
                        y: geo.size.height * (1 - min(1, max(0, value))))
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Connected drives, with how full they are and an eject button.
private struct DrivesSection: View {
    @Environment(AppModel.self) private var model
    @State private var volumes: [MountedVolume] = []
    @State private var ejecting: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !volumes.isEmpty {
                Text("DRIVES").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
            }
            ForEach(volumes) { volume in
                HStack(spacing: 10) {
                    Image(nsImage: FileIcons.icon(forPath: volume.path)).resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(volume.name).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text("\(Format.bytes(volume.available)) free").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        GrowingBar(fraction: Double(volume.used) / Double(max(volume.total, 1)), fill: ModuleTheme.updater.gradient, height: 4)
                            .background(Capsule().fill(.white.opacity(0.08)))
                    }
                    if volume.ejectable {
                        Button {
                            eject(volume)
                        } label: {
                            if ejecting.contains(volume.path) {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "eject.fill")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(ejecting.contains(volume.path))
                        .help("Eject \(volume.name)")
                    }
                }
                .padding(8)
                .glass(cornerRadius: 10)
            }
        }
        .onAppear { refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refresh() }
    }

    private func refresh() {
        withAnimation(.spring(duration: 0.3)) { volumes = Volumes.external() }
    }

    private func eject(_ volume: MountedVolume) {
        ejecting.insert(volume.path)
        let path = volume.path, name = volume.name
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            ejecting.remove(path)
            if let error {
                model.notice = Notice(style: .error, title: "Couldn't eject \(name)", detail: "\(error) An app may still be using it.")
            }
            refresh()
        }
    }
}
