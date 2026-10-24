import DevSweepCore
import SwiftUI

/// Shown before every manual clean. Lists exactly what will be removed; Python virtual
/// environments are only removed if ticked here.
struct CleanReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let review: CleanReview

    private enum PlanState {
        case loading
        case ready(PythonSnapshot.Plan)
        case unreadable
    }

    @State private var approved: Set<String> = []
    @State private var plans: [String: PlanState] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AppGlyph(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.bold())
                    Text("Only the folders below are removed. Your code is never touched.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if activeCount > 0 {
                        Label(activeCount == projects.count && activeCount == 1
                              ? "This project is still in use. You'll need to reinstall or rebuild next time you work on it."
                              : "\(activeCount) of these projects are still in use. You'll need to reinstall or rebuild next time you work on them.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if !venvs.isEmpty { venvSection }
                    if !others.isEmpty { otherSection }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Removes \(Format.bytes(total))").fontWeight(.medium).monospacedDigit()
                    Text(model.settings.removalMode == .trash ? "Moved to the Trash, so you can put it back." : "Deleted immediately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.settings.removalMode == .trash ? "Move to Trash" : "Delete") { clean() }
                    .buttonStyle(PrimaryPillStyle(theme: .projects))
                    .keyboardShortcut(.defaultAction)
                    .disabled(total == 0)
            }
            .padding(16)
        }
        .frame(width: 620)
        .frame(minHeight: 380, idealHeight: 540)
        .task { await loadPlans() }
    }

    // MARK: Sections

    private var venvSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Python virtual environments").font(.headline)
                    Text(model.settings.snapshotPython
                         ? "Removed only if you tick them. Each one's packages are saved to a requirements file first, so you can rebuild it with one command."
                         : "Removed only if you tick them. Saving packages first is turned off in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                let selectable = venvs.filter { canApprove($0.venv) }.map(\.venv.path)
                Button(Set(selectable).isSubset(of: approved) && !selectable.isEmpty ? "Untick All" : "Tick All") {
                    if Set(selectable).isSubset(of: approved) { approved.subtract(selectable) } else { approved.formUnion(selectable) }
                }
                .disabled(selectable.isEmpty)
            }

            VStack(spacing: 0) {
                ForEach(venvs, id: \.venv.path) { item in
                    Toggle(isOn: binding(item.venv.path)) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.project.name) / \(item.project.relativePath(of: item.venv))").fontWeight(.medium)
                                planLine(item.venv)
                            }
                            Spacer()
                            BytesText(bytes: item.venv.bytes, font: .callout.weight(.semibold))
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!canApprove(item.venv))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    if item.venv.path != venvs.last?.venv.path { Divider().padding(.leading, 12) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }

    private var otherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Rebuildable folders").font(.headline)
                Text("Dependencies and build output your tools recreate on the next install or build.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(others, id: \.project.id) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.project.name).fontWeight(.medium)
                            Text(Set(item.artifacts.map(\.kind)).map(\.displayName).sorted().joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        BytesText(bytes: item.artifacts.reduce(0) { $0 + $1.bytes }, font: .callout.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    if item.project.id != others.last?.project.id { Divider().padding(.leading, 12) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }

    @ViewBuilder private func planLine(_ venv: Artifact) -> some View {
        switch plans[venv.path] ?? .loading {
        case .loading:
            Text("Reading its packages…").font(.caption).foregroundStyle(.secondary)
        case .unreadable:
            Text(model.settings.snapshotPython ? "Its packages can't be read, so it will be kept." : "Its packages can't be read.")
                .font(.caption).foregroundStyle(.orange)
        case .ready(let plan):
            let env = plan.environment
            let about = ["\(env.requirements.count) package\(env.requirements.count == 1 ? "" : "s")", env.pythonVersion.map { "Python \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            Text(about + " · " + destination(plan.outcome)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func destination(_ outcome: PythonSnapshot.Outcome) -> String {
        guard model.settings.snapshotPython else { return "not saved" }
        switch outcome {
        case .written(let path): return "saved to \((path as NSString).lastPathComponent)"
        case .alreadyCovered(let path): return "already listed in \((path as NSString).lastPathComponent)"
        case .empty: return "nothing to save"
        }
    }

    // MARK: Data

    private var title: String {
        projects.count == 1 ? "Clean \(projects[0].name)" : "Clean \(projects.count) projects"
    }

    private var projects: [Project] { review.projects.filter { !model.isProtected($0) } }

    private var venvs: [(project: Project, venv: Artifact)] {
        projects.flatMap { project in
            model.policy.cleanableArtifacts(of: project).filter { $0.kind == .pythonVenv }.map { (project, $0) }
        }
    }

    private var others: [(project: Project, artifacts: [Artifact])] {
        projects.compactMap { project in
            let artifacts = model.policy.cleanableArtifacts(of: project).filter { $0.kind != .pythonVenv }
            return artifacts.isEmpty ? nil : (project, artifacts)
        }
    }

    private var activeCount: Int { projects.filter { !model.status(of: $0).isStale }.count }

    private var total: Int64 {
        others.flatMap(\.artifacts).reduce(0) { $0 + $1.bytes }
            + venvs.filter { approved.contains($0.venv.path) }.reduce(0) { $0 + $1.venv.bytes }
    }

    /// A venv whose packages can't be saved is kept by the cleaner anyway, so it can't be ticked.
    private func canApprove(_ venv: Artifact) -> Bool {
        if case .unreadable = plans[venv.path], model.settings.snapshotPython { return false }
        return true
    }

    private func binding(_ path: String) -> Binding<Bool> {
        Binding {
            approved.contains(path)
        } set: { on in
            if on { approved.insert(path) } else { approved.remove(path) }
        }
    }

    private func loadPlans() async {
        let paths = venvs.map(\.venv.path)
        for path in paths { plans[path] = .loading }
        let results = await Task.detached(priority: .userInitiated) {
            paths.map { path in (path, try? PythonSnapshot.plan(venv: path)) }
        }.value
        for (path, plan) in results {
            plans[path] = plan.map(PlanState.ready) ?? .unreadable
        }
        // With "ask first" turned off, venvs start ticked; otherwise every one needs a tick.
        if !model.settings.askBeforeVenvs {
            approved = Set(paths.filter { path in venvs.first { $0.venv.path == path }.map { canApprove($0.venv) } ?? false })
        }
    }

    private func clean() {
        let targets = projects
        let chosen = approved
        dismiss()
        Task { await model.clean(targets, approvedVenvs: chosen) }
    }
}
