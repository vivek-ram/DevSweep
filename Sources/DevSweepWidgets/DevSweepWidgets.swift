import DevSweepCore
import DevSweepWidgetUI
import SwiftUI
import WidgetKit

// Desktop and Notification Center widgets. They read the snapshot the DevSweep app writes every
// few minutes (WidgetSnapshot); the widget itself is sandboxed and measures nothing.

@main
struct DevSweepWidgets: WidgetBundle {
    var body: some Widget {
        HealthWidget()
        StorageWidget()
        TemperatureWidget()
    }
}

// MARK: Timeline

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? (context.isPreview ? .sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // DevSweep asks for a reload when something changes; this is the fallback.
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

// MARK: Widgets

/// Reads the widget's size from the environment for the shared views.
struct FamilyReader<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder var content: (WidgetFamily) -> Content
    var body: some View { content(family) }
}

struct HealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DevSweepHealth", provider: SnapshotProvider()) { entry in
            FamilyReader { family in HealthWidgetView(entry: entry, family: family) }
                .widgetURL(URL(string: "devsweep://overview"))
        }
        .configurationDisplayName("Mac Health")
        .description("Your Mac's health score and how much space DevSweep can free.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StorageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DevSweepStorage", provider: SnapshotProvider()) { entry in
            FamilyReader { family in StorageWidgetView(entry: entry, family: family) }
                .widgetURL(URL(string: "devsweep://storageMap"))
        }
        .configurationDisplayName("Storage")
        .description("Free space on your Mac, and what's ready to clean.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TemperatureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DevSweepTemperature", provider: SnapshotProvider()) { entry in
            FamilyReader { family in TemperatureWidgetView(entry: entry, family: family) }
                .widgetURL(URL(string: "devsweep://heat"))
        }
        .configurationDisplayName("Temperature")
        .description("How hot your Mac is, and the apps heating it up.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

