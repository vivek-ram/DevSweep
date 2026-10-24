import Foundation
@testable import DevSweepCore

/// Builds throwaway project trees in a temp folder.
final class Fixture {
    let root: String
    static let old = Date().addingTimeInterval(-90 * 86_400)
    static let recent = Date().addingTimeInterval(-2 * 86_400)

    init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("devsweep-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = Paths.normalize(base.resolvingSymlinksInPath().path)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func file(_ relative: String, _ content: String = "x", date: Date = Fixture.old) -> String {
        let path = root + "/" + relative
        try! FileManager.default.createDirectory(atPath: Paths.parent(path), withIntermediateDirectories: true)
        try! content.write(toFile: path, atomically: false, encoding: .utf8)
        setDate(path, date)
        return path
    }

    @discardableResult
    func dir(_ relative: String, date: Date = Fixture.old) -> String {
        let path = root + "/" + relative
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        setDate(path, date)
        return path
    }

    func setDate(_ path: String, _ date: Date) {
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// A venv with packages installed as dist-info folders.
    @discardableResult
    func venv(_ relative: String, packages: [(String, String)], extra: (String) -> Void = { _ in }) -> String {
        let venv = root + "/" + relative
        file(relative + "/pyvenv.cfg", "home = /usr/bin\ninclude-system-site-packages = false\nversion = 3.11.4\n")
        file(relative + "/bin/python", "#!")
        for (name, version) in packages + [("pip", "24.0"), ("setuptools", "69.0.0")] {
            let distInfo = "\(relative)/lib/python3.11/site-packages/\(name.replacingOccurrences(of: "-", with: "_"))-\(version).dist-info"
            file(distInfo + "/METADATA", "Metadata-Version: 2.1\nName: \(name)\nVersion: \(version)\nSummary: s\n\nLong description\nName: wrong\n")
            file(distInfo + "/RECORD", "")
        }
        extra(venv + "/lib/python3.11/site-packages")
        // Directory mtimes change as files are created; pin them last.
        for sub in ["", "/bin", "/lib", "/lib/python3.11", "/lib/python3.11/site-packages"] {
            setDate(venv + sub, Fixture.old)
        }
        return venv
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root + "/" + relative)
    }

    func read(_ relative: String) -> String {
        (try? String(contentsOfFile: root + "/" + relative, encoding: .utf8)) ?? ""
    }

    /// Creating files bumps their folders' dates; age every folder so only the dates a test set
    /// explicitly on files count as activity.
    func settle() {
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let relative = enumerator?.nextObject() as? String {
            let path = root + "/" + relative
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                setDate(path, Fixture.old)
            }
        }
    }

    func scan(editors: EditorActivity = EditorActivity()) async throws -> ScanResult {
        settle()
        return try await ProjectScanner().scan(roots: [root], editorActivity: editors)
    }
}

extension ScanResult {
    func project(_ fixture: Fixture, _ relative: String) -> Project? {
        projects.first { $0.path == fixture.root + "/" + relative }
    }
}
