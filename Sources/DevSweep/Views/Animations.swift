import AppKit
import DevSweepCore
import SwiftUI

// Motion used across the app. Continuous effects run on TimelineView only while they're
// visible and active, and everything falls back to a still image with Reduce Motion on.

/// Decorative motion runs at 30 fps: smooth to the eye at half the work.
let decorativeFrameInterval: TimeInterval = 1.0 / 30

private struct MotionHiddenKey: EnvironmentKey { static let defaultValue = false }
private struct AmbientMotionPausedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The window can't be seen (closed to the menu bar, minimised, covered or on another
    /// Space): every animation holds still.
    var motionHidden: Bool {
        get { self[MotionHiddenKey.self] }
        set { self[MotionHiddenKey.self] = newValue }
    }

    /// Also true while you're in another app: purely ambient motion (the background drift,
    /// breathing buttons) holds still, while progress animations keep going.
    var ambientMotionPaused: Bool {
        get { self[AmbientMotionPausedKey.self] }
        set { self[AmbientMotionPausedKey.self] = newValue }
    }
}

/// Tracks whether the window showing this view is visible and its app is active, and tells
/// the animations below through the environment.
struct MotionVisibility: ViewModifier {
    @State private var window: NSWindow?
    @State private var visible = true
    @State private var appActive = NSApp?.isActive ?? true

    func body(content: Content) -> some View {
        content
            .environment(\.motionHidden, !visible)
            .environment(\.ambientMotionPaused, !visible || !appActive)
            .background(WindowAccessor { found in
                window = found
                visible = found.occlusionState.contains(.visible)
            })
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                guard let changed = note.object as? NSWindow, changed === window else { return }
                visible = changed.occlusionState.contains(.visible)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                if let closing = note.object as? NSWindow, closing === window { visible = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
    }
}

extension View {
    /// Pauses this window's animations while nobody can see them.
    func pausesMotionWhenHidden() -> some View { modifier(MotionVisibility()) }

    /// Runs `start` while the view is on screen in a visible window and `stop` once it isn't.
    /// (A window closed to the menu bar keeps its views, so onDisappear alone isn't enough.)
    func whileVisible(start: @escaping () -> Void, stop: @escaping () -> Void) -> some View {
        modifier(WhileVisible(start: start, stop: stop))
    }
}

private struct WhileVisible: ViewModifier {
    let start: () -> Void
    let stop: () -> Void
    @Environment(\.motionHidden) private var hidden
    @State private var running = false

    func body(content: Content) -> some View {
        content
            .onAppear { set(!hidden) }
            .onDisappear { set(false) }
            .onChange(of: hidden) { _, isHidden in set(!isHidden) }
    }

    private func set(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on { start() } else { stop() }
    }
}

/// Sonar rings, a sweeping arc and a breathing core: "something is being looked at".
/// Drawn on a Canvas so each frame is a repaint, not a re-layout of the page around it.
struct ScanningOrb: View {
    var size: CGFloat = 64
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionHidden) private var hidden

    var body: some View {
        TimelineView(.animation(minimumInterval: decorativeFrameInterval, paused: reduceMotion || hidden)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, area in
                let center = CGPoint(x: area.width / 2, y: area.height / 2)
                let radius = min(area.width, area.height) / 2
                func circle(_ r: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                }
                for ring in 0..<3 {
                    let phase = (t / 2.4 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    canvas.stroke(circle(radius * (0.42 + phase * 0.58) - 1), with: .color(tint.opacity(0.55 * (1 - phase))), lineWidth: 1.5)
                }
                // Sweeping arc with a fading tail.
                let arcRadius = radius * 0.8
                let lead = Angle.degrees(t * 230)
                for step in 0..<12 {
                    var arc = Path()
                    let from = lead - .degrees(Double(step + 1) * 9)
                    arc.addArc(center: center, radius: arcRadius, startAngle: from, endAngle: from + .degrees(9.5), clockwise: false)
                    canvas.stroke(arc, with: .color(tint.opacity(1 - Double(step) / 12)),
                                  style: StrokeStyle(lineWidth: max(2, size * 0.045), lineCap: step == 0 ? .round : .butt))
                }
                canvas.fill(circle(radius * 0.44 * (1 + 0.07 * sin(t * 3))), with: .color(tint.opacity(0.18)))
            }
            .drawingGroup()
        }
        .overlay {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.22, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Scanning")
    }
}

/// Little four-pointed stars drifting upwards and twinkling.
struct SparkleField: View {
    var active: Bool
    var color: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Particle {
        let x = Double.random(in: 0...1)
        let speed = Double.random(in: 0.05...0.14)
        let size = Double.random(in: 2...6)
        let phase = Double.random(in: 0...1)
        let sway = Double.random(in: 0.6...1.6)
    }

    @State private var particles = (0..<34).map { _ in Particle() }
    @Environment(\.motionHidden) private var hidden

    var body: some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: decorativeFrameInterval, paused: hidden)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Canvas { canvas, size in
                    for p in particles {
                        let progress = (t * p.speed + p.phase).truncatingRemainder(dividingBy: 1)
                        let y = size.height * (1.05 - progress * 1.1)
                        let x = size.width * p.x + sin(t * p.sway + p.phase * 6) * 14
                        let twinkle = 0.55 + 0.45 * sin(t * 4 + p.phase * 12)
                        canvas.opacity = min(progress * 5, (1 - progress) * 3, 1) * twinkle * 0.85
                        canvas.fill(star(CGPoint(x: x, y: y), radius: p.size), with: .color(color))
                    }
                }
                .drawingGroup()
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

func star(_ center: CGPoint, radius: Double) -> Path {
    var path = Path()
    let inner = radius * 0.28
    for i in 0..<8 {
        let angle = Double(i) * .pi / 4 - .pi / 2
        let r = i.isMultiple(of: 2) ? radius : inner
        let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// The brand gradient, slowly turning and with a soft light drifting across while active.
struct LivelyGradient: View {
    var active: Bool
    var cornerRadius: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionHidden) private var hidden

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if active && !reduceMotion {
                TimelineView(.animation(minimumInterval: decorativeFrameInterval, paused: hidden)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Canvas { canvas, size in
                        let rect = CGRect(origin: .zero, size: size)
                        let angle = t * 0.35
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let reach = CGPoint(x: cos(angle) * size.width * 0.6, y: sin(angle) * size.height * 0.6)
                        canvas.fill(Path(rect), with: .linearGradient(
                            Gradient(colors: [Brand.teal, Color(red: 0.2, green: 0.55, blue: 0.92), Brand.indigo]),
                            startPoint: CGPoint(x: center.x - reach.x, y: center.y - reach.y),
                            endPoint: CGPoint(x: center.x + reach.x, y: center.y + reach.y)))
                        // A soft light drifting left and right.
                        let light = CGPoint(x: size.width * (0.5 + 0.45 * sin(t * 0.6)), y: size.height * 0.2)
                        canvas.fill(Path(rect), with: .radialGradient(
                            Gradient(colors: [.white.opacity(0.2), .white.opacity(0)]),
                            center: light, startRadius: 0, endRadius: size.height * 0.9))
                    }
                    .drawingGroup()
                }
            } else {
                shape.fill(Brand.gradient)
            }
        }
        .clipShape(shape)
    }
}

/// A one-shot burst of confetti, timed from `start`.
struct ConfettiBurst: View {
    let start: Date
    var duration: Double = 2.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finished = false

    private struct Piece {
        let vx = Double.random(in: -1.7...1.7)
        let vy = Double.random(in: -3.4...(-1.3))
        let spin = Double.random(in: -9...9)
        let color = [Brand.teal, Brand.indigo, Color.pink, .orange, .yellow, .green, .purple].randomElement()!
        let width = Double.random(in: 5...8)
        let isStar = Double.random(in: 0...1) < 0.3
    }

    @State private var pieces = (0..<70).map { _ in Piece() }

    var body: some View {
        if !reduceMotion && !finished {
            TimelineView(.animation(minimumInterval: decorativeFrameInterval)) { context in
                let t = context.date.timeIntervalSince(start)
                Canvas { canvas, size in
                    guard t >= 0, t < duration else { return }
                    let origin = CGPoint(x: size.width / 2, y: size.height * 0.32)
                    for p in pieces {
                        let x = origin.x + p.vx * t * 150
                        let y = origin.y + p.vy * t * 150 + 260 * t * t
                        canvas.opacity = max(0, 1 - t / duration)
                        if p.isStar {
                            canvas.fill(star(CGPoint(x: x, y: y), radius: p.width), with: .color(p.color))
                        } else {
                            var piece = canvas
                            piece.translateBy(x: x, y: y)
                            piece.rotate(by: .radians(p.spin * t))
                            piece.fill(Path(roundedRect: CGRect(x: -p.width / 2, y: -p.width * 0.75, width: p.width, height: p.width * 1.5),
                                            cornerRadius: 1.5), with: .color(p.color))
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .task {
                try? await Task.sleep(for: .seconds(duration + 0.1))
                finished = true
            }
        }
    }
}

/// Byte counts that count up to their value (and between values) instead of jumping.
struct CountUpBytes: View {
    var value: Int64
    var font: Font = .body
    var duration: Double = 0.9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var from: Int64 = 0
    @State private var target: Int64 = 0
    @State private var start = Date.distantPast
    @State private var settled = true

    var body: some View {
        Group {
            if reduceMotion {
                Text(Format.bytes(value))
            } else {
                TimelineView(.animation(minimumInterval: decorativeFrameInterval, paused: settled)) { context in
                    let progress = min(1, max(0, context.date.timeIntervalSince(start) / duration))
                    let eased = 1 - pow(1 - progress, 3)
                    let shown = settled ? Double(target) : Double(from) + Double(target - from) * eased
                    Text(Format.bytes(Int64(shown)))
                }
            }
        }
        .font(font)
        .monospacedDigit()
        .onAppear { animate(from: 0, to: value) }
        .onChange(of: value) { old, new in animate(from: old, to: new) }
        .task(id: start) {
            try? await Task.sleep(for: .seconds(duration + 0.05))
            settled = true
        }
    }

    private func animate(from old: Int64, to new: Int64) {
        from = old
        target = new
        start = Date()
        settled = false
    }
}

/// A capsule that grows from nothing to its width when it appears.
struct GrowingBar<Fill: ShapeStyle>: View {
    var fraction: Double
    var fill: Fill
    var height: CGFloat = 6
    var delay: Double = 0
    @State private var shown = false

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(fill)
                .frame(width: max(3, geo.size.width * (shown ? min(1, max(0, fraction)) : 0)))
        }
        .frame(height: height)
        .animation(.spring(duration: 0.6), value: fraction)
        .onAppear {
            withAnimation(.spring(duration: 0.8, bounce: 0.15).delay(delay)) { shown = true }
        }
    }
}

/// A ring that fills with progress.
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 10
    var spinning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionHidden) private var hidden

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            if spinning && !reduceMotion {
                TimelineView(.animation(minimumInterval: decorativeFrameInterval, paused: hidden)) { context in
                    Circle()
                        .trim(from: 0, to: 0.18)
                        .stroke(Brand.teal.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 260))
                }
            }
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(AngularGradient(colors: [Brand.teal, Brand.indigo, Brand.teal], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Brand.indigo.opacity(0.35), radius: 6)
        }
        .animation(.spring(duration: 0.5), value: progress)
    }
}

extension View {
    /// Fades and slides the view in when it first appears.
    func appearIn(delay: Double = 0) -> some View { modifier(AppearIn(delay: delay)) }

    /// Lifts the view slightly under the pointer.
    func hoverLift() -> some View { modifier(HoverLift()) }
}

private struct AppearIn: ViewModifier {
    var delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                withAnimation(.spring(duration: 0.55, bounce: 0.2).delay(delay)) { shown = true }
            }
    }
}

private struct HoverLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.02 : 1)
            .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: hovering ? 12 : 0, y: hovering ? 6 : 0)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Full-page "measuring" state with the orb and rolling counters.
struct ScanningPlaceholder: View {
    @Environment(AppModel.self) private var model
    var title: String

    var body: some View {
        VStack(spacing: 18) {
            ScanningOrb(size: 130, tint: Brand.teal)
            Text(title).font(.title3.weight(.semibold))
            HStack(spacing: 6) {
                Text(model.storageProgress.files.formatted())
                    .contentTransition(.numericText(value: Double(model.storageProgress.files)))
                Text("files ·")
                Text(Format.bytes(model.storageProgress.bytes))
                    .contentTransition(.numericText(value: Double(model.storageProgress.bytes)))
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .animation(.snappy(duration: 0.25), value: model.storageProgress.files)
            Text(Paths.display(model.storageProgress.currentPath))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
            Button("Stop") { model.cancelSmartScan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}
