import AppKit
import Charts
import DevSweepCore
import SwiftUI

/// Browse what's using space, folder by folder.
struct StorageMapView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingTrash: StorageNode?

    var body: some View {
        let _ = model.storageVersion
        Group {
            if let root = model.storage?.root {
                let current = root.descendant(at: model.mapPath ?? root.path) ?? root
                VStack(spacing: 0) {
                    header(root: root, current: current)
                    HStack(alignment: .top, spacing: 16) {
                        SpaceDonut(node: current) { child in
                            if child.isDirectory, !child.isPackage, child.note == nil { open(child.path) }
                        }
                        .frame(width: 290)
                        .padding(18)
                        .glass(cornerRadius: 20)
                        .id(current.path)

                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(current.children.enumerated()), id: \.element.path) { index, node in
                                    VStack(spacing: 0) {
                                        MapRow(node: node, parentSize: current.size, index: index) {
                                            if node.isDirectory, !node.isPackage, node.note == nil { open(node.path) }
                                        }
                                        .contextMenu { menu(for: node) }
                                        Divider().opacity(0.4).padding(.leading, 58)
                                    }
                                    .appearIn(delay: min(Double(index) * 0.03, 0.45))
                                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                                }
                                if current.smallItemsSize > 0 {
                                    HStack {
                                        Image(systemName: "ellipsis.circle").frame(width: 28).foregroundStyle(.secondary)
                                        Text("Smaller items").foregroundStyle(.secondary)
                                        Spacer()
                                        BytesText(bytes: current.smallItemsSize).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                }
                            }
                            .padding(.vertical, 6)
                            .id(current.path)
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                        }
                        .glass(cornerRadius: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .animation(.spring(duration: 0.4, bounce: 0.15), value: model.mapPath)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
            } else if model.isScanningStorage {
                ScanningPlaceholder(title: "Measuring \(model.settings.storageScope == .home ? "your home folder" : "the whole disk")…")
            } else {
                ModuleIntro(theme: .spaceLens, title: "Storage Map",
                            subtitle: "DevSweep measures every folder in \(model.settings.storageScope == .home ? "your home folder" : "the whole disk") so you can see what's big and drill into it. Nothing is changed.",
                            bullets: [("chart.pie.fill", "Every folder as a ring you can click into"),
                                      ("icloud.slash", "Cloud-only files aren't downloaded to measure them"),
                                      ("trash", "Anything you remove goes to the Trash")],
                            actionTitle: "Measure Now") { model.scanStorage() }
            }
        }
        .navigationTitle("Storage Map")
        .confirmationDialog("Move \(pendingTrash?.name ?? "") to the Trash?",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                            titleVisibility: .visible) {
            if let node = pendingTrash {
                Button("Move \(Format.bytes(node.size)) to Trash") {
                    Task { await model.trashItems([(node.path, node.size)]) }
                }
            }
        } message: {
            if let node = pendingTrash {
                Text(RemovalRules.isAppData(node.path)
                     ? "This is data an app keeps. Removing it can reset that app or lose its settings. You can put it back from the Trash."
                     : "You can put it back from the Trash until you empty it.")
            }
        }
    }

    private func header(root: StorageNode, current: StorageNode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ModuleHeader(theme: .spaceLens, title: "Storage Map",
                         subtitle: "\(Format.bytes(current.size)) in \(current.fileCount.formatted()) files. Click a ring segment or a row to look inside.") {
                Button { model.scanStorage() } label: { Label("Measure Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(GlassPillStyle())
                    .disabled(model.isScanningStorage)
            }
            HStack(spacing: 4) {
                ForEach(trail(to: current), id: \.path) { node in
                    if node !== root { Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary) }
                    Button(node === root ? (root.path == StorageScanner.wholeDisk ? "Macintosh HD" : "Home") : node.name) {
                        open(node.path)
                    }
                    .buttonStyle(.plain)
                    .fontWeight(node === current ? .semibold : .regular)
                    .foregroundStyle(node === current ? AnyShapeStyle(ModuleTheme.spaceLens.gradient) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glass(cornerRadius: 12)
            if let storage = model.storage, !storage.restricted.isEmpty, !model.hasFullDiskAccess {
                AccessRow(text: "App containers weren't measured. Allow Full Disk Access to include them.")
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private func open(_ path: String) {
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) { model.mapPath = path }
    }

    private func trail(to node: StorageNode) -> [StorageNode] {
        var trail: [StorageNode] = []
        var current: StorageNode? = node
        while let n = current {
            trail.insert(n, at: 0)
            current = n.parent
        }
        return trail
    }

    @ViewBuilder private func menu(for node: StorageNode) -> some View {
        Button("Show in Finder") { model.reveal(node.path) }
        if node.isDirectory, !node.isPackage, node.note == nil {
            Button("Open") { open(node.path) }
        }
        Divider()
        let problem = RemovalRules.problem(removing: node.path)
        Button("Move to Trash…") { pendingTrash = node }
            .disabled(problem != nil || model.isCleaning)
        if let problem { Text(problem) }
    }
}

/// The current folder's biggest children as a ring. Hovering a segment names it; clicking opens it.
private struct SpaceDonut: View {
    let node: StorageNode
    var open: (StorageNode) -> Void
    @State private var selectedValue: Double?
    @State private var grown = false
    static let palette: [Color] = [0x2DD4BF, 0x60A5FA, 0xA78BFA, 0xF472B6, 0xFB923C, 0xFACC15, 0x4ADE80, 0x38BDF8].map(ModuleTheme.hex)

    private struct Slice: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let color: Color
        let node: StorageNode?
    }

    private var slices: [Slice] {
        let top = Array(node.children.prefix(8))
        var slices = top.enumerated().map { index, child in
            Slice(id: child.path, name: child.name, bytes: child.size, color: Self.palette[index % Self.palette.count], node: child)
        }
        let rest = node.size - top.reduce(0) { $0 + $1.size }
        if rest > 0 { slices.append(Slice(id: "rest", name: "Everything else", bytes: rest, color: .white.opacity(0.18), node: nil)) }
        return slices
    }

    private func slice(at value: Double?) -> Slice? {
        guard let value else { return nil }
        var running = 0.0
        for slice in slices {
            running += Double(slice.bytes)
            if value <= running { return slice }
        }
        return nil
    }

    var body: some View {
        let slices = self.slices
        let selected = slice(at: selectedValue)
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                Chart(slices) { slice in
                    SectorMark(angle: .value("Size", grown ? Double(slice.bytes) : (slice.id == slices.first?.id ? 1 : 0)),
                               innerRadius: .ratio(0.64), outerRadius: .ratio(selected?.id == slice.id ? 1 : 0.94),
                               angularInset: 1.5)
                        .cornerRadius(5)
                        .foregroundStyle(slice.color.gradient)
                        .opacity(selected == nil || selected?.id == slice.id ? 1 : 0.45)
                }
                .chartLegend(.hidden)
                .chartAngleSelection(value: $selectedValue)
                .onTapGesture {
                    if let node = selected?.node { open(node) }
                }
                VStack(spacing: 2) {
                    Text(Format.bytes(selected?.bytes ?? node.size))
                        .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(selected?.name ?? node.name)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: 140)
                }
                .allowsHitTesting(false)
                .animation(.snappy(duration: 0.2), value: selected?.id)
            }
            .frame(height: 250)
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(slices.prefix(6)) { slice in
                    HStack(spacing: 8) {
                        Circle().fill(slice.color).frame(width: 8, height: 8)
                        Text(slice.name).lineLimit(1)
                        Spacer()
                        Text(Format.bytes(slice.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
        .onAppear { withAnimation(.spring(duration: 1.0, bounce: 0.1).delay(0.05)) { grown = true } }
    }
}

private struct MapRow: View {
    let node: StorageNode
    let parentSize: Int64
    var index = 0
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(nsImage: FileIcons.icon(forPath: node.path, isFolder: node.isDirectory && !node.isPackage))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(node.name).fontWeight(.medium).lineLimit(1)
                        if let kind = node.artifactKind {
                            Text("Rebuildable · \(kind.ecosystem.displayName)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .foregroundStyle(kind.ecosystem.color)
                                .background(Capsule().fill(kind.ecosystem.color.opacity(0.14)))
                        }
                        if node.note == .needsFullDiskAccess {
                            Label("Needs Full Disk Access", systemImage: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        } else if node.note == .unreadable {
                            Label("Couldn't be read", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    GrowingBar(fraction: Double(node.size) / Double(max(parentSize, 1)), fill: ModuleTheme.spaceLens.gradient, height: 5,
                               delay: 0.1 + min(Double(index) * 0.03, 0.45))
                        .background(Capsule().fill(.white.opacity(0.07)))
                }
                VStack(alignment: .trailing, spacing: 2) {
                    BytesText(bytes: node.size, font: .callout.weight(.semibold))
                    if node.isDirectory && !node.isPackage {
                        Text("\(node.fileCount.formatted()) files").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text(node.modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 100, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .opacity(node.isDirectory && !node.isPackage && node.note == nil ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(hovering ? Color.white.opacity(0.06) : .clear)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(node.displayPath)
    }
}
