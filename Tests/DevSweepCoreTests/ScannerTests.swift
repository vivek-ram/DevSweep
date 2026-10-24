import Foundation
import Testing
@testable import DevSweepCore

@Suite struct ScannerTests {
    @Test func findsArtifactsAndGroupsThemByProject() async throws {
        let f = Fixture()
        f.dir("webapp/.git")
        f.file("webapp/package.json", "{}")
        f.file("webapp/node_modules/react/package.json", #"{"version":"18.2.0"}"#)
        f.file("webapp/.next/cache/x")
        f.file("webapp/packages/ui/package.json", "{}")
        f.file("webapp/packages/ui/node_modules/lodash/index.js")
        f.file("rusty/Cargo.toml")
        f.file("rusty/target/debug/app")
        f.file("pyproj/requirements.txt", "requests==2.0\n")
        f.venv("pyproj/.venv", packages: [("requests", "2.31.0")])
        f.file("pyproj/src/pkg/__pycache__/m.cpython-311.pyc")

        let result = try await f.scan()
        let web = try #require(result.project(f, "webapp"))
        #expect(Set(web.artifacts.map(\.kind)) == [.nodeModules, .jsBuildCache])
        #expect(web.artifacts.count == 3, "the workspace package's node_modules belongs to the git repo")
        #expect(web.isGitRepo)

        let rust = try #require(result.project(f, "rusty"))
        #expect(rust.artifacts.map(\.kind) == [.rustTarget])

        let py = try #require(result.project(f, "pyproj"))
        #expect(Set(py.artifacts.map(\.kind)) == [.pythonVenv, .pythonCache])
        #expect(py.totalBytes > 0)
    }

    @Test func requiresTheRightNeighbourFiles() async throws {
        let f = Fixture()
        f.file("notrust/target/thing")           // no Cargo.toml
        f.file("notrust/build/out")              // no build.gradle
        f.file("notrust/Pods/x")                 // no Podfile
        f.file("notrust/.next/x")                // no package.json
        f.file("notrust/main.py")
        let result = try await f.scan()
        #expect(result.projects.isEmpty)
    }

    @Test func detectsVenvsByPyvenvCfgWhateverTheirName() async throws {
        let f = Fixture()
        f.file("tool/main.py")
        f.venv("tool/my-weird-env", packages: [("rich", "13.0.0")])
        let result = try await f.scan()
        #expect(result.project(f, "tool")?.artifacts.first?.kind == .pythonVenv)
    }

    @Test func neverEntersToolFoldersOrGlobalInstalls() async throws {
        let f = Fixture()
        f.file(".vscode/extensions/ext/package.json", "{}")
        f.file(".vscode/extensions/ext/node_modules/a/index.js")
        f.file("miniconda3/conda-meta/history")
        f.file("miniconda3/pkgs/thing/node_modules/a/index.js")
        f.file("pylib/lib/python3.11/site-packages/foo/__pycache__/x.pyc")
        f.file("Some.app/Contents/Resources/node_modules/a/index.js")
        let result = try await f.scan()
        #expect(result.projects.isEmpty, "found \(result.projects.map(\.path))")
    }

    @Test func groupsStrayCachesIntoTheLargestFolderWithoutOtherProjects() async throws {
        let f = Fixture()
        f.file("research/v1/scripts/run.py")
        f.file("research/v1/scripts/__pycache__/run.pyc")
        f.file("research/v2/tools/__pycache__/t.pyc")
        f.file("research/v2/tools/t.py")
        f.file("collection/real/package.json", "{}")
        f.file("collection/real/node_modules/a/index.js")
        f.file("collection/loose/__pycache__/x.pyc")
        let result = try await f.scan()
        let research = try #require(result.project(f, "research"))
        #expect(research.artifacts.count == 2)
        #expect(result.project(f, "collection/real") != nil)
        #expect(result.project(f, "collection/loose") != nil, "collection holds another project, so it isn't one itself")
    }

    @Test func lastEditedIgnoresArtifactsAndNoise() async throws {
        let f = Fixture()
        f.file("app/package.json", "{}", date: Fixture.old)
        f.file("app/src/index.js", "", date: Fixture.old)
        f.file("app/node_modules/a/index.js", "", date: Date())   // fresh install inside artifact
        f.file("app/.DS_Store", "", date: Date())
        let result = try await f.scan()
        let app = try #require(result.project(f, "app"))
        let edited = try #require(app.lastEdited)
        #expect(abs(edited.timeIntervalSince(Fixture.old)) < 2)
        #expect(RetentionPolicy(days: 30).status(of: app).isStale)
    }

    @Test func recentEditsAnywhereInTheProjectKeepItActive() async throws {
        let f = Fixture()
        f.file("app/package.json", "{}")
        f.file("app/node_modules/a/index.js")
        f.file("app/src/deep/nested/file.ts", "", date: Fixture.recent)
        let result = try await f.scan()
        let app = try #require(result.project(f, "app"))
        #expect(!RetentionPolicy(days: 30).status(of: app).isStale)
    }

    @Test func editorOpensCountAsActivity() async throws {
        let f = Fixture()
        f.file("app/package.json", "{}")
        f.file("app/node_modules/a/index.js")
        let editors = EditorActivity(folders: [f.root + "/app/src": .init(date: Fixture.recent, app: "Cursor")])
        let result = try await f.scan(editors: editors)
        let app = try #require(result.project(f, "app"))
        #expect(app.openedWith == "Cursor")
        #expect(!RetentionPolicy(days: 30).status(of: app).isStale)
    }

    @Test func keepMarkerProtectsEverythingBelowIt() async throws {
        let f = Fixture()
        f.file("keep/\(ArtifactRules.keepMarker)", "")
        f.file("keep/app/package.json", "{}")
        f.file("keep/app/node_modules/a/index.js")
        let result = try await f.scan()
        let app = try #require(result.project(f, "keep/app"))
        #expect(app.hasKeepMarker)
        #expect(RetentionPolicy(days: 1).status(of: app) == .protected)
    }

    @Test func nestedRootsAreScannedOnce() {
        #expect(ProjectScanner.minimalRoots(["/a/b", "/a", "/a/b/c", "/ab"]) == ["/a", "/ab"])
    }

    @Test func claudeCodeKeyMatchesItsEncoding() {
        #expect(EditorActivity.claudeKey(for: "/Users/me/Code Projects /my_app") == "-Users-me-Code-Projects--my-app")
    }
}

@Suite struct DiskUsageTests {
    @Test func countsHardLinkedFilesOnlyWhenAllLinksAreInside() throws {
        let f = Fixture()
        let blob = String(repeating: "a", count: 200_000)
        let inside = f.file("tree/a.bin", blob)
        try FileManager.default.linkItem(atPath: inside, toPath: f.root + "/tree/b.bin")
        let shared = f.file("store/c.bin", blob)
        try FileManager.default.linkItem(atPath: shared, toPath: f.root + "/tree/c.bin")

        let size = DiskUsage.freeableBytes(at: f.root + "/tree")
        // a.bin/b.bin count once; c.bin is still referenced from store/ so removing tree frees nothing for it.
        #expect(size >= 200_000 && size < 400_000, "got \(size)")
    }
}

@Suite struct PolicyTests {
    func project(idle days: Double, path: String = "/p") -> Project {
        Project(path: path, root: "/", artifacts: [Artifact(path: path + "/node_modules", kind: .nodeModules, bytes: 10, modified: .distantPast)],
                lastEdited: Date().addingTimeInterval(-days * 86_400))
    }

    @Test func staleAfterRetentionPeriod() {
        let policy = RetentionPolicy(days: 30)
        #expect(policy.status(of: project(idle: 31)).isStale)
        #expect(policy.status(of: project(idle: 29)) == .active(staleInDays: 1))
    }

    @Test func lowDiskSpaceHalvesTheRetentionPeriod() {
        let policy = RetentionPolicy(days: 30, lowSpaceBoost: true, lowSpaceThreshold: 10_000)
        #expect(policy.status(of: project(idle: 20), freeBytes: 5_000).isStale)
        #expect(!policy.status(of: project(idle: 20), freeBytes: 50_000).isStale)
        #expect(RetentionPolicy(days: 10, lowSpaceThreshold: 10_000).effectiveDays(freeBytes: 1) == 7)
    }

    @Test func protectedPathsCoverSubfolders() {
        let policy = RetentionPolicy(days: 1, protectedPaths: ["/work"])
        #expect(policy.status(of: project(idle: 400, path: "/work/app")) == .protected)
        #expect(policy.status(of: project(idle: 400, path: "/workshop")).isStale)
    }

    @Test func onlyEnabledKindsAreCleanable() {
        let policy = RetentionPolicy(days: 1, enabledKinds: [.pythonVenv])
        #expect(policy.cleanableArtifacts(of: project(idle: 400)).isEmpty)
    }
}
