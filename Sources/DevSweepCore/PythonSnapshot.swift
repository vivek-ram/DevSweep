import Foundation

/// Reads what is installed in a Python virtual environment, `pip freeze` style, straight from
/// the package metadata on disk. Nothing is executed, so it also works for old environments
/// whose base interpreter has since been upgraded or removed by Homebrew.
public enum PythonSnapshot {
    public struct Requirement: Hashable, Sendable {
        public var name: String
        public var version: String
        /// The line written to requirements.txt.
        public var line: String
    }

    public struct Environment: Sendable {
        public var pythonVersion: String?
        /// "uv 0.4.18", "virtualenv 20.26.0" or nil for the stdlib venv module.
        public var creator: String?
        public var requirements: [Requirement]
        /// pip / setuptools / wheel: present but not pinned, like `pip freeze`.
        public var tooling: [Requirement]
        /// Created with --system-site-packages; those packages live outside the venv and stay.
        public var usesSystemPackages = false
    }

    public enum Outcome: Sendable, Equatable {
        /// A file was written at this path.
        case written(String)
        /// An existing requirements file already pins exactly these versions.
        case alreadyCovered(String)
        /// Nothing installed beyond pip itself; there is nothing to save.
        case empty
    }

    static let toolingPackages: Set<String> = ["pip", "setuptools", "wheel", "distribute"]
    static let headerTag = "saved by DevSweep"

    // MARK: Reading

    public static func inspect(venv: String) throws -> Environment {
        let config = parseConfig(venv + "/pyvenv.cfg")
        var env = Environment(pythonVersion: config["version_info"] ?? config["version"],
                              creator: config["uv"].map { "uv \($0)" } ?? config["virtualenv"].map { "virtualenv \($0)" },
                              requirements: [], tooling: [],
                              usesSystemPackages: config["include-system-site-packages"]?.lowercased() == "true")

        let projectDir = Paths.parent(venv)
        var byName: [String: Requirement] = [:]
        for sitePackages in try sitePackagesDirectories(venv: venv) {
            let entries = try FileManager.default.contentsOfDirectory(atPath: sitePackages)
            for entry in entries {
                let path = sitePackages + "/" + entry
                var requirement: Requirement?
                if entry.hasSuffix(".dist-info") {
                    requirement = readDistInfo(path, projectDir: projectDir)
                } else if entry.hasSuffix(".egg-info") {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                    requirement = readCoreMetadata(isDir.boolValue ? path + "/PKG-INFO" : path)
                        .map { Requirement(name: $0.name, version: $0.version, line: "\($0.name)==\($0.version)") }
                } else if entry.hasSuffix(".egg-link") {
                    requirement = readEggLink(path, projectDir: projectDir)
                }
                guard let requirement else { continue }
                let key = normalizedName(requirement.name)
                // Prefer dist-info (modern) over egg-info for the same package.
                if byName[key] == nil || entry.hasSuffix(".dist-info") { byName[key] = requirement }
            }
        }

        for (key, requirement) in byName {
            if toolingPackages.contains(key) { env.tooling.append(requirement) } else { env.requirements.append(requirement) }
        }
        env.requirements.sort { $0.name.lowercased() < $1.name.lowercased() }
        env.tooling.sort { $0.name.lowercased() < $1.name.lowercased() }
        return env
    }

    static func sitePackagesDirectories(venv: String) throws -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        var seen = Set<String>()
        let libPath = venv + "/lib"
        let versions = (try? fm.contentsOfDirectory(atPath: libPath)) ?? []
        for version in versions.sorted() where version.hasPrefix("python") || version.hasPrefix("pypy") {
            let candidate = libPath + "/" + version + "/site-packages"
            let real = (candidate as NSString).resolvingSymlinksInPath
            if fm.fileExists(atPath: candidate), seen.insert(real).inserted { result.append(candidate) }
        }
        if result.isEmpty {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: venv + "/lib",
                                                         NSLocalizedDescriptionKey: "No site-packages folder found"])
        }
        return result
    }

    static func parseConfig(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func readDistInfo(_ dir: String, projectDir: String) -> Requirement? {
        guard let meta = readCoreMetadata(dir + "/METADATA") else { return nil }
        let pinned = Requirement(name: meta.name, version: meta.version, line: "\(meta.name)==\(meta.version)")

        // PEP 610: how the package was installed if not from an index.
        guard let data = FileManager.default.contents(atPath: dir + "/direct_url.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = json["url"] as? String else { return pinned }

        if let dirInfo = json["dir_info"] as? [String: Any], dirInfo["editable"] as? Bool == true {
            let path = URL(string: url)?.path ?? url
            return Requirement(name: meta.name, version: meta.version, line: "-e " + relative(path, to: projectDir))
        }
        if let vcs = json["vcs_info"] as? [String: Any], let tool = vcs["vcs"] as? String {
            var line = "\(meta.name) @ \(tool)+\(url)"
            if let commit = vcs["commit_id"] as? String { line += "@\(commit)" }
            return Requirement(name: meta.name, version: meta.version, line: line)
        }
        return Requirement(name: meta.name, version: meta.version, line: "\(meta.name) @ \(url)")
    }

    /// Name and Version from a METADATA / PKG-INFO file (RFC 822 style headers).
    static func readCoreMetadata(_ path: String) -> (name: String, version: String)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // Headers come first; the (possibly huge) description follows after a blank line.
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var name: String?
        var version: String?
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.isEmpty { break }
            if name == nil, line.hasPrefix("Name:") {
                name = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if version == nil, line.hasPrefix("Version:") {
                version = line.dropFirst(8).trimmingCharacters(in: .whitespaces)
            }
            if name != nil, version != nil { break }
        }
        guard let name, let version, !name.isEmpty, !version.isEmpty else { return nil }
        return (name, version)
    }

    static func readEggLink(_ path: String, projectDir: String) -> Requirement? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let target = text.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return Requirement(name: name, version: "", line: "-e " + relative(target, to: projectDir))
    }

    static func relative(_ path: String, to base: String) -> String {
        let path = Paths.normalize(path)
        if path == base { return "." }
        if path.hasPrefix(base + "/") { return "./" + path.dropFirst(base.count + 1) }
        return path
    }

    /// PEP 503 normalisation, used to compare names.
    static func normalizedName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
    }

    // MARK: Writing

    public static func render(_ env: Environment, venvName: String, fileName: String, date: Date = Date()) -> String {
        let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        var lines = ["# Packages from \"\(venvName)\", \(headerTag) on \(day) before the folder was removed."]
        var about: [String] = []
        if let version = env.pythonVersion { about.append("Python \(version)") }
        if let creator = env.creator { about.append("created with \(creator)") }
        if env.usesSystemPackages { about.append("with system site-packages (not listed; they were not removed)") }
        if !about.isEmpty { lines.append("# " + about.joined(separator: ", ")) }
        if !env.tooling.isEmpty {
            lines.append("# Also installed (not pinned): " + env.tooling.map(\.line).joined(separator: ", "))
        }
        lines.append("#")
        lines.append("# Recreate it with:")
        let python = env.pythonVersion.map { "python" + $0.split(separator: ".").prefix(2).joined(separator: ".") } ?? "python3"
        let system = env.usesSystemPackages ? " --system-site-packages" : ""
        if env.creator?.hasPrefix("uv") == true {
            lines.append("#   uv venv\(system) --python \(python.dropFirst(6)) \(venvName) && uv pip install -r \(fileName) --python \(venvName)")
        } else {
            lines.append("#   \(python) -m venv\(system) \(venvName) && \(venvName)/bin/pip install -r \(fileName)")
        }
        lines.append("")
        lines.append(contentsOf: env.requirements.map(\.line))
        return lines.joined(separator: "\n") + "\n"
    }

    /// What saving a venv would do, without writing anything. Used to show it before asking.
    public struct Plan: Sendable {
        public var environment: Environment
        /// `.written(path)` here means "will be written to path".
        public var outcome: Outcome
    }

    /// Where the environment's packages would be saved.
    ///
    /// An existing `requirements.txt` is never modified: if it doesn't already pin exactly what is
    /// installed, the snapshot goes to `requirements-snapshot.txt` instead.
    public static func plan(venv: String) throws -> Plan {
        let env = try inspect(venv: venv)
        guard !env.requirements.isEmpty else { return Plan(environment: env, outcome: .empty) }

        let dir = Paths.parent(venv)
        let venvName = (venv as NSString).lastPathComponent
        let fm = FileManager.default
        var target = dir + "/requirements.txt"

        if fm.fileExists(atPath: target) {
            let existing = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
            if covers(existing: existing, env.requirements) { return Plan(environment: env, outcome: .alreadyCovered(target)) }
            let standard: Set<String> = [".venv", "venv", "env", ".env"]
            let suffix = standard.contains(venvName) ? "" : "-" + venvName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            target = dir + "/requirements-snapshot\(suffix).txt"
            var counter = 2
            while fm.fileExists(atPath: target), !isOurs(target) {
                target = dir + "/requirements-snapshot\(suffix)-\(counter).txt"
                counter += 1
            }
        }
        return Plan(environment: env, outcome: .written(target))
    }

    /// Writes the environment's packages next to the venv before it is removed. The written file
    /// gets `preserveDate` as its modification date so the snapshot doesn't make the project look active.
    public static func save(venv: String, preserveDate: Date? = nil, now: Date = Date()) throws -> Outcome {
        let plan = try plan(venv: venv)
        guard case .written(let target) = plan.outcome else { return plan.outcome }
        let venvName = (venv as NSString).lastPathComponent
        let content = render(plan.environment, venvName: venvName, fileName: (target as NSString).lastPathComponent, date: now)
        try content.write(toFile: target, atomically: true, encoding: .utf8)
        if let preserveDate {
            try? FileManager.default.setAttributes([.modificationDate: preserveDate], ofItemAtPath: target)
        }
        return .written(target)
    }

    /// True if every requirement already appears in `existing` (exact pins or identical lines).
    static func covers(existing: String, _ requirements: [Requirement]) -> Bool {
        var lines = Set<String>()
        var pins = Set<String>()
        for raw in existing.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }
            lines.insert(line)
            let parts = line.components(separatedBy: "==")
            if parts.count == 2 {
                let name = parts[0].split(separator: "[").first.map(String.init) ?? parts[0]
                pins.insert(normalizedName(name.trimmingCharacters(in: .whitespaces)) + "==" + parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return requirements.allSatisfy { req in
            lines.contains(req.line) || pins.contains(normalizedName(req.name) + "==" + req.version)
        }
    }

    static func isOurs(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 300)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return head.contains(headerTag)
    }
}
