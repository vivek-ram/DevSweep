#if DEBUG
import AppKit
import DevSweepCore
import SwiftUI

/// Debug aid: renders each screen to a PNG without needing screen-recording permission.
///   DevSweep --render-screens <output-dir> <folder-to-scan>...
@MainActor
enum ScreenRenderer {
    static func run(output: String, roots: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let env = ProcessInfo.processInfo.environment
        app.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

        let model = AppModel.shared
        model.settings.roots = roots
        model.settings.retentionDays = Int(env["RENDER_DAYS"] ?? "") ?? 30
        model.refreshDisk()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let result = try? await ProjectScanner().scan(roots: roots)
            let storage = env["RENDER_STORAGE"] != nil ? try? await StorageScanner().scan(root: NSHomeDirectory()) : nil
            let junk = JunkScanner.scan()
            await MainActor.run {
                model.storage = storage
                model.largeFiles = storage?.largeFiles ?? []
                model.junk = junk
                model.junkSelection = Set(junk.filter(\.suggested).map(\.path))
                model.junkScannedAt = Date()
                model.projects = result?.projects ?? []
                model.lastScan = result?.date
                model.lastScanDuration = result?.duration
                model.caches = CacheCatalog.installed()
                for i in model.caches.indices { model.caches[i].bytes = DiskUsage.freeableBytes(at: model.caches[i].path) }
                model.caches.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        let size = NSSize(width: 1120, height: 740)
        func waitUntil(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(240)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        if env["RENDER_FEATURES"] != nil {
            model.uninstaller.scan()
            model.duplicates.scan(folders: model.settings.duplicateFolders)
            model.devTools.scan()
            model.loginItems.refresh()
            waitUntil { !model.uninstaller.isScanning && !model.duplicates.isScanning && !model.devTools.isScanning && !model.loginItems.isLoading }
            model.uninstaller.selectedApp = model.uninstaller.apps.first?.id
            // Illustrative history so the chart and growth card have something to show.
            var history = SpaceHistory()
            let now = Date()
            for hour in stride(from: 24 * 30, through: 0, by: -6) {
                let wobble = sin(Double(hour) / 30) * 3e9 - Double(24 * 30 - hour) * 1.5e7
                history.record(free: Int64(52e9 + wobble), total: 245_000_000_000, at: now.addingTimeInterval(-Double(hour) * 3_600))
            }
            if let root = model.storage?.root {
                history.record(root, at: now.addingTimeInterval(-6 * 86_400))
                var sizes = history.snapshots.last?.sizes ?? [:]
                let google = NSHomeDirectory() + "/Library/Caches/Google"
                for path in [google, NSHomeDirectory() + "/Library/Caches", NSHomeDirectory() + "/Library", NSHomeDirectory()] {
                    sizes[path, default: 0] += 6_400_000_000
                }
                history.record(sizes: sizes, at: now)
            }
            model.spaceHistory = history
            model.settings.autoCleanRuns = [AutoCleanRun(date: now.addingTimeInterval(-2 * 86_400), reason: .schedule, freed: 1_840_000_000, items: 23),
                                            AutoCleanRun(date: now.addingTimeInterval(-9 * 86_400), reason: .lowSpace, freed: 4_200_000_000, items: 31)]
            model.settings.lastAutoClean = now.addingTimeInterval(-2 * 86_400)
            model.monitor.start()
            RunLoop.main.run(until: Date().addingTimeInterval(5))
            for (section, name) in [(SidebarSection.duplicates, "11-duplicates"), (.uninstaller, "12-uninstaller"), (.devTools, "13-devtools"),
                                    (.autoClean, "14-autoclean"), (.loginItems, "15-loginitems")] {
                model.section = section
                snap(MainView(), size, name, output)
            }
            snap(MenuBarPanel(), NSSize(width: 310, height: 560), "16-menubar-monitor", output)
            snap(MenuBarPanel(showing: .memory), NSSize(width: 310, height: 760), "16b-menubar-memory", output)
            snap(HStack(alignment: .top, spacing: 16) { FreeSpaceTrendCard(); GrowthCard() }.padding(24).frame(width: 900),
                 NSSize(width: 900, height: 330), "17-history-cards", output)
        }
        if env["RENDER_CARE"] != nil {
            model.privacy.scan()
            model.cloud.scan()
            model.updater.check()
            model.maintenance.refresh()
            waitUntil { !model.privacy.isScanning && !model.cloud.isScanning && !model.updater.isChecking }
            model.monitor.start()
            model.processes.start()
            RunLoop.main.run(until: Date().addingTimeInterval(4.5))
            for (section, name) in [(SidebarSection.privacy, "18-privacy"), (.maintenance, "19-maintenance"), (.updater, "20-updater"),
                                    (.cloud, "21-cloud"), (.screenCleaning, "22-screen-cleaning"), (.memory, "23-memory")] {
                model.section = section
                snap(MainView(), size, name, output)
            }
        }
        model.section = .overview
        snap(MainView(), size, "1-overview", output)
        model.section = .projects
        model.projectFilter = .all
        model.selectedProjects = model.projects.first.map { [$0.id] } ?? []
        snap(MainView(), size, "2-projects", output)
        model.section = .caches
        snap(MainView(), size, "3-caches", output)
        model.section = .storageMap
        model.mapPath = nil
        snap(MainView(), size, "7-storage-map", output)
        model.section = .junk
        snap(MainView(), size, "8-junk", output)
        model.section = .largeFiles
        snap(MainView(), size, "9-large-files", output)
        model.section = .history
        snap(MainView(), size, "4-history", output)
        snap(MenuBarPanel(), NSSize(width: 310, height: 330), "5-menubar", output)
        let withVenvs = model.projects.filter { $0.artifacts.contains { $0.kind == .pythonVenv } }
        if !withVenvs.isEmpty {
            snap(CleanReviewSheet(review: CleanReview(projects: Array(withVenvs.prefix(3)))), NSSize(width: 620, height: 540), "10-review", output)
        }
        snap(SettingsView(), NSSize(width: 560, height: 620), "6-settings", output)
        model.settings.roots = []
        snap(OnboardingView(), size, "0-onboarding", output)
    }

    /// Clicks each sidebar row with synthesized mouse events and checks the section changes.
    static func testSidebar() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel.shared
        model.settings.roots = ["/tmp"]
        model.section = .overview
        let hosting = NSHostingView(rootView: MainView().environment(model))
        hosting.frame = NSRect(x: 0, y: 0, width: 1120, height: 740)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .fullSizeContentView, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        func tables(_ v: NSView) -> [NSTableView] { (v as? NSTableView).map { [$0] } ?? [] + v.subviews.flatMap(tables) }
        // What a click does once it reaches the table: change its selection, which SwiftUI must
        // turn into a new value for the List's selection binding.
        let sidebar = tables(window.contentView!).first { $0.frame.width < 300 }

        // Section headers are rows too; select every row and collect where each one leads.
        var reached = Set<SidebarSection>()
        for row in 0..<(sidebar?.numberOfRows ?? 0) {
            model.section = nil
            // Let SwiftUI clear the table's selection first, or re-selecting the same row is a no-op.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            sidebar?.selectRowIndexes([row], byExtendingSelection: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            if let section = model.section {
                reached.insert(section)
                print("✔ row \(row) → \(section.title)")
            } else {
                print("  row \(row) → (no section: header or spacer)")
            }
        }
        let missing = Set(SidebarSection.allCases).subtracting(reached)
        print(missing.isEmpty ? "SIDEBAR OK" : "SIDEBAR BROKEN, unreachable: \(missing.map(\.title))")
    }

    /// Captures frames of the scanning hero and of a real clean (of throwaway fixture projects,
    /// deleted permanently) so the motion can be checked frame by frame.
    static func renderMotion(output: String, fixtures: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["DEMO"] != nil { loadDemo() }
        let model = AppModel.shared
        model.settings.roots = [fixtures]
        model.settings.removalMode = .permanent
        model.refreshDisk()

        let window = host(MainView(), NSSize(width: 1120, height: 740))
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func frame(_ name: String) {
            guard let createImage, let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue() else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
        }

        // Scanning: fake a storage scan in flight.
        model.section = .overview
        model.isScanningStorage = true
        model.isScanningJunk = true
        wait(1.0)
        for i in 0..<3 {
            model.storageProgress.files += 48_211 + i * 9_000
            model.storageProgress.bytes += 7_400_000_000
            model.storageProgress.currentPath = NSHomeDirectory() + "/Library/Caches/Google/Chrome/Default/Cache_\(i)"
            if i == 1 { model.isScanningJunk = false }
            wait(0.35)
            frame("scan-\(i)")
        }
        model.isScanningStorage = false
        model.isScanningJunk = false

        // Cleaning: scan the fixtures, then clean them all and film the panel.
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let result = try? await ProjectScanner().scan(roots: [fixtures])
            await MainActor.run { model.projects = result?.projects ?? [] }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut { wait(0.05) }
        model.section = .projects
        wait(0.5)
        let targets = model.projects
        Task { await model.clean(targets, approvedVenvs: []) }
        for (i, delay) in [0.25, 0.5, 0.6, 0.6, 0.35, 0.35].enumerated() {
            wait(delay)
            frame("clean-\(i)")
        }
        window.orderOut(nil)
    }

    /// CPU used by the Smart Scan page while its scanning animations run, measured inside the
    /// normal app event loop (so idle time is really idle).
    static func measureScanningCPU() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel.shared
        model.settings.roots = ["/tmp"]
        model.section = .overview
        model.isScanningStorage = true
        model.isScanningJunk = true
        let window = host(MainView(), NSSize(width: 1120, height: 740))
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                model.storageProgress.files += 3_000
                model.storageProgress.bytes += 400_000_000
                model.storageProgress.currentPath = NSHomeDirectory() + "/Library/Caches/item-\(model.storageProgress.files)"
            }
        }
        var before = 0.0
        var started = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            before = cpuSeconds()
            started = Date()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            let used = cpuSeconds() - before
            print(String(format: "Scanning page: %.0f%% of one core", used / Date().timeIntervalSince(started) * 100))
            window.orderOut(nil)
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
        }
        app.run()
    }

    /// Fills every store with made-up data (see DemoData), so screenshots show nothing real.
    static func loadDemo() {
        let model = AppModel.shared
        AppModel.demo = true
        Volumes.demo = DemoData.volumes()
        model.settings.roots = [DemoData.projectRoot]
        model.settings.retentionDays = 30
        model.hasFullDiskAccess = true
        model.disk = DemoData.disk
        model.projects = DemoData.projects()
        model.lastScan = Date().addingTimeInterval(-240)
        model.lastScanDuration = 3.4
        model.projectFilter = .all
        model.selectedProjects = ["\(DemoData.projectRoot)/ml-experiments"]

        let storage = DemoData.storage()
        model.storage = storage
        model.largeFiles = storage.largeFiles
        model.mapPath = nil
        model.storageVersion += 1
        let junk = DemoData.junk()
        model.junk = junk
        model.junkSelection = Set(junk.filter(\.suggested).map(\.path))
        model.junkScannedAt = Date()
        model.caches = DemoData.caches()

        model.uninstaller.apps = DemoData.apps().map { AppRow(app: $0.app, files: $0.files, lastUsed: $0.app.lastUsed) }
            .sorted { $0.totalBytes > $1.totalBytes }
        model.uninstaller.leftovers = DemoData.leftovers()
        model.uninstaller.leftoverSelection = Set(DemoData.leftovers().flatMap { $0.files.map(\.path) })
        model.uninstaller.selectedApp = "/Applications/Google Chrome.app"
        model.uninstaller.scannedAt = Date()
        model.duplicates.groups = DemoData.duplicates()
        model.duplicates.scannedAt = Date()
        model.duplicates.markSuggested()
        model.devTools.items = DemoData.toolCleanups()
        model.devTools.selection = Set(DemoData.toolCleanups().filter(\.suggested).map(\.id))
        model.devTools.scannedAt = Date()
        model.loginItems.demo = true
        model.loginItems.items = DemoData.launchItems()

        let privacy = DemoData.privacyItems()
        model.privacy.items = privacy
        model.privacy.recentLists = DemoData.recentItemsLists()
        model.privacy.permissions = DemoData.permissions()
        model.privacy.security = DemoData.security()
        model.privacy.selection = Set(privacy.filter(\.kind.suggested).map(\.id))
        model.privacy.scannedAt = Date()
        model.updater.updates = DemoData.updates()
        model.updater.checkedAt = Date().addingTimeInterval(-60)
        model.cloud.locations = DemoData.cloudLocations()
        model.cloud.files = DemoData.cloudFiles()
        model.cloud.selection = Set(DemoData.cloudFiles().prefix(3).map(\.path))
        model.cloud.scannedAt = Date()
        model.downloads.items = DemoData.downloads()
        model.downloads.scannedAt = Date()
        model.processes.showDemo(DemoData.appUsage(), quittable: DemoData.quittablePIDs)
        model.monitor.showDemo(DemoData.memorySnapshot())

        model.history = DemoData.history()
        model.trashedItems = []
        let now = Date()
        model.settings.autoCleanEnabled = true
        model.settings.autoCleanRuns = [AutoCleanRun(date: now.addingTimeInterval(-86_400), reason: .schedule, freed: 2_120_000_000, items: 18),
                                        AutoCleanRun(date: now.addingTimeInterval(-15 * 86_400), reason: .schedule, freed: 1_740_000_000, items: 22),
                                        AutoCleanRun(date: now.addingTimeInterval(-29 * 86_400), reason: .lowSpace, freed: 3_900_000_000, items: 31)]
        model.settings.lastAutoClean = now.addingTimeInterval(-86_400)

        // A month of free space with a dip, and one folder that grew.
        var history = SpaceHistory()
        for hour in stride(from: 24 * 30, through: 0, by: -6) {
            let days = Double(24 * 30 - hour) / 24
            let free = 58e9 + sin(days / 3.2) * 4e9 - days * 2.5e8 + (days > 22 ? 9e9 : 0)
            history.record(free: Int64(free), total: DemoData.disk.total, at: now.addingTimeInterval(-Double(hour) * 3_600))
        }
        history.record(storage.root, at: now.addingTimeInterval(-6 * 86_400))
        var sizes = history.snapshots.last?.sizes ?? [:]
        for path in [Paths.home + "/Library/Developer/CoreSimulator", Paths.home + "/Library/Developer", Paths.home + "/Library"] {
            sizes[path, default: 0] -= 5_200_000_000
        }
        history.record(sizes: sizes, at: now.addingTimeInterval(-6 * 86_400 + 60))
        history.record(storage.root, at: now)
        model.spaceHistory = history
    }

    /// Renders the README screenshots from demo data.   DevSweep --render-demo <output-dir>
    static func renderDemo(output: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        loadDemo()
        let model = AppModel.shared
        let size = NSSize(width: 1120, height: 740)
        let screens: [(SidebarSection, String)] = [
            (.overview, "smart-scan"), (.junk, "junk"), (.cloud, "cloud"), (.privacy, "privacy"), (.maintenance, "maintenance"),
            (.memory, "memory"), (.loginItems, "login-items"), (.uninstaller, "uninstaller"), (.updater, "updater"),
            (.storageMap, "storage-map"), (.largeFiles, "large-files"), (.duplicates, "duplicates"), (.projects, "projects"),
            (.caches, "caches"), (.devTools, "devtools"), (.autoClean, "auto-clean"), (.screenCleaning, "screen-cleaning"),
            (.history, "activity"),
        ]
        for (section, name) in screens {
            model.section = section
            snap(MainView(), size, name, output)
        }
        snap(MenuBarPanel(showing: .memory), NSSize(width: 310, height: 770), "menubar", output, windowChrome: false)
    }

    /// Puts the main window in full screen and captures it, to check nothing is drawn above
    /// the content.   DevSweep --render-fullscreen <output.png>
    static func renderFullScreen(output: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .darkAqua)
        let model = AppModel.shared
        model.settings.roots = ["/tmp"]
        model.refreshDisk()
        model.section = .largeFiles
        let hosting = NSHostingView(rootView: MainView().environment(model).preferredColorScheme(.dark).tint(ModuleTheme.smartScan.primary))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { window.toggleFullScreen(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            print("fullscreen:", window.styleMask.contains(.fullScreen), "toolbar:", window.toolbar == nil ? "none" : "present")
            // Every window this process shows, so a separate full-screen toolbar window would show up too.
            let mine = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
            for info in mine {
                print("window", info[kCGWindowNumber as String] ?? "", info[kCGWindowBounds as String] ?? "")
            }
            if let createImage, let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            }
            window.toggleFullScreen(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) {
            window.close()
            app.terminate(nil)
        }
        app.run()
    }

    /// CPU each page uses while just sitting there, measured in the normal event loop.
    ///   DevSweep --perf-idle
    static func measureIdleCPU() {
        let app = NSApplication.shared
        // PERF_ACTIVE=1 measures with DevSweep in front, so ambient motion runs.
        let active = ProcessInfo.processInfo.environment["PERF_ACTIVE"] != nil
        app.setActivationPolicy(active ? .regular : .accessory)
        let model = AppModel.shared
        model.settings.roots = ["/tmp"]
        model.refreshDisk()
        model.lastScan = Date()
        let window = host(MainView(), NSSize(width: 1120, height: 740))
        if active {
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }
        let sections: [SidebarSection] = [.overview, .junk, .maintenance, .memory, .screenCleaning, .autoClean, .history]
        func measure(_ index: Int) {
            guard index < sections.count else {
                window.orderOut(nil)
                app.stop(nil)
                app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
                return
            }
            model.section = sections[index]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let before = cpuSeconds(), started = Date(), refreshes = model.processes.refreshCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    let used = cpuSeconds() - before
                    print(String(format: "%@: %.0f%% of one core (%d app samples, window visible: %@)", sections[index].title,
                                 used / Date().timeIntervalSince(started) * 100, model.processes.refreshCount - refreshes,
                                 window.occlusionState.contains(.visible) ? "yes" : "no"))
                    measure(index + 1)
                }
            }
        }
        DispatchQueue.main.async { measure(0) }
        app.run()
    }

    private static func host<V: View>(_ view: V, _ size: NSSize) -> NSWindow {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(AppModel.shared).preferredColorScheme(.dark).tint(ModuleTheme.smartScan.primary))
        hosting.sizingOptions = [.minSize]
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        return window
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// A process may always capture its own windows. CGWindowListCreateImage is hidden from the
    /// current SDK, so look it up at runtime.
    private static let createImage: CreateImage? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    private static func snap<V: View>(_ view: V, _ size: NSSize, _ name: String, _ output: String, windowChrome: Bool = true) {
        // A fixed frame, like the real window's minimum size, so wrapping text isn't measured at zero width.
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(AppModel.shared).preferredColorScheme(.dark).tint(ModuleTheme.smartScan.primary))
        hosting.sizingOptions = [.minSize]
        hosting.frame = NSRect(origin: .zero, size: size)
        // Panels like the menu bar's have no title bar or window buttons.
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: windowChrome ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(Palette.base)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        if ProcessInfo.processInfo.environment["DEBUG_TOOLBAR"] != nil {
            let close = window.standardWindowButton(.closeButton)
            print(name, "toolbar:", window.toolbar.map { "visible=\($0.isVisible) items=\($0.items.map(\.itemIdentifier.rawValue))" } ?? "none",
                  "titlebarHeight:", window.frame.height - window.contentLayoutRect.height,
                  "window buttons:", close == nil ? "missing" : (close!.isHidden || close!.superview?.isHidden == true || close!.window == nil ? "hidden" : "shown"))
        }
        // Tear the view down so its animations stop and don't slow the next screens.
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        // .optionIncludingWindow, .boundsIgnoreFraming | .bestResolution
        guard let createImage, let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue() else {
            print("capture failed for \(name)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
    }
}
#endif
