import Foundation
import Testing
@testable import DevSweepCore

@Suite struct PythonSnapshotTests {
    @Test func freezesPackagesLikePip() throws {
        let f = Fixture()
        let venv = f.venv("proj/.venv", packages: [("requests", "2.31.0"), ("Flask", "3.0.0"), ("typing_extensions", "4.9.0")]) { site in
            // Installed from git
            f.file(String(site.dropFirst(f.root.count + 1)) + "/mylib-0.1.dist-info/METADATA", "Name: mylib\nVersion: 0.1\n")
            f.file(String(site.dropFirst(f.root.count + 1)) + "/mylib-0.1.dist-info/direct_url.json",
                   #"{"url": "https://github.com/me/mylib.git", "vcs_info": {"vcs": "git", "commit_id": "abc123"}}"#)
            // The project itself, installed with pip install -e .
            f.file(String(site.dropFirst(f.root.count + 1)) + "/proj-1.0.dist-info/METADATA", "Name: proj\nVersion: 1.0\n")
            f.file(String(site.dropFirst(f.root.count + 1)) + "/proj-1.0.dist-info/direct_url.json",
                   #"{"url": "file://\#(f.root)/proj", "dir_info": {"editable": true}}"#)
        }

        let env = try PythonSnapshot.inspect(venv: venv)
        #expect(env.pythonVersion == "3.11.4")
        #expect(env.requirements.map(\.line) == [
            "Flask==3.0.0",
            "mylib @ git+https://github.com/me/mylib.git@abc123",
            "-e .",
            "requests==2.31.0",
            "typing_extensions==4.9.0",
        ])
        #expect(env.tooling.map(\.name) == ["pip", "setuptools"])

        let text = PythonSnapshot.render(env, venvName: ".venv", fileName: "requirements.txt")
        #expect(text.contains("python3.11 -m venv .venv && .venv/bin/pip install -r requirements.txt"))
        #expect(text.hasSuffix("typing_extensions==4.9.0\n"))
    }

    @Test func writesRequirementsTxtWhenMissing() throws {
        let f = Fixture()
        let venv = f.venv("proj/.venv", packages: [("numpy", "1.26.4")])
        let outcome = try PythonSnapshot.save(venv: venv, preserveDate: Fixture.old)
        #expect(outcome == .written(f.root + "/proj/requirements.txt"))
        #expect(f.read("proj/requirements.txt").contains("\nnumpy==1.26.4\n"))
        let attrs = try FileManager.default.attributesOfItem(atPath: f.root + "/proj/requirements.txt")
        let date = try #require(attrs[.modificationDate] as? Date)
        #expect(abs(date.timeIntervalSince(Fixture.old)) < 2, "snapshot must not make the project look active")
    }

    @Test func neverOverwritesTheUsersRequirementsTxt() throws {
        let f = Fixture()
        f.file("proj/requirements.txt", "numpy>=1.20\n")
        let venv = f.venv("proj/.venv", packages: [("numpy", "1.26.4")])
        let outcome = try PythonSnapshot.save(venv: venv)
        #expect(outcome == .written(f.root + "/proj/requirements-snapshot.txt"))
        #expect(f.read("proj/requirements.txt") == "numpy>=1.20\n")
        #expect(f.read("proj/requirements-snapshot.txt").contains("numpy==1.26.4"))
    }

    @Test func skipsWritingWhenExistingFileAlreadyPinsEverything() throws {
        let f = Fixture()
        f.file("proj/requirements.txt", "# deps\nNumPy==1.26.4  # pinned\nrequests[socks]==2.31.0\n")
        let venv = f.venv("proj/.venv", packages: [("numpy", "1.26.4"), ("requests", "2.31.0")])
        #expect(try PythonSnapshot.save(venv: venv) == .alreadyCovered(f.root + "/proj/requirements.txt"))
        #expect(!f.exists("proj/requirements-snapshot.txt"))
    }

    @Test func emptyEnvironmentWritesNothing() throws {
        let f = Fixture()
        let venv = f.venv("proj/.venv", packages: [])
        #expect(try PythonSnapshot.save(venv: venv) == .empty)
        #expect(!f.exists("proj/requirements.txt"))
    }
}

@Suite struct CleanerTests {
    func staleProject(_ f: Fixture) async throws -> Project {
        f.file("proj/main.py")
        f.venv("proj/.venv", packages: [("numpy", "1.26.4")])
        f.file("proj/package.json", "{}")
        f.file("proj/node_modules/left-pad/package.json", #"{"version":"1.3.0"}"#)
        f.file("proj/__pycache__/main.cpython-311.pyc")
        return try #require(try await f.scan().project(f, "proj"))
    }

    @Test func savesPackagesThenRemoves() async throws {
        let f = Fixture()
        let project = try await staleProject(f)
        let records = Cleaner.clean(project.artifacts, in: project, options: CleanOptions(mode: .permanent))

        #expect(records.allSatisfy { $0.outcome == .removed }, "\(records.map { $0.message ?? "" })")
        #expect(!f.exists("proj/.venv") && !f.exists("proj/node_modules") && !f.exists("proj/__pycache__"))
        #expect(f.exists("proj/main.py"), "source code is never touched")
        #expect(f.read("proj/requirements.txt").contains("numpy==1.26.4"))
        #expect(f.read("proj/\(NodeSnapshot.fileName)").contains(#""left-pad" : "1.3.0""#))
        #expect(records.first { $0.kind == "pythonVenv" }?.snapshotPath == f.root + "/proj/requirements.txt")
    }

    @Test func noNodeSnapshotWhenALockfileExists() async throws {
        let f = Fixture()
        f.file("proj/package-lock.json", "{}")
        let project = try await staleProject(f)
        _ = Cleaner.clean(project.artifacts, in: project, options: CleanOptions(mode: .permanent))
        #expect(!f.exists("proj/\(NodeSnapshot.fileName)"))
    }

    @Test func dryRunTouchesNothing() async throws {
        let f = Fixture()
        let project = try await staleProject(f)
        let records = Cleaner.clean(project.artifacts, in: project, options: CleanOptions(mode: .permanent, dryRun: true))
        #expect(records.allSatisfy { $0.outcome == .skipped })
        #expect(f.exists("proj/.venv") && f.exists("proj/node_modules") && !f.exists("proj/requirements.txt"))
    }

    @Test func revalidatesBeforeRemoving() async throws {
        let f = Fixture()
        let project = try await staleProject(f)
        // After the scan, the user drops a keep marker and turns the venv into something else.
        f.file("proj/\(ArtifactRules.keepMarker)", "")
        let records = Cleaner.clean(project.artifacts, in: project, options: CleanOptions(mode: .permanent))
        #expect(records.allSatisfy { $0.outcome == .skipped })
        #expect(f.exists("proj/.venv"))
    }

    @Test func refusesSymlinksAndPathsOutsideTheProject() throws {
        let f = Fixture()
        f.file("elsewhere/node_modules/a/index.js")
        f.dir("proj")
        try FileManager.default.createSymbolicLink(atPath: f.root + "/proj/node_modules", withDestinationPath: f.root + "/elsewhere/node_modules")
        let project = Project(path: f.root + "/proj", root: f.root, artifacts: [])
        let link = Artifact(path: f.root + "/proj/node_modules", kind: .nodeModules, modified: .now)
        let outside = Artifact(path: f.root + "/elsewhere/node_modules", kind: .nodeModules, modified: .now)
        let sneaky = Artifact(path: f.root + "/proj/../elsewhere/node_modules", kind: .nodeModules, modified: .now)
        #expect(Cleaner.validate(link, in: project) == "Is a symbolic link")
        #expect(Cleaner.validate(outside, in: project) != nil)
        #expect(Cleaner.validate(sneaky, in: project) != nil)
        _ = Cleaner.clean([link, outside, sneaky], in: project, options: CleanOptions(mode: .permanent))
        #expect(f.exists("elsewhere/node_modules/a/index.js"))
    }

    @Test func keepsTheVenvIfItsPackagesCannotBeRead() async throws {
        let f = Fixture()
        f.file("proj/main.py")
        f.file("proj/broken/pyvenv.cfg", "version = 3.12.0\n")   // no lib/ at all
        let project = try #require(try await f.scan().project(f, "proj"))
        let records = Cleaner.clean(project.artifacts, in: project, options: CleanOptions(mode: .permanent))
        #expect(records.first?.outcome == .skipped)
        #expect(f.exists("proj/broken/pyvenv.cfg"))
    }

    @Test func purgeOnlyDeletesItemsWeTrashed() throws {
        let f = Fixture()
        let ours = f.file("fake/.Trash/node_modules 10.42.11/a.js")
        let theirs = f.file("fake/.Trash/holiday-photo.jpg")
        let record = CleanupRecord(projectPath: "/p", itemPath: "/p/node_modules", kind: "nodeModules", bytes: 5,
                                   mode: .trash, outcome: .removed, trashPath: Paths.parent(ours))
        #expect(Cleaner.itemsStillInTrash([record]).count == 1)
        let result = Cleaner.purgeFromTrash([record])
        #expect(result.freed == 5 && result.failures == 0)
        #expect(!FileManager.default.fileExists(atPath: Paths.parent(ours)))
        #expect(FileManager.default.fileExists(atPath: theirs))
    }

    @Test func venvsNeedExplicitApproval() {
        let venvA = Artifact(path: "/p/a/.venv", kind: .pythonVenv, modified: .now)
        let venvB = Artifact(path: "/p/b/venv", kind: .pythonVenv, modified: .now)
        let modules = Artifact(path: "/p/node_modules", kind: .nodeModules, modified: .now)
        let all = [venvA, venvB, modules]
        #expect(Cleaner.applyingVenvApproval(all, askBeforeVenvs: true, approvedVenvs: []) == [modules])
        #expect(Cleaner.applyingVenvApproval(all, askBeforeVenvs: true, approvedVenvs: [venvB.path]) == [venvB, modules])
        #expect(Cleaner.applyingVenvApproval(all, askBeforeVenvs: false, approvedVenvs: []) == all)
    }

    @Test func planShowsWhereRequirementsWillGoWithoutWriting() throws {
        let f = Fixture()
        f.file("proj/requirements.txt", "numpy>=1\n")
        let venv = f.venv("proj/.venv", packages: [("numpy", "1.26.4"), ("rich", "13.0.0")])
        let plan = try PythonSnapshot.plan(venv: venv)
        #expect(plan.environment.requirements.count == 2)
        #expect(plan.outcome == .written(f.root + "/proj/requirements-snapshot.txt"))
        #expect(!f.exists("proj/requirements-snapshot.txt"))
    }

    @Test func onlyRealTrashLocationsCount() {
        #expect(Cleaner.isInTrash("/Users/me/.Trash/node_modules"))
        #expect(Cleaner.isInTrash("/Volumes/Ext/.Trashes/501/target"))
        #expect(!Cleaner.isInTrash("/Users/me/.Trash"))
        #expect(!Cleaner.isInTrash("/Users/me/.Trashy/important"))
        #expect(!Cleaner.isInTrash("/Users/me/.Trash/../Documents"))
    }
}
