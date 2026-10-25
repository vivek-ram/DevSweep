import Foundation
import Testing
@testable import DevSweepCore

@Suite struct MacHealthTests {
    let gb: Int64 = 1_000_000_000

    @Test func aRoomyTidyMacScoresFull() {
        let health = MacHealth.evaluate(MacHealth.Input(freeBytes: 200 * gb, totalBytes: 500 * gb))
        #expect(health.score == 100)
        #expect(health.status == .excellent)
        #expect(health.factors.isEmpty)
    }

    @Test func lowSpaceAndJunkCostPointsWorstFirst() {
        var input = MacHealth.Input(freeBytes: 10 * gb, totalBytes: 250 * gb)
        input.junkBytes = 18 * gb
        input.brokenLaunchItems = 2
        let health = MacHealth.evaluate(input)
        #expect(health.factors.map(\.id) == ["space", "junk", "launch"])
        #expect(health.score == 100 - 40 - 10 - 3)
        #expect(health.status == .needsAttention)
    }

    @Test func memoryPressureAndSwapAddUp() {
        var input = MacHealth.Input(freeBytes: 200 * gb, totalBytes: 500 * gb)
        input.memoryPressure = .critical
        input.swapBytes = 9 * gb
        let health = MacHealth.evaluate(input)
        #expect(health.factors.first { $0.id == "memory" }?.penalty == 21)
    }
}

@Suite struct UpdateTests {
    @Test func comparesVersionsNumerically() {
        #expect(UpdateChecker.isNewer("1.10", than: "1.9"))
        #expect(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        #expect(UpdateChecker.isNewer("27.1", than: "26.6"))
        #expect(!UpdateChecker.isNewer("2.0", than: "2.0"))
        #expect(!UpdateChecker.isNewer("1.9", than: "1.10"))
        #expect(UpdateChecker.isNewer("3.2 (build 7)", than: "3.1"))
    }

    @Test func readsSparkleAppcastsAndDropsItemsForNewerMacOS() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>Version 2.1</title>
              <pubDate>Tue, 06 Oct 2026 10:00:00 +0000</pubDate>
              <description><![CDATA[<ul><li>Faster sync</li></ul>]]></description>
              <enclosure url="https://example.com/App-2.1.zip" sparkle:version="210" sparkle:shortVersionString="2.1" />
            </item>
            <item>
              <title>Version 3.0</title>
              <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
              <enclosure url="https://example.com/App-3.0.zip" sparkle:version="300" sparkle:shortVersionString="3.0" />
            </item>
          </channel>
        </rss>
        """
        let items = AppcastParser.parse(Data(xml.utf8))
        #expect(items.count == 1)
        #expect(items.first?.build == "210")
        #expect(items.first?.shortVersion == "2.1")
        #expect(items.first?.download == "https://example.com/App-2.1.zip")
        #expect(items.first?.notes?.contains("Faster sync") == true)
        #expect(items.first?.notes?.contains("<li>") == false)
        #expect(items.first?.date != nil)
    }
}

@Suite struct PrivacyTests {
    @Test func findsChromiumProfilesByTheirDisplayNames() throws {
        let f = Fixture()
        let chrome = "Library/Application Support/Google/Chrome"
        f.file(chrome + "/Local State", #"{"profile":{"info_cache":{"Default":{"name":"Work"}}}}"#)
        f.file(chrome + "/Default/History", String(repeating: "h", count: 4_000))
        f.file(chrome + "/Default/Network/Cookies", String(repeating: "c", count: 2_000))
        f.file(chrome + "/Default/Local Storage/leveldb/000003.log", String(repeating: "s", count: 3_000))
        f.file(chrome + "/Default/Login Data", "saved passwords stay")
        let items = PrivacyScanner.scan(home: f.root).filter { $0.browser == .chrome }
        #expect(Set(items.map(\.kind)) == [.history, .cookies, .siteData])
        #expect(items.allSatisfy { $0.profileName == "Work" })
        #expect(!items.flatMap(\.paths).contains { $0.hasSuffix("Login Data") })
    }

    @Test func countsFirefoxHistoryWithoutTouchingBookmarks() throws {
        let f = Fixture()
        let profile = f.dir("Library/Application Support/Firefox/Profiles/abc123.default-release")
        f.file("Library/Application Support/Firefox/Profiles/abc123.default-release/prefs.js", "user_pref();")
        f.file("Library/Application Support/Firefox/Profiles/abc123.default-release/cookies.sqlite", String(repeating: "c", count: 2_000))
        let places = profile + "/places.sqlite"
        // SQLiteFile only opens existing databases, so make this one with the sqlite3 tool.
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [places, """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, foreign_count INTEGER DEFAULT 0);
            CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER);
            CREATE TABLE moz_inputhistory (place_id INTEGER, input TEXT);
            INSERT INTO moz_places (url, foreign_count) VALUES ('https://bookmarked.example', 1), ('https://visited.example', 0);
            INSERT INTO moz_historyvisits (place_id) VALUES (1), (2), (2);
            """]
        try sqlite.run()
        sqlite.waitUntilExit()
        #expect(sqlite.terminationStatus == 0)
        let items = PrivacyScanner.scan(home: f.root).filter { $0.browser == .firefox }
        #expect(items.first { $0.kind == .history }?.database == places)
        #expect(items.first { $0.profileName == "default-release" } != nil)
        #expect(SQLiteFile.count(places, table: "moz_historyvisits") == 3)

        // The same statements the cleaner runs: visits go, the bookmarked page stays.
        try SQLiteFile.execute(places, "DELETE FROM moz_historyvisits; DELETE FROM moz_inputhistory; DELETE FROM moz_places WHERE foreign_count = 0;")
        #expect(SQLiteFile.count(places, table: "moz_historyvisits") == 0)
        #expect(SQLiteFile.query(places, "SELECT url FROM moz_places")?.compactMap(\.first) == ["https://bookmarked.example"])
    }

    @Test func refusesToClearARunningBrowser() {
        let item = PrivacyItem(browser: .chrome, profile: "/tmp/x", profileName: "Default", kind: .history,
                               paths: ["/tmp/x/History"], database: nil, bytes: 10)
        let record = PrivacyScanner.clean(item, browserIsRunning: true)
        #expect(record.outcome == .skipped)
    }
}

@Suite struct NewJunkTests {
    @Test func findsAIAppCachesButNotTheirData() {
        let f = Fixture()
        f.file("Library/Application Support/Claude/Cache/data_0", "c")
        f.file("Library/Application Support/Claude/Code Cache/js/1", "c")
        f.file("Library/Application Support/Claude/Local Storage/leveldb/1", "chats")
        f.file("Library/Application Support/Claude/claude_desktop_config.json", "{}")
        f.file(".codex/log/codex.log", "l")
        f.file(".codex/sessions/1.json", "keep")
        let found = Dictionary(uniqueKeysWithValues: JunkScanner.aiClutterFolders(home: f.root).map { ($0.0, $0.1) })
        #expect(Set(found.keys) == [f.root + "/Library/Application Support/Claude/Cache",
                                    f.root + "/Library/Application Support/Claude/Code Cache",
                                    f.root + "/.codex/log"])
        #expect(found[f.root + "/.codex/log"] == "Codex · Logs")
    }

    @Test func flagsOnlyUnreadableThirdPartyPreferences() throws {
        let f = Fixture()
        let good = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0)
        try good.write(to: URL(fileURLWithPath: f.file("Library/Preferences/com.vendor.good.plist")))
        let bad = f.file("Library/Preferences/com.vendor.bad.plist", "not a plist {{{")
        let empty = f.file("Library/Preferences/com.vendor.empty.plist", "")
        f.file("Library/Preferences/com.apple.weird.plist", "not a plist either")
        #expect(Set(JunkScanner.brokenPreferences(home: f.root)) == [bad, empty])
    }

    @Test func marksTheNewestBackupOfEachDevice() throws {
        let f = Fixture()
        func backup(_ id: String, device: String, daysAgo: Double) throws {
            let info: [String: Any] = ["Device Name": device, "Last Backup Date": Date().addingTimeInterval(-daysAgo * 86_400)]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: f.file("Library/Application Support/MobileSync/Backup/\(id)/Info.plist")))
        }
        try backup("old", device: "iPhone", daysAgo: 300)
        try backup("new", device: "iPhone", daysAgo: 3)
        try backup("pad", device: "iPad", daysAgo: 100)
        let latest = Set(JunkScanner.deviceBackups(home: f.root).filter(\.isLatest).map { ($0.path as NSString).lastPathComponent })
        #expect(latest == ["new", "pad"])
    }
}

@Suite struct MaintenanceTests {
    @Test func readsEachTasksMarker() {
        let tasks: [MaintenanceTask] = [.freeRAM, .flushDNS, .periodicScripts]
        let outcomes = Maintenance.adminOutcomes(tasks, status: 0, output: "OK:freeRAM\nFAIL:flushDNS\nOK:periodicScripts\n")
        #expect(outcomes.map(\.succeeded) == [true, false, true])
    }

    @Test func aCancelledPasswordPromptRunsNothing() {
        let outcomes = Maintenance.adminOutcomes([.freeRAM, .flushDNS], status: 1, output: "execution error: User canceled. (-128)")
        #expect(outcomes.allSatisfy { !$0.succeeded && $0.message == "Password prompt was cancelled" })
    }

    @Test func onlySomeTasksNeedAnAdministrator() {
        #expect(MaintenanceTask.allCases.filter(\.needsAdmin).allSatisfy { $0.adminCommand != nil })
        #expect(MaintenanceTask.allCases.filter { !$0.needsAdmin }.allSatisfy { $0.adminCommand == nil })
    }
}

@Suite struct DownloadsTests {
    @Test func groupsByTheAppThatDownloadedIt() throws {
        let f = Fixture()
        let zip = f.file("Downloads/report.zip", String(repeating: "z", count: 10_000))
        let quarantine = "0081;65000000;Google Chrome;8F2A6E1C-0000-0000-0000-000000000000"
        #expect(setxattr(zip, "com.apple.quarantine", quarantine, quarantine.utf8.count, 0, XATTR_NOFOLLOW) == 0)
        let whereFrom = try PropertyListSerialization.data(fromPropertyList: ["https://www.example.com/report.zip"], format: .binary, options: 0)
        _ = whereFrom.withUnsafeBytes { setxattr(zip, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, whereFrom.count, 0, XATTR_NOFOLLOW) }
        f.file("Downloads/notes.txt", "n")
        f.file("Downloads/some-repo/package.json", "{}")
        f.file("Downloads/some-repo/index.js", "x")

        let items = DownloadsAnalyzer.scan(home: f.root)
        let report = items.first { $0.name == "report.zip" }
        #expect(report?.source == "Google Chrome")
        #expect(report?.website == "example.com")
        #expect(items.first { $0.name == "notes.txt" }?.source == "Unknown")
        #expect(!items.contains { $0.name == "some-repo" })
    }
}

@Suite struct SecurityStatusTests {
    @Test func readsEachCommandsWording() {
        #expect(SecurityStatus.parse((0, "assessments enabled\n"), on: "assessments enabled", off: "assessments disabled") == true)
        #expect(SecurityStatus.parse((0, "FileVault is On.\n"), on: "FileVault is On", off: "FileVault is Off") == true)
        #expect(SecurityStatus.parse((0, "FileVault is Off.\n"), on: "FileVault is On", off: "FileVault is Off") == false)
        #expect(SecurityStatus.parse((0, "Firewall is disabled. (State = 0)"), on: "enabled", off: "disabled") == false)
        #expect(SecurityStatus.parse((1, "error"), on: "enabled", off: "disabled") == nil)
    }
}

@Suite struct ProcessUsageTests {
    @Test func helpersBelongToTheOutermostApp() {
        #expect(ProcessSampler.outerApp("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
                == "/Applications/Google Chrome.app")
        #expect(ProcessSampler.outerApp("/Applications/Xcode.app") == "/Applications/Xcode.app")
        #expect(ProcessSampler.outerApp("/usr/bin/python3") == nil)
    }

    @Test func findsThisProcessWithItsMemory() {
        let sampler = ProcessSampler()
        let apps = sampler.sample()
        #expect(!apps.isEmpty)
        #expect(apps.contains { $0.processCount >= 1 && $0.memory > 0 })
        #expect(apps.reduce(0) { $0 + $1.processCount } >= 1)
        #expect(apps == apps.sorted { $0.memory > $1.memory })
        // CPU needs two samples; the second one has rates.
        let again = sampler.sample()
        #expect(again.allSatisfy { $0.cpu >= 0 })
    }
}

@Suite struct ThermalTests {
    @Test func groupsSensorsByPartAndIgnoresCalibration() {
        var snapshot = ThermalSnapshot()
        snapshot.sensors = [("PMU tdie1", 61), ("PMU tdie4", 66), ("PMU tcal", 90), ("pACC MTR Temp Sensor2", 64),
                            ("GPU MTR Temp Sensor1", 48), ("NAND CH0 temp", 37), ("gas gauge battery", 30), ("SOC MTR Temp Sensor0", 55)]
            .map { ThermalSnapshot.Sensor(name: $0.0, celsius: $0.1) }
        let groups = Dictionary(uniqueKeysWithValues: snapshot.groups.map { ($0.title, $0.celsius) })
        #expect(groups["CPU cores"] == 66)      // the tcal reading (90) isn't a real temperature
        #expect(groups["Graphics"] == 48)
        #expect(groups["SSD"] == 37)
        #expect(groups["Battery"] == 30)
        #expect(groups["Chip"] == 55)
        #expect(groups["Neural Engine"] == nil)
    }

    @Test func readsSensorsWithoutCrashing() {
        let snapshot = ThermalSensors.read()
        // Not every Mac (or CI machine) shares its sensors; when it does, readings are plausible.
        if let cpu = snapshot.cpu { #expect(cpu > 5 && cpu < 130) }
        #expect(snapshot.sensors.allSatisfy { $0.celsius > 5 && $0.celsius < 130 })
    }
}

@Suite struct WidgetSnapshotTests {
    @Test func survivesTheTripToTheWidget() throws {
        var snapshot = WidgetSnapshot.sample
        snapshot.hotApps[0].iconFile = "icon-abc.png"
        snapshot.hotApps[1].iconFile = "/tmp/elsewhere.png"
        let copy = try #require(WidgetSnapshot.decode(try snapshot.encoded()))
        #expect(copy.healthScore == snapshot.healthScore)
        #expect(copy.hotApps.map(\.name) == snapshot.hotApps.map(\.name))
        #expect(abs(copy.date.timeIntervalSince(snapshot.date)) < 1)
        #expect(copy.readyToFree == snapshot.junkBytes + snapshot.idleProjectBytes)
        // A bare icon name lives in the widget folder; a full path is used as is.
        #expect(copy.iconPath(copy.hotApps[0]) == WidgetSnapshot.folder + "/icon-abc.png")
        #expect(copy.iconPath(copy.hotApps[1]) == "/tmp/elsewhere.png")
        #expect(copy.iconPath(copy.hotApps[2]) == nil)
    }

    @Test func theWidgetFolderIsInTheRealHomeFolder() {
        #expect(WidgetSnapshot.folder.hasSuffix("/Library/Application Support/DevSweep/Widget"))
        #expect(!WidgetSnapshot.folder.contains("/Containers/"))
    }
}
