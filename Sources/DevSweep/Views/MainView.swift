import DevSweepCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            // No toolbar items at all, so the window has no toolbar: every page has its own header
            // and buttons, and macOS draws a toolbar as a solid grey bar in full screen. (Hiding the
            // toolbar outright would hide the close/minimise/zoom buttons too.) ⌘R still rescans.
            Sidebar()
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 280)
        } detail: {
            Group {
                switch model.section ?? .overview {
                case .overview: OverviewView()
                case .junk: JunkView()
                case .cloud: CloudView()
                case .privacy: PrivacyView()
                case .maintenance: MaintenanceView()
                case .memory: MemoryView()
                case .heat: TemperatureView()
                case .loginItems: LoginItemsView()
                case .uninstaller: UninstallerView()
                case .updater: UpdaterView()
                case .storageMap: StorageMapView()
                case .largeFiles: LargeFilesView()
                case .duplicates: DuplicatesView()
                case .projects: if model.settings.roots.isEmpty { OnboardingView() } else { ProjectsView() }
                case .caches: CachesView()
                case .devTools: DevToolsView()
                case .autoClean: AutoCleanView()
                case .screenCleaning: ScreenCleaningView()
                case .history: HistoryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AuroraBackground(theme: (model.section ?? .overview).theme))
            .id(model.section)
            .transition(.opacity.combined(with: .scale(scale: 0.99)))
            .animation(.easeInOut(duration: 0.22), value: model.section)
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                NoticeBanner(notice: notice) { model.notice = nil }
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(notice.style == .error ? 12 : 7))
                        if model.notice?.id == notice.id { model.notice = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: model.notice)
        .overlay {
            if let session = model.cleaning {
                CleaningOverlay(session: session)
            }
        }
        .pausesMotionWhenHidden()
        .sheet(item: $model.cleanReview) { review in
            CleanReviewSheet(review: review).environment(model)
        }
        .background(WindowAccessor { window in
            model.mainWindow = window
            if model.launchedAtLogin {
                // Started at login: live quietly in the menu bar.
                model.launchedAtLogin = false
                window.close()
            }
        })
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
            NSApp.setActivationPolicy(.regular)
        }
        .onReceive(NotificationCenter.default.publisher(for: .devSweepRescan)) { _ in rescan() }
        .onOpenURL { model.open($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let window = note.object as? NSWindow, window === model.mainWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

extension Notification.Name {
    static let devSweepRescan = Notification.Name("DevSweepRescan")
}

extension MainView {
    func rescan() {
        switch model.section ?? .overview {
        case .overview: model.smartScan()
        case .storageMap, .largeFiles: model.scanStorage()
        case .junk: model.scanJunk()
        case .caches: model.measureCaches()
        case .duplicates: model.duplicates.scan(folders: model.settings.duplicateFolders)
        case .uninstaller: model.uninstaller.scan()
        case .devTools: model.devTools.scan()
        case .loginItems: model.loginItems.refresh()
        case .privacy: model.privacy.scan()
        case .maintenance: model.maintenance.refresh()
        case .memory, .heat: model.processes.refreshNow()
        case .updater: model.updater.check()
        case .cloud: model.cloud.scan()
        case .autoClean, .screenCleaning: break
        case .projects, .history: model.scan()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.section) {
            // Rows are tagged with the section itself; the List maps that onto its optional
            // selection. (Identifiable rows would be tagged with their String id instead, and a
            // click would set the selection to nil.)
            ForEach(Array(SidebarSection.groups.enumerated()), id: \.offset) { _, group in
                if let title = group.title {
                    Section(title) {
                        ForEach(group.sections, id: \.self, content: row)
                    }
                } else {
                    ForEach(group.sections, id: \.self, content: row)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.base.opacity(0.55))
        .safeAreaInset(edge: .bottom) {
            if let disk = model.disk {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "internaldrive.fill").foregroundStyle(ModuleTheme.smartScan.gradient)
                        Text("\(Format.bytes(disk.available)) free")
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(disk.available)))
                            .animation(.snappy, value: disk.available)
                    }
                    .font(.callout.weight(.semibold))
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.1))
                            .overlay(alignment: .leading) {
                                Capsule().fill(ModuleTheme.smartScan.gradient)
                                    .frame(width: geo.size.width * Double(disk.used) / Double(max(disk.total, 1)))
                            }
                    }
                    .frame(height: 6)
                    Text("\(Format.bytes(disk.used)) used of \(Format.bytes(disk.total))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .glass(cornerRadius: 14)
                .padding(10)
            }
        }
    }

    private func row(_ section: SidebarSection) -> some View {
        HStack(spacing: 10) {
            ModuleGlyph(theme: section.theme, size: 22)
            Text(section.title)
            Spacer(minLength: 0)
            if let badge = badge(for: section) {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(section.theme.gradient))
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 2)
        .tag(section)
    }

    private func badge(for section: SidebarSection) -> String? {
        switch section {
        case .projects: model.idleProjects.isEmpty ? nil : "\(model.idleProjects.count)"
        case .updater: model.updater.updates.isEmpty ? nil : "\(model.updater.updates.count)"
        case .junk where model.suggestedJunkBytes > 1_000_000_000: Format.bytes(model.suggestedJunkBytes)
        default: nil
        }
    }
}
