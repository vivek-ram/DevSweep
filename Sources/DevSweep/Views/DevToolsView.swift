import DevSweepCore
import SwiftUI

struct DevToolsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        let store = model.devTools
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ModuleHeader(theme: .devTools, title: "Toolchains & Models",
                                 subtitle: "Old simulators, Homebrew leftovers, Docker images, downloaded AI models and language versions you no longer use. Where a tool has its own cleanup command, DevSweep runs that.") {
                        if store.isScanning {
                            HStack(spacing: 8) { ScanningOrb(size: 30, tint: ModuleTheme.devTools.primary); Text("Asking your tools…").foregroundStyle(.secondary) }
                        } else {
                            Button { store.scan() } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                                .buttonStyle(GlassPillStyle())
                        }
                    }
                    .appearIn()

                    let groups = Dictionary(grouping: store.items, by: \.tool).sorted { $0.key < $1.key }
                    ForEach(Array(groups.enumerated()), id: \.element.key) { index, entry in
                        Card(padding: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.key.uppercased())
                                    .font(.caption.weight(.bold)).tracking(1).foregroundStyle(ModuleTheme.devTools.gradient)
                                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                                ForEach(entry.value) { item in
                                    ToolRow(item: item)
                                    if item.id != entry.value.last?.id { Divider().opacity(0.5).padding(.leading, 44) }
                                }
                            }
                        }
                        .appearIn(delay: Double(index) * 0.05)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    if store.items.isEmpty, store.scannedAt != nil {
                        ContentUnavailableView("Nothing to clean", systemImage: "checkmark.seal",
                                               description: Text("Your developer tools aren't holding on to anything big."))
                    }
                }
                .padding(28)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }
            ActionBar {
                let chosen = store.selectedItems
                let bytes = chosen.compactMap(\.bytes).reduce(0, +)
                Text(chosen.isEmpty ? "Nothing selected" : "\(chosen.count) selected · \(Format.bytes(bytes))")
                    .foregroundStyle(chosen.isEmpty ? .secondary : .primary)
            } trailing: {
                Button { confirm = true } label: { Label("Clean", systemImage: "sparkles") }
                    .buttonStyle(PrimaryPillStyle(theme: .devTools))
                    .disabled(store.selectedItems.isEmpty || model.isCleaning)
            }
        }
        .navigationTitle("Toolchains & Models")
        .onAppear { if store.scannedAt == nil { store.scan() } }
        .confirmationDialog("Clean \(store.selectedItems.count) item\(store.selectedItems.count == 1 ? "" : "s")?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Clean") { Task { await store.runSelected() } }
        } message: {
            Text(store.selectedItems.compactMap(\.caution).first.map { "Note: \($0)" } ?? "Each tool downloads or rebuilds what it needs again.")
        }
    }
}

private struct ToolRow: View {
    @Environment(AppModel.self) private var model
    let item: ToolCleanup

    var body: some View {
        @Bindable var store = model.devTools
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { store.selection.contains(item.id) },
                set: { on in if on { store.selection.insert(item.id) } else { store.selection.remove(item.id) } }))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(.medium)
                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let caution = item.caution {
                    Label(caution, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                if case .command(let executable, let arguments, _) = item.action {
                    Text("Runs: \((executable as NSString).lastPathComponent) \(arguments.joined(separator: " "))")
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            Group {
                if let bytes = item.bytes {
                    CountUpBytes(value: bytes, font: .callout.weight(.semibold), duration: 0.6)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
