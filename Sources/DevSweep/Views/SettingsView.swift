import DevSweepCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            FolderSettings().tabItem { Label("Folders", systemImage: "folder") }
            TypeSettings().tabItem { Label("Types", systemImage: "square.stack.3d.up") }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Clean projects idle for", selection: $settings.retentionDays) {
                    ForEach(SettingsStore.retentionChoices, id: \.self) { Text(Format.days($0)).tag($0) }
                }
                Toggle(isOn: $settings.smartLowSpace) {
                    Text("Be stricter when the disk is nearly full")
                    Text("Below 20 GB free, projects count as idle after half the time (at least 7 days).")
                }
            } header: {
                Text("Retention")
            } footer: {
                Text("A project is idle when none of its own files changed, nothing was installed or built, and no editor opened it for that long.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Smart Scan measures", selection: $settings.storageScope) {
                    ForEach(StorageScope.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(model.hasFullDiskAccess ? "Allowed" : "Not allowed")
                            .foregroundStyle(model.hasFullDiskAccess ? .green : .secondary)
                        Button(model.hasFullDiskAccess ? "Privacy Settings…" : "Allow…") { model.openFullDiskAccessSettings() }
                    }
                }
            } header: {
                Text("Mac scan")
            } footer: {
                Text("Without Full Disk Access, app containers, Mail and the Trash aren't measured, and macOS would otherwise ask about each app. Add DevSweep in Privacy & Security → Full Disk Access, then scan again.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Automation") {
                Picker("When projects go idle", selection: $settings.automation) {
                    ForEach(AutomationMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Toggle("Open DevSweep at login", isOn: Binding(get: { settings.launchAtLogin },
                                                              set: { settings.setLaunchAtLogin($0) }))
                LabeledContent("Next to the menu bar icon") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(MenuBarStat.allCases) { stat in
                            Toggle(stat.title, isOn: Binding(
                                get: { settings.menuBarStats.contains(stat) },
                                set: { on in
                                    var stats = settings.menuBarStats.filter { $0 != stat }
                                    if on { stats.append(stat) }
                                    settings.menuBarStats = MenuBarStat.allCases.filter(stats.contains)
                                }))
                        }
                    }
                }
                Toggle(isOn: $settings.trackSpaceHistory) {
                    Text("Keep a history of disk usage")
                    Text("Measures your home folder once a day to chart free space and spot folders that suddenly grow.")
                }
                Toggle("Alert me when a folder grows by 2 GB or more", isOn: $settings.growthAlerts)
                    .disabled(!settings.trackSpaceHistory)
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("DevSweep checks a few times a day while it's in the menu bar, and acts at most once a day.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Removing") {
                Picker("Removed folders", selection: $settings.removalMode) {
                    Text("Move to the Trash (can be restored)").tag(RemovalMode.trash)
                    Text("Delete immediately (frees space right away)").tag(RemovalMode.permanent)
                }
                .pickerStyle(.radioGroup)
                Toggle(isOn: $settings.askBeforeVenvs) {
                    Text("Ask me before removing a Python virtual environment")
                    Text("Automatic cleaning never removes one, and each must be ticked in the review before it goes.")
                }
                Toggle(isOn: $settings.snapshotPython) {
                    Text("Save a virtual environment's packages to requirements.txt first")
                    Text("Your own requirements.txt is never changed; if it differs, the list goes to requirements-snapshot.txt.")
                }
                Toggle(isOn: $settings.snapshotNode) {
                    Text("Save installed npm versions when a project has no lockfile")
                    Text("Written to node_modules.snapshot.json next to package.json.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.hasFullDiskAccess = FullDiskAccess.isGranted }
    }
}

private struct FolderSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selectedRoot: String?
    @State private var selectedProtected: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                List(selection: $selectedRoot) {
                    ForEach(settings.roots, id: \.self) { root in
                        Label(Paths.abbreviate(root), systemImage: "folder.fill").tag(root)
                    }
                }
                .frame(minHeight: 110)
                HStack {
                    Button("Add Folder…") {
                        settings.addRoots(chooseFolders(message: "Choose folders that contain your projects"))
                    }
                    Button("Remove") {
                        settings.roots.removeAll { $0 == selectedRoot }
                        selectedRoot = nil
                    }
                    .disabled(selectedRoot == nil)
                    Spacer()
                    Button("Scan Now") { model.scan() }.disabled(settings.roots.isEmpty || model.isScanning)
                }
            } header: {
                Text("Folders to scan")
            } footer: {
                Text("Hidden folders, app bundles, global package installs and conda environments are never entered.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                List(selection: $selectedProtected) {
                    ForEach(settings.protectedPaths, id: \.self) { path in
                        Label(Paths.abbreviate(path), systemImage: "lock.fill").tag(path)
                    }
                }
                .frame(minHeight: 90)
                HStack {
                    Button("Add Folder…") {
                        for path in chooseFolders(message: "Choose folders DevSweep should never clean")
                        where !settings.protectedPaths.contains(path) {
                            settings.protectedPaths.append(path)
                        }
                    }
                    Button("Remove") {
                        settings.protectedPaths.removeAll { $0 == selectedProtected }
                        selectedProtected = nil
                    }
                    .disabled(selectedProtected == nil)
                }
            } header: {
                Text("Never clean")
            } footer: {
                Text("You can also drop an empty \(ArtifactRules.keepMarker) file into any folder to protect it and everything inside.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TypeSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(ArtifactKind.allCases) { kind in
                    Toggle(isOn: binding(kind)) {
                        HStack(spacing: 8) {
                            EcosystemBadge(ecosystem: kind.ecosystem)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.displayName)
                                Text(kind.folderNames).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Folders DevSweep may remove")
            } footer: {
                Text("Each is only matched next to the file that proves what it is: target needs a Cargo.toml beside it, build needs build.gradle or pubspec.yaml, and so on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ kind: ArtifactKind) -> Binding<Bool> {
        Binding {
            model.settings.enabledKinds.contains(kind)
        } set: { on in
            if on { model.settings.enabledKinds.insert(kind) } else { model.settings.enabledKinds.remove(kind) }
        }
    }
}
