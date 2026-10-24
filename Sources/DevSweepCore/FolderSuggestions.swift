import Foundation

/// Guesses where someone keeps their code, for first launch.
public enum FolderSuggestions {
    static let commonNames = [
        "Developer", "Projects", "projects", "Code", "code", "dev", "Dev", "src", "repos", "Repos", "git", "GitHub",
        "workspace", "Workspace", "Sites", "Documents/GitHub", "Documents/Projects", "Documents/Code",
    ]
    static let skipped: Set<String> = ["Library", "Applications", "Pictures", "Music", "Movies", "Public", "Pods"]

    /// Folders that exist and look like they hold several projects.
    public static func find(home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        func add(_ path: String) {
            let path = Paths.normalize(path)
            if !result.contains(path) { result.append(path) }
        }

        for name in commonNames {
            var isDir: ObjCBool = false
            let path = home + "/" + name
            // Case-insensitive disks report "projects" and "Projects" as the same folder.
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
               !result.contains(where: { $0.lowercased() == path.lowercased() }) {
                add(path)
            }
        }

        // A folder whose children include at least two projects is a "projects folder".
        for base in [home, home + "/Desktop", home + "/Documents", home + "/Downloads"] {
            if base != home, projectChildren(of: base) >= 2 { add(base) }
            for child in subfolders(of: base) where projectChildren(of: child) >= 2 {
                add(child)
            }
        }
        return result.filter { candidate in !result.contains { $0 != candidate && Paths.isInside(candidate, $0) } }
    }

    static func subfolders(of path: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return entries.filter { !$0.hasPrefix(".") && !skipped.contains($0) }.compactMap { name in
            let full = path + "/" + name
            var st = stat()
            guard lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, !name.hasSuffix(".app") else { return nil }
            return full
        }
    }

    static func isProject(_ path: String) -> Bool {
        ArtifactRules.exists(path, ".git") || ArtifactRules.projectMarkers.contains { ArtifactRules.exists(path, $0) }
    }

    static func projectChildren(of path: String) -> Int {
        subfolders(of: path).lazy.filter(isProject).prefix(2).count
    }
}
