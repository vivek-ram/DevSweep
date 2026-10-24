import Charts
import DevSweepCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<CleanupRecord.ID>()
    @State private var confirmPurge = false
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ModuleHeader(theme: .activity, title: "My Activity",
                                 subtitle: "Everything DevSweep has freed, where it came from, and every item it removed.") {
                        Button("Clear History") { confirmClear = true }
                            .buttonStyle(GlassPillStyle())
                            .disabled(model.history.isEmpty)
                    }
                    .appearIn()

                    ActivityStats().appearIn(delay: 0.05)

                    HStack(alignment: .top, spacing: 16) {
                        FreedByCategoryCard()
                        FreedByWeekCard()
                    }
                    .appearIn(delay: 0.1)

                    if !model.trashedItems.isEmpty {
                        HStack(spacing: 12) {
                            ModuleGlyph(theme: .activity, size: 34, symbol: "trash.fill")
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(Format.bytes(model.trashedBytes)) is still in the Trash").fontWeight(.medium)
                                Text("The space comes back once it's deleted from the Trash.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Free Trash Space") { confirmPurge = true }
                                .buttonStyle(PrimaryPillStyle(theme: .activity))
                        }
                        .padding(14)
                        .glass()
                        .appearIn(delay: 0.14)
                    }

                    Text("EVERY ITEM").font(.caption.weight(.bold)).tracking(1).foregroundStyle(ModuleTheme.activity.gradient)
                        .padding(.top, 4)
                    historyTable
                        .frame(height: 420)
                        .padding(6)
                        .glass(cornerRadius: 18)
                        .appearIn(delay: 0.18)
                }
                .padding(28)
                .frame(maxWidth: 1060)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("My Activity")
        .onAppear { model.refreshTrash() }
        .confirmationDialog("Delete \(Format.bytes(model.trashedBytes)) from the Trash?", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) { Task { await model.purgeTrash() } }
        } message: {
            Text("Only the \(model.trashedItems.count) items DevSweep moved to the Trash are deleted. Anything else in your Trash stays put.")
        }
        .confirmationDialog("Clear the cleanup history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This only forgets the list. Files in the Trash stay there.")
        }
    }

    private var historyTable: some View {
            Table(model.history, selection: $selection) {
                TableColumn("When") { record in
                    Text(record.date.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                        .help(record.date.shortDateTime)
                }
                .width(min: 90, ideal: 110)

                TableColumn("Item") { record in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(record)).fontWeight(.medium)
                        Text(Paths.display(record.itemPath)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    .padding(.vertical, 2)
                    .help(record.itemPath)
                }
                .width(min: 220, ideal: 360)

                TableColumn("Size") { record in
                    BytesText(bytes: record.bytes).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 80)

                TableColumn("Result") { record in
                    HStack(spacing: 6) {
                        Image(systemName: icon(record)).foregroundStyle(color(record))
                        Text(result(record)).lineLimit(1)
                        if record.snapshotPath != nil {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                                .help("Saved \(record.snapshotPath.map { ($0 as NSString).lastPathComponent } ?? "")")
                        }
                        if record.automatic {
                            Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary).help("Cleaned automatically")
                        }
                    }
                    .help(record.message ?? "")
                }
                .width(min: 160, ideal: 260)
            }
            .contextMenu(forSelectionType: CleanupRecord.ID.self) { ids in
                if let record = model.history.first(where: { ids.contains($0.id) }) {
                    if let snapshot = record.snapshotPath {
                        Button("Show Saved Requirements") { model.reveal(snapshot) }
                    }
                    if let trash = record.trashPath, FileManager.default.fileExists(atPath: trash) {
                        Button("Show in Trash") { model.reveal(trash) }
                    }
                    Button("Show Project in Finder") { model.reveal(record.projectPath) }
                }
            }
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .overlay {
                if model.history.isEmpty {
                    ContentUnavailableView("Nothing cleaned yet", systemImage: "clock",
                                           description: Text("Everything DevSweep removes is listed here, with any requirements files it saved."))
                }
            }
    }

    private func title(_ record: CleanupRecord) -> String {
        if record.isCache { return model.caches.first { "cache:\($0.id)" == record.kind }?.name ?? "Developer cache" }
        let name = (record.itemPath as NSString).lastPathComponent
        if record.kind == "file" { return name }
        if record.kind.hasPrefix("junk:"), let category = JunkCategory(rawValue: String(record.kind.dropFirst(5))) {
            return category == .trash ? "Emptied the Trash" : "\(category.title) — \(category == .appCaches ? (JunkNames.appName(forBundleID: name) ?? name) : name)"
        }
        let project = (record.projectPath as NSString).lastPathComponent
        let kind = record.artifactKind?.displayName ?? record.kind
        return "\(project) — \(kind)"
    }

    private func result(_ record: CleanupRecord) -> String {
        switch record.outcome {
        case .removed: record.mode == .trash ? "Moved to Trash" : "Deleted"
        case .skipped: record.message ?? "Kept"
        case .failed: record.message ?? "Failed"
        }
    }

    private func icon(_ record: CleanupRecord) -> String {
        switch record.outcome {
        case .removed: "checkmark.circle.fill"
        case .skipped: "minus.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func color(_ record: CleanupRecord) -> Color {
        switch record.outcome {
        case .removed: .green
        case .skipped: .secondary
        case .failed: .red
        }
    }
}

// MARK: Dashboard

extension CleanupRecord {
    /// The bucket this item counts toward on the activity dashboard.
    var activityCategory: String {
        if kind.hasPrefix("junk:"), let category = JunkCategory(rawValue: String(kind.dropFirst(5))) {
            return category == .trash ? "Trash" : category.title
        }
        if kind.hasPrefix("cache:") { return "Developer caches" }
        if kind.hasPrefix("tool:") { return "Toolchains & models" }
        if kind.hasPrefix("privacy:") { return "Privacy" }
        if kind.hasPrefix("cloud:") { return "Cloud copies" }
        if kind.hasPrefix("maintenance:") { return "Maintenance" }
        if kind == "app" { return "Apps" }
        if kind == "launch" { return "Login items" }
        if kind == "file" { return "Your files" }
        return "Project folders"
    }
}

private struct ActivityStats: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Maintenance tasks are logged too, but they don't remove anything.
        let removed = model.history.filter { $0.outcome == .removed && !$0.kind.hasPrefix("maintenance:") }
        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
        HStack(spacing: 14) {
            stat("Freed in total", Format.bytes(removed.reduce(0) { $0 + $1.bytes }), "sparkles")
            stat("This month", Format.bytes(removed.filter { $0.date >= monthStart }.reduce(0) { $0 + $1.bytes }), "calendar")
            stat("Items cleaned", removed.count.formatted(), "checklist")
            stat("Auto-clean runs", model.settings.autoCleanRuns.count.formatted(), "clock.badge.checkmark.fill")
        }
    }

    private func stat(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ModuleGlyph(theme: .activity, size: 30, symbol: symbol)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass()
    }
}

private struct FreedByCategoryCard: View {
    @Environment(AppModel.self) private var model
    @State private var grown = false

    var body: some View {
        let totals = Dictionary(grouping: model.history.filter { $0.outcome == .removed }, by: \.activityCategory)
            .map { (name: $0.key, bytes: $0.value.reduce(0) { $0 + $1.bytes }) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
        let largest = Double(totals.first?.bytes ?? 1)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "Where the space came from")
                if totals.isEmpty {
                    Text("Clean something and it shows up here.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150)
                }
                ForEach(Array(totals.prefix(7).enumerated()), id: \.element.name) { index, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.name).font(.callout)
                            Spacer()
                            Text(Format.bytes(entry.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                        }
                        GrowingBar(fraction: Double(entry.bytes) / largest, fill: ModuleTheme.activity.gradient, height: 6,
                                   delay: 0.2 + Double(index) * 0.05)
                            .background(Capsule().fill(.white.opacity(0.06)))
                    }
                }
            }
        }
    }
}

private struct FreedByWeekCard: View {
    @Environment(AppModel.self) private var model
    @State private var revealed = false

    var body: some View {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let weeks = (0..<12).reversed().compactMap { calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) }
        let removed = model.history.filter { $0.outcome == .removed }
        let data = weeks.map { start -> (week: Date, bytes: Double) in
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) ?? start
            return (start, Double(removed.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.bytes }))
        }
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "Freed each week", subtitle: "Last 12 weeks")
                Chart(data, id: \.week) { entry in
                    BarMark(x: .value("Week", entry.week, unit: .weekOfYear), y: .value("Freed", revealed ? entry.bytes : 0))
                        .foregroundStyle(ModuleTheme.activity.gradient)
                        .cornerRadius(5)
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel { Text(Format.bytes(Int64(value.as(Double.self) ?? 0))) }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 3)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 180)
                .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.15).delay(0.25)) { revealed = true } }
            }
        }
    }
}
