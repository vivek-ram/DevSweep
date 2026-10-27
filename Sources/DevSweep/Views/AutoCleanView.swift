import DevSweepCore
import SwiftUI

struct AutoCleanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero.appearIn()

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(title: "What gets cleaned", subtitle: "Only things that are safe to lose. Caches and logs are deleted; installers go to the Trash first.")
                        ruleToggle("App caches", "Only caches DevSweep knows the app rebuilds, never ones it doesn't recognise. Skips apps that are open right now.", \.appCaches)
                        ruleToggle("Logs and crash reports", nil, \.logs)
                        HStack {
                            ruleToggle("Installers in Downloads", "Disk images and packages older than the age on the right.", \.oldInstallers)
                            Spacer()
                            Stepper("\(settings.autoCleanRules.installerAgeDays) days", value: $settings.autoCleanRules.installerAgeDays, in: 7...365, step: 7)
                                .fixedSize()
                                .disabled(!settings.autoCleanRules.oldInstallers)
                        }
                        HStack {
                            ruleToggle("Empty old installers from the Trash", "Only installers Auto-Clean moved there, after the days on the right. What you clean yourself stays in the Trash.", \.emptyTrashedItems)
                            Spacer()
                            Stepper("\(settings.autoCleanRules.trashedItemAgeDays) days", value: $settings.autoCleanRules.trashedItemAgeDays, in: 1...60)
                                .fixedSize()
                                .disabled(!settings.autoCleanRules.emptyTrashedItems)
                        }
                        ruleToggle("Developer download caches", "pip, npm, Yarn, Homebrew, Cargo and similar. They're downloaded again when needed.", \.developerCaches)
                        Label("Never cleaned automatically: your files, Python virtual environments, archives, iPhone updates and the rest of your Trash.",
                              systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .appearIn(delay: 0.06)

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $settings.lowSpaceAutoClean) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Clean right away when space runs low").fontWeight(.medium)
                                Text("Checked every 30 minutes; at most every 6 hours.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        HStack {
                            Text("Low means less than")
                            Picker("", selection: $settings.lowSpaceThresholdGB) {
                                ForEach([5, 10, 15, 20, 30, 50], id: \.self) { Text("\($0) GB free").tag($0) }
                            }
                            .labelsHidden().fixedSize()
                            Spacer()
                            if let disk = model.disk {
                                Text("Now: \(Format.bytes(disk.available)) free")
                                    .foregroundStyle(model.isLowOnSpace ? .orange : .secondary)
                            }
                        }
                        .font(.callout)
                    }
                }
                .appearIn(delay: 0.12)

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        CardTitle(title: "Recent runs")
                        if settings.autoCleanRuns.isEmpty {
                            Text("Nothing yet. The first run happens shortly after DevSweep starts.").foregroundStyle(.secondary)
                        }
                        ForEach(settings.autoCleanRuns.prefix(10)) { run in
                            HStack {
                                Image(systemName: run.reason == .lowSpace ? "exclamationmark.triangle.fill" : run.reason == .manual ? "hand.tap.fill" : "clock.fill")
                                    .foregroundStyle(run.reason == .lowSpace ? AnyShapeStyle(.orange) : AnyShapeStyle(ModuleTheme.autoClean.gradient))
                                    .frame(width: 20)
                                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                                Text(run.reason == .lowSpace ? "· low on space" : run.reason == .manual ? "· run by hand" : "· scheduled")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(run.items == 0 ? "Nothing to clean" : "\(run.items) items · \(Format.bytes(run.freed))")
                                    .monospacedDigit().foregroundStyle(run.items == 0 ? .secondary : .primary)
                            }
                            .font(.callout)
                        }
                    }
                }
                .appearIn(delay: 0.18)
            }
            .padding(28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Auto-Clean")
    }

    private var hero: some View {
        @Bindable var settings = model.settings
        let theme = ModuleTheme.autoClean
        return HStack(spacing: 24) {
            HeroGlyph(theme: ModuleTheme(colors: settings.autoCleanEnabled ? theme.colors : [.gray, .gray.opacity(0.6)],
                                         glyph: settings.autoCleanEnabled ? "clock.badge.checkmark.fill" : "clock.badge.xmark"),
                      size: 92, active: model.isCleaning)
                .frame(width: 140, height: 110)
            VStack(alignment: .leading, spacing: 6) {
                Text("AUTO-CLEAN").font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(theme.gradient)
                Text(settings.autoCleanEnabled ? "On · \(settings.autoCleanFrequency.title.lowercased())" : "Off")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
                Group {
                    if settings.autoCleanEnabled, let next = model.nextAutoClean {
                        Text(next <= Date() ? "Runs within the next half hour" : "Next run \(next.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("Caches and logs pile up again; turn it on to keep them in check.")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                if let last = settings.autoCleanRuns.first {
                    Text("Last run \(last.date.formatted(.relative(presentation: .named))) freed \(Format.bytes(last.freed))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 12) {
                Toggle("", isOn: $settings.autoCleanEnabled.animation(.spring(duration: 0.4)))
                    .toggleStyle(.switch).labelsHidden().tint(theme.primary)
                Picker("", selection: $settings.autoCleanFrequency) {
                    ForEach(AutoCleanFrequency.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(!settings.autoCleanEnabled)
                Button("Run Now") { Task { await model.runAutoClean(reason: .manual, showProgress: true) } }
                    .buttonStyle(PrimaryPillStyle(theme: theme))
                    .disabled(model.isCleaning)
            }
        }
        .padding(24)
        .background {
            ZStack {
                GlassBackground(cornerRadius: 26)
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(RadialGradient(colors: [theme.primary.opacity(0.07), .clear], center: .leading, startRadius: 0, endRadius: 420))
            }
        }
    }

    private func ruleToggle(_ title: String, _ detail: String?, _ key: WritableKeyPath<AutoCleanRules, Bool>) -> some View {
        Toggle(isOn: Binding(get: { model.settings.autoCleanRules[keyPath: key] },
                             set: { model.settings.autoCleanRules[keyPath: key] = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .toggleStyle(.checkbox)
    }
}
