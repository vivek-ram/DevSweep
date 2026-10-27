import Foundation
import Testing
@testable import DevSweepCore

@Suite struct StorageScannerTests {
    @Test func measuresTheTreeAndFindsLargeFiles() async throws {
        let f = Fixture()
        let big = String(repeating: "b", count: 3_000_000)
        f.file("Documents/report.pdf", big)
        f.file("Documents/notes/a.txt", "small")
        f.file("Movies/clip.mov", big + big)
        f.file("Photos.app/Contents/Resources/huge.bin", big)
        f.file("code/package.json", "{}")
        f.file("code/node_modules/dep/blob.bin", big)

        var scanner = StorageScanner(hasFullDiskAccess: true)
        scanner.largeFileThreshold = 2_000_000
        let result = try await scanner.scan(root: f.root)
        let root = result.root

        let expected = DiskUsage.freeableBytes(at: f.root)
        #expect(abs(root.size - expected) < 64_000, "tree total \(root.size) vs du-style \(expected)")
        #expect(root.children.first?.name == "Movies", "biggest first")

        let app = try #require(root.children.first { $0.name == "Photos.app" })
        #expect(app.isPackage && app.children.isEmpty, "bundles show as one item")

        let modules = try #require(root.descendant(at: f.root + "/code/node_modules"))
        #expect(modules.artifactKind == .nodeModules)

        // Large files: not inside bundles or rebuildable folders.
        #expect(Set(result.largeFiles.map(\.name)) == ["clip.mov", "report.pdf"])
    }

    @Test func skipsAppContainersWithoutFullDiskAccess() async throws {
        let f = Fixture()
        f.file("Library/Containers/com.example/Data/x", "x")
        f.file("Library/Caches/thing/y", String(repeating: "y", count: 2_000_000))
        let result = try await StorageScanner(hasFullDiskAccess: false).scan(root: f.root)
        let containers = try #require(result.root.descendant(at: f.root + "/Library")?.children.first { $0.name == "Containers" })
        #expect(containers.note == .needsFullDiskAccess)
        #expect(result.restricted == [f.root + "/Library/Containers"])
    }

    @Test func removingANodeUpdatesSizesUpTheTree() async throws {
        let f = Fixture()
        f.file("a/b/big.bin", String(repeating: "x", count: 2_000_000))
        f.file("a/keep.bin", String(repeating: "y", count: 2_000_000))
        let result = try await StorageScanner(hasFullDiskAccess: true).scan(root: f.root)
        let before = result.root.size
        let b = try #require(result.root.descendant(at: f.root + "/a/b"))
        let removed = b.size
        b.parent?.remove(b)
        #expect(result.root.size == before - removed)
        #expect(result.root.descendant(at: f.root + "/a/b") == nil)
    }
}

@Suite struct JunkTests {
    @Test func findsCachesLogsAndInstallersButNotAppleOrDevCaches() {
        let f = Fixture()
        let blob = String(repeating: "j", count: 200_000)
        f.file("Library/Caches/com.example.app/data", blob)
        f.file("Library/Caches/com.apple.Safari/data", blob)
        f.file("Library/Caches/pip/http/x", blob)
        f.file("Library/Logs/SomeApp/log.txt", blob)
        f.file("Downloads/Tool.dmg", blob)
        f.file("Downloads/new.dmg", blob, date: Date())
        f.file("Downloads/photos.zip", blob)
        f.file("Downloads/project/package.json", "{}")
        f.file("Downloads/project/build.dmg", blob)

        let items = JunkScanner.scan(home: f.root)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName["com.example.app"]?.category == .appCaches)
        #expect(byName["com.example.app"]?.suggested == false, "unknown apps' caches aren't ticked")
        #expect(byName["com.example.app"]?.note != nil)
        #expect(byName["com.apple.Safari"] == nil, "Apple's caches are left alone")
        #expect(byName["pip"] == nil, "developer caches have their own page")
        #expect(byName["SomeApp"]?.category == .logs)
        #expect(byName["Tool.dmg"]?.suggested == true)
        #expect(byName["new.dmg"]?.suggested == false, "recent downloads aren't suggested")
        #expect(byName["photos.zip"]?.suggested == false, "archives are never pre-ticked")
        #expect(byName["build.dmg"] == nil, "files inside code folders are left alone")
    }

    @Test func revalidatesBeforeRemoving() {
        let f = Fixture()
        f.file("Library/Caches/com.example.app/data", String(repeating: "j", count: 200_000))
        let item = JunkItem(category: .appCaches, path: f.root + "/Library/Caches/com.example.app", bytes: 1, modified: .now, suggested: true)
        #expect(JunkScanner.validate(item, home: f.root) == nil)
        let forged = JunkItem(category: .appCaches, path: f.root + "/Documents", bytes: 1, modified: .now, suggested: true)
        #expect(JunkScanner.validate(forged, home: f.root) != nil)

        let record = Cleaner.clean(item, mode: .permanent, home: f.root)
        #expect(record.outcome == .removed)
        #expect(!f.exists("Library/Caches/com.example.app"))
        #expect(f.exists("Library/Caches"))
    }

    @Test func storageMapRemovalRules() {
        let home = "/Users/me"
        #expect(RemovalRules.problem(removing: "/Users/me/Documents", home: home) != nil)
        #expect(RemovalRules.problem(removing: "/Users/me/Library/Caches", home: home) != nil)
        #expect(RemovalRules.problem(removing: "/Users/me", home: home) != nil)
        #expect(RemovalRules.problem(removing: "/System/Library", home: home) != nil)
        #expect(RemovalRules.problem(removing: "/Users/me/Documents/old.mov", home: home) == nil)
        #expect(RemovalRules.problem(removing: "/Users/me/Library/Caches/com.x", home: home) == nil)
        #expect(RemovalRules.problem(removing: "/Applications/Some.app", home: home) == nil)
        #expect(RemovalRules.problem(removing: "/Applications/Utilities/Terminal.app", home: home) != nil)
        #expect(RemovalRules.problem(removing: "/System/Volumes/Data/Users/me/Movies/a.mov", home: home) == nil)
        #expect(RemovalRules.problem(removing: "/Users/me/Documents/../../other", home: home) != nil)
    }
}
