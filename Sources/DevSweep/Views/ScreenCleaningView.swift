import AppKit
import SwiftUI

struct ScreenCleaningView: View {
    @AppStorage("screenCleaningMinutes") private var minutes = 2
    let theme = ModuleTheme.screenCleaning

    var body: some View {
        VStack(spacing: 0) {
            ModuleIntro(theme: theme, title: "Screen & Keyboard Cleaning",
                        subtitle: "Turns every display black and ignores the keyboard and trackpad, so you can wipe them without clicking or typing anything.",
                        bullets: [("display", "A black screen shows smudges and dust clearly"),
                                  ("keyboard", "Keys, clicks and gestures do nothing while it's on"),
                                  ("escape", "Hold esc for two seconds to finish"),
                                  ("timer", "Ends on its own after \(minutes) minute\(minutes == 1 ? "" : "s")")],
                        actionTitle: "Start Cleaning") { CleaningModeController.shared.start(minutes: minutes) }
            HStack(spacing: 10) {
                Text("Finish automatically after").foregroundStyle(.secondary)
                Picker("", selection: $minutes) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.bottom, 36)
        }
    }
}

// MARK: Cleaning mode

@Observable @MainActor
final class CleaningModeState {
    var escProgress = 0.0
    var remaining = 0
    var hintVisible = true
}

/// Full-screen black windows on every display that swallow input until esc is held.
@MainActor
final class CleaningModeController {
    static let shared = CleaningModeController()
    static let holdDuration = 2.0

    private let state = CleaningModeState()
    private var windows: [NSWindow] = []
    private var savedOptions: NSApplication.PresentationOptions = []
    private var monitor: Any?
    private var countdown: Timer?
    private var hold: DispatchWorkItem?
    private var hintHide: DispatchWorkItem?

    var isActive: Bool { !windows.isEmpty }

    func start(minutes: Int) {
        guard windows.isEmpty else { return }
        state.escProgress = 0
        state.remaining = max(1, minutes) * 60
        savedOptions = NSApp.presentationOptions
        for screen in NSScreen.screens {
            let window = CleaningWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: CleaningModeScreen(state: state, showsControls: screen == NSScreen.main))
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Hiding the Dock and menu bar is what lets macOS also turn off app switching.
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication, .disableAppleMenu]
        NSCursor.hide()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown,
                                                              .otherMouseDown, .scrollWheel, .magnify, .rotate, .swipe, .mouseMoved]) { [weak self] event in
            self?.handle(event)
            return nil
        }
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in CleaningModeController.shared.tick() }
        }
        showHint()
    }

    func stop() {
        guard !windows.isEmpty else { return }
        countdown?.invalidate()
        countdown = nil
        hold?.cancel()
        hintHide?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NSApp.presentationOptions = savedOptions
        NSCursor.unhide()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private func tick() {
        state.remaining -= 1
        if state.remaining <= 0 { stop() }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown where event.keyCode == 53:
            guard !event.isARepeat, hold == nil else { return }
            showHint()
            withAnimation(.linear(duration: Self.holdDuration)) { state.escProgress = 1 }
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            hold = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: work)
        case .keyUp where event.keyCode == 53:
            hold?.cancel()
            hold = nil
            withAnimation(.easeOut(duration: 0.25)) { state.escProgress = 0 }
        case .keyDown, .leftMouseDown, .rightMouseDown:
            showHint()
        default:
            break
        }
    }

    /// The hint fades out after a few seconds so the screen is fully black for spotting smudges.
    private func showHint() {
        withAnimation(.easeOut(duration: 0.3)) { state.hintVisible = true }
        hintHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hold == nil else { return }
            withAnimation(.easeInOut(duration: 1.2)) { self.state.hintVisible = false }
        }
        hintHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

private final class CleaningWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct CleaningModeScreen: View {
    let state: CleaningModeState
    let showsControls: Bool

    var body: some View {
        ZStack {
            Color.black
            if showsControls {
                VStack(spacing: 16) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: state.escProgress)
                            .stroke(ModuleTheme.screenCleaning.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("esc").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                    }
                    .frame(width: 58, height: 58)
                    Text("Wipe away. Hold esc to finish.")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("Ends by itself in \(state.remaining / 60):\(String(format: "%02d", state.remaining % 60))")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
                .opacity(state.hintVisible || state.escProgress > 0 ? 1 : 0)
            }
        }
        .ignoresSafeArea()
    }
}
