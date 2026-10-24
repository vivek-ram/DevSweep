import Charts
import DevSweepCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SmartScanHero()
                    .appearIn()
                ModuleTiles()
                    .appearIn(delay: 0.08)
                HStack(alignment: .top, spacing: 16) {
                    HealthCard()
                    if let disk = model.disk { DiskCard(disk: disk) }
                }
                .appearIn(delay: 0.16)
                HStack(alignment: .top, spacing: 16) {
                    BiggestFoldersCard()
                    LargestProjectsCard()
                }
                .appearIn(delay: 0.22)
                HStack(alignment: .top, spacing: 16) {
                    FreeSpaceTrendCard()
                    GrowthCard()
                }
                .appearIn(delay: 0.28)
                Footer()
            }
            .padding(28)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .whileVisible(start: { model.monitor.start() }, stop: { model.monitor.stop() })
    }
}

extension AppModel {
    /// Large files outside app data, which is what people usually mean by "my big files".
    var personalLargeFiles: [LargeFile] { largeFiles.filter { $0.place != .appData } }
}

// MARK: Hero

/// Mac Health on the left, what's happening in the middle, and the one big button on the right.
private struct SmartScanHero: View {
    @Environment(AppModel.self) private var model
    @State private var celebrating = false
    @State private var confirmClean = false
    let theme = ModuleTheme.smartScan

    private var scanning: Bool { model.isSmartScanning && (model.isScanningStorage || !hasResults) }
    private var hasResults: Bool { model.storage != nil || model.lastScan != nil }
    private var junkBytes: Int64 { model.junkScannedAt == nil ? 0 : model.suggestedJunkBytes }
    private var freeable: Int64 { junkBytes + model.idleBytes }

    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            visual
                .frame(width: 190, height: 190)
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 12) { actions }
                .frame(minWidth: 170)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        .background {
            ZStack {
                GlassBackground(cornerRadius: 28)
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(RadialGradient(colors: [theme.primary.opacity(scanning ? 0.32 : 0.2), .clear],
                                         center: .leading, startRadius: 0, endRadius: 520))
                SparkleField(active: scanning || celebrating)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
        }
        .animation(.spring(duration: 0.5), value: scanning)
        .animation(.spring(duration: 0.5), value: hasResults)
        .onChange(of: scanning) { wasScanning, isScanning in
            // A few seconds of sparkles when results land.
            if wasScanning && !isScanning {
                celebrating = true
                Task { try? await Task.sleep(for: .seconds(2.5)); celebrating = false }
            }
        }
        .confirmationDialog("Clean \(Format.bytes(junkBytes)) of junk?", isPresented: $confirmClean, titleVisibility: .visible) {
            Button("Clean") { Task { await model.cleanJunk(model.junk.filter(\.suggested)) } }
            Button("Review First") { model.section = .junk }
        } message: {
            Text(model.settings.removalMode == .trash
                 ? "Caches, logs and leftovers DevSweep marked as safe go to the Trash. Idle projects are reviewed separately."
                 : "Caches, logs and leftovers DevSweep marked as safe are removed. Idle projects are reviewed separately.")
        }
    }

    @ViewBuilder private var visual: some View {
        if scanning {
            ZStack {
                Circle().fill(RadialGradient(colors: [theme.primary.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: 120))
                ScanningOrb(size: 170, tint: .white)
            }
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        } else if hasResults || model.health != nil {
            HealthRing(health: model.health, size: 170)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        } else {
            HeroGlyph(theme: theme, size: 130)
        }
    }

    @ViewBuilder private var content: some View {
        if scanning {
            eyebrow("SCANNING YOUR MAC")
            Text(model.isScanningStorage ? "Looking everywhere…" : "Almost done…")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            if model.isScanningStorage {
                HStack(spacing: 6) {
                    Text(model.storageProgress.files.formatted())
                        .contentTransition(.numericText(value: Double(model.storageProgress.files)))
                    Text("files ·")
                    Text(Format.bytes(model.storageProgress.bytes))
                        .contentTransition(.numericText(value: Double(model.storageProgress.bytes)))
                }
                .font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                .animation(.snappy(duration: 0.25), value: model.storageProgress.files)
                Text(Paths.display(model.storageProgress.currentPath))
                    .font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.tertiary)
                    .id(model.storageProgress.currentPath)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: model.storageProgress.currentPath)
            }
            FlowChips {
                step("Projects", theme: .projects, done: !model.isScanning)
                step("Junk", theme: .cleanup, done: !model.isScanningJunk)
                step("Storage", theme: .spaceLens, done: !model.isScanningStorage)
                step("Caches", theme: .devCaches, done: !model.isMeasuringCaches)
                step("Updates", theme: .updater, done: !model.updater.isChecking)
                step("Privacy", theme: .privacy, done: !model.privacy.isScanning)
            }
            .padding(.top, 4)
        } else if !hasResults {
            eyebrow("SMART SCAN")
            Text("Find what's filling your Mac").font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Junk, forgotten projects, big files, developer caches, app updates and browser traces in one pass. Nothing is removed until you say so.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if freeable > 0 {
            eyebrow("READY TO FREE")
            CountUpBytes(value: freeable, font: .system(size: 50, weight: .bold, design: .rounded), duration: 1.2)
                .foregroundStyle(LinearGradient(colors: [.white, theme.secondary.opacity(0.9)], startPoint: .top, endPoint: .bottom))
            Text("\(Format.bytes(junkBytes)) of junk · \(Format.bytes(model.idleBytes)) in idle projects")
                .font(.callout).foregroundStyle(.secondary)
            if !model.venvsAwaitingApproval.isEmpty {
                let venvs = model.venvsAwaitingApproval
                Label("Includes \(venvs.count) virtual environment\(venvs.count == 1 ? "" : "s") that need\(venvs.count == 1 ? "s" : "") your OK",
                      systemImage: "hand.raised.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
            }
        } else {
            eyebrow("ALL TIDY")
            Text("Nothing to clean right now").font(.system(size: 30, weight: .bold, design: .rounded))
            if let next = model.nextToIdle {
                Text("\(next.project.name) becomes idle in \(Format.days(next.days)).").font(.callout).foregroundStyle(.secondary)
            } else if let health = model.health {
                Text("Mac Health is \(health.status.title.lowercased()).").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if scanning {
            Button("Stop") { model.cancelSmartScan() }
                .buttonStyle(OrbButtonStyle(theme: ModuleTheme(colors: [.white.opacity(0.28), .white.opacity(0.12)], glyph: "stop"), size: 112))
        } else if !hasResults {
            Button("Scan") { model.smartScan() }
                .buttonStyle(OrbButtonStyle(theme: theme, size: 120))
        } else if junkBytes > 0 {
            Button("Clean") { confirmClean = true }
                .buttonStyle(OrbButtonStyle(theme: theme, size: 120))
                .disabled(model.isCleaning)
            secondaryLinks
        } else if model.idleBytes > 0 {
            Button("Review") { model.requestClean(model.idleProjects) }
                .buttonStyle(OrbButtonStyle(theme: .projects, size: 120))
            secondaryLinks
        } else {
            Button("Scan") { model.smartScan() }
                .buttonStyle(OrbButtonStyle(theme: theme, size: 120))
        }
    }

    @ViewBuilder private var secondaryLinks: some View {
        HStack(spacing: 14) {
            if junkBytes > 0, model.idleBytes > 0 {
                Button("Projects") { model.requestClean(model.idleProjects) }
            }
            Button("Scan Again") { model.smartScan() }
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text).font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(theme.gradient)
    }

    private func step(_ title: String, theme: ModuleTheme, done: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(done ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: !done)
            Text(title)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(done ? 0.12 : 0.06)))
        .overlay(Capsule().strokeBorder(theme.primary.opacity(done ? 0.4 : 0), lineWidth: 1))
        .animation(.spring(duration: 0.4, bounce: 0.4), value: done)
    }
}

/// Lays chips out in rows, wrapping when they run out of room.
struct FlowChips: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// Kept for pages that sit on a coloured hero.
struct HeroButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .frame(minWidth: 150)
            .foregroundStyle(prominent ? AnyShapeStyle(Brand.indigo) : AnyShapeStyle(.white))
            .background {
                if prominent {
                    Capsule().fill(.white)
                } else {
                    Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .contentShape(Capsule())
    }
}

// MARK: Module tiles

private struct ModuleTiles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            ModuleTile(theme: .cleanup, title: "Cleanup",
                       value: model.junkScannedAt == nil ? nil : Format.bytes(model.suggestedJunkBytes),
                       caption: model.junkScannedAt == nil ? "Caches, logs, installers, AI app clutter" : "\(model.junk.filter(\.suggested).count) items marked safe",
                       busy: model.isScanningJunk) { model.section = .junk }
            ModuleTile(theme: .projects, title: "Idle Projects",
                       value: model.lastScan == nil ? nil : Format.bytes(model.idleBytes),
                       caption: "\(model.idleProjects.count) untouched for \(model.effectiveDays)+ days",
                       busy: model.isScanning) { model.showProjects(filter: .idle) }
            ModuleTile(theme: .largeFiles, title: "Large Files",
                       value: model.storage == nil ? nil : Format.bytes(model.personalLargeFiles.reduce(0) { $0 + $1.size }),
                       caption: model.storage == nil ? "Files over 50 MB" : "\(model.personalLargeFiles.count) files over 50 MB",
                       busy: model.isScanningStorage) { model.section = .largeFiles }
            ModuleTile(theme: .devCaches, title: "Developer Caches",
                       value: model.cacheBytes.map(Format.bytes),
                       caption: "pip, npm, Cargo, Xcode, Docker…",
                       busy: model.isMeasuringCaches) { model.section = .caches }
            ModuleTile(theme: .updater, title: "Updates",
                       value: model.updater.checkedAt == nil ? nil : (model.updater.updates.isEmpty ? "Up to date" : "\(model.updater.updates.count) apps"),
                       caption: model.updater.updates.isEmpty ? "App Store, developer feeds, Homebrew" : model.updater.updates.prefix(3).map(\.name).joined(separator: ", "),
                       busy: model.updater.isChecking) { model.section = .updater }
            ModuleTile(theme: .privacy, title: "Privacy",
                       value: model.privacy.scannedAt == nil ? nil : Format.bytes(model.privacy.items.reduce(0) { $0 + $1.bytes }),
                       caption: model.privacy.scannedAt == nil ? "Browser history, cookies, site data"
                           : "Traces in \(Set(model.privacy.items.map(\.browser)).count) browser\(Set(model.privacy.items.map(\.browser)).count == 1 ? "" : "s")",
                       busy: model.privacy.isScanning) { model.section = .privacy }
        }
    }
}

private struct ModuleTile: View {
    var theme: ModuleTheme
    var title: String
    var value: String?
    var caption: String
    var busy: Bool
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ModuleGlyph(theme: theme, size: 38)
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            .opacity(hovering ? 1 : 0.4)
                    }
                }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(value ?? "—")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(caption).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    GlassBackground(cornerRadius: 20)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(RadialGradient(colors: [theme.primary.opacity(hovering ? 0.3 : 0.16), .clear],
                                             center: .topLeading, startRadius: 0, endRadius: 220))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .animation(.spring(duration: 0.4), value: value)
    }
}

// MARK: Health

/// What's pulling the Mac Health score down, and where to fix it.
private struct HealthCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardTitle(title: "Mac Health", subtitle: model.health.map { "\($0.score) of 100 · \($0.status.title)" } ?? "Measured after a scan")
                    Spacer()
                    if let health = model.health {
                        Circle().fill(health.status.color).frame(width: 10, height: 10).shadow(color: health.status.color, radius: 6)
                    }
                }
                let factors = model.health?.factors.sorted { $0.penalty > $1.penalty } ?? []
                if factors.isEmpty {
                    Label(model.health == nil ? "Run a Smart Scan to see how your Mac is doing." : "Everything looks good.",
                          systemImage: model.health == nil ? "sparkle.magnifyingglass" : "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(factors.prefix(5)) { factor in
                        Button { open(factor) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: factor.symbol)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(color(for: factor))
                                    .frame(width: 26, height: 26)
                                    .background(Circle().fill(color(for: factor).opacity(0.15)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(factor.title).font(.callout.weight(.medium))
                                    Text(factor.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Text("−\(factor.penalty)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(color(for: factor))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: 400)
    }

    private func color(for factor: MacHealth.Factor) -> Color {
        factor.penalty >= 15 ? MacHealth.Status.critical.color : factor.penalty >= 8 ? MacHealth.Status.needsAttention.color : MacHealth.Status.fair.color
    }

    private func open(_ factor: MacHealth.Factor) {
        switch factor.id {
        case "junk": model.section = .junk
        case "projects": model.showProjects(filter: .idle)
        case "space": model.openMap(at: nil)
        case "trash": model.section = .junk
        case "launch": model.section = .loginItems
        case "memory": model.section = .memory
        default: break
        }
    }
}

// MARK: Disk

/// Startup disk split into what's using it, once the storage map has been measured.
private struct DiskCard: View {
    @Environment(AppModel.self) private var model
    var disk: VolumeSpace

    struct Segment: Identifiable {
        var id: String { title }
        let title: String
        let bytes: Int64
        let color: Color
    }

    @State private var grown = false

    var body: some View {
        let _ = model.storageVersion
        let segments = self.segments
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    CardTitle(title: "Macintosh HD", subtitle: "\(Format.bytes(disk.available)) free of \(Format.bytes(disk.total))")
                    Spacer()
                    Button("Space Lens") { model.openMap(at: nil) }.buttonStyle(GlassPillStyle()).controlSize(.small)
                }
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(segments) { segment in
                            RoundedRectangle(cornerRadius: 3).fill(segment.color.gradient)
                                .frame(width: max(2, geo.size.width * Double(segment.bytes) / Double(max(disk.total, 1)) * (grown ? 1 : 0)))
                                .help("\(segment.title): \(Format.bytes(segment.bytes))")
                        }
                        Rectangle().fill(.white.opacity(0.07))
                    }
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                }
                .frame(height: 16)
                .animation(.spring(duration: 0.9, bounce: 0.12), value: segments.map(\.bytes))
                .onAppear { withAnimation(.spring(duration: 1.1, bounce: 0.12).delay(0.15)) { grown = true } }
                FlowLegend(segments: segments)
                if model.storage == nil {
                    Text("Run a Smart Scan to see what's using your disk.").font(.caption).foregroundStyle(.secondary)
                }
                if model.isLowSpaceMode {
                    Label("Low on space: projects count as idle after \(model.effectiveDays) days instead of \(model.settings.retentionDays)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var segments: [Segment] {
        guard let root = model.storage?.root else {
            return [Segment(title: "Used", bytes: disk.used, color: .white.opacity(0.4))]
        }
        let wholeDisk = root.path == StorageScanner.wholeDisk
        let home = wholeDisk ? root.descendant(at: StorageScanner.wholeDisk + Paths.home) : root
        func child(_ name: String) -> Int64 { home?.children.first { $0.name == name }?.size ?? 0 }
        let documents = child("Documents") + child("Desktop")
        let downloads = child("Downloads")
        let media = child("Pictures") + child("Movies") + child("Music")
        let library = child("Library")
        let hidden = home?.children.filter { $0.name.hasPrefix(".") }.reduce(0) { $0 + $1.size } ?? 0
        let homeTotal = home?.size ?? 0
        let apps = wholeDisk ? (root.children.first { $0.name == "Applications" }?.size ?? 0) : 0
        let otherHome = max(0, homeTotal - documents - downloads - media - library - hidden)
        let system = max(0, disk.used - homeTotal - apps)
        return [
            Segment(title: "Documents & Desktop", bytes: documents, color: ModuleTheme.hex(0x60A5FA)),
            Segment(title: "Downloads", bytes: downloads, color: ModuleTheme.hex(0x2DD4BF)),
            Segment(title: "Photos, Music & Movies", bytes: media, color: ModuleTheme.hex(0xF472B6)),
            Segment(title: "App data", bytes: library, color: ModuleTheme.hex(0xFB923C)),
            Segment(title: "Developer tools", bytes: hidden, color: ModuleTheme.hex(0xA78BFA)),
            Segment(title: "Apps", bytes: apps, color: ModuleTheme.hex(0x4ADE80)),
            Segment(title: "Other files", bytes: otherHome, color: ModuleTheme.hex(0xFACC15)),
            Segment(title: wholeDisk ? "macOS & system" : "macOS, apps & system", bytes: system, color: .white.opacity(0.35)),
        ].filter { $0.bytes > 0 }
    }
}

private struct FlowLegend: View {
    var segments: [DiskCard.Segment]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(segments) { segment in
                HStack(spacing: 6) {
                    Circle().fill(segment.color).frame(width: 8, height: 8)
                    Text(segment.title).foregroundStyle(.secondary)
                    Text(Format.bytes(segment.bytes)).monospacedDigit()
                }
                .font(.caption)
            }
        }
    }
}

private struct BiggestFoldersCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.storageVersion
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardTitle(title: "Biggest folders", subtitle: "In your home folder")
                    Spacer()
                    Button("Storage Map") { model.openMap(at: nil) }.buttonStyle(.link)
                }
                if let home = homeNode {
                    let largest = Double(home.children.first?.size ?? 1)
                    ForEach(Array(home.children.prefix(7).enumerated()), id: \.element.path) { index, node in
                        Button {
                            model.openMap(at: node.isDirectory && !node.isPackage ? node.path : home.path)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(node.name).font(.callout).lineLimit(1)
                                    Spacer()
                                    BytesText(bytes: node.size, font: .callout.weight(.medium))
                                }
                                GrowingBar(fraction: Double(node.size) / largest, fill: ModuleTheme.spaceLens.gradient, delay: 0.3 + Double(index) * 0.06)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else if model.isScanningStorage {
                    HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                } else {
                    Text("Run a Smart Scan to see which folders are biggest.").foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 380)
    }

    private var homeNode: StorageNode? {
        guard let root = model.storage?.root else { return nil }
        return root.path == StorageScanner.wholeDisk ? root.descendant(at: StorageScanner.wholeDisk + Paths.home) : root
    }
}

private struct LargestProjectsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle(title: "Largest projects", subtitle: "Rebuildable folders in your code")
                    Spacer()
                    Button("Show All") { model.showProjects(filter: .all) }.buttonStyle(.link)
                }
                if model.projects.isEmpty {
                    Text(model.settings.roots.isEmpty ? "Choose your project folders in Settings → Folders." : "No projects with rebuildable folders yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(model.projects.prefix(6))) { project in
                    Button {
                        model.showProjects(selecting: project)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).fontWeight(.medium).lineLimit(1)
                                Text(Format.idle(since: project.lastActivity)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            EcosystemBadges(project: project)
                            StatusPill(status: model.status(of: project))
                            BytesText(bytes: project.totalBytes, font: .callout.weight(.semibold))
                                .frame(width: 76, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if project.id != model.projects.prefix(6).last?.id { Divider() }
                }
            }
        }
    }
}

private struct Footer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if let date = model.storage?.date {
                Text("Storage measured \(date.formatted(.relative(presentation: .named)))")
                if let duration = model.storage?.duration { Text("in \(String(format: "%.0f", duration))s") }
                Text("·")
            }
            Text("Projects idle after \(Format.days(model.settings.retentionDays))")
            Text("· Automation: \(model.settings.automation == .off ? "off" : model.settings.automation == .notify ? "notify" : "auto-clean")")
            if !model.hasFullDiskAccess {
                Text("·")
                Button("Allow Full Disk Access for a complete scan") { model.openFullDiskAccessSettings() }.buttonStyle(.link)
            }
            Spacer()
            SettingsLink { Text("Settings…") }.buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Free space over the last 30 days.
struct FreeSpaceTrendCard: View {
    @Environment(AppModel.self) private var model
    @State private var revealed = false

    var body: some View {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let samples = model.spaceHistory.samples.filter { $0.date >= cutoff }
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    CardTitle(title: "Free space", subtitle: "Last 30 days")
                    Spacer()
                    if let first = samples.first, let last = samples.last, samples.count > 1 {
                        let change = last.free - first.free
                        Label("\(change >= 0 ? "+" : "−")\(Format.bytes(abs(change)))", systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(change >= 0 ? .green : .orange)
                    }
                }
                if samples.count < 2 {
                    Text("DevSweep started tracking just now. Check back in a day or two to see the trend.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else {
                    let low = Double(samples.map(\.free).min() ?? 0)
                    let high = Double(samples.map(\.free).max() ?? 1)
                    let pad = max((high - low) * 0.15, 1_000_000_000)
                    Chart(samples, id: \.date) { sample in
                        AreaMark(x: .value("Date", sample.date),
                                 yStart: .value("Base", low - pad),
                                 yEnd: .value("Free", revealed ? Double(sample.free) : low - pad))
                            .foregroundStyle(LinearGradient(colors: [ModuleTheme.smartScan.primary.opacity(0.4), ModuleTheme.smartScan.primary.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", sample.date), y: .value("Free", revealed ? Double(sample.free) : low - pad))
                            .foregroundStyle(ModuleTheme.smartScan.gradient)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: (low - pad)...(high + pad))
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine()
                            AxisValueLabel { Text(Format.bytes(Int64(value.as(Double.self) ?? 0))) }
                        }
                    }
                    .frame(height: 140)
                    .onAppear { withAnimation(.spring(duration: 1.0, bounce: 0.1).delay(0.4)) { revealed = true } }
                }
            }
        }
    }
}

/// Folders that grew noticeably since a few days ago.
struct GrowthCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let growth = Array(model.recentGrowth.prefix(5))
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "What grew", subtitle: "Compared with your last measurements")
                if model.spaceHistory.snapshots.count < 2 {
                    Text("After two daily measurements, folders that suddenly get bigger show up here, and you get a notification when one jumps by 2 GB or more.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if growth.isEmpty {
                    Label("Nothing grew by more than 500 MB.", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                } else {
                    let largest = Double(growth.first?.delta ?? 1)
                    ForEach(Array(growth.enumerated()), id: \.element.id) { index, item in
                        Button {
                            model.openMap(at: item.path)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "arrow.up.right").foregroundStyle(.orange)
                                    Text(item.name).lineLimit(1)
                                    Spacer()
                                    Text("+\(Format.bytes(item.delta))").monospacedDigit().fontWeight(.semibold).foregroundStyle(.orange)
                                }
                                .font(.callout)
                                Text(Paths.display(item.path)).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                                GrowingBar(fraction: Double(item.delta) / largest, fill: Color.orange.gradient, height: 4, delay: 0.4 + Double(index) * 0.06)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: 380)
    }
}
