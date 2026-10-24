import AppKit
import DevSweepCore
import SwiftUI

struct UninstallerView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.apps
    @State private var search = ""
    @State private var sort = Sort.size
    @State private var confirmApp: AppRow?
    @State private var confirmLeftovers = false

    enum Tab: String, CaseIterable { case apps = "Applications", leftovers = "Leftovers" }
    enum Sort: String, CaseIterable { case size = "Size", lastUsed = "Last Used", name = "Name" }
    enum Filter: String, CaseIterable { case all = "All Apps", unused = "Unused 3+ Months", appStore = "App Store", downloaded = "Downloaded" }
    @State private var filter = Filter.all

    var body: some View {
        let store = model.uninstaller
        VStack(spacing: 0) {
            ModuleHeader(theme: .uninstaller, title: "Uninstaller",
                         subtitle: tab == .apps
                            ? "Remove apps together with the caches, preferences and support files they leave in your Library."
                            : "Support files left by apps you already deleted.") {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab == .leftovers && !store.leftovers.isEmpty ? "\(tab.rawValue) (\(store.leftovers.count))" : tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 14)
            .appearIn()
            if store.scannedAt == nil {
                if store.isScanning {
                    ScanProgressView(theme: .uninstaller, title: "Looking at your apps…", detail: "Measuring each app and what it keeps", path: "/Applications") {}
                } else {
                    VStack(spacing: 20) {
                        HeroGlyph(theme: .uninstaller, size: 110)
                        Button("Find Apps") { store.scan() }.buttonStyle(PrimaryPillStyle(theme: .uninstaller, large: true))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                switch tab {
                case .apps: appsPane
                case .leftovers: leftoversPane
                }
            }
        }
        .navigationTitle("Uninstaller")
        .onAppear { if store.scannedAt == nil { store.scan() } }
        .confirmationDialog("Uninstall \(confirmApp?.app.name ?? "")?", isPresented: Binding(get: { confirmApp != nil }, set: { if !$0 { confirmApp = nil } }),
                            titleVisibility: .visible) {
            if let row = confirmApp {
                Button(store.isRunning(row.app) ? "Quit and Uninstall" : "Uninstall") {
                    Task { await store.uninstall(row) }
                }
                .keyboardShortcut(.defaultAction)
            }
        } message: {
            if let row = confirmApp {
                let files = row.files.filter { !store.keptFiles.contains($0.path) }
                Text("The app and \(files.count) support item\(files.count == 1 ? "" : "s") (\(Format.bytes(row.app.appBytes + files.reduce(0) { $0 + $1.bytes }))) go to the Trash. \(row.app.isApple ? "It's an Apple app; you can get it back from the App Store." : "You can put them back from the Trash.")")
            }
        }
        .confirmationDialog("Remove \(store.selectedLeftoverFiles.count) leftover items?", isPresented: $confirmLeftovers, titleVisibility: .visible) {
            Button("Move \(Format.bytes(store.selectedLeftoverFiles.reduce(0) { $0 + $1.bytes })) to Trash") {
                Task { await store.removeLeftovers() }
            }
        } message: {
            Text("They belong to apps that are no longer installed. You can put them back from the Trash.")
        }
    }

    // MARK: Apps

    private var rows: [AppRow] {
        let query = search.lowercased()
        let unusedSince = Date().addingTimeInterval(-90 * 86_400)
        let filtered = model.uninstaller.apps
            .filter { query.isEmpty || $0.app.name.lowercased().contains(query) || $0.app.vendor.contains(query) }
            .filter { row in
                switch filter {
                case .all: true
                case .unused: (row.lastUsed ?? .distantPast) < unusedSince
                case .appStore: row.app.isAppStore
                case .downloaded: !row.app.isAppStore && !row.app.isApple
                }
            }
        switch sort {
        case .size: return filtered.sorted { $0.totalBytes > $1.totalBytes }
        case .name: return filtered.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        case .lastUsed: return filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    private var appsPane: some View {
        @Bindable var store = model.uninstaller
        return HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search apps", text: $search).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.07)))
                    Menu {
                        Picker("Show", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Sort by", selection: $sort) {
                            ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Filter and sort")
                }
                .padding(12)
                if filter != .all {
                    HStack {
                        Text(filter.rawValue).font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(ModuleTheme.uninstaller.primary.opacity(0.25)))
                        Spacer()
                        Button("Show All") { filter = .all }.buttonStyle(.link).font(.caption)
                    }
                    .padding(.horizontal, 14).padding(.bottom, 4)
                }
                List(selection: $store.selectedApp) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        AppListRow(row: row)
                            .tag(row.id)
                            .appearIn(delay: min(Double(index) * 0.02, 0.4))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
                HStack {
                    Text("\(rows.count) apps · \(Format.bytes(rows.reduce(0) { $0 + $1.totalBytes }))").foregroundStyle(.secondary)
                    Spacer()
                    Button { store.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .buttonStyle(GlassPillStyle()).controlSize(.small)
                        .disabled(store.isScanning)
                }
                .font(.callout)
                .padding(12)
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 440)
            .glass(cornerRadius: 20)

            Group {
                if let row = store.selected {
                    AppDetail(row: row) { confirmApp = row }
                        .id(row.id)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    ContentUnavailableView("Select an app", systemImage: "app.dashed",
                                           description: Text("See everything it keeps on your Mac before removing it."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glass(cornerRadius: 20)
            .animation(.spring(duration: 0.35), value: store.selectedApp)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    // MARK: Leftovers

    private var leftoversPane: some View {
        let store = model.uninstaller
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Named after apps that aren't installed anymore. Ones from a developer whose other apps you still use aren't ticked, since they may be shared.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !model.hasFullDiskAccess {
                        AccessRow(text: "Allow Full Disk Access to also check app containers.")
                    }
                    if store.leftovers.isEmpty {
                        ContentUnavailableView("No leftovers", systemImage: "checkmark.seal",
                                               description: Text("Every support file belongs to an app you have."))
                    }
                    ForEach(Array(store.leftovers.enumerated()), id: \.element.id) { index, leftover in
                        LeftoverCard(leftover: leftover)
                            .appearIn(delay: min(Double(index) * 0.04, 0.4))
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 16)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }
            ActionBar {
                let files = store.selectedLeftoverFiles
                Text(files.isEmpty ? "Nothing selected" : "\(files.count) selected · \(Format.bytes(files.reduce(0) { $0 + $1.bytes }))")
                    .foregroundStyle(files.isEmpty ? .secondary : .primary)
            } trailing: {
                Button { confirmLeftovers = true } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(PrimaryPillStyle(theme: .uninstaller))
                    .disabled(store.selectedLeftoverFiles.isEmpty || model.isCleaning)
            }
        }
    }
}

private struct AppListRow: View {
    let row: AppRow

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.app.name).fontWeight(.medium).lineLimit(1)
                Text(row.lastUsed.map { "Used \(Format.idle(since: $0).lowercased())" } ?? "No record of use")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            BytesText(bytes: row.totalBytes, font: .callout.weight(.semibold))
        }
        .padding(.vertical, 3)
    }
}

private struct AppDetail: View {
    @Environment(AppModel.self) private var model
    let row: AppRow
    var uninstall: () -> Void

    var body: some View {
        let store = model.uninstaller
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.path)).resizable().frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.app.name).font(.system(size: 24, weight: .bold, design: .rounded))
                        Text([row.app.version.map { "Version \($0)" }, row.app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(row.lastUsed.map { "Last used \(Format.idle(since: $0).lowercased())" } ?? "No record of it being opened")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 16) {
                    stat("App", row.app.appBytes)
                    stat("Support files", row.files.filter { !store.keptFiles.contains($0.path) }.reduce(0) { $0 + $1.bytes })
                    stat("Total", row.app.appBytes + row.files.filter { !store.keptFiles.contains($0.path) }.reduce(0) { $0 + $1.bytes })
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text("WHAT GETS REMOVED").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 8)
                    fileRow(icon: NSWorkspace.shared.icon(forFile: row.app.path), title: "\(row.app.name).app", subtitle: Paths.display(row.app.path),
                            bytes: row.app.appBytes, isOn: .constant(true))
                        .disabled(true)
                    ForEach(row.files) { file in
                        Divider()
                        fileRow(icon: FileIcons.icon(forPath: file.path, isFolder: file.kind != .preferences), title: file.kind.title, subtitle: Paths.display(file.path),
                                bytes: file.bytes, isOn: Binding(
                                    get: { !store.keptFiles.contains(file.path) },
                                    set: { on in if on { store.keptFiles.remove(file.path) } else { store.keptFiles.insert(file.path) } }))
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))

                if !model.hasFullDiskAccess {
                    Label("Its sandbox container (if it has one) isn't listed without Full Disk Access.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Show in Finder") { model.reveal(row.app.path) }.buttonStyle(.link)
                    Spacer()
                    Button(action: uninstall) {
                        Label(store.isRunning(row.app) ? "Quit & Uninstall" : "Uninstall", systemImage: "trash")
                    }
                    .buttonStyle(PrimaryPillStyle(theme: ModuleTheme(colors: [ModuleTheme.hex(0xF43F5E), ModuleTheme.hex(0xE11D48)], glyph: "trash")))
                    .disabled(model.isCleaning || row.app.bundleID == "app.devsweep.DevSweep")
                }
            }
            .padding(22)
        }
    }

    private func stat(_ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            CountUpBytes(value: bytes, font: .title3.weight(.bold), duration: 0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
    }

    private func fileRow(icon: NSImage, title: String, subtitle: String, bytes: Int64, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: isOn).toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            BytesText(bytes: bytes, font: .callout)
        }
        .padding(.vertical, 6)
    }
}

private struct LeftoverCard: View {
    @Environment(AppModel.self) private var model
    let leftover: Leftover

    var body: some View {
        @Bindable var store = model.uninstaller
        let paths = Set(leftover.files.map(\.path))
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("", isOn: Binding(
                        get: { paths.isSubset(of: store.leftoverSelection) },
                        set: { on in if on { store.leftoverSelection.formUnion(paths) } else { store.leftoverSelection.subtract(paths) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Image(systemName: "app.dashed").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(leftover.identifier).fontWeight(.medium)
                        Text(leftover.vendorStillInstalled ? "Another app from this developer is installed; check before removing."
                                                           : "\(leftover.files.count) item\(leftover.files.count == 1 ? "" : "s") from an app you no longer have")
                            .font(.caption).foregroundStyle(leftover.vendorStillInstalled ? .orange : .secondary)
                    }
                    Spacer()
                    BytesText(bytes: leftover.bytes, font: .callout.weight(.semibold))
                }
                ForEach(leftover.files) { file in
                    HStack {
                        Text(file.kind.title).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        Text(Paths.display(file.path)).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        BytesText(bytes: file.bytes, font: .caption)
                    }
                    .padding(.leading, 34)
                    .contextMenu { Button("Show in Finder") { model.reveal(file.path) } }
                }
            }
        }
    }
}
