import Foundation

/// "When did I last open this folder?" gathered from the state editors keep on this Mac.
/// Running code doesn't change files, so without this a project you use every day but never
/// edit would look abandoned.
public struct EditorActivity: Sendable {
    public struct Entry: Sendable, Equatable {
        public var date: Date
        public var app: String
    }

    /// Absolute folder path → most recent open.
    public private(set) var folders: [String: Entry] = [:]
    /// Claude Code stores sessions under a lossy encoding of the path; matched per project.
    private var claudeSessions: [String: Date] = [:]

    public init(folders: [String: Entry] = [:]) {
        self.folders = folders
    }

    public static func collect(home: String = NSHomeDirectory()) -> EditorActivity {
        var activity = EditorActivity()
        activity.collectVSCodeFamily(home: home)
        activity.collectXcode(home: home)
        activity.collectClaudeCode(home: home)
        return activity
    }

    /// Most recent open of `project` or any folder inside it. JetBrains IDEs keep their state
    /// inside the project, so that is checked directly.
    public func lastOpened(project: String) -> Entry? {
        var best: Entry?
        func consider(_ entry: Entry) {
            if best == nil || entry.date > best!.date { best = entry }
        }
        for (folder, entry) in folders where Paths.isInside(folder, project) {
            consider(entry)
        }
        // Sessions started in a subfolder count too. The encoding is lossy, so a sibling named
        // "<project>-old" can match as well; that only ever errs towards keeping a project.
        let key = Self.claudeKey(for: project)
        for (session, date) in claudeSessions where session == key || session.hasPrefix(key + "-") {
            consider(Entry(date: date, app: "Claude Code"))
        }
        if let date = modificationDate(project + "/.idea/workspace.xml") {
            consider(Entry(date: date, app: "JetBrains"))
        }
        return best
    }

    private mutating func record(_ folder: String, _ date: Date, _ app: String) {
        let path = Paths.normalize(folder)
        if let existing = folders[path], existing.date >= date { return }
        folders[path] = Entry(date: date, app: app)
    }

    // MARK: VS Code, Cursor, Windsurf, …

    private static let vscodeFamily: [(dir: String, name: String)] = [
        ("Code", "VS Code"), ("Code - Insiders", "VS Code"), ("Cursor", "Cursor"), ("Windsurf", "Windsurf"),
        ("VSCodium", "VSCodium"), ("Trae", "Trae"), ("Kiro", "Kiro"), ("Antigravity", "Antigravity"),
        ("Positron", "Positron"),
    ]

    private mutating func collectVSCodeFamily(home: String) {
        let fm = FileManager.default
        for (dir, app) in Self.vscodeFamily {
            let storage = "\(home)/Library/Application Support/\(dir)/User/workspaceStorage"
            guard let workspaces = try? fm.contentsOfDirectory(atPath: storage) else { continue }
            for id in workspaces {
                let base = "\(storage)/\(id)"
                guard let data = fm.contents(atPath: base + "/workspace.json"),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                var folder: String?
                if let uri = json["folder"] as? String, let url = URL(string: uri), url.isFileURL {
                    folder = url.path
                } else if let uri = json["workspace"] as? String, let url = URL(string: uri), url.isFileURL {
                    folder = url.deletingLastPathComponent().path
                }
                guard let folder else { continue }
                let date = [modificationDate(base + "/state.vscdb"), modificationDate(base)].compactMap { $0 }.max()
                if let date { record(folder, date, app) }
            }
        }
    }

    // MARK: Xcode

    private mutating func collectXcode(home: String) {
        let derived = "\(home)/Library/Developer/Xcode/DerivedData"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: derived) else { return }
        for entry in entries {
            let plist = "\(derived)/\(entry)/info.plist"
            guard let data = FileManager.default.contents(atPath: plist),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspace = info["WorkspacePath"] as? String else { continue }
            let date = (info["LastAccessedDate"] as? Date) ?? modificationDate(plist)
            if let date { record((workspace as NSString).deletingLastPathComponent, date, "Xcode") }
        }
    }

    // MARK: Claude Code

    private mutating func collectClaudeCode(home: String) {
        let base = "\(home)/.claude/projects"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return }
        for entry in entries {
            let dir = "\(base)/\(entry)"
            let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            let newest = files.compactMap { modificationDate("\(dir)/\($0)") }.max() ?? modificationDate(dir)
            if let newest { claudeSessions[entry] = newest }
        }
    }

    /// Claude Code names a project's folder by replacing every non-alphanumeric character with "-".
    static func claudeKey(for path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        })
    }
}

func modificationDate(_ path: String) -> Date? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
}
