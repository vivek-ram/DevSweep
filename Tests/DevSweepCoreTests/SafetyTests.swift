import Foundation
import Testing
@testable import DevSweepCore

@Suite struct CacheSafetyTests {
    @Test func knowsBrowsersUpdatersAndToolsButNotEveryApp() {
        #expect(CacheSafety.isKnown("com.google.Chrome"))
        #expect(CacheSafety.isKnown("com.tinyspeck.slackmacgap"))
        #expect(CacheSafety.isKnown("com.vendor.App.ShipIt"))
        #expect(CacheSafety.isKnown("org.swift.swiftpm"))
        #expect(!CacheSafety.isKnown("com.me.ConsoleMac"))
        #expect(!CacheSafety.isKnown("com.valvesoftware.steam"))
    }

    @Test func readsTeamsFromSigningCertificates() {
        #expect(CacheSafety.team(fromCertificate: "Developer ID Application: Jane Doe (AB12CD34EF)") == "AB12CD34EF")
        #expect(CacheSafety.team(fromCertificate: "Apple Development: Jane Doe (ZZ99YY88XX)") == "ZZ99YY88XX")
        #expect(CacheSafety.team(fromCertificate: "Developer ID Certification Authority") == nil)
        #expect(CacheSafety.team(fromCertificate: "Some Root CA (not a team)") == nil)
        #expect(CacheSafety.isDevelopmentCertificate("Apple Development: Jane Doe (ZZ99YY88XX)"))
        #expect(!CacheSafety.isDevelopmentCertificate("Developer ID Application: Jane Doe (AB12CD34EF)"))
    }

    @Test func aCacheFullOfArtworkIsNotTicked() {
        let f = Fixture()
        let blob = String(repeating: "a", count: 10_000)
        for i in 0..<30 { f.file("Library/Caches/com.me.ConsoleMac/artwork/game\(i).png", blob) }
        f.file("Library/Caches/com.example.Plain/data", String(repeating: "b", count: 200_000))
        f.file("Library/Caches/com.google.Chrome/Default/Cache/data_1", String(repeating: "c", count: 200_000))

        let byName = Dictionary(uniqueKeysWithValues: JunkScanner.scan(home: f.root, includeDownloads: false).map { ($0.name, $0) })
        let console = byName["com.me.ConsoleMac"]
        #expect(console?.suggested == false)
        #expect(console?.caution?.contains("30 pictures") == true)
        #expect(byName["com.example.Plain"]?.suggested == false)
        #expect(byName["com.google.Chrome"]?.suggested == true, "known caches stay ticked")
    }

    @Test func signaturesTellYourOwnAppsApart() {
        // An unsigned app bundle is one you built (Xcode's "Sign to Run Locally" is ad-hoc).
        let f = Fixture()
        f.file("Console Mac.app/Contents/Info.plist", "<plist><dict/></plist>")
        #expect(CacheSafety.isYourApp(URL(fileURLWithPath: f.root + "/Console Mac.app")))
        // A released app signed by someone else isn't.
        #expect(!CacheSafety.isYourApp(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
    }
}

@Suite(.serialized) struct ProtectionTests {
    @Test func neverCleanFoldersAreLeftOutAndRefused() throws {
        let f = Fixture()
        let blob = String(repeating: "p", count: 200_000)
        f.file("Library/Caches/com.google.Chrome/data", blob)
        f.file("Library/Caches/com.me.Game/art/cover.dat", blob)
        Protection.paths = [f.root + "/Library/Caches/com.me.Game/art"]
        defer { Protection.paths = [] }

        let names = Set(JunkScanner.scan(home: f.root, includeDownloads: false).map(\.name))
        #expect(!names.contains("com.me.Game"), "a cache holding a protected folder isn't listed")
        #expect(names.contains("com.google.Chrome"))
        #expect(throws: Protection.Refused.self) { try Cleaner.remove(f.root + "/Library/Caches/com.me.Game", mode: .permanent) }
        #expect(f.exists("Library/Caches/com.me.Game/art/cover.dat"))
    }

    @Test func aKeepFileProtectsItsFolder() {
        let f = Fixture()
        f.file("Library/Caches/com.me.Game/\(ArtifactRules.keepMarker)", "")
        f.file("Library/Caches/com.me.Game/art/cover.dat", String(repeating: "k", count: 200_000))
        #expect(Protection.isProtected(f.root + "/Library/Caches/com.me.Game"))
        #expect(Protection.isProtected(f.root + "/Library/Caches/com.me.Game/art"))
        #expect(!Protection.isProtected(f.root + "/Library/Caches"), "the marker protects its own folder, not its parent")
        #expect(!JunkScanner.scan(home: f.root, includeDownloads: false).contains { $0.name == "com.me.Game" })
    }
}

@Suite struct HistorySafetyTests {
    @Test func oneUnreadableRecordDoesNotLoseTheRest() throws {
        let f = Fixture()
        let storage = Storage(directory: URL(fileURLWithPath: f.root))
        let good = CleanupRecord(projectPath: "/p", itemPath: "/p/a", kind: "nodeModules", bytes: 5, mode: .trash, outcome: .removed)
        storage.saveHistory([good])
        // A record from a newer version with a removal mode this one doesn't know.
        var json = try String(contentsOfFile: f.root + "/history.json", encoding: .utf8)
        json = json.replacingOccurrences(of: "]", with: #",{"id":"\#(UUID().uuidString)","date":0,"projectPath":"/p","itemPath":"/p/b","kind":"x","bytes":1,"mode":"shredded","outcome":"removed","automatic":false}]"#)
        try json.write(toFile: f.root + "/history.json", atomically: true, encoding: .utf8)

        #expect(storage.loadHistory().map(\.itemPath) == ["/p/a"])
        let backups = try FileManager.default.contentsOfDirectory(atPath: f.root).filter { $0.hasPrefix("history-unreadable-") }
        #expect(backups.count == 1, "the original file is kept before it's rewritten")
    }

    @Test func putsItemsBackFromTheTrash() throws {
        let f = Fixture()
        let trashed = f.file("fake/.Trash/artwork/cover.png", "art")
        let record = CleanupRecord(projectPath: f.root + "/Library/Caches", itemPath: f.root + "/Library/Caches/com.me.Game",
                                   kind: "junk:appCaches", bytes: 3, mode: .trash, outcome: .removed, trashPath: Paths.parent(trashed))
        try Cleaner.putBack(record)
        #expect(f.exists("Library/Caches/com.me.Game/cover.png"))
        #expect(!f.exists("fake/.Trash/artwork"))
        #expect(throws: Cleaner.PutBackError.self) { try Cleaner.putBack(record) }
    }
}
