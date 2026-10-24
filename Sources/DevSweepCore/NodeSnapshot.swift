import Foundation

/// Records the versions installed in a node_modules folder when the project has no lockfile,
/// so the exact set can still be reproduced after the folder is removed.
public enum NodeSnapshot {
    public static let fileName = "node_modules.snapshot.json"
    static let lockfiles = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"]

    /// Looks for a lockfile next to node_modules and in every folder up to the project root
    /// (workspaces keep a single lockfile at the top).
    public static func hasLockfile(nodeModules: String, projectRoot: String) -> Bool {
        var dir = Paths.parent(nodeModules)
        while true {
            if lockfiles.contains(where: { ArtifactRules.exists(dir, $0) }) { return true }
            if dir == projectRoot || !dir.hasPrefix(projectRoot) || dir == "/" { return false }
            dir = Paths.parent(dir)
        }
    }

    /// Top-level packages (including @scoped ones) and their installed versions.
    public static func installedVersions(nodeModules: String) -> [String: String] {
        let fm = FileManager.default
        var result: [String: String] = [:]
        func read(_ name: String, _ dir: String) {
            guard let data = fm.contents(atPath: dir + "/package.json"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String else { return }
            result[name] = version
        }
        for entry in (try? fm.contentsOfDirectory(atPath: nodeModules)) ?? [] where !entry.hasPrefix(".") {
            let path = nodeModules + "/" + entry
            if entry.hasPrefix("@") {
                for scoped in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where !scoped.hasPrefix(".") {
                    read(entry + "/" + scoped, path + "/" + scoped)
                }
            } else {
                read(entry, path)
            }
        }
        return result
    }

    /// Writes `node_modules.snapshot.json` next to node_modules unless a lockfile already pins
    /// the install. Returns the written path, or nil if no snapshot was needed.
    public static func saveIfNeeded(nodeModules: String, projectRoot: String, preserveDate: Date? = nil,
                                    now: Date = Date()) throws -> String? {
        guard !hasLockfile(nodeModules: nodeModules, projectRoot: projectRoot) else { return nil }
        let versions = installedVersions(nodeModules: nodeModules)
        guard !versions.isEmpty else { return nil }

        let document: [String: Any] = [
            "generatedBy": "DevSweep",
            "date": ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate]),
            "note": "Versions that were installed in node_modules when it was removed. The project had no lockfile, so they are kept here to help reproduce the install.",
            "installed": versions,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let target = Paths.parent(nodeModules) + "/" + fileName
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        if let preserveDate {
            try? FileManager.default.setAttributes([.modificationDate: preserveDate], ofItemAtPath: target)
        }
        return target
    }
}
