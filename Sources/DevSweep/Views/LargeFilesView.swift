import AppKit
import DevSweepCore
import SwiftUI

struct LargeFileRow: Identifiable {
    let file: LargeFile
    var id: String { file.id }
    var name: String { file.name.lowercased() }
    var size: Int64 { file.size }
    var modified: Date { file.modified }
    var place: String { file.place.title }
}

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.large
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\LargeFileRow.size, order: .reverse)]
    @State private var place: LargeFile.Place?
    @State private var olderThanSixMonths = false
    @State private var minimum: Int64 = 50_000_000
    @State private var confirm = false

    enum Tab: String, CaseIterable { case large = "Large & Old", downloads = "Downloads" }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(theme: .largeFiles, title: "Large Files",
                         subtitle: tab == .large
                            ? "Every file over 50 MB in \(model.settings.storageScope == .home ? "your home folder" : "the whole disk"), biggest first."
                            : "What's in Downloads, grouped by the app or website it came from.") {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 12)
            .appearIn()
            switch tab {
            case .large: largePane
            case .downloads: DownloadsPane()
            }
        }
        .navigationTitle("Large Files")
        .confirmationDialog("Move \(selectedFiles.count) file\(selectedFiles.count == 1 ? "" : "s") to the Trash?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Move \(Format.bytes(selectedFiles.reduce(0) { $0 + $1.size })) to Trash") {
                let items = selectedFiles.map { (path: $0.path, bytes: $0.size) }
                selection.removeAll()
                Task { await model.trashItems(items) }
            }
        } message: {
            Text(selectedFiles.contains { $0.place == .appData }
                 ? "Some of these belong to apps (Library). Removing them can break or reset those apps. Everything can be put back from the Trash."
                 : "These are your own files. You can put them back from the Trash until you empty it.")
        }
    }

    @ViewBuilder private var largePane: some View {
        if model.storage == nil {
            if model.isScanningStorage {
                ScanProgressView(theme: .largeFiles, title: "Looking for large files…",
                                 detail: "\(model.storageProgress.files.formatted()) files · \(Format.bytes(model.storageProgress.bytes))",
                                 path: model.storageProgress.currentPath) { model.cancelSmartScan() }
            } else {
                VStack(spacing: 20) {
                    HeroGlyph(theme: .largeFiles, size: 110)
                    Text("Nothing is changed until you pick files and move them to the Trash.").foregroundStyle(.secondary)
                    Button("Find Large Files") { model.scanStorage() }
                        .buttonStyle(PrimaryPillStyle(theme: .largeFiles, large: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker("Where", selection: $place) {
                        Text("Everywhere except app data").tag(LargeFile.Place?.none)
                        ForEach(LargeFile.Place.allCases, id: \.self) { Text($0.title).tag(LargeFile.Place?.some($0)) }
                    }
                    .labelsHidden().fixedSize()
                    Picker("Size", selection: $minimum) {
                        Text("Over 50 MB").tag(Int64(50_000_000))
                        Text("Over 250 MB").tag(Int64(250_000_000))
                        Text("Over 1 GB").tag(Int64(1_000_000_000))
                    }
                    .labelsHidden().fixedSize()
                    Toggle("Untouched 6+ months", isOn: $olderThanSixMonths).toggleStyle(.button)
                    Spacer()
                    Button { model.scanStorage() } label: {
                        HStack(spacing: 6) {
                            if model.isScanningStorage { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                            Text(model.isScanningStorage ? "Measuring…" : "Measure Again")
                        }
                    }
                    .buttonStyle(GlassPillStyle())
                    .disabled(model.isScanningStorage)
                }
                .padding(.horizontal, 28).padding(.bottom, 12)
                table
            }
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 10) {
                        Image(nsImage: FileIcons.icon(forPath: row.file.path, isFolder: false)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.file.name).fontWeight(.medium).lineLimit(1)
                            Text(row.file.folderDisplayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .padding(.vertical, 2)
                    .help(Paths.display(row.file.path))
                }
                .width(min: 220, ideal: 330)
                TableColumn("Where", value: \.place) { row in
                    Text(row.file.place.title).foregroundStyle(row.file.place == .appData ? .orange : .secondary)
                }
                .width(min: 100, ideal: 140)
                TableColumn("Modified", value: \.modified) { row in
                    Text(Format.idle(since: row.modified)).foregroundStyle(.secondary).help(row.modified.shortDateTime)
                }
                .width(min: 90, ideal: 110)
                TableColumn("Size", value: \.size) { row in
                    BytesText(bytes: row.size, font: .body.weight(.medium)).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 90)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let id = ids.first {
                    Button("Show in Finder") { model.reveal(id) }
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: id)) }
                    Divider()
                }
                Button("Move to Trash…") { selection = ids; confirm = true }
                    .disabled(ids.isEmpty || model.isCleaning)
            } primaryAction: { ids in
                ids.forEach { model.reveal($0) }
            }
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No files match", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Try a smaller size or another place."))
                }
            }
            .padding(6)
            .glass(cornerRadius: 18)
            .padding(.horizontal, 28)
            .padding(.bottom, 18)

            ActionBar {
                let total = rows.reduce(0) { $0 + $1.size }
                if selectedFiles.isEmpty {
                    Text("\(rows.count) files · \(Format.bytes(total))").foregroundStyle(.secondary)
                } else {
                    Text("\(selectedFiles.count) selected · \(Format.bytes(selectedFiles.reduce(0) { $0 + $1.size }))")
                }
            } trailing: {
                Button { confirm = true } label: { Label("Move to Trash", systemImage: "trash") }
                    .buttonStyle(PrimaryPillStyle(theme: .largeFiles))
                    .disabled(selectedFiles.isEmpty || model.isCleaning)
            }
        }
    }

    private var rows: [LargeFileRow] {
        let cutoff = Date().addingTimeInterval(-182 * 86_400)
        return model.largeFiles
            .filter { place == nil ? $0.place != .appData : $0.place == place }
            .filter { $0.size >= minimum }
            .filter { !olderThanSixMonths || $0.modified < cutoff }
            .map(LargeFileRow.init)
            .sorted(using: sortOrder)
    }

    private var selectedFiles: [LargeFile] {
        model.largeFiles.filter { selection.contains($0.path) }
    }
}

// MARK: Downloads

private struct DownloadsPane: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    let theme = ModuleTheme.largeFiles

    var body: some View {
        let store = model.downloads
        Group {
            if store.scannedAt == nil {
                ScanProgressView(theme: theme, title: "Sorting your downloads…", detail: "Checking where each file came from", path: Paths.home + "/Downloads") {}
                    .onAppear { if !store.isScanning { store.scan() } }
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if store.items.isEmpty {
                                ContentUnavailableView("Downloads is empty", systemImage: "checkmark.seal",
                                                       description: Text("Nothing to sort through."))
                            }
                            ForEach(Array(store.bySource.enumerated()), id: \.element.source) { index, entry in
                                SourceCard(source: entry.source, items: entry.items)
                                    .appearIn(delay: min(Double(index) * 0.04, 0.4))
                            }
                        }
                        .padding(.horizontal, 28).padding(.bottom, 16)
                    }
                    ActionBar {
                        let chosen = store.items.filter { store.selection.contains($0.path) }
                        Text(chosen.isEmpty ? "\(store.items.count) items · \(Format.bytes(store.items.reduce(0) { $0 + $1.bytes }))"
                                            : "\(chosen.count) selected · \(Format.bytes(chosen.reduce(0) { $0 + $1.bytes }))")
                            .foregroundStyle(chosen.isEmpty ? .secondary : .primary)
                    } trailing: {
                        Button { store.scan() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                            .buttonStyle(GlassPillStyle()).disabled(store.isScanning)
                        Button { confirm = true } label: { Label("Move to Trash", systemImage: "trash") }
                            .buttonStyle(PrimaryPillStyle(theme: theme))
                            .disabled(store.selection.isEmpty || model.isCleaning)
                    }
                }
            }
        }
        .confirmationDialog("Move \(store.selection.count) item\(store.selection.count == 1 ? "" : "s") to the Trash?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Move to Trash") { Task { await store.trashSelected() } }
        } message: {
            Text("You can put them back from the Trash until you empty it.")
        }
    }
}

private struct SourceCard: View {
    @Environment(AppModel.self) private var model
    let source: String
    let items: [DownloadItem]
    @State private var expanded = false

    var body: some View {
        @Bindable var store = model.downloads
        let paths = Set(items.map(\.path))
        let selectedCount = paths.intersection(store.selection).count
        let shown = expanded ? items : Array(items.prefix(4))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(get: { selectedCount == paths.count && !paths.isEmpty },
                                         set: { on in if on { store.selection.formUnion(paths) } else { store.selection.subtract(paths) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                SourceIcon(source: source).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source).font(.headline)
                    Text("\(items.count) item\(items.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                BytesText(bytes: items.reduce(0) { $0 + $1.bytes }, font: .callout.weight(.semibold))
            }
            .padding(14)
            Divider().opacity(0.5)
            ForEach(shown) { item in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { store.selection.contains(item.path) },
                                             set: { on in if on { store.selection.insert(item.path) } else { store.selection.remove(item.path) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Image(nsImage: FileIcons.icon(forPath: item.path, isFolder: item.isFolder)).resizable().frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text([item.website, "Added \(Format.idle(since: item.added).lowercased())",
                              item.lastOpened == nil ? "never opened" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    BytesText(bytes: item.bytes, font: .callout)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .contextMenu { Button("Show in Finder") { model.reveal(item.path) } }
            }
            if items.count > 4 {
                Button(expanded ? "Show fewer" : "Show all \(items.count)") { withAnimation(.spring(duration: 0.35)) { expanded.toggle() } }
                    .buttonStyle(.link).font(.caption)
                    .padding(.horizontal, 14).padding(.bottom, 10).padding(.top, 2)
            }
        }
        .padding(.bottom, 4)
        .glass()
    }
}

/// The downloading app's icon when it's installed, otherwise a symbol.
private struct SourceIcon: View {
    let source: String

    var body: some View {
        if let path = Self.appPath(for: source) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            ModuleGlyph(theme: .largeFiles, size: 32, symbol: source == "AirDrop" ? "dot.radiowaves.left.and.right" : "arrow.down.circle.fill")
        }
    }

    static func appPath(for name: String) -> String? {
        ["/Applications", "/System/Applications", "/System/Applications/Utilities", Paths.home + "/Applications"]
            .map { "\($0)/\(name).app" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }
}
