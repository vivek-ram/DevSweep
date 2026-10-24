import DevSweepCore
import SwiftUI

struct ProjectRow: Identifiable {
    let project: Project
    let status: ProjectStatus
    let bytes: Int64

    var id: String { project.id }
    var name: String { project.name.lowercased() }
    var lastActivity: Date { project.lastActivity }
    var statusRank: Int { status.rank }
}

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\ProjectRow.bytes, order: .reverse)]
    @State private var search = ""
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ModuleHeader(theme: .projects, title: "Projects",
                         subtitle: "Your code always stays. In projects untouched for \(Format.days(model.effectiveDays)), rebuildable folders can go — virtual environments only with your OK.") {
                Picker("Show", selection: $model.projectFilter) {
                    ForEach(ProjectFilter.allCases) { filter in
                        Text("\(filter.title) (\(model.projects(matching: filter).count))").tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .appearIn()

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter projects", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .frame(maxWidth: 280)
                .background(Capsule().fill(.white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Palette.hairline))
                if model.isScanning {
                    HStack(spacing: 6) {
                        ScanningOrb(size: 22, tint: ModuleTheme.projects.primary)
                        Text("Scanning… \(model.progress.foldersVisited.formatted()) folders").font(.callout).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Button { model.scan() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(GlassPillStyle())
                    .disabled(model.isScanning)
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .padding(.vertical, 1)
                }
                .buttonStyle(GlassPillStyle())
                .help(showInspector ? "Hide project details" : "Show project details")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 16) {
            Table(rows, selection: $model.selectedProjects, sortOrder: $sortOrder) {
                TableColumn("Project", value: \.name) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.project.name).fontWeight(.medium).lineLimit(1)
                            EcosystemBadges(project: row.project)
                        }
                        Text(row.project.displayPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    .padding(.vertical, 3)
                    .help(row.project.path)
                }
                .width(min: 140, ideal: 160)

                TableColumn("Last Active", value: \.lastActivity) { row in
                    Text(Format.idle(since: row.lastActivity))
                        .foregroundStyle(.secondary)
                        .help(row.lastActivity == .distantPast ? "No activity found" : row.lastActivity.shortDateTime)
                }
                .width(min: 92, ideal: 104)

                TableColumn("Status", value: \.statusRank) { row in
                    StatusPill(status: row.status)
                }
                .width(min: 80, ideal: 86)

                TableColumn("Size", value: \.bytes) { row in
                    BytesText(bytes: row.bytes, font: .body.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 76)
            }
            .contextMenu(forSelectionType: Project.ID.self) { ids in
                let selected = projects(for: ids)
                if !selected.isEmpty {
                    Button("Clean…") { model.requestClean(selected) }
                        .disabled(selected.allSatisfy(model.isProtected))
                    Divider()
                    if selected.count == 1, let project = selected.first {
                        Button("Show in Finder") { model.reveal(project.path) }
                        Button(model.isProtected(project) ? "Stop Protecting" : "Protect from Cleaning") {
                            model.toggleProtection(project)
                        }
                        .disabled(project.hasKeepMarker)
                    }
                }
            } primaryAction: { ids in
                projects(for: ids).forEach { model.reveal($0.path) }
            }
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .overlay {
                if rows.isEmpty { emptyState }
            }
            .padding(6)
            .glass(cornerRadius: 18)

                if showInspector {
                    ProjectInspector(clean: { model.requestClean($0) })
                        .frame(width: 300)
                        .glass(cornerRadius: 18)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 18)
            .animation(.spring(duration: 0.35), value: showInspector)

            footer
        }
        .navigationTitle("Projects")
    }

    private var rows: [ProjectRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.projects(matching: model.projectFilter)
            .filter { query.isEmpty || $0.path.lowercased().contains(query) }
            .map { ProjectRow(project: $0, status: model.status(of: $0), bytes: model.cleanableBytes(of: $0)) }
            .sorted(using: sortOrder)
    }

    private func projects(for ids: Set<Project.ID>) -> [Project] {
        model.projects.filter { ids.contains($0.id) }
    }

    private var footer: some View {
        let selected = projects(for: model.selectedProjects).filter { !model.isProtected($0) }
        let bytes = selected.reduce(0) { $0 + model.cleanableBytes(of: $1) }
        return ActionBar {
            if selected.isEmpty {
                Text("\(rows.count) project\(rows.count == 1 ? "" : "s") · \(Format.bytes(rows.reduce(0) { $0 + $1.bytes }))")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(selected.count) selected · \(Format.bytes(bytes))")
            }
        } trailing: {
            Button {
                model.requestClean(selected)
            } label: {
                Label("Clean Selected", systemImage: "sparkles")
            }
            .buttonStyle(PrimaryPillStyle(theme: .projects))
            .disabled(bytes == 0 || model.isCleaning)
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.projectFilter {
        case .idle where search.isEmpty:
            ContentUnavailableView("Nothing idle", systemImage: "checkmark.seal",
                                   description: Text("No project has gone \(model.effectiveDays) days without activity."))
        case .protected where search.isEmpty:
            ContentUnavailableView("No protected projects", systemImage: "lock",
                                   description: Text("Right-click a project to protect it, or drop a \(ArtifactRules.keepMarker) file into any folder."))
        default:
            ContentUnavailableView.search(text: search)
        }
    }
}

struct ProjectInspector: View {
    @Environment(AppModel.self) private var model
    var clean: ([Project]) -> Void

    var body: some View {
        let selected = model.projects.filter { model.selectedProjects.contains($0.id) }
        Group {
            if selected.count == 1, let project = selected.first {
                ProjectDetail(project: project, clean: clean)
            } else if selected.count > 1 {
                let bytes = selected.reduce(0) { $0 + model.cleanableBytes(of: $1) }
                VStack(spacing: 14) {
                    ModuleGlyph(theme: .projects, size: 64, symbol: "square.stack.3d.up.fill")
                    Text("\(selected.count) projects").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("\(Format.bytes(bytes)) can be removed").foregroundStyle(.secondary)
                    Button("Clean \(selected.count) Projects") { clean(selected) }
                        .buttonStyle(PrimaryPillStyle(theme: .projects))
                        .disabled(bytes == 0)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Selection", systemImage: "folder",
                                       description: Text("Select a project to see what can be removed and why."))
            }
        }
    }
}

private struct ProjectDetail: View {
    @Environment(AppModel.self) private var model
    var project: Project
    var clean: ([Project]) -> Void

    var body: some View {
        let status = model.status(of: project)
        let groups = Dictionary(grouping: project.artifacts, by: \.kind)
            .map { (kind: $0.key, items: $0.value.sorted { $0.bytes > $1.bytes }) }
            .sorted { $0.items.reduce(0) { $0 + $1.bytes } > $1.items.reduce(0) { $0 + $1.bytes } }

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(project.name).font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(2)
                        if project.isGitRepo {
                            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).help("Git repository")
                        }
                    }
                    Text(project.displayPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        StatusPill(status: status)
                        EcosystemBadges(project: project)
                    }
                    Text(explanation(status)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Activity") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        activityRow("Edited", project.lastEdited, "Newest change to your own files")
                        activityRow(project.openedWith.map { "Opened in \($0)" } ?? "Opened", project.lastOpened,
                                    "Last time an editor (VS Code, Cursor, Xcode, JetBrains, Claude Code) opened it")
                        activityRow("Built / installed", project.lastBuilt, "Newest change to a dependency or build folder")
                    }
                }

                section("Rebuildable folders") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups, id: \.kind) { group in
                            KindGroup(project: project, kind: group.kind, items: group.items,
                                      enabled: model.settings.enabledKinds.contains(group.kind))
                        }
                    }
                }

                VStack(spacing: 8) {
                    Button {
                        clean([project])
                    } label: {
                        Label("Clean This Project", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryPillStyle(theme: .projects))
                    .disabled(status == .protected || model.cleanableBytes(of: project) == 0 || model.isCleaning)

                    HStack {
                        Button("Show in Finder") { model.reveal(project.path) }
                        Spacer()
                        Button(model.isProtected(project) ? "Stop Protecting" : "Protect") { model.toggleProtection(project) }
                            .disabled(project.hasKeepMarker)
                            .help(project.hasKeepMarker ? "Protected by a \(ArtifactRules.keepMarker) file" : "Never clean this project")
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(18)
        }
    }

    private func explanation(_ status: ProjectStatus) -> String {
        switch status {
        case .stale(let idle):
            "Nothing has changed here for \(Format.days(idle)), longer than your \(Format.days(model.effectiveDays)) limit."
        case .active(let days):
            "In use. It becomes idle in \(Format.days(days)) if nothing changes."
        case .protected:
            project.hasKeepMarker ? "Protected by a \(ArtifactRules.keepMarker) file." : "You protected this project. It is never cleaned."
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func activityRow(_ label: String, _ date: Date?, _ help: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(date.map { Format.idle(since: $0) } ?? "—")
                .help(date?.shortDateTime ?? help)
        }
        .font(.callout)
        .help(help)
    }
}

private struct KindGroup: View {
    @Environment(AppModel.self) private var model
    var project: Project
    var kind: ArtifactKind
    var items: [Artifact]
    var enabled: Bool
    @State private var expanded = false

    var body: some View {
        let total = items.reduce(0) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(kind.ecosystem.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.displayName).fontWeight(.medium)
                    Text(items.count == 1 ? project.relativePath(of: items[0]) : "\(items.count) folders")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                BytesText(bytes: total, font: .callout.weight(.semibold))
            }
            .opacity(enabled ? 1 : 0.45)

            if !enabled {
                Text("Turned off in Settings → Types, so it is kept.").font(.caption).foregroundStyle(.secondary)
            } else if kind == .pythonVenv {
                Label(model.settings.askBeforeVenvs ? "Removed only after you tick it in the review"
                                                    : "Included when this project is cleaned",
                      systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.secondary)
                if model.settings.snapshotPython {
                    Label("Packages are saved to requirements.txt first", systemImage: "doc.text")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Get it back: \(kind.restoreHint)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            if items.count > 1 {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(items) { item in
                            HStack {
                                Text(project.relativePath(of: item)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                BytesText(bytes: item.bytes)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Show folders").font(.caption)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline))
    }
}
