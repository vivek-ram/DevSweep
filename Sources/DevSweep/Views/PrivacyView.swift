import AppKit
import DevSweepCore
import SwiftUI

struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.browsers
    @State private var confirm = false
    let theme = ModuleTheme.privacy

    enum Tab: String, CaseIterable { case browsers = "Browsers", recent = "Recent Items", permissions = "App Permissions" }

    var body: some View {
        let store = model.privacy
        Group {
            if store.scannedAt == nil {
                ModuleIntro(theme: theme, title: "Privacy", subtitle: "Clear the traces your browsers and Mac keep, and see which apps can use your camera, microphone and files.",
                            bullets: [("globe", "History, cookies and website data in Safari, Chrome, Edge, Brave, Arc and Firefox"),
                                      ("clock.arrow.circlepath", "Recent Items lists in the Apple menu"),
                                      ("lock.shield", "Every permission you've granted, with one-click revoke")],
                            actionTitle: "Scan", busy: store.isScanning) { store.scan() }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ModuleHeader(theme: theme, title: "Privacy", subtitle: "Browsers must be closed before their data can be cleared. Saved passwords are never touched.") {
                        Picker("", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    .padding(.horizontal, 28).padding(.top, 24)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let security = store.security { ProtectionStrip(status: security) }
                            switch tab {
                            case .browsers: browsers
                            case .recent: recent
                            case .permissions: permissions
                            }
                        }
                        .padding(.horizontal, 28).padding(.bottom, 24)
                    }
                    if tab == .browsers { footer }
                }
            }
        }
        .onAppear { if store.scannedAt == nil, !store.isScanning { store.scan() } }
        .confirmationDialog("Clear \(store.selectedItems.count) item\(store.selectedItems.count == 1 ? "" : "s")?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Clear") { Task { await store.clean() } }
        } message: {
            Text("Files go to the Trash. Clearing cookies signs you out of websites.")
        }
    }

    // MARK: Browsers

    @ViewBuilder private var browsers: some View {
        let store = model.privacy
        let byBrowser = Dictionary(grouping: store.items, by: \.browser)
        if store.items.isEmpty {
            ContentUnavailableView("Nothing to clear", systemImage: "checkmark.shield", description: Text("No browsing data was found."))
        }
        ForEach(Browser.allCases.filter { byBrowser[$0] != nil }) { browser in
            let items = byBrowser[browser] ?? []
            let running = store.isRunning(browser)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    browserIcon(browser).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(browser.name).font(.headline)
                        Text(Set(items.map(\.profileName)).sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if running {
                        Label("Open — quit it to clear", systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange)
                        Button("Quit \(browser.name)") {
                            for id in browser.bundleIDs { NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() } }
                        }
                        .buttonStyle(GlassPillStyle()).controlSize(.small)
                    }
                }
                .padding(14)
                Divider().opacity(0.4)
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(get: { store.selection.contains(item.id) },
                                                 set: { on in if on { store.selection.insert(item.id) } else { store.selection.remove(item.id) } }))
                            .toggleStyle(.checkbox).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind.title + (Set(items.map(\.profileName)).count > 1 ? " · \(item.profileName)" : "")).fontWeight(.medium)
                            Text(item.kind.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        BytesText(bytes: item.bytes, font: .callout.weight(.semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                }
            }
            .glass()
            .opacity(running ? 0.75 : 1)
        }
    }

    private var footer: some View {
        let store = model.privacy
        let chosen = store.selectedItems
        return HStack {
            Text(chosen.isEmpty ? "Nothing selected" : "\(chosen.count) selected · \(Format.bytes(chosen.reduce(0) { $0 + $1.bytes }))")
                .foregroundStyle(.secondary)
            Spacer()
            Button { store.scan() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }.buttonStyle(GlassPillStyle())
            Button("Clear Selected") { confirm = true }
                .buttonStyle(PrimaryPillStyle(theme: theme))
                .disabled(chosen.isEmpty || model.isCleaning)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    // MARK: Recent Items

    @ViewBuilder private var recent: some View {
        let store = model.privacy
        if store.recentLists.isEmpty {
            fullDiskAccessCard("macOS keeps the Recent Items lists in a protected folder. Allow Full Disk Access to clear them.")
        }
        ForEach(store.recentLists) { list in
            HStack(spacing: 12) {
                ModuleGlyph(theme: theme, size: 34, symbol: "clock.arrow.circlepath")
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.title).fontWeight(.medium)
                    Text("Shown in the Apple menu → Recent Items").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { Task { await store.clear(list) } }.buttonStyle(GlassPillStyle()).disabled(model.isCleaning)
            }
            .padding(14)
            .glass()
        }
    }

    // MARK: Permissions

    @ViewBuilder private var permissions: some View {
        let store = model.privacy
        if let permissions = store.permissions {
            let allowed = permissions.filter(\.allowed)
            Text("\(allowed.count) grants across \(Set(allowed.map(\.client)).count) apps. Remove the ones you don't recognise or don't need.")
                .foregroundStyle(.secondary)
            ForEach(Dictionary(grouping: allowed, by: \.service).sorted { $0.key < $1.key }, id: \.key) { service, grants in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        ModuleGlyph(theme: theme, size: 30, symbol: Permissions.symbol(for: service))
                        Text(Permissions.title(for: service)).font(.headline)
                        Spacer()
                        Text("\(grants.count)").foregroundStyle(.secondary)
                        Button { NSWorkspace.shared.open(Permissions.settingsURL(for: service)) } label: { Image(systemName: "arrow.up.forward.app") }
                            .buttonStyle(.borderless).help("Open in System Settings")
                    }
                    .padding(12)
                    ForEach(grants) { grant in
                        HStack(spacing: 10) {
                            appIcon(grant.client).frame(width: 22, height: 22)
                            Text(store.appName(grant.client)).lineLimit(1)
                            if let date = grant.lastModified {
                                Text(Format.idle(since: date).lowercased()).font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("Remove Access") { store.revoke(grant) }.buttonStyle(GlassPillStyle()).controlSize(.small)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .padding(.bottom, 6)
                }
                .glass()
            }
        } else {
            fullDiskAccessCard("macOS only lets apps with Full Disk Access read the list of permissions you've granted.")
        }
    }

    private func fullDiskAccessCard(_ text: String) -> some View {
        HStack(spacing: 14) {
            ModuleGlyph(theme: theme, size: 40, symbol: "lock.fill")
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Allow Full Disk Access") { model.openFullDiskAccessSettings() }.buttonStyle(PrimaryPillStyle(theme: theme))
        }
        .padding(16)
        .glass()
    }

    private func browserIcon(_ browser: Browser) -> some View {
        Group {
            if let url = browser.bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "globe").font(.title2)
            }
        }
    }

    private func appIcon(_ client: String) -> some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else if client.hasPrefix("/") {
                Image(nsImage: NSWorkspace.shared.icon(forFile: client)).resizable()
            } else {
                Image(systemName: "app.dashed")
            }
        }
    }
}

/// macOS's own protections at a glance. Read only; DevSweep doesn't change them.
private struct ProtectionStrip: View {
    let status: SecurityStatus

    var body: some View {
        HStack(spacing: 10) {
            ForEach(status.checks) { check in
                let color: Color = check.isOn == true ? .green : check.isOn == false ? .orange : .secondary
                HStack(spacing: 8) {
                    Image(systemName: check.symbol).foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.title).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(check.isOn == true ? "On" : check.isOn == false ? "Off" : "Unknown")
                            .font(.caption2).foregroundStyle(color)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .glass(cornerRadius: 12)
                .help(check.detail)
                .onTapGesture { if check.isOn == false { NSWorkspace.shared.open(Self.settingsURL(for: check.id)) } }
            }
        }
    }

    static func settingsURL(for id: String) -> URL {
        switch id {
        case "firewall": URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")!
        default: URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!
        }
    }
}
