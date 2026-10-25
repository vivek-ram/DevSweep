import DevSweepCore
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var suggestions: [String] = []
    @State private var chosen: Set<String> = []
    @State private var searching = true

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    AppGlyph(size: 84)
                    Text("Where do you keep your code?")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("DevSweep looks inside these folders for projects you haven't touched in a while and removes only what your tools can rebuild — virtual environments, node_modules, build output. Your source code is never touched.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 520)
                }

                Card(padding: 6) {
                    VStack(spacing: 0) {
                        if searching {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Looking for project folders…").foregroundStyle(.secondary)
                            }
                            .padding(14)
                        } else if suggestions.isEmpty {
                            Text("No project folders found automatically. Add yours below.")
                                .foregroundStyle(.secondary)
                                .padding(14)
                        }
                        ForEach(suggestions, id: \.self) { path in
                            Toggle(isOn: binding(for: path)) {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(Brand.teal)
                                    Text(Paths.abbreviate(path)).fontWeight(.medium)
                                    Spacer()
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            if path != suggestions.last { Divider().padding(.leading, 12) }
                        }
                    }
                }
                .frame(maxWidth: 520)

                HStack(spacing: 12) {
                    Button("Add Folder…") {
                        let picked = chooseFolders(message: "Choose folders that contain your projects")
                        for path in picked where !suggestions.contains(path) { suggestions.append(path) }
                        chosen.formUnion(picked)
                    }
                    .controlSize(.large)
                    Button {
                        model.settings.addRoots(suggestions.filter(chosen.contains))
                        model.scan()
                    } label: {
                        Text("Start Scanning").frame(minWidth: 140)
                    }
                    .buttonStyle(PrimaryPillStyle(theme: .projects, large: true))
                    .disabled(chosen.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }

                Text("Scanning only reads folder listings and dates. Nothing is removed until you say so.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .task {
            let found = await Task.detached { FolderSuggestions.find() }.value
            suggestions = found
            chosen = Set(found)
            searching = false
        }
        .navigationTitle("Welcome")
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding {
            chosen.contains(path)
        } set: { on in
            if on { chosen.insert(path) } else { chosen.remove(path) }
        }
    }
}

/// The app's mark: a gradient squircle with sparkles.
struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Brand.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: size * 0.04, y: size * 0.02)
            }
            .shadow(color: .black.opacity(0.2), radius: size * 0.05, y: size * 0.03)
    }
}
