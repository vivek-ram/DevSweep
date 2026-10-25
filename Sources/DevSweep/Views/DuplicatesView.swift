import AppKit
import DevSweepCore
import ImageIO
import SwiftUI

struct DuplicatesView: View {
    @State private var tab = Tab.identical

    enum Tab: String, CaseIterable { case identical = "Identical Files", similar = "Similar Photos" }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(theme: .duplicates, title: "Duplicates",
                         subtitle: tab == .identical
                            ? "Files with exactly the same contents, compared byte for byte. One copy is always kept."
                            : "Bursts, retakes and near-identical screenshots. Keep the sharpest shot, remove the rest.") {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 8)
            .appearIn()
            switch tab {
            case .identical: IdenticalFilesPane()
            case .similar: SimilarPhotosPane()
            }
        }
        .navigationTitle("Duplicates")
    }
}

// MARK: Identical files

private struct IdenticalFilesPane: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    let theme = ModuleTheme.duplicates

    var body: some View {
        let store = model.duplicates
        Group {
            if store.isScanning {
                ScanProgressView(theme: theme,
                                 title: store.progress.phase == .listing ? "Looking through your files…" : "Comparing contents…",
                                 detail: store.progress.phase == .listing
                                    ? "\(store.progress.filesSeen.formatted()) files"
                                    : "\(store.progress.hashed.formatted()) checks of \(store.progress.candidates.formatted()) look-alikes",
                                 path: store.progress.currentPath) { store.cancel() }
            } else if store.scannedAt == nil {
                start
            } else {
                results
            }
        }
        .confirmationDialog("Move \(store.markedCount) duplicate\(store.markedCount == 1 ? "" : "s") to the Trash?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Move \(Format.bytes(store.reclaimable)) to Trash") { Task { await store.trashMarked() } }
        } message: {
            Text("One copy of every file is always kept. You can put the rest back from the Trash.")
        }
    }

    private var start: some View {
        VStack(spacing: 20) {
            HeroGlyph(theme: theme, size: 110)
            Text("Rebuildable dev folders and app bundles are skipped.")
                .foregroundStyle(.secondary)
            FolderChips()
            Button {
                model.duplicates.scan(folders: model.settings.duplicateFolders)
            } label: {
                Text("Find Duplicates")
            }
            .buttonStyle(PrimaryPillStyle(theme: theme, large: true))
            .disabled(model.settings.duplicateFolders.isEmpty)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        let store = model.duplicates
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(Format.bytes(store.groups.reduce(0) { $0 + $1.wasted })) in duplicates")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                            Text("\(store.groups.count) sets. Click a copy to switch between keep and remove. Copies inside code projects start as kept.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Menu("Select") {
                            Button("Suggested (skip code projects)") { withAnimation { store.markSuggested() } }
                            Button("Keep one copy of everything") {
                                withAnimation {
                                    store.marked = Set(store.groups.flatMap { group in
                                        let keeper = DuplicateFinder.suggestedKeeper(group)
                                        return group.files.map(\.path).filter { $0 != keeper }
                                    })
                                }
                            }
                            Button("Keep everything") { withAnimation { store.marked.removeAll() } }
                        }
                        .fixedSize()
                        Button { store.scan(folders: model.settings.duplicateFolders) } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                            .buttonStyle(GlassPillStyle())
                    }
                    FolderChips()
                    if store.groups.isEmpty {
                        ContentUnavailableView("No duplicates", systemImage: "checkmark.seal",
                                               description: Text("Every file over 1 MB in these folders is unique."))
                    }
                    ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                        GroupCard(group: group)
                            .appearIn(delay: min(Double(index) * 0.03, 0.4))
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 12)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }
            ActionBar {
                Text(store.markedCount == 0 ? "Nothing selected" : "\(store.markedCount) copies selected · \(Format.bytes(store.reclaimable))")
                    .foregroundStyle(store.markedCount == 0 ? .secondary : .primary)
                    .contentTransition(.numericText())
            } trailing: {
                Button { confirm = true } label: { Label("Move to Trash", systemImage: "trash") }
                    .buttonStyle(PrimaryPillStyle(theme: theme))
                    .disabled(store.markedCount == 0 || model.isCleaning)
            }
        }
    }
}

// MARK: Similar photos

private struct SimilarPhotosPane: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    let theme = ModuleTheme.duplicates

    var body: some View {
        let store = model.similar
        Group {
            if store.isScanning {
                ScanProgressView(theme: theme, title: "Looking at your photos…",
                                 detail: "\(store.progress.analysed.formatted()) of \(store.progress.found.formatted()) images compared",
                                 path: store.progress.currentPath) { store.cancel() }
            } else if store.scannedAt == nil {
                VStack(spacing: 20) {
                    HeroGlyph(theme: ModuleTheme(colors: theme.colors, glyph: "photo.stack.fill"), size: 110)
                    Text("Compares what's in each picture in \(SimilarImagesStore.defaultFolders().map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")). Your Photos library isn't touched.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 480)
                    Button("Find Similar Photos") { store.scan() }
                        .buttonStyle(PrimaryPillStyle(theme: theme, large: true))
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(store.groups.isEmpty ? "No similar photos" : "\(store.groups.count) sets of similar photos")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                Spacer()
                                Button("Mark All but the Best") { withAnimation { store.markAllButBest() } }
                                    .buttonStyle(GlassPillStyle()).disabled(store.groups.isEmpty)
                                Button { store.scan() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                                    .buttonStyle(GlassPillStyle())
                            }
                            if store.groups.isEmpty {
                                ContentUnavailableView("Nothing alike", systemImage: "checkmark.seal",
                                                       description: Text("No two pictures in these folders look nearly the same."))
                            }
                            ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                                SimilarGroupCard(group: group)
                                    .appearIn(delay: min(Double(index) * 0.04, 0.4))
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 28).padding(.vertical, 12)
                    }
                    ActionBar {
                        Text(store.markedCount == 0 ? "Tick the shots you don't need" : "\(store.markedCount) photos selected · \(Format.bytes(store.reclaimable))")
                            .foregroundStyle(store.markedCount == 0 ? .secondary : .primary)
                    } trailing: {
                        Button { confirm = true } label: { Label("Move to Trash", systemImage: "trash") }
                            .buttonStyle(PrimaryPillStyle(theme: theme))
                            .disabled(store.markedCount == 0 || model.isCleaning)
                    }
                }
            }
        }
        .confirmationDialog("Move \(store.markedCount) photo\(store.markedCount == 1 ? "" : "s") to the Trash?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Move \(Format.bytes(store.reclaimable)) to Trash") { Task { await store.trashMarked() } }
        } message: {
            Text("At least one photo of every set is always kept. You can put them back from the Trash.")
        }
    }
}

private struct SimilarGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: SimilarGroup

    var body: some View {
        let store = model.similar
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(group.images.count) similar").font(.headline)
                Text("· up to \(Format.bytes(group.reclaimable)) to free").foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(group.images) { image in
                        let marked = store.marked.contains(image.path)
                        VStack(alignment: .leading, spacing: 6) {
                            Thumbnail(path: image.path)
                                .frame(width: 150, height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(.black.opacity(marked ? 0.45 : 0))
                                    if marked {
                                        Image(systemName: "trash.circle.fill").font(.system(size: 30)).foregroundStyle(.white, .red)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(marked ? Color.red.opacity(0.8) : (image.path == group.best ? Color.green.opacity(0.8) : Palette.hairline), lineWidth: 2))
                                .overlay(alignment: .topLeading) {
                                    if image.path == group.best {
                                        badge("Best", .green)
                                    } else if image.flaw == .blurry {
                                        badge("Blurry", .orange)
                                    }
                                }
                            Text(image.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
                            Text("\(Format.bytes(image.bytes)) · \(image.modified.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.spring(duration: 0.3)) { store.toggle(image.path, in: group) } }
                        .contextMenu {
                            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: image.path)) }
                            Button("Show in Finder") { model.reveal(image.path) }
                        }
                        .help(Paths.display(image.path))
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .glass()
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.bold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color))
            .padding(6)
    }
}

/// A small, downsampled preview of an image file, made off the main thread.
struct Thumbnail: View {
    let path: String
    var maxPixels = 360
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.06))
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: path) {
            let path = path, maxPixels = maxPixels
            let loaded = await Task.detached(priority: .utility) { Thumbnail.load(path, maxPixels: maxPixels) }.value
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }

    nonisolated static func load(_ path: String, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A module's "working on it" state: the orb, what's happening, and a Stop button.
struct ScanProgressView: View {
    var theme: ModuleTheme
    var title: String
    var detail: String
    var path: String
    var stop: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(RadialGradient(colors: [theme.primary.opacity(0.12), .clear], center: .center, startRadius: 0, endRadius: 110))
                    .frame(width: 220, height: 220)
                ScanningOrb(size: 130, tint: .white)
            }
            Text(title).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(detail).monospacedDigit().foregroundStyle(.secondary).contentTransition(.numericText())
            Text(Paths.display(path)).font(.caption).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
            Button("Stop", action: stop).buttonStyle(GlassPillStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FolderChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let folders = model.settings.duplicateFolders
        HStack(spacing: 6) {
            Text("Looking in").font(.caption).foregroundStyle(.secondary)
            ForEach(folders, id: \.self) { folder in
                HStack(spacing: 4) {
                    Text((folder as NSString).lastPathComponent)
                    Button {
                        withAnimation { model.settings.duplicateFolders.removeAll { $0 == folder } }
                    } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain)
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(ModuleTheme.duplicates.primary.opacity(0.22)))
                .overlay(Capsule().strokeBorder(ModuleTheme.duplicates.primary.opacity(0.4)))
                .help(Paths.display(folder))
            }
            Button {
                for path in chooseFolders(message: "Choose folders to search for duplicates") where !model.settings.duplicateFolders.contains(path) {
                    model.settings.duplicateFolders.append(path)
                }
            } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Add a folder")
        }
    }
}

private struct GroupCard: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup

    var body: some View {
        let store = model.duplicates
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: FileIcons.icon(forPath: group.files[0].path, isFolder: false)).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.files[0].name).fontWeight(.semibold).lineLimit(1)
                        Text("\(group.files.count) copies · \(Format.bytes(group.size)) each").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        BytesText(bytes: group.size * Int64(group.files.filter { store.marked.contains($0.path) }.count), font: .callout.weight(.semibold))
                        Text("to free").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                Divider().opacity(0.5)
                ForEach(group.files) { file in
                    let removing = store.marked.contains(file.path)
                    HStack(spacing: 10) {
                        Image(systemName: removing ? "trash.circle.fill" : "checkmark.seal.fill")
                            .foregroundStyle(removing ? Color.secondary : Color.green)
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.folderDisplayPath).lineLimit(1).truncationMode(.head)
                                .foregroundStyle(removing ? .secondary : .primary)
                                .strikethrough(removing, color: .secondary)
                            Text("Modified \(file.modified.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(removing ? "Remove" : "Keep")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .foregroundStyle(removing ? Color.secondary : Color.green)
                            .background(Capsule().fill((removing ? Color.secondary : Color.green).opacity(0.12)))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.spring(duration: 0.3)) { store.toggle(file.path, in: group) } }
                    .contextMenu {
                        Button("Keep Only This Copy") { withAnimation { store.keepOnly(file.path, in: group) } }
                        Button("Show in Finder") { model.reveal(file.path) }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}
