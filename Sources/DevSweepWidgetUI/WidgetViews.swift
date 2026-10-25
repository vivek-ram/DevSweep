import AppKit
import DevSweepCore
import SwiftUI
import WidgetKit

// The widgets' views, shared by the widget extension and the app's screenshot renderer.

public struct SnapshotEntry: TimelineEntry {
    public let date: Date
    /// nil until DevSweep has run once.
    public let snapshot: WidgetSnapshot?

    public init(date: Date, snapshot: WidgetSnapshot?) {
        self.date = date
        self.snapshot = snapshot
    }
}

// MARK: Look

public enum WidgetStyle {
    public static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    public static let violet = hex(0x8B5CF6)
    public static let pink = hex(0xEC4899)
    public static let teal = hex(0x2DD4BF)
    public static let orange = hex(0xFB923C)
    public static let red = hex(0xEF4444)
    public static let yellow = hex(0xFACC15)
    public static let background = LinearGradient(colors: [hex(0x14152A), hex(0x0B0C16)], startPoint: .top, endPoint: .bottom)

    public static func health(_ status: String?) -> Color {
        switch status {
        case "excellent": hex(0x34D399)
        case "good": hex(0x22D3EE)
        case "fair": yellow
        case "needsAttention": orange
        case "critical": red
        default: .secondary
        }
    }

    public static func healthTitle(_ status: String?) -> String {
        switch status {
        case "excellent": "Excellent"
        case "good": "Good"
        case "fair": "Fair"
        case "needsAttention": "Needs attention"
        case "critical": "Critical"
        default: "Not measured"
        }
    }

    public static func temperature(_ celsius: Double?) -> Color {
        guard let celsius else { return .secondary }
        switch celsius {
        case ..<55: return teal
        case ..<72: return yellow
        case ..<88: return orange
        default: return red
        }
    }

    public static func thermalTitle(_ state: String) -> String {
        switch state {
        case "fair": "Warm"
        case "serious": "Hot"
        case "critical": "Very hot"
        default: "Cool"
        }
    }
}

/// A ring with a value inside, like the app's gauges but without the glow.
public struct RingGauge<Center: View>: View {
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat = 8
    @ViewBuilder var center: Center

    public var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            center
        }
    }
}

/// Shown until the DevSweep app has written its first snapshot.
public struct NotYetView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(WidgetStyle.violet)
            Text("Open DevSweep").font(.headline)
            Text("It fills this widget in after its first scan.").font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .containerBackground(for: .widget) { WidgetStyle.background }
    }
}

private func bytes(_ value: Int64) -> String { Format.bytes(value) }

private func updated(_ date: Date) -> some View {
    Text("Updated \(date, style: .time)").font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
}

// MARK: Mac Health

public struct HealthWidgetView: View {
    let entry: SnapshotEntry
    let family: WidgetFamily

    public init(entry: SnapshotEntry, family: WidgetFamily) {
        self.entry = entry
        self.family = family
    }

    public var body: some View {
        if let snapshot = entry.snapshot {
            let color = WidgetStyle.health(snapshot.healthStatus)
            Group {
                if family == .systemSmall {
                    VStack(spacing: 8) {
                        RingGauge(fraction: Double(snapshot.healthScore ?? 0) / 100, color: color) {
                            VStack(spacing: 0) {
                                Text(snapshot.healthScore.map(String.init) ?? "—")
                                    .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                                Text(WidgetStyle.healthTitle(snapshot.healthStatus).uppercased())
                                    .font(.system(size: 8, weight: .bold)).foregroundStyle(color).lineLimit(1)
                            }
                        }
                        .frame(width: 86, height: 86)
                        Text("\(bytes(snapshot.readyToFree)) to free").font(.caption.weight(.semibold)).lineLimit(1)
                    }
                } else {
                    HStack(spacing: 18) {
                        RingGauge(fraction: Double(snapshot.healthScore ?? 0) / 100, color: color, lineWidth: 10) {
                            VStack(spacing: 0) {
                                Text(snapshot.healthScore.map(String.init) ?? "—")
                                    .font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                                Text(WidgetStyle.healthTitle(snapshot.healthStatus).uppercased())
                                    .font(.system(size: 8, weight: .bold)).foregroundStyle(color).lineLimit(1)
                            }
                        }
                        .frame(width: 112, height: 112)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("READY TO FREE").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(WidgetStyle.violet)
                            Text(bytes(snapshot.readyToFree)).font(.system(size: 24, weight: .bold, design: .rounded))
                            row("trash", "Junk", bytes(snapshot.junkBytes))
                            row("folder", "Idle projects", "\(bytes(snapshot.idleProjectBytes)) · \(snapshot.idleProjects)")
                            row("arrow.down.app", "Updates", "\(snapshot.updates)")
                            Spacer(minLength: 0)
                            updated(snapshot.date)
                        }
                    }
                }
            }
            .containerBackground(for: .widget) { WidgetStyle.background }
        } else {
            NotYetView()
        }
    }

    private func row(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption2).foregroundStyle(.secondary).frame(width: 14)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
    }
}

// MARK: Storage

public struct StorageWidgetView: View {
    let entry: SnapshotEntry
    let family: WidgetFamily

    public init(entry: SnapshotEntry, family: WidgetFamily) {
        self.entry = entry
        self.family = family
    }

    public var body: some View {
        if let snapshot = entry.snapshot {
            let used = snapshot.totalBytes > 0 ? 1 - Double(snapshot.freeBytes) / Double(snapshot.totalBytes) : 0
            let color = used > 0.9 ? WidgetStyle.red : used > 0.8 ? WidgetStyle.orange : WidgetStyle.teal
            Group {
                if family == .systemSmall {
                    VStack(spacing: 8) {
                        RingGauge(fraction: used, color: color) {
                            VStack(spacing: 0) {
                                Text(bytes(snapshot.freeBytes)).font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Text("FREE").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                        }
                        .frame(width: 86, height: 86)
                        Text("of \(bytes(snapshot.totalBytes))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Label("Macintosh HD", systemImage: "internaldrive.fill").font(.headline)
                            Spacer()
                            Text("\(bytes(snapshot.freeBytes)) free").font(.headline).foregroundStyle(color).monospacedDigit()
                        }
                        GeometryReader { geo in
                            Capsule().fill(.white.opacity(0.1))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(color).frame(width: geo.size.width * used).widgetAccentable()
                                }
                        }
                        .frame(height: 10)
                        HStack(spacing: 14) {
                            stat("Junk", bytes(snapshot.junkBytes))
                            stat("Idle projects", bytes(snapshot.idleProjectBytes))
                            stat("Freed this month", bytes(snapshot.freedThisMonth))
                        }
                        Spacer(minLength: 0)
                        updated(snapshot.date)
                    }
                }
            }
            .containerBackground(for: .widget) { WidgetStyle.background }
        } else {
            NotYetView()
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: Temperature

public struct TemperatureWidgetView: View {
    let entry: SnapshotEntry
    let family: WidgetFamily

    public init(entry: SnapshotEntry, family: WidgetFamily) {
        self.entry = entry
        self.family = family
    }

    public var body: some View {
        if let snapshot = entry.snapshot {
            Group {
                switch family {
                case .systemSmall: small(snapshot)
                case .systemLarge: large(snapshot)
                default: medium(snapshot)
                }
            }
            .containerBackground(for: .widget) { WidgetStyle.background }
        } else {
            NotYetView()
        }
    }

    private func gauge(_ snapshot: WidgetSnapshot, size: CGFloat) -> some View {
        let celsius = snapshot.cpuTemperature
        return RingGauge(fraction: celsius.map { ($0 - 20) / 90 } ?? 0, color: WidgetStyle.temperature(celsius), lineWidth: size / 11) {
            VStack(spacing: 0) {
                Text(celsius.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(.system(size: size * 0.3, weight: .bold, design: .rounded)).monospacedDigit()
                Text(WidgetStyle.thermalTitle(snapshot.thermalState).uppercased())
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(WidgetStyle.temperature(celsius))
            }
        }
        .frame(width: size, height: size)
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(spacing: 8) {
            gauge(snapshot, size: 86)
            if let top = snapshot.hotApps.first {
                HStack(spacing: 4) {
                    icon(top, snapshot, size: 14)
                    Text(top.name).font(.caption2).lineLimit(1)
                    Text(watts(top.watts)).font(.caption2.weight(.semibold)).monospacedDigit()
                }
            }
        }
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 16) {
            gauge(snapshot, size: 104)
            VStack(alignment: .leading, spacing: 7) {
                Text("HEATING YOUR MAC").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(WidgetStyle.orange)
                apps(snapshot, count: 3)
                Spacer(minLength: 0)
                updated(snapshot.date)
            }
        }
    }

    private func large(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                gauge(snapshot, size: 110)
                VStack(alignment: .leading, spacing: 6) {
                    Text("CPU temperature").font(.caption).foregroundStyle(.secondary)
                    Text(snapshot.cpuTemperature.map { "\(Int($0.rounded()))°C · \(WidgetStyle.thermalTitle(snapshot.thermalState))" } ?? "—")
                        .font(.title3.weight(.bold))
                    if snapshot.memoryTotal > 0 {
                        Text("Memory \(bytes(snapshot.memoryUsed)) of \(bytes(snapshot.memoryTotal))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("HEATING YOUR MAC").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(WidgetStyle.orange)
            apps(snapshot, count: 5)
            Spacer(minLength: 0)
            Text("Apps are ranked by the power they draw: that's what warms the chip.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            updated(snapshot.date)
        }
    }

    private func apps(_ snapshot: WidgetSnapshot, count: Int) -> some View {
        let shown = Array(snapshot.hotApps.prefix(count))
        let peak = max(shown.first?.watts ?? 1, 0.01)
        return VStack(alignment: .leading, spacing: 6) {
            if shown.isEmpty {
                Text("Nothing is working hard.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shown) { app in
                HStack(spacing: 6) {
                    icon(app, snapshot, size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(app.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(watts(app.watts)).font(.caption.weight(.semibold)).monospacedDigit()
                        }
                        GeometryReader { geo in
                            Capsule().fill(.white.opacity(0.08))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(WidgetStyle.orange).frame(width: max(2, geo.size.width * app.watts / peak))
                                        .widgetAccentable()
                                }
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func icon(_ app: WidgetSnapshot.App, _ snapshot: WidgetSnapshot, size: CGFloat) -> some View {
        if let path = snapshot.iconPath(app), let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.fill").font(.system(size: size * 0.7)).foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }

    private func watts(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f W", value) : String(format: "%.1f W", value)
    }
}
