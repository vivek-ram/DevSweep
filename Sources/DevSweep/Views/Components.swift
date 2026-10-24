import AppKit
import UniformTypeIdentifiers
import DevSweepCore
import SwiftUI

/// The app-wide accents, matched to the module themes in Theme.swift.
enum Brand {
    static let teal = ModuleTheme.hex(0x2DD4BF)
    static let indigo = ModuleTheme.hex(0x8B5CF6)
    static let gradient = LinearGradient(colors: [ModuleTheme.hex(0x8B5CF6), ModuleTheme.hex(0xEC4899)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Ecosystem {
    var color: Color {
        switch self {
        case .python: Color(red: 0.23, green: 0.48, blue: 0.85)
        case .node: Color(red: 0.30, green: 0.66, blue: 0.27)
        case .rust: Color(red: 0.86, green: 0.43, blue: 0.20)
        case .swift: Color(red: 0.95, green: 0.33, blue: 0.24)
        case .gradle: Color(red: 0.47, green: 0.38, blue: 0.86)
        case .flutter: Color(red: 0.10, green: 0.63, blue: 0.84)
        case .cocoapods: Color(red: 0.84, green: 0.26, blue: 0.42)
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(cornerRadius: 18)
    }
}

struct CardTitle: View {
    var title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct EcosystemBadge: View {
    var ecosystem: Ecosystem

    var body: some View {
        Text(ecosystem.shortLabel)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(ecosystem.color)
            .background(Capsule().fill(ecosystem.color.opacity(0.14)))
            .help(ecosystem.displayName)
    }
}

struct EcosystemBadges: View {
    var project: Project

    var body: some View {
        HStack(spacing: 4) {
            ForEach(project.ecosystems) { EcosystemBadge(ecosystem: $0) }
        }
    }
}

struct StatusPill: View {
    var status: ProjectStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).imageScale(.small)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.13)))
        .fixedSize()
    }

    private var text: String {
        switch status {
        case .stale(let idle): "Idle \(idle)d"
        case .active(let days): days <= 7 ? "\(days)d left" : "Active"
        case .protected: "Protected"
        }
    }

    private var icon: String {
        switch status {
        case .stale: "moon.zzz.fill"
        case .active(let days): days <= 7 ? "hourglass" : "bolt.fill"
        case .protected: "lock.fill"
        }
    }

    private var color: Color {
        switch status {
        case .stale: .orange
        case .active(let days): days <= 7 ? Color(red: 0.85, green: 0.58, blue: 0.0) : .green
        case .protected: .blue
        }
    }
}

struct BytesText: View {
    var bytes: Int64
    var font: Font = .body

    var body: some View {
        Text(bytes == 0 ? "—" : Format.bytes(bytes))
            .font(font)
            .monospacedDigit()
    }
}

/// Disk usage as a single bar: dev artifacts, everything else, free.
struct CapacityBar: View {
    var space: VolumeSpace
    var devBytes: Int64
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(space.total), 1)
            let dev = min(Double(devBytes), Double(space.used))
            let other = max(Double(space.used) - dev, 0)
            HStack(spacing: 2) {
                Rectangle().fill(Color.secondary.opacity(0.45))
                    .frame(width: geo.size.width * other / total)
                Rectangle().fill(Brand.gradient)
                    .frame(width: max(dev > 0 ? 3 : 0, geo.size.width * dev / total))
                Rectangle().fill(Color.secondary.opacity(0.12))
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(Format.bytes(space.available)) free of \(Format.bytes(space.total))")
    }
}

struct LegendDot: View {
    var color: AnyShapeStyle
    var label: String

    init<S: ShapeStyle>(_ style: S, _ label: String) {
        color = AnyShapeStyle(style)
        self.label = label
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct NoticeBanner: View {
    var notice: Notice
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.headline)
                if let detail = notice.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.35)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private var icon: String {
        switch notice.style {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch notice.style {
        case .success: .green
        case .info: .blue
        case .error: .orange
        }
    }
}

/// Lets SwiftUI views get at their hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension Date {
    var shortDateTime: String { formatted(date: .abbreviated, time: .shortened) }
}

func chooseFolders(message: String) -> [String] {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.message = message
    panel.prompt = "Choose"
    return panel.runModal() == .OK ? panel.urls.map { Paths.normalize($0.path) } : []
}

/// Finder's icon for a file, or its type's icon when the file is gone (moved, deleted, or on a
/// drive that's no longer connected).
enum FileIcons {
    static func icon(forPath path: String, isFolder: Bool? = nil) -> NSImage {
        if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        if path.hasPrefix("/Volumes/"), Paths.parent(path) == "/Volumes" {
            return NSImage(contentsOfFile: "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/External.icns")
                ?? NSWorkspace.shared.icon(for: .volume)
        }
        let ext = (path as NSString).pathExtension
        if isFolder == true || (isFolder == nil && ext.isEmpty) { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}
