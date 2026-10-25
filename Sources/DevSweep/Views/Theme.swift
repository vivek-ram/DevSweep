import AppKit
import DevSweepCore
import SwiftUI

// DevSweep's look: a dark, deep background washed with the current module's colours, glass
// cards floating on it, and one glowing gradient glyph per module.

/// A module's colours and symbol.
struct ModuleTheme: Equatable {
    let colors: [Color]
    let glyph: String

    var primary: Color { colors[0] }
    var secondary: Color { colors.last ?? colors[0] }
    var gradient: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }

    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static let smartScan = ModuleTheme(colors: [hex(0x8B5CF6), hex(0xEC4899)], glyph: "sparkles")
    static let cleanup = ModuleTheme(colors: [hex(0x10B981), hex(0x22D3EE)], glyph: "bubbles.and.sparkles.fill")
    static let cloud = ModuleTheme(colors: [hex(0x38BDF8), hex(0x6366F1)], glyph: "icloud.fill")
    static let privacy = ModuleTheme(colors: [hex(0xF43F5E), hex(0xFB923C)], glyph: "hand.raised.fill")
    static let maintenance = ModuleTheme(colors: [hex(0xF59E0B), hex(0xF97316)], glyph: "gauge.with.dots.needle.67percent")
    static let memory = ModuleTheme(colors: [hex(0x22D3EE), hex(0x818CF8)], glyph: "memorychip.fill")
    static let heat = ModuleTheme(colors: [hex(0xFB923C), hex(0xEF4444)], glyph: "thermometer.medium")
    static let loginItems = ModuleTheme(colors: [hex(0xFB7185), hex(0xC084FC)], glyph: "power")
    static let uninstaller = ModuleTheme(colors: [hex(0x0EA5E9), hex(0x6366F1)], glyph: "xmark.app.fill")
    static let updater = ModuleTheme(colors: [hex(0x3B82F6), hex(0x06B6D4)], glyph: "arrow.down.app.fill")
    static let spaceLens = ModuleTheme(colors: [hex(0x14B8A6), hex(0x3B82F6)], glyph: "chart.pie.fill")
    static let largeFiles = ModuleTheme(colors: [hex(0xF59E0B), hex(0xEF4444)], glyph: "doc.fill")
    static let duplicates = ModuleTheme(colors: [hex(0x6366F1), hex(0xA855F7)], glyph: "square.on.square.fill")
    static let projects = ModuleTheme(colors: [hex(0x84CC16), hex(0x10B981)], glyph: "folder.fill")
    static let devCaches = ModuleTheme(colors: [hex(0xF97316), hex(0xEAB308)], glyph: "shippingbox.fill")
    static let devTools = ModuleTheme(colors: [hex(0x06B6D4), hex(0x14B8A6)], glyph: "hammer.fill")
    static let autoClean = ModuleTheme(colors: [hex(0x2DD4BF), hex(0x22C55E)], glyph: "clock.badge.checkmark.fill")
    static let screenCleaning = ModuleTheme(colors: [hex(0x60A5FA), hex(0xE879F9)], glyph: "display")
    static let activity = ModuleTheme(colors: [hex(0xA855F7), hex(0xF472B6)], glyph: "chart.bar.xaxis")
}

extension SidebarSection {
    var theme: ModuleTheme {
        switch self {
        case .overview: .smartScan
        case .junk: .cleanup
        case .cloud: .cloud
        case .privacy: .privacy
        case .maintenance: .maintenance
        case .memory: .memory
        case .heat: .heat
        case .loginItems: .loginItems
        case .uninstaller: .uninstaller
        case .updater: .updater
        case .storageMap: .spaceLens
        case .largeFiles: .largeFiles
        case .duplicates: .duplicates
        case .projects: .projects
        case .caches: .devCaches
        case .devTools: .devTools
        case .autoClean: .autoClean
        case .screenCleaning: .screenCleaning
        case .history: .activity
        }
    }
}

enum Palette {
    static let base = ModuleTheme.hex(0x0B0C16)
    static let baseRaised = ModuleTheme.hex(0x12131F)
    static let hairline = Color.white.opacity(0.09)
}

// MARK: Background

/// A deep background with two soft colour fields drifting slowly — the module's "aurora".
/// The fields are gradient layers drawn once; their drift is a Core Animation animation, so it
/// runs in the window server and costs the app nothing per frame. It holds still with Reduce
/// Motion, while you're in another app and while the window is hidden.
struct AuroraBackground: View {
    var theme: ModuleTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ambientMotionPaused) private var ambientPaused

    var body: some View {
        AuroraLayers(primary: NSColor(theme.primary), secondary: NSColor(theme.secondary),
                     moving: !reduceMotion, paused: ambientPaused)
            .ignoresSafeArea()
    }
}

private struct AuroraLayers: NSViewRepresentable {
    var primary: NSColor
    var secondary: NSColor
    var moving: Bool
    var paused: Bool

    func makeNSView(context: Context) -> AuroraView { AuroraView() }

    func updateNSView(_ view: AuroraView, context: Context) {
        view.update(primary: primary, secondary: secondary, moving: moving, paused: paused)
    }
}

final class AuroraView: NSView {
    private let first = CAGradientLayer()
    private let second = CAGradientLayer()
    private let vignette = CAGradientLayer()
    private var moving = true
    private var paused = false
    private var laidOutSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(Palette.base).cgColor
        for glow in [first, second] {
            glow.type = .radial
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.locations = [0, 0.55, 1]
            layer?.addSublayer(glow)
        }
        vignette.colors = [NSColor.clear.cgColor, NSColor(Palette.base).withAlphaComponent(0.55).cgColor]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 0.5, y: 0)   // layer coordinates run bottom-up
        layer?.addSublayer(vignette)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(primary: NSColor, secondary: NSColor, moving: Bool, paused: Bool) {
        // Colours cross-fade when you switch pages (instantly while frozen, or they'd stay frozen).
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.8)
        CATransaction.setDisableActions(self.paused || paused)
        first.colors = glowColors(primary, strength: 0.20)
        second.colors = glowColors(secondary, strength: 0.13)
        CATransaction.commit()
        if moving != self.moving {
            self.moving = moving
            laidOutSize = .zero
            needsLayout = true
        }
        if paused != self.paused {
            self.paused = paused
            setDriftPaused(paused)
        }
    }

    private func glowColors(_ color: NSColor, strength: CGFloat) -> [CGColor] {
        [color.withAlphaComponent(strength).cgColor, color.withAlphaComponent(strength * 0.28).cgColor, NSColor.clear.cgColor]
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size != laidOutSize, size.width > 0, size.height > 0 else { return }
        laidOutSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = max(size.width, size.height) * 1.3
        vignette.frame = bounds
        // Positions in layer coordinates (y up), matching the old top-left / bottom-right placement.
        place(first, diameter: side, from: CGPoint(x: size.width * 0.02, y: size.height * 1.04),
              to: CGPoint(x: size.width * 0.12, y: size.height * 0.92))
        place(second, diameter: side * 0.9, from: CGPoint(x: size.width * 1.02, y: -size.height * 0.08),
              to: CGPoint(x: size.width * 0.92, y: size.height * 0.02))
        CATransaction.commit()
        if paused { setDriftPaused(true) }
    }

    private func place(_ glow: CAGradientLayer, diameter: CGFloat, from: CGPoint, to: CGPoint) {
        glow.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        glow.position = from
        glow.removeAnimation(forKey: "drift")
        guard moving else { return }
        let drift = CABasicAnimation(keyPath: "position")
        drift.fromValue = NSValue(point: from)
        drift.toValue = NSValue(point: to)
        drift.duration = 14
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // A drift this slow looks continuous at a low frame rate.
        drift.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
        glow.add(drift, forKey: "drift")
    }

    /// Freezes or resumes the drift where it is (Apple's QA1673 technique).
    private func setDriftPaused(_ pause: Bool) {
        guard let layer else { return }
        if pause {
            guard layer.speed != 0 else { return }
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = now
        } else {
            guard layer.speed == 0 else { return }
            let pausedAt = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        }
    }
}

// MARK: Glass

/// A translucent card with a hairline edge and a soft top highlight.
struct GlassBackground: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 18) -> some View {
        background(GlassBackground(cornerRadius: cornerRadius))
    }
}

// MARK: Glyphs

/// The module's symbol on a glowing gradient squircle.
struct ModuleGlyph: View {
    var theme: ModuleTheme
    var size: CGFloat = 64
    var symbol: String? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(theme.gradient)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center))
            )
            .overlay(
                Image(systemName: symbol ?? theme.glyph)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: size * 0.04, y: size * 0.02)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.22), radius: size * 0.06, y: size * 0.03)
    }
}

/// The big intro glyph: the module symbol in a glowing orb with slowly turning orbit rings.
struct HeroGlyph: View {
    var theme: ModuleTheme
    var size: CGFloat = 150
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ambientMotionPaused) private var ambientPaused

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [theme.primary.opacity(0.14), .clear], center: .center, startRadius: 0, endRadius: size * 0.75))
                .frame(width: size * 1.5, height: size * 1.5)
            // One turn every 40 seconds needs only a few frames a second.
            TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion || ambientPaused)) { context in
                let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 40) / 40 * 360
                ZStack {
                    ForEach(0..<2, id: \.self) { ring in
                        Ellipse()
                            .strokeBorder(LinearGradient(colors: [theme.colors[0].opacity(0.4), .clear, theme.secondary.opacity(0.4)],
                                                         startPoint: .leading, endPoint: .trailing), lineWidth: 1.2)
                            .frame(width: size * (1.18 + Double(ring) * 0.22), height: size * (0.46 + Double(ring) * 0.1))
                            .rotationEffect(.degrees((ring == 0 ? -18 : 24) + turn * (ring == 0 ? 1 : -1)))
                    }
                }
            }
            Circle()
                .fill(theme.gradient)
                .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .frame(width: size * 0.72, height: size * 0.72)
                .shadow(color: .black.opacity(0.3), radius: size * 0.06, y: size * 0.03)
            Image(systemName: theme.glyph)
                .font(.system(size: size * 0.3, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating, isActive: active && !reduceMotion)
        }
        .frame(width: size * 1.5, height: size * 1.1)
    }
}

// MARK: Headers & intros

/// The top of every module page: glyph, title, subtitle and the page's main actions.
struct ModuleHeader<Actions: View>: View {
    var theme: ModuleTheme
    var title: String
    var subtitle: String
    @ViewBuilder var actions: Actions

    init(theme: ModuleTheme, title: String, subtitle: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.theme = theme
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ModuleGlyph(theme: theme, size: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                // No fixed vertical size: the header often sits outside a scroll view, and a fixed
                // height measured at the column's narrowest would become the window's minimum height.
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 16)
            actions
        }
    }
}

/// A module's first screen before it has results: big glyph, pitch, what it covers, and one button.
struct ModuleIntro: View {
    var theme: ModuleTheme
    var title: String
    var subtitle: String
    var bullets: [(symbol: String, text: String)] = []
    var actionTitle: String
    var busy = false
    var action: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            HeroGlyph(theme: theme, size: 128, active: busy)
                .appearIn()
            VStack(spacing: 8) {
                Text(title).font(.system(size: 32, weight: .bold, design: .rounded))
                Text(subtitle).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            .appearIn(delay: 0.06)
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                        Label {
                            Text(bullet.text).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: bullet.symbol).foregroundStyle(theme.gradient).frame(width: 22)
                        }
                    }
                }
                .font(.callout)
                .appearIn(delay: 0.12)
            }
            Button(action: action) {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(actionTitle)
                }
            }
            .buttonStyle(PrimaryPillStyle(theme: theme, large: true))
            .disabled(busy)
            .appearIn(delay: 0.18)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Buttons

/// A gradient capsule with a soft glow. The main action on a page.
struct PrimaryPillStyle: ButtonStyle {
    var theme: ModuleTheme
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .title3.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 34 : 18)
            .padding(.vertical, large ? 13 : 8)
            .background {
                Capsule().fill(theme.gradient)
                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.15), .clear], startPoint: .top, endPoint: .center)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            }
            .shadow(color: .black.opacity(isEnabled ? 0.25 : 0), radius: large ? 6 : 4, y: large ? 3 : 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A translucent capsule for secondary actions.
struct GlassPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// The large round button at the heart of Smart Scan.
struct OrbButtonStyle: ButtonStyle {
    var theme: ModuleTheme
    var size: CGFloat = 132

    func makeBody(configuration: Configuration) -> some View {
        OrbButtonBody(configuration: configuration, theme: theme, size: size)
    }
}

private struct OrbButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let theme: ModuleTheme
    let size: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ambientMotionPaused) private var ambientPaused

    var body: some View {
        ZStack {
            // The halo breathes on a capped timeline: only this circle redraws.
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || ambientPaused)) { context in
                let breathe = reduceMotion ? 0.5 : (1 - cos(context.date.timeIntervalSinceReferenceDate * .pi / 2.2)) / 2
                Circle()
                    .fill(theme.primary.opacity(0.07))
                    .frame(width: size * 1.32, height: size * 1.32)
                    .scaleEffect(0.96 + 0.06 * breathe)
            }
            Circle()
                .fill(theme.gradient)
                .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center)))
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                .frame(width: size, height: size)
            configuration.label
                .font(.system(size: size * 0.17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size * 1.32, height: size * 1.32)
        .scaleEffect(configuration.isPressed ? 0.94 : 1)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.spring(duration: 0.3, bounce: 0.45), value: configuration.isPressed)
        .contentShape(Circle())
    }
}

// MARK: Mac Health

extension MacHealth.Status {
    var color: Color {
        switch self {
        case .excellent: ModuleTheme.hex(0x34D399)
        case .good: ModuleTheme.hex(0x22D3EE)
        case .fair: ModuleTheme.hex(0xFACC15)
        case .needsAttention: ModuleTheme.hex(0xFB923C)
        case .critical: ModuleTheme.hex(0xF43F5E)
        }
    }
}

/// The Mac Health score as a glowing ring.
struct HealthRing: View {
    var health: MacHealth?
    var size: CGFloat = 180
    @State private var shown = false

    var body: some View {
        let color = health?.status.color ?? .white.opacity(0.4)
        let fraction = Double(health?.score ?? 0) / 100
        ZStack {
            Circle().fill(RadialGradient(colors: [color.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: size * 0.7))
                .frame(width: size * 1.35, height: size * 1.35)
            Circle().stroke(.white.opacity(0.08), lineWidth: 12)
                .frame(width: size - 12, height: size - 12)
            Circle()
                .trim(from: 0, to: shown ? fraction : 0)
                .stroke(AngularGradient(colors: [color.opacity(0.5), color, color.opacity(0.9)], center: .center),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size - 12, height: size - 12)
            VStack(spacing: 2) {
                if let health {
                    Text("\(health.score)")
                        .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                        .contentTransition(.numericText(value: Double(health.score)))
                    Text(health.status.title.uppercased())
                        .font(.system(size: 11, weight: .bold)).tracking(1.2)
                        .foregroundStyle(color)
                } else {
                    Image(systemName: "heart.text.square").font(.system(size: size * 0.2)).foregroundStyle(.secondary)
                    Text("MAC HEALTH").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 1.2, bounce: 0.15), value: health?.score)
        .onAppear { withAnimation(.spring(duration: 1.4, bounce: 0.12).delay(0.2)) { shown = true } }
        .accessibilityElement()
        .accessibilityLabel(health.map { "Mac Health \($0.score) of 100, \($0.status.title)" } ?? "Mac Health not measured yet")
    }
}

// MARK: Action bar

/// The bar along the bottom of a page: a summary on the left, the page's actions on the right.
struct ActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .font(.callout)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

/// A slim notice row that asks for Full Disk Access.
struct AccessRow: View {
    @Environment(AppModel.self) private var model
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Allow Full Disk Access") { model.openFullDiskAccessSettings() }
                .buttonStyle(GlassPillStyle()).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glass(cornerRadius: 14)
    }
}
