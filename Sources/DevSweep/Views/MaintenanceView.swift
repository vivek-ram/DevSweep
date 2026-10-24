import DevSweepCore
import SwiftUI

struct MaintenanceView: View {
    @Environment(AppModel.self) private var model
    let theme = ModuleTheme.maintenance

    var body: some View {
        let store = model.maintenance
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ModuleHeader(theme: theme, title: "Maintenance",
                                 subtitle: "Routine care macOS doesn't always get around to. Tasks marked with a lock ask for your password once, in a macOS window.") {
                        Button("Recommended") {
                            withAnimation { store.selection = Set(MaintenanceTask.allCases.filter(\.recommended)) }
                        }
                        .buttonStyle(GlassPillStyle())
                    }
                    .appearIn()

                    HStack(spacing: 14) {
                        stat("Memory in use", model.monitor.current.memoryTotal > 0
                             ? "\(Format.bytes(model.monitor.current.memoryUsed)) of \(Format.bytes(model.monitor.current.memoryTotal))" : "—",
                             symbol: "memorychip.fill")
                        stat("Purgeable space", store.purgeable.map(Format.bytes) ?? "—", symbol: "internaldrive.fill")
                        stat("Local snapshots", "\(store.snapshots.count)", symbol: "clock.arrow.circlepath")
                    }
                    .appearIn(delay: 0.05)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(Array(MaintenanceTask.allCases.enumerated()), id: \.element) { index, task in
                            TaskTile(task: task, theme: theme)
                                .appearIn(delay: 0.08 + Double(index) * 0.03)
                        }
                    }
                }
                .padding(28)
            }
            HStack {
                let count = store.selection.count
                let admin = store.selection.contains { $0.needsAdmin }
                Text(count == 0 ? "Choose tasks to run" : "\(count) task\(count == 1 ? "" : "s") selected" + (admin ? " · asks for your password" : ""))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(store.isRunning ? "Running…" : "Run Tasks") { Task { await store.run() } }
                    .buttonStyle(PrimaryPillStyle(theme: theme))
                    .disabled(count == 0 || store.isRunning || model.isCleaning)
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            .background(.ultraThinMaterial)
        }
        .onAppear { store.refresh() }
        .whileVisible(start: { model.monitor.start() }, stop: { model.monitor.stop() })
    }

    private func stat(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            ModuleGlyph(theme: theme, size: 34, symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline).monospacedDigit().contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glass()
    }
}

private struct TaskTile: View {
    @Environment(AppModel.self) private var model
    let task: MaintenanceTask
    let theme: ModuleTheme

    var body: some View {
        let store = model.maintenance
        let selected = store.selection.contains(task)
        let result = store.lastResults[task]
        Button {
            withAnimation(.spring(duration: 0.3)) {
                if selected { store.selection.remove(task) } else { store.selection.insert(task) }
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ModuleGlyph(theme: selected ? theme : ModuleTheme(colors: [.gray.opacity(0.6), .gray.opacity(0.35)], glyph: task.symbol),
                            size: 40, symbol: task.symbol)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(task.title).fontWeight(.semibold)
                        if task.needsAdmin { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(task.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let result {
                        Label(result.succeeded ? "Done \(store.lastRun[task].map { Format.idle(since: $0).lowercased() } ?? "")" : (result.message ?? "Didn't run"),
                              systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(result.succeeded ? .green : .orange)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass()
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.primary.opacity(selected ? 0.55 : 0), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
    }
}
