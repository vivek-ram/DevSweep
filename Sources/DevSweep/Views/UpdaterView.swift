import AppKit
import DevSweepCore
import SwiftUI

struct UpdaterView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    let theme = ModuleTheme.updater

    var body: some View {
        let store = model.updater
        Group {
            if store.checkedAt == nil {
                ModuleIntro(theme: theme, title: "Updater", subtitle: "See which apps have a newer version, from the App Store, the developer's own updater or Homebrew.",
                            bullets: [("bag.fill", "App Store apps"), ("arrow.triangle.2.circlepath", "Apps with built-in updaters"),
                                      ("mug.fill", "Homebrew casks, updated in place")],
                            actionTitle: "Check for Updates", busy: store.isChecking) { store.check() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ModuleHeader(theme: theme, title: store.updates.isEmpty ? "Everything's up to date" : "\(store.updates.count) update\(store.updates.count == 1 ? "" : "s") available",
                                     subtitle: "Checked \(store.checkedAt?.formatted(.relative(presentation: .named)) ?? "") · App Store, developer feeds and Homebrew.") {
                            Button { store.check() } label: {
                                HStack(spacing: 6) {
                                    if store.isChecking { ProgressView().controlSize(.small) }
                                    Text("Check Again")
                                }
                            }
                            .buttonStyle(GlassPillStyle())
                            .disabled(store.isChecking)
                        }
                        .appearIn()

                        if store.updates.isEmpty {
                            HeroGlyph(theme: theme, size: 110).frame(maxWidth: .infinity).padding(.top, 30)
                        }
                        ForEach(Array(store.updates.enumerated()), id: \.element.id) { index, update in
                            row(update)
                                .appearIn(delay: Double(index) * 0.05)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                    .padding(28)
                }
            }
        }
        .onAppear { if store.checkedAt == nil, !store.isChecking { store.check() } }
    }

    private func row(_ update: AppUpdate) -> some View {
        let store = model.updater
        let open = expanded.contains(update.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Group {
                    if update.appPath.hasPrefix("/") {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: update.appPath)).resizable()
                    } else {
                        ModuleGlyph(theme: theme, size: 44, symbol: "mug.fill")
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(update.name).font(.headline)
                    HStack(spacing: 6) {
                        Text(update.installedVersion).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(update.newVersion).fontWeight(.semibold).foregroundStyle(theme.gradient)
                        Text("· \(update.sourceTitle)").foregroundStyle(.tertiary)
                        if let date = update.releaseDate { Text("· \(Format.idle(since: date).lowercased())").foregroundStyle(.tertiary) }
                    }
                    .font(.callout)
                }
                Spacer()
                if update.releaseNotes?.isEmpty == false {
                    Button(open ? "Hide Notes" : "What's New") {
                        withAnimation(.spring(duration: 0.35)) { if open { expanded.remove(update.id) } else { expanded.insert(update.id) } }
                    }
                    .buttonStyle(.link)
                }
                Button {
                    store.update(update)
                } label: {
                    HStack(spacing: 6) {
                        if store.updating.contains(update.id) { ProgressView().controlSize(.small).tint(.white) }
                        Text(buttonTitle(update))
                    }
                }
                .buttonStyle(PrimaryPillStyle(theme: theme))
                .disabled(store.updating.contains(update.id))
            }
            if open, let notes = update.releaseNotes {
                Text(notes)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(14)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .glass()
    }

    private func buttonTitle(_ update: AppUpdate) -> String {
        switch update.source {
        case .appStore: "Open App Store"
        case .sparkle: "Open to Update"
        case .homebrew: "Update"
        }
    }
}
