import AppKit
import DevSweepCore
import SwiftUI

struct JunkView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ModuleHeader(theme: .cleanup, title: "System Junk",
                                 subtitle: "Files macOS and your apps leave behind. Safe items are ticked; nothing is removed until you press Clean.") {
                        if model.isScanningJunk {
                            HStack(spacing: 8) {
                                ScanningOrb(size: 30, tint: ModuleTheme.cleanup.secondary)
                                Text("Looking…").foregroundStyle(.secondary)
                            }
                            .transition(.opacity)
                        } else {
                            Button { model.scanJunk() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                                .buttonStyle(GlassPillStyle())
                        }
                    }
                    .appearIn()

                    if !model.hasFullDiskAccess {
                        AccessRow(text: "Allow Full Disk Access to include your Trash and Mail downloads.")
                    }

                    ForEach(Array(JunkCategory.allCases.enumerated()), id: \.element) { index, category in
                        let items = model.junk.filter { $0.category == category }
                        if !items.isEmpty {
                            CategoryCard(category: category, items: items)
                                .appearIn(delay: 0.05 + Double(index) * 0.06)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }

                    if model.junk.isEmpty, !model.isScanningJunk {
                        ContentUnavailableView("No junk found", systemImage: "checkmark.seal",
                                               description: Text("Caches, logs and old installers are all small right now."))
                    }
                }
                .padding(28)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }

            ActionBar {
                let selected = model.selectedJunk
                Text(selected.isEmpty ? "Nothing selected" : "\(selected.count) selected · \(Format.bytes(selected.reduce(0) { $0 + $1.bytes }))")
                    .foregroundStyle(selected.isEmpty ? .secondary : .primary)
            } trailing: {
                Button {
                    confirm = true
                } label: {
                    Label("Clean", systemImage: "sparkles")
                }
                .buttonStyle(PrimaryPillStyle(theme: .cleanup))
                .disabled(model.selectedJunk.isEmpty || model.isCleaning)
            }
        }
        .navigationTitle("System Junk")
        .confirmationDialog("Clean \(Format.bytes(model.selectedJunk.reduce(0) { $0 + $1.bytes })) of junk?", isPresented: $confirm, titleVisibility: .visible) {
            Button(model.settings.removalMode == .trash ? "Clean" : "Delete") {
                let items = model.selectedJunk
                Task { await model.cleanJunk(items) }
            }
        } message: {
            let selected = model.selectedJunk
            var parts = ["\(selected.count) item\(selected.count == 1 ? "" : "s") will be removed."]
            if selected.contains(where: { $0.category == .appCaches }) { parts.append("Apps rebuild their caches; some may start a little slower the first time.") }
            if selected.contains(where: { $0.category == .trash }) { parts.append("Emptying the Trash deletes its contents permanently.") }
            if model.settings.removalMode == .trash, selected.contains(where: { $0.category != .trash }) { parts.append("The rest goes to the Trash first.") }
            return Text(parts.joined(separator: " "))
        }
    }
}

private struct CategoryCard: View {
    @Environment(AppModel.self) private var model
    let category: JunkCategory
    let items: [JunkItem]
    @State private var expanded = false

    var body: some View {
        @Bindable var model = model
        let paths = Set(items.map(\.path))
        let selectedCount = paths.intersection(model.junkSelection).count
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { selectedCount == paths.count },
                        set: { on in if on { model.junkSelection.formUnion(paths) } else { model.junkSelection.subtract(paths) } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    ModuleGlyph(theme: ModuleTheme(colors: [color, color.opacity(0.65)], glyph: category.icon), size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title).fontWeight(.semibold)
                        Text(category.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        BytesText(bytes: items.reduce(0) { $0 + $1.bytes }, font: .callout.weight(.semibold))
                        Text("\(selectedCount) of \(items.count) selected").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { withAnimation { expanded.toggle() } } label: {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .buttonStyle(.borderless)
                    .disabled(category == .trash)
                }
                .padding(14)

                if expanded {
                    Divider()
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { model.junkSelection.contains(item.path) },
                                set: { on in if on { model.junkSelection.insert(item.path) } else { model.junkSelection.remove(item.path) } }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            Image(nsImage: icon(for: item)).resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(displayName(item)).lineLimit(1)
                                if let caution = item.caution {
                                    Label(caution, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(1)
                                }
                                Text(Paths.display(item.path)).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            BytesText(bytes: item.bytes, font: .callout)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .contextMenu { Button("Show in Finder") { model.reveal(item.path) } }
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var color: Color {
        switch category {
        case .appCaches: .pink
        case .aiClutter: .purple
        case .brokenPreferences: .yellow
        case .deviceBackups: .cyan
        case .mailAttachments: .blue
        case .logs: .gray
        case .installers: Brand.teal
        case .deviceUpdates: .blue
        case .archives: .orange
        case .trash: Brand.indigo
        }
    }

    /// App caches are named by bundle id; show the app's name when it's installed.
    private func displayName(_ item: JunkItem) -> String {
        if let label = item.label { return label }
        guard item.category == .appCaches else { return item.name }
        return JunkNames.appName(forBundleID: item.name) ?? item.name
    }

    private func icon(for item: JunkItem) -> NSImage {
        if item.category == .appCaches, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.name) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return FileIcons.icon(forPath: item.path)
    }
}

@MainActor
enum JunkNames {
    private static var cache: [String: String?] = [:]

    static func appName(forBundleID id: String) -> String? {
        if let cached = cache[id] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        cache[id] = name
        return name
    }
}
