import AppKit
import DevSweepCore
import SwiftUI
@preconcurrency import UserNotifications

@main
enum Entry {
    static func main() {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--render-motion"), i + 2 < CommandLine.arguments.count {
            ScreenRenderer.renderMotion(output: CommandLine.arguments[i + 1], fixtures: CommandLine.arguments[i + 2])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-demo"), i + 1 < CommandLine.arguments.count {
            ScreenRenderer.renderDemo(output: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-fullscreen"), i + 1 < CommandLine.arguments.count {
            ScreenRenderer.renderFullScreen(output: CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--perf-idle") {
            ScreenRenderer.measureIdleCPU()
            return
        }
        if CommandLine.arguments.contains("--perf-scanning") {
            ScreenRenderer.measureScanningCPU()
            return
        }
        if CommandLine.arguments.contains("--test-sidebar") {
            ScreenRenderer.testSidebar()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-screens"), i + 1 < CommandLine.arguments.count {
            ScreenRenderer.run(output: CommandLine.arguments[i + 1], roots: Array(CommandLine.arguments[(i + 2)...]))
            return
        }
        #endif
        DevSweepApp.main()
    }
}

struct DevSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("DevSweep", id: "main") {
            MainView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(ModuleTheme.smartScan.primary)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Again") { NotificationCenter.default.post(name: .devSweepRescan, object: nil) }
                    .keyboardShortcut("r")
                    .disabled(model.isSmartScanning)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Started by macOS at login: stay in the menu bar instead of opening a window.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            AppModel.shared.launchedAtLogin = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        AppModel.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.showMainWindow() }
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            let model = AppModel.shared
            model.showMainWindow()
            model.showProjects(filter: .idle)
            model.requestClean(model.idleProjects)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
