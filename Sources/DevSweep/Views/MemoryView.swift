import AppKit
import DevSweepCore
import SwiftUI

/// What's using memory and CPU right now, and which apps to quit to get it back.
struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var byCPU = false
    let theme = ModuleTheme.memory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModuleHeader(theme: theme, title: "Memory",
                             subtitle: "What's using memory and CPU right now. Quitting an app you aren't using gives its share back.") {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    } label: { Label("Activity Monitor", systemImage: "waveform.path.ecg") }
                        .buttonStyle(GlassPillStyle())
                    Button {
                        Task { await model.processes.freeMemory() }
                    } label: {
                        HStack(spacing: 6) {
                            if model.processes.isFreeing { ProgressView().controlSize(.small).tint(.white) }
                            Text(model.processes.isFreeing ? "Freeing…" : "Free Up Memory")
                        }
                    }
                    .buttonStyle(PrimaryPillStyle(theme: theme))
                    .disabled(model.processes.isFreeing)
                    .help("Asks macOS to drop cached memory. macOS asks for your password.")
                }
                .appearIn()

                HStack(alignment: .top, spacing: 16) {
                    MemoryRingCard()
                        .frame(width: 280)
                    MemoryBreakdownCard()
                }
                .appearIn(delay: 0.06)

                TopAppsCard(byCPU: $byCPU)
                    .appearIn(delay: 0.12)
            }
            .padding(28)
            .frame(maxWidth: 1060)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Memory")
        // Samples only while the page can be seen.
        .whileVisible(start: {
            model.monitor.start()
            model.processes.start()
        }, stop: {
            model.monitor.stop()
            model.processes.stop()
        })
    }
}

extension SystemSnapshot.Pressure {
    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Under pressure"
        case .critical: "Critical"
        }
    }

    var color: Color {
        switch self {
        case .normal: MacHealth.Status.excellent.color
        case .warning: MacHealth.Status.needsAttention.color
        case .critical: MacHealth.Status.critical.color
        }
    }
}

private struct MemoryRingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let now = model.monitor.current
        let fraction = now.memoryTotal > 0 ? Double(now.memoryUsed) / Double(now.memoryTotal) : 0
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(RadialGradient(colors: [now.pressure.color.opacity(0.25), .clear], center: .center, startRadius: 0, endRadius: 120))
                    .frame(width: 230, height: 230)
                Circle().stroke(.white.opacity(0.08), lineWidth: 14)
                    .frame(width: 168, height: 168)
                // The numbers change every two seconds, so the arc only follows the monitor's short
                // ease, and its glow is a still blur behind it rather than a shadow redrawn each frame.
                Circle()
                    .stroke((now.pressure == .normal ? ModuleTheme.memory.primary : now.pressure.color).opacity(0.35), lineWidth: 22)
                    .frame(width: 168, height: 168)
                    .padding(40)          // room for the blur, so it isn't cut off square
                    .blur(radius: 14)
                    .drawingGroup()
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(now.pressure == .normal ? AnyShapeStyle(ModuleTheme.memory.gradient) : AnyShapeStyle(now.pressure.color),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 168, height: 168)
                VStack(spacing: 2) {
                    Text(now.memoryTotal > 0 ? Format.bytes(now.memoryUsed) : "—")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(now.memoryTotal > 0 ? "of \(Format.bytes(now.memoryTotal))" : "Measuring…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 190)
            HStack(spacing: 6) {
                Circle().fill(now.pressure.color).frame(width: 8, height: 8).shadow(color: now.pressure.color, radius: 4)
                Text("Pressure: \(now.pressure.title)").font(.callout.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(now.pressure.color.opacity(0.14)))
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .glass(cornerRadius: 20)
    }
}

private struct MemoryBreakdownCard: View {
    @Environment(AppModel.self) private var model

    private struct Part: Identifiable {
        var id: String { title }
        let title: String
        let bytes: Int64
        let color: Color
        let help: String
    }

    var body: some View {
        let now = model.monitor.current
        let total = Double(max(now.memoryTotal, 1))
        let parts = [
            Part(title: "Apps", bytes: now.memoryApp, color: ModuleTheme.hex(0x22D3EE), help: "Memory apps are using right now."),
            Part(title: "Wired", bytes: now.memoryWired, color: ModuleTheme.hex(0x818CF8), help: "Memory macOS itself needs and can't move."),
            Part(title: "Compressed", bytes: now.memoryCompressed, color: ModuleTheme.hex(0xF472B6), help: "Memory squeezed to make room. Lots of it means memory is tight."),
            Part(title: "Cached files", bytes: now.memoryCached, color: ModuleTheme.hex(0x94A3B8), help: "Recently used files kept in memory. macOS hands this back the moment apps need it."),
        ]
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(title: "What it's made of", subtitle: "Cached files count as free: macOS gives them back as soon as apps need room.")
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(parts) { part in
                            RoundedRectangle(cornerRadius: 3).fill(part.color.gradient)
                                .frame(width: max(2, geo.size.width * Double(part.bytes) / total))
                                .help("\(part.title): \(Format.bytes(part.bytes))")
                        }
                        Rectangle().fill(.white.opacity(0.07))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 16)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(parts) { part in
                        HStack(spacing: 8) {
                            Circle().fill(part.color).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(part.title).font(.caption).foregroundStyle(.secondary)
                                Text(Format.bytes(part.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                            }
                        }
                        .help(part.help)
                    }
                    HStack(spacing: 8) {
                        Circle().fill(.white.opacity(0.25)).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Swap used").font(.caption).foregroundStyle(.secondary)
                            Text(Format.bytes(now.swapUsed)).font(.callout.weight(.semibold)).monospacedDigit()
                        }
                    }
                    .help("Memory written out to disk because RAM ran short. A few GB means apps are crowding memory.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("LAST FEW MINUTES").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.tertiary)
                    if model.monitor.memoryHistory.count > 1 {
                        Sparkline(values: model.monitor.memoryHistory, tint: ModuleTheme.memory.primary).frame(height: 44)
                    } else {
                        Text("Collecting…").font(.caption).foregroundStyle(.tertiary).frame(height: 44)
                    }
                }
            }
        }
    }
}

private struct TopAppsCard: View {
    @Environment(AppModel.self) private var model
    @Binding var byCPU: Bool

    var body: some View {
        let store = model.processes
        let apps = store.top(by: byCPU, limit: 12)
        let largest = byCPU ? max(apps.first?.cpu ?? 1, 0.01) : Double(max(apps.first?.memory ?? 1, 1))
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    CardTitle(title: byCPU ? "Busiest apps" : "Apps using the most memory",
                              subtitle: "Helper processes, browser tabs and tools an app started count toward it.")
                    Spacer()
                    Picker("", selection: $byCPU) {
                        Text("Memory").tag(false)
                        Text("CPU").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .padding(16)
                if apps.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                        .padding(16)
                }
                ForEach(apps) { app in
                    AppUsageRow(app: app, byCPU: byCPU, fraction: byCPU ? app.cpu / largest : Double(app.memory) / largest)
                    if app.id != apps.last?.id { Divider().opacity(0.4).padding(.leading, 60) }
                }
            }
            .padding(.bottom, 6)
        }
    }
}

/// One app in a "top apps" list: icon, name, a bar, the numbers and a Quit button.
struct AppUsageRow: View {
    @Environment(AppModel.self) private var model
    let app: AppUsage
    var byCPU: Bool
    var fraction: Double
    var compact = false
    @State private var hovering = false

    var body: some View {
        let store = model.processes
        let quittable = store.canQuit(app)
        HStack(spacing: compact ? 8 : 12) {
            icon.frame(width: compact ? 20 : 30, height: compact ? 20 : 30)
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                HStack(spacing: 6) {
                    Text(app.name).font(compact ? .callout : .body.weight(.medium)).lineLimit(1)
                    if !compact, app.processCount > 1 {
                        Text("\(app.processCount) processes").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if !compact {
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.06))
                            .overlay(alignment: .leading) {
                                Capsule().fill(ModuleTheme.memory.gradient)
                                    .frame(width: max(3, geo.size.width * min(1, fraction)))
                            }
                    }
                    .frame(height: 5)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(byCPU ? "\(Int((app.cpu * 100).rounded()))%" : Format.bytes(app.memory))
                    .font((compact ? Font.callout : .body).weight(.semibold)).monospacedDigit()
                if !compact {
                    Text(byCPU ? Format.bytes(app.memory) : "\(Int((app.cpu * 100).rounded()))% CPU")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(minWidth: compact ? 56 : 80, alignment: .trailing)
            // In the compact list, Quit takes the number's place while the pointer is over the row.
            .opacity(compact && quittable && hovering ? 0 : 1)
            .overlay(alignment: .trailing) {
                if compact, quittable, hovering {
                    Button("Quit") { store.quit(app) }
                        .buttonStyle(GlassPillStyle())
                        .controlSize(.mini)
                        .transition(.opacity)
                }
            }
            if !compact {
                if quittable {
                    Button("Quit") { store.quit(app) }
                        .buttonStyle(GlassPillStyle())
                        .controlSize(.small)
                        .help("Quit \(app.name). It asks to save anything unsaved.")
                } else {
                    Color.clear.frame(width: 62, height: 1)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .padding(.horizontal, compact ? 8 : 16)
        .padding(.vertical, compact ? 5 : 8)
        .background(hovering ? Color.white.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .contextMenu {
            if quittable {
                Button("Quit \(app.name)") { store.quit(app) }
                Button("Force Quit \(app.name)") { store.quit(app, force: true) }
                Divider()
            }
            if let bundle = app.bundlePath { Button("Show in Finder") { model.reveal(bundle) } }
        }
    }

    @ViewBuilder private var icon: some View {
        if let bundle = app.bundlePath {
            Image(nsImage: AppIcons.icon(for: bundle)).resizable()
        } else {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: compact ? 11 : 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: compact ? 20 : 30, height: compact ? 20 : 30)
                .background(RoundedRectangle(cornerRadius: compact ? 5 : 8, style: .continuous).fill(.white.opacity(0.12)))
        }
    }
}

/// App icons, loaded from disk once per app instead of on every refresh.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let icon = cache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}
