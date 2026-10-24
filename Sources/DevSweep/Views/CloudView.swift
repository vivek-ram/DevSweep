import AppKit
import DevSweepCore
import SwiftUI

struct CloudView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    let theme = ModuleTheme.cloud

    var body: some View {
        let store = model.cloud
        Group {
            if store.scannedAt == nil {
                ModuleIntro(theme: theme, title: "Cloud Cleanup", subtitle: "Big files in iCloud Drive, Dropbox, Google Drive or OneDrive that are also downloaded on this Mac. Free the local copy; the file stays in the cloud.",
                            bullets: [("icloud.fill", "iCloud Drive"), ("externaldrive.fill.badge.icloud", "Cloud folders in Finder's sidebar"),
                                      ("arrow.down.circle", "Files download again the moment you open them")],
                            actionTitle: "Scan", busy: store.isScanning) { store.scan() }
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ModuleHeader(theme: theme, title: "Cloud Cleanup",
                                         subtitle: "\(Format.bytes(store.files.reduce(0) { $0 + $1.bytes })) of cloud files are downloaded on this Mac.") {
                                Button { store.scan() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                                    .buttonStyle(GlassPillStyle()).disabled(store.isScanning)
                            }
                            .appearIn()

                            HStack(spacing: 14) {
                                ForEach(store.locations) { location in
                                    let files = store.files.filter { Paths.isInside($0.path, location.path) }
                                    HStack(spacing: 12) {
                                        ModuleGlyph(theme: theme, size: 36, symbol: location.provider.symbol)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(location.provider.title).fontWeight(.semibold)
                                            Text(files.isEmpty ? "Nothing large stored locally" : "\(files.count) files · \(Format.bytes(files.reduce(0) { $0 + $1.bytes })) local")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity)
                                    .glass()
                                }
                                if store.locations.isEmpty {
                                    Text("No iCloud Drive or cloud storage folders on this Mac.").foregroundStyle(.secondary)
                                }
                            }
                            .appearIn(delay: 0.06)

                            if store.files.isEmpty, !store.locations.isEmpty {
                                ContentUnavailableView("Nothing to free", systemImage: "checkmark.icloud",
                                                       description: Text("No cloud files over 5 MB are taking space on this Mac."))
                            }
                            ForEach(store.files.prefix(200)) { file in
                                HStack(spacing: 12) {
                                    Toggle("", isOn: Binding(get: { store.selection.contains(file.path) },
                                                             set: { on in if on { store.selection.insert(file.path) } else { store.selection.remove(file.path) } }))
                                        .toggleStyle(.checkbox).labelsHidden()
                                    Image(nsImage: FileIcons.icon(forPath: file.path, isFolder: false)).resizable().frame(width: 26, height: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name).lineLimit(1)
                                        Text("\(file.provider.title) · \(file.folderDisplayPath)").font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                                    }
                                    Spacer()
                                    Text("Opened \(Format.idle(since: file.lastOpened ?? file.modified).lowercased())")
                                        .font(.caption).foregroundStyle(.secondary)
                                    BytesText(bytes: file.bytes, font: .callout.weight(.semibold)).frame(width: 80, alignment: .trailing)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .glass(cornerRadius: 12)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                        }
                        .padding(28)
                    }
                    HStack {
                        let chosen = store.selectedFiles
                        Text(chosen.isEmpty ? "Nothing selected" : "\(chosen.count) selected · \(Format.bytes(chosen.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary)
                        Spacer()
                        Button("Free Up Local Copies") { confirm = true }
                            .buttonStyle(PrimaryPillStyle(theme: theme))
                            .disabled(chosen.isEmpty || model.isCleaning)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .onAppear { if store.scannedAt == nil, !store.isScanning { store.scan() } }
        .confirmationDialog("Free \(Format.bytes(store.selectedFiles.reduce(0) { $0 + $1.bytes })) on this Mac?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Free Up") { Task { await store.freeUp() } }
        } message: {
            Text("Nothing is deleted from the cloud. Each file shows a cloud icon in Finder and downloads again when you open it, so you'll need an internet connection then.")
        }
    }
}
