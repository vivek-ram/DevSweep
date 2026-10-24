import DevSweepCore
import SwiftUI

struct CachesView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: DevCache?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                let groups = Dictionary(grouping: model.caches, by: \.tool)
                    .sorted { ($0.value.compactMap(\.bytes).reduce(0, +)) > ($1.value.compactMap(\.bytes).reduce(0, +)) }
                ForEach(groups, id: \.key) { tool, caches in
                    Card(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(tool.uppercased())
                                .font(.caption.weight(.bold)).tracking(1).foregroundStyle(ModuleTheme.devCaches.gradient)
                                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                            ForEach(caches) { cache in
                                CacheRow(cache: cache) { pending = cache }
                                if cache.id != caches.last?.id { Divider().opacity(0.5).padding(.leading, 16) }
                            }
                        }
                    }
                }
                if model.caches.isEmpty {
                    ContentUnavailableView("No developer caches found", systemImage: "shippingbox",
                                           description: Text("None of the caches DevSweep knows about exist on this Mac."))
                }
            }
            .padding(28)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Developer Caches")
        .onAppear {
            if model.cacheBytes == nil { model.measureCaches() }
        }
        .confirmationDialog("Clear \(pending?.name ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            if let cache = pending {
                Button(model.settings.removalMode == .trash ? "Move to Trash" : "Delete") {
                    Task { await model.clean(cache) }
                }
            }
        } message: {
            if let cache = pending {
                Text([cache.detail, cache.caution].compactMap { $0 }.joined(separator: " "))
            }
        }
    }

    private var header: some View {
        ModuleHeader(theme: .devCaches, title: "Developer Caches",
                     subtitle: "Downloads and build caches your tools keep for every project. Safe to clear — tools fetch what they need again. Never cleaned automatically.") {
            VStack(alignment: .trailing, spacing: 8) {
                if let total = model.cacheBytes {
                    CountUpBytes(value: total, font: .system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(ModuleTheme.devCaches.gradient)
                }
                Button {
                    model.measureCaches()
                } label: {
                    if model.isMeasuringCaches {
                        HStack(spacing: 6) { ScanningOrb(size: 20, tint: ModuleTheme.devCaches.primary); Text("Measuring…") }
                    } else {
                        Label("Measure Again", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(GlassPillStyle())
                .disabled(model.isMeasuringCaches)
            }
        }
        .appearIn()
    }
}

private struct CacheRow: View {
    @Environment(AppModel.self) private var model
    var cache: DevCache
    var clean: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(cache.name).fontWeight(.medium)
                Text(cache.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let caution = cache.caution {
                    Label(caution, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(cache.displayPath).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    .onTapGesture(count: 2) { model.reveal(cache.path) }
                    .help("Double-click to show in Finder")
            }
            Spacer(minLength: 12)
            Group {
                if let bytes = cache.bytes {
                    CountUpBytes(value: bytes, font: .callout.weight(.semibold), duration: 0.6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 80, alignment: .trailing)
            Button("Clear", action: clean)
                .buttonStyle(GlassPillStyle())
                .controlSize(.small)
                .disabled((cache.bytes ?? 0) == 0 || model.isCleaning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
