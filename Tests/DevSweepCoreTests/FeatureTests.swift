import Foundation
import Testing
@testable import DevSweepCore

@Suite struct AutoCleanTests {
    func junk(_ category: JunkCategory, _ name: String, age days: Double = 60) -> JunkItem {
        JunkItem(category: category, path: "/Users/me/Library/Caches/\(name)", bytes: 1_000_000,
                 modified: Date().addingTimeInterval(-days * 86_400), suggested: true)
    }

    @Test func skipsCachesOfRunningAppsAndNeverTouchesArchivesOrTrash() {
        let items = [
            junk(.appCaches, "com.google.Chrome"), junk(.appCaches, "com.vendor.App.ShipIt"), junk(.appCaches, "Google"),
            junk(.appCaches, "com.idle.app"), junk(.logs, "Old"), junk(.archives, "a.zip"), junk(.trash, ".Trash"),
            junk(.installers, "new.dmg", age: 3), junk(.installers, "old.dmg", age: 90), junk(.deviceUpdates, "x.ipsw"),
        ]
        let running = [RunningApp(bundleID: "com.google.Chrome", name: "Google Chrome"),
                       RunningApp(bundleID: "com.vendor.App", name: "App")]
        let chosen = Set(AutoClean.select(items, rules: AutoCleanRules(), running: running).map(\.name))
        #expect(chosen == ["com.idle.app", "Old", "old.dmg"])
    }

    @Test func rulesCanTurnCategoriesOff() {
        var rules = AutoCleanRules()
        rules.appCaches = false
        rules.logs = false
        let chosen = AutoClean.select([junk(.appCaches, "com.idle.app"), junk(.logs, "Old")], rules: rules, running: [])
        #expect(chosen.isEmpty)
    }

    @Test func emptiesOnlyOldTrashedItems() throws {
        let f = Fixture()
        let old = f.file("fake/.Trash/old_modules/a")
        let fresh = f.file("fake/.Trash/new_modules/a")
        let records = [
            CleanupRecord(date: Date().addingTimeInterval(-10 * 86_400), projectPath: "/p", itemPath: "/p/a", kind: "nodeModules",
                          bytes: 1, mode: .trash, outcome: .removed, trashPath: Paths.parent(old)),
            CleanupRecord(date: Date(), projectPath: "/p", itemPath: "/p/b", kind: "nodeModules",
                          bytes: 1, mode: .trash, outcome: .removed, trashPath: Paths.parent(fresh)),
        ]
        #expect(AutoClean.trashedItemsToEmpty(records, olderThanDays: 7).map(\.itemPath) == ["/p/a"])
    }
}

@Suite struct AppInventoryTests {
    func makeApp(_ f: Fixture, name: String, id: String, bundleName: String? = nil) -> InstalledApp {
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": bundleName ?? name, "CFBundleShortVersionString": "1.0"]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        f.file("Applications/\(name).app/Contents/Info.plist", String(decoding: data, as: UTF8.self))
        return AppInventory.installedApps(home: f.root, folders: [f.root + "/Applications"]).first { $0.bundleID == id }!
    }

    @Test func findsAnAppsSupportFilesByBundleIDAndName() {
        let f = Fixture()
        let app = makeApp(f, name: "Visual Studio Code", id: "com.microsoft.VSCode", bundleName: "Code")
        f.file("Library/Application Support/Code/state.db", String(repeating: "s", count: 5_000))
        f.file("Library/Caches/com.microsoft.VSCode.ShipIt/update.zip", "u")
        f.file("Library/Preferences/com.microsoft.VSCode.plist", "p")
        f.file("Library/Saved Application State/com.microsoft.VSCode.savedState/data", "w")
        f.file("Library/Caches/com.microsoft.VSCodeInsiders/x", "other app")
        f.file("Library/Application Support/Codex/x", "other app")

        let files = AppInventory.files(for: app, home: f.root, fullDiskAccess: false)
        #expect(Set(files.map(\.name)) == ["Code", "com.microsoft.VSCode.ShipIt", "com.microsoft.VSCode.plist", "com.microsoft.VSCode.savedState"])
        #expect(AppInventory.lastUsed(app, files: files) != nil)
    }

    @Test func leftoversAreOnlyBundleIDsNoInstalledAppOwns() {
        let f = Fixture()
        let app = makeApp(f, name: "Chrome", id: "com.google.Chrome")
        f.file("Library/Caches/com.google.Chrome.helper/x", "helper of an installed app")
        f.file("Library/Preferences/com.google.Keystone.Agent.plist", "same vendor")
        f.file("Library/Application Support/com.gone.Editor/data", String(repeating: "d", count: 10_000))
        f.file("Library/Preferences/com.gone.Editor.plist", "p")
        f.file("Library/Caches/com.apple.Safari/x", "apple")
        f.file("Library/Caches/Google/x", "not a bundle id")
        f.file("Library/Caches/org.swift.swiftpm/x", "toolchain")
        f.file("Library/Caches/com.known.ByLaunchServices/x", "installed elsewhere")

        let leftovers = AppInventory.leftovers(installed: [app], isInstalled: { $0 == "com.known.ByLaunchServices" },
                                               home: f.root, fullDiskAccess: false)
        let byID = Dictionary(uniqueKeysWithValues: leftovers.map { ($0.identifier, $0) })
        #expect(Set(byID.keys) == ["com.gone.editor", "com.google.keystone"])
        #expect(byID["com.gone.editor"]?.files.count == 2)
        #expect(byID["com.gone.editor"]?.vendorStillInstalled == false)
        #expect(byID["com.google.keystone"]?.vendorStillInstalled == true)
    }

    @Test func bundleIdentifierParsing() {
        #expect(AppInventory.bundleIdentifier(fromFileName: "com.vendor.app.plist", kind: .preferences) == "com.vendor.app")
        #expect(AppInventory.bundleIdentifier(fromFileName: "ABCDE12345.com.vendor.app", kind: .groupContainers) == "com.vendor.app")
        #expect(AppInventory.bundleIdentifier(fromFileName: "Google", kind: .caches) == nil)
        #expect(AppInventory.bundleIdentifier(fromFileName: "my.notes", kind: .caches) == nil)
    }

    @Test func refusesToTrashAppsOutsideApplicationFolders() {
        let app = InstalledApp(path: "/Users/me/Documents/Thing.app", name: "Thing", bundleID: "com.x.thing", bundleName: nil, version: nil)
        #expect(Cleaner.trashApp(app, home: "/Users/me").outcome == .skipped)
    }
}

@Suite struct DuplicateFinderTests {
    @Test func findsIdenticalFilesButNotHardLinksOrLookalikes() async throws {
        let f = Fixture()
        let content = String(repeating: "dup", count: 400_000)
        f.file("Documents/report.pdf", content)
        f.file("Downloads/report (1).pdf", content)
        f.file("Downloads/old/report copy.pdf", content)
        // Same size, different bytes in the middle: partial hash matches, full hash doesn't.
        var lookalike = Array(content.utf8)
        lookalike[lookalike.count / 2] = UInt8(ascii: "X")
        f.file("Documents/lookalike.pdf", String(decoding: lookalike, as: UTF8.self))
        // A hard link is the same file, not a copy.
        let original = f.file("Pictures/photo.raw", String(repeating: "p", count: 1_200_000))
        try FileManager.default.linkItem(atPath: original, toPath: f.root + "/Pictures/photo-link.raw")
        f.file("Documents/node_modules/pkg/report.pdf", content)   // rebuildable folders are skipped
        f.file("Documents/small.txt", "tiny")

        let groups = try await DuplicateFinder(minimumSize: 1_000_000).find(in: [f.root + "/Documents", f.root + "/Downloads", f.root + "/Pictures"])
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group.files.map(\.name)) == ["report.pdf", "report (1).pdf", "report copy.pdf"])
        #expect(group.wasted == Int64(content.utf8.count) * 2)
        #expect(DuplicateFinder.suggestedKeeper(group, home: f.root) == f.root + "/Documents/report.pdf", "keep the copy outside Downloads")
    }

    @Test func copiesInsideCodeProjectsAreNotSuggestedForRemoval() {
        let f = Fixture()
        f.file("Projects/app/v1/package.json", "{}")
        f.file("Projects/app/v2/package.json", "{}")
        let group = DuplicateGroup(id: "x", size: 10, files: [
            DuplicateFile(path: f.root + "/Projects/app/v1/weights.bin", modified: Fixture.old),
            DuplicateFile(path: f.root + "/Projects/app/v2/weights.bin", modified: Date()),
            DuplicateFile(path: f.root + "/Downloads/weights.bin", modified: Date()),
        ])
        #expect(DuplicateFinder.suggestedRemovals(group, home: f.root) == [f.root + "/Downloads/weights.bin"])
    }
}

@Suite struct SpaceHistoryTests {
    func node(_ path: String, _ size: Int64, _ children: [StorageNode] = []) -> StorageNode {
        let n = StorageNode(name: (path as NSString).lastPathComponent, path: path, isDirectory: true, size: size, modified: Date())
        for child in children { n.attach(child) }
        return n
    }

    @Test func reportsTheMostSpecificFolderThatGrew() {
        var history = SpaceHistory()
        let start = Date().addingTimeInterval(-5 * 86_400)
        history.record(node("/h", 10_000_000_000, [node("/h/Library", 6_000_000_000, [node("/h/Library/Caches", 1_000_000_000, [node("/h/Library/Caches/Google", 500_000_000)])]),
                                                   node("/h/Movies", 2_000_000_000)]), at: start)
        history.record(node("/h", 17_500_000_000, [node("/h/Library", 12_000_000_000, [node("/h/Library/Caches", 7_000_000_000, [node("/h/Library/Caches/Google", 6_400_000_000)])]),
                                                   node("/h/Movies", 3_500_000_000)]), at: Date())
        let growth = history.growth(minimum: 1_000_000_000)
        // Library and Caches grew because of Google; /h grew because of both.
        #expect(growth.map(\.path) == ["/h/Library/Caches/Google", "/h/Movies"])
        #expect(growth.first?.delta == 5_900_000_000)

        var alerts = history
        #expect(alerts.newAlerts(minimum: 2_000_000_000).map(\.path) == ["/h/Library/Caches/Google"])
        #expect(alerts.newAlerts(minimum: 2_000_000_000).isEmpty, "not announced twice")
    }

    @Test func samplesAreThinnedOverTime() {
        var history = SpaceHistory()
        let now = Date()
        for hour in stride(from: 24 * 30, through: 0, by: -1) {
            history.record(free: 1, total: 2, at: now.addingTimeInterval(-Double(hour) * 3_600))
        }
        // ~14 days of hourly samples plus ~16 daily ones.
        #expect(history.samples.count > 14 * 24 && history.samples.count < 14 * 24 + 20)
    }
}

@Suite struct ToolParsingTests {
    @Test func parsesSizesTheWayToolsPrintThem() {
        #expect(DevTools.parseBytes("98.7MB") == 98_700_000)
        #expect(DevTools.parseBytes("4.7 GB") == 4_700_000_000)
        #expect(DevTools.parseBytes("512kB") == 512_000)
        #expect(DevTools.parseBytes("1GiB") == 1_073_741_824)
        #expect(DevTools.parseBytes("lots") == nil)
        #expect(DevTools.parseFreeEstimate("==> This operation would free approximately 231.6MB of disk space.") == 231_600_000)
    }

    @Test func parsesLaunchctlDisabledOutput() {
        let output = """
        disabled services = {
            "com.google.keystone.agent" => disabled
            "com.vendor.helper" => enabled
            "com.new.style" => true
            "com.new.on" => false
        }
        """
        #expect(LaunchItems.parseDisabled(output) == ["com.google.keystone.agent", "com.new.style"])
    }

    @Test func readsLaunchAgentPlists() throws {
        let f = Fixture()
        let plist: [String: Any] = ["Label": "com.gone.updater", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/updater", "--wake"], "RunAtLoad": true]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let path = f.file("LaunchAgents/com.gone.updater.plist", String(decoding: data, as: UTF8.self))
        let item = try #require(LaunchItems.read(path, scope: .user, disabled: [], loaded: []))
        #expect(item.label == "com.gone.updater")
        #expect(item.runsAtLoad && item.isBroken, "its program no longer exists")
        #expect(item.isLoaded == false)
    }

    @Test func systemSamplerReturnsSaneNumbers() {
        let sampler = SystemSampler()
        _ = sampler.sample()
        let s = sampler.sample()
        #expect((0...1).contains(s.cpu))
        #expect(s.memoryTotal > 0 && s.memoryUsed > 0 && s.memoryUsed <= s.memoryTotal)
    }
}
