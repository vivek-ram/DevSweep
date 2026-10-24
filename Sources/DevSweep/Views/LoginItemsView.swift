import AppKit
import DevSweepCore
import SwiftUI

struct LoginItemsView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRemoval: LaunchItem?

    var body: some View {
        let store = model.loginItems
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModuleHeader(theme: .loginItems, title: "Login Items",
                             subtitle: "Helpers that start with your Mac and keep running: updaters, sync agents, menu bar helpers. Turning off ones you don't need makes startup quicker and frees memory.") {
                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .buttonStyle(GlassPillStyle())
                    }
                }
                .appearIn()

                Card(padding: 14) {
                    HStack {
                        ModuleGlyph(theme: .loginItems, size: 34, symbol: "person.crop.circle.badge.checkmark")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apps that open when you log in").fontWeight(.medium)
                            Text("macOS manages that list itself, in System Settings.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Login Items Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .buttonStyle(GlassPillStyle())
                    }
                }
                .appearIn()

                let broken = store.items.filter(\.isBroken)
                if !broken.isEmpty {
                    Label("\(broken.count) item\(broken.count == 1 ? " points" : "s point") to a program that no longer exists, probably left by an app you deleted. Safe to remove.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }

                ForEach(Array(LaunchItem.Scope.allCases.enumerated()), id: \.element) { index, scope in
                    let items = store.items.filter { $0.scope == scope }
                    if !items.isEmpty {
                        Card(padding: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text(scope.title.uppercased()).font(.caption.weight(.bold)).tracking(1).foregroundStyle(ModuleTheme.loginItems.gradient)
                                    Spacer()
                                    if scope != .user {
                                        Text("Changing these needs an administrator").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                                ForEach(items) { item in
                                    LaunchRow(item: item) { pendingRemoval = item }
                                    if item.id != items.last?.id { Divider().opacity(0.5).padding(.leading, 56) }
                                }
                            }
                        }
                        .appearIn(delay: 0.06 + Double(index) * 0.06)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Login Items")
        .onAppear { store.refresh() }
        .confirmationDialog("Remove \(pendingRemoval?.label ?? "")?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            if let item = pendingRemoval {
                Button("Stop and Move to Trash") { Task { await store.remove(item) } }
            }
        } message: {
            Text("It's stopped and its launch file goes to the Trash. Reinstalling the app that added it brings it back.")
        }
    }
}

private struct LaunchRow: View {
    @Environment(AppModel.self) private var model
    let item: LaunchItem
    var remove: () -> Void

    var body: some View {
        let store = model.loginItems
        HStack(spacing: 12) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ownerName ?? item.label).fontWeight(.medium).lineLimit(1)
                    if item.isBroken { badge("Program missing", .orange) }
                    if item.isLoaded == true { badge("Running", .green) }
                    if item.isDisabled { badge("Off", .secondary) }
                }
                Text(ownerName == nil ? (item.program.map(Paths.display) ?? "") : item.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if item.runsAtLoad { Label("Starts at login", systemImage: "power").labelStyle(.titleAndIcon) }
                    if item.keepsAlive { Label("Kept running", systemImage: "arrow.triangle.2.circlepath") }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if item.scope == .user {
                Toggle("", isOn: Binding(get: { !item.isDisabled }, set: { store.setEnabled(item, $0) }))
                    .toggleStyle(.switch).labelsHidden()
                    .help(item.isDisabled ? "Turned off: it won't start" : "Turn off so it doesn't start")
            }
            Menu {
                Button("Show in Finder") { model.reveal(item.plistPath) }
                if let program = item.program, item.programExists { Button("Show Program in Finder") { model.reveal(program) } }
                if item.scope == .user {
                    Divider()
                    Button("Remove…", role: .destructive, action: remove)
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(item.isBroken ? Color.orange.opacity(0.06) : .clear)
    }

    private var ownerURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.vendorID)
            ?? item.program.flatMap { program in
                program.range(of: ".app/").map { URL(fileURLWithPath: String(program[..<$0.lowerBound]) + ".app") }
            }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private var ownerName: String? {
        ownerURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    @ViewBuilder private var icon: some View {
        if let url = ownerURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: item.isBroken ? "exclamationmark.triangle" : "gearshape.2")
                .font(.title3).foregroundStyle(item.isBroken ? .orange : .secondary)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
