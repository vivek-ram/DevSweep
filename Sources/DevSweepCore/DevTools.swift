import Foundation

/// A cleanup a developer tool offers, done with the tool's own command where it has one.
public struct ToolCleanup: Identifiable, Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        /// Run a command (no shell); `environment` is added to the user's.
        case command(executable: String, arguments: [String], environment: [String: String])
        /// Several commands in a row (e.g. one per simulator).
        case commands([[String]], executable: String, environment: [String: String])
        /// Move these folders to the Trash.
        case trash([String])
    }

    public let id: String
    public let tool: String
    public let title: String
    public let detail: String
    /// Estimated bytes freed (nil when the tool can't say beforehand).
    public let bytes: Int64?
    public let action: Action
    public let caution: String?
    /// Ticked by default in the list.
    public let suggested: Bool
}

public enum DevTools {
    /// Looks for every tool on this Mac and asks each what it could clean. Each probe has a
    /// timeout, so a hung tool can't stall the list.
    public static func discover(home: String = NSHomeDirectory(), now: Date = Date()) async -> [ToolCleanup] {
        await withTaskGroup(of: [ToolCleanup].self) { group in
            group.addTask { simulators(home: home, now: now) }
            group.addTask { homebrew() }
            group.addTask { docker() }
            group.addTask { ollama() }
            group.addTask { modelFolders(home: home, now: now) }
            group.addTask { versionManagers(home: home) }
            group.addTask { xcodeArchives(home: home) }
            var all: [ToolCleanup] = []
            for await items in group { all += items }
            return all.sorted { ($0.tool, -($0.bytes ?? 0)) < ($1.tool, -($1.bytes ?? 0)) }
        }
    }

    /// Runs one cleanup. Blocking.
    public static func run(_ item: ToolCleanup) -> CleanupRecord {
        var record = CleanupRecord(projectPath: item.tool, itemPath: item.title, kind: "tool:\(item.id)",
                                   bytes: item.bytes ?? 0, mode: .permanent, outcome: .removed)
        switch item.action {
        case .command(let executable, let arguments, let environment):
            let result = shell(executable, arguments, environment: environment, timeout: 600)
            if result.status != 0 {
                record.outcome = .failed
                record.message = result.output.split(separator: "\n").last.map(String.init) ?? "Exited with \(result.status)"
            }
        case .commands(let list, let executable, let environment):
            var failures = 0
            for arguments in list where shell(executable, arguments, environment: environment, timeout: 300).status != 0 {
                failures += 1
            }
            if failures == list.count {
                record.outcome = .failed
                record.message = "The tool reported an error"
            } else if failures > 0 {
                record.message = "\(failures) of \(list.count) steps failed"
            }
        case .trash(let paths):
            record.mode = .trash
            for path in paths {
                do { record.trashPath = try Cleaner.remove(path, mode: .trash) } catch {
                    record.outcome = .failed
                    record.message = error.localizedDescription
                }
            }
        }
        return record
    }

    // MARK: Xcode

    static func developerDir() -> String? {
        let fm = FileManager.default
        let candidates = ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted()
        return candidates.map { "/Applications/\($0)/Contents/Developer" }.first { fm.fileExists(atPath: $0) }
    }

    static func simulators(home: String, now: Date) -> [ToolCleanup] {
        let devices = home + "/Library/Developer/CoreSimulator/Devices"
        guard FileManager.default.fileExists(atPath: devices) else { return [] }
        guard let developer = developerDir() else {
            // Xcode is gone, so its simulators can never run again.
            let bytes = DiskUsage.freeableBytes(at: devices)
            guard bytes > 50_000_000 else { return [] }
            return [ToolCleanup(id: "sim-orphaned", tool: "Xcode", title: "Simulators from a removed Xcode",
                                detail: "Xcode isn't installed, so these simulator devices can't be used.",
                                bytes: bytes, action: .trash([devices]), caution: nil, suggested: true)]
        }
        let env = ["DEVELOPER_DIR": developer]
        var items: [ToolCleanup] = []

        let list = shell("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], environment: env, timeout: 60)
        if list.status == 0, let data = list.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let byRuntime = json["devices"] as? [String: [[String: Any]]] {
            let all = byRuntime.values.flatMap { $0 }
            let unavailable = all.filter { $0["isAvailable"] as? Bool == false }
            if !unavailable.isEmpty {
                let bytes = unavailable.compactMap { $0["dataPathSize"] as? Int64 ?? ($0["dataPathSize"] as? Int).map(Int64.init) }.reduce(0, +)
                items.append(ToolCleanup(id: "sim-unavailable", tool: "Xcode", title: "Unavailable simulators",
                                         detail: "\(unavailable.count) simulator\(unavailable.count == 1 ? "" : "s") for iOS versions that are no longer installed.",
                                         bytes: bytes, action: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"], environment: env),
                                         caution: nil, suggested: true))
            }
            // Erasing keeps the device but resets its apps and data to factory state.
            let iso = ISO8601DateFormatter()
            let stale = all.filter { device in
                guard device["isAvailable"] as? Bool == true, device["state"] as? String == "Shutdown" else { return false }
                let lastBooted = (device["lastBootedAt"] as? String).flatMap(iso.date(from:))
                return lastBooted.map { now.timeIntervalSince($0) > 30 * 86_400 } ?? true
            }
            let reclaim = stale.compactMap { device -> Int64? in
                let size = device["dataPathSize"] as? Int64 ?? (device["dataPathSize"] as? Int).map(Int64.init) ?? 0
                return max(0, size - 20_000_000)
            }.reduce(0, +)
            if reclaim > 100_000_000 {
                items.append(ToolCleanup(id: "sim-erase", tool: "Xcode", title: "Reset simulators unused for 30 days",
                                         detail: "Erases the apps and data inside \(stale.count) simulator\(stale.count == 1 ? "" : "s"). The simulators themselves stay.",
                                         bytes: reclaim,
                                         action: .commands(stale.compactMap { ($0["udid"] as? String).map { ["simctl", "erase", $0] } },
                                                           executable: "/usr/bin/xcrun", environment: env),
                                         caution: "Apps you installed in those simulators are removed.", suggested: false))
            }
        }

        // Older runtimes of a platform, when a newer one is installed.
        let runtimes = shell("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], environment: env, timeout: 60)
        if runtimes.status == 0, let data = runtimes.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            let byPlatform = Dictionary(grouping: json.values) { $0["platformIdentifier"] as? String ?? "" }
            for (_, list) in byPlatform where list.count > 1 {
                let sorted = list.sorted { ($0["version"] as? String ?? "").compare($1["version"] as? String ?? "", options: .numeric) == .orderedDescending }
                for runtime in sorted.dropFirst() where runtime["deletable"] as? Bool != false {
                    guard let id = runtime["identifier"] as? String else { continue }
                    let version = runtime["version"] as? String ?? "?"
                    let size = runtime["sizeBytes"] as? Int64 ?? (runtime["sizeBytes"] as? Int).map(Int64.init)
                    items.append(ToolCleanup(id: "runtime-\(id)", tool: "Xcode", title: "Simulator runtime \(version)",
                                             detail: "An older simulator runtime; a newer one is installed.",
                                             bytes: size, action: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", id], environment: env),
                                             caution: "Testing on \(version) needs it downloaded again.", suggested: false))
                }
            }
        }
        return items
    }

    static func xcodeArchives(home: String) -> [ToolCleanup] {
        let archives = home + "/Library/Developer/Xcode/Archives"
        guard FileManager.default.fileExists(atPath: archives) else { return [] }
        let bytes = DiskUsage.freeableBytes(at: archives)
        guard bytes > 50_000_000 else { return [] }
        return [ToolCleanup(id: "xcode-archives", tool: "Xcode", title: "Xcode archives", detail: "Builds you archived for distribution.",
                            bytes: bytes, action: .trash([archives]),
                            caution: "Archives hold the symbols needed to read crash reports of builds you shipped.", suggested: false)]
    }

    // MARK: Homebrew

    static func homebrew() -> [ToolCleanup] {
        guard let brew = which("brew") else { return [] }
        let env = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
        var items: [ToolCleanup] = []
        let cleanup = shell(brew, ["cleanup", "--prune=all", "-n"], environment: env, timeout: 120)
        if cleanup.status == 0, let bytes = parseFreeEstimate(cleanup.output), bytes > 0 {
            items.append(ToolCleanup(id: "brew-cleanup", tool: "Homebrew", title: "Old versions and downloads",
                                     detail: "Outdated package versions and cached downloads. Same as `brew cleanup --prune=all`.",
                                     bytes: bytes, action: .command(executable: brew, arguments: ["cleanup", "--prune=all"], environment: env),
                                     caution: nil, suggested: true))
        }
        let autoremove = shell(brew, ["autoremove", "-n"], environment: env, timeout: 120)
        let unused = autoremove.output.split(separator: "\n").filter { !$0.hasPrefix("==>") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if autoremove.status == 0, !unused.isEmpty {
            items.append(ToolCleanup(id: "brew-autoremove", tool: "Homebrew", title: "Unused dependencies",
                                     detail: "\(unused.count) package\(unused.count == 1 ? "" : "s") nothing depends on anymore: \(unused.prefix(4).joined(separator: ", "))\(unused.count > 4 ? "…" : "").",
                                     bytes: nil, action: .command(executable: brew, arguments: ["autoremove"], environment: env),
                                     caution: nil, suggested: false))
        }
        return items
    }

    /// "This operation would free approximately 98.7MB of disk space."
    static func parseFreeEstimate(_ output: String) -> Int64? {
        guard let range = output.range(of: #"approximately\s+([\d.]+\s*[KMGT]i?B)"#, options: .regularExpression) else { return nil }
        let match = output[range].replacingOccurrences(of: "approximately", with: "")
        return parseBytes(match)
    }

    /// "4.7 GB", "98.7MB", "512kB", "1.2GiB" → bytes.
    public static func parseBytes(_ text: some StringProtocol) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"^([\d.]+)\s*([kKMGTP]?)(i?)B$"#, options: .regularExpression),
              range.lowerBound == trimmed.startIndex else { return nil }
        let number = trimmed.prefix { "0123456789.".contains($0) }
        guard let value = Double(number) else { return nil }
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        let base: Double = unit.contains("i") ? 1024 : 1000
        let power: Double = switch unit.first?.uppercased() {
        case "K": 1
        case "M": 2
        case "G": 3
        case "T": 4
        case "P": 5
        default: 0
        }
        return Int64(value * pow(base, power))
    }

    // MARK: Docker & OrbStack

    static func docker() -> [ToolCleanup] {
        guard let docker = which("docker") else { return [] }
        let df = shell(docker, ["system", "df", "--format", "{{json .}}"], environment: [:], timeout: 30)
        guard df.status == 0 else { return [] }   // not running
        var reclaimable: [String: Int64] = [:]
        for line in df.output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = row["Type"] as? String, let text = row["Reclaimable"] as? String else { continue }
            reclaimable[type] = parseBytes(text.split(separator: "(").first ?? "")
        }
        var items: [ToolCleanup] = []
        if let build = reclaimable["Build Cache"], build > 0 {
            items.append(ToolCleanup(id: "docker-builder", tool: "Docker", title: "Build cache",
                                     detail: "Layers cached by docker build. Same as `docker builder prune`.",
                                     bytes: build, action: .command(executable: docker, arguments: ["builder", "prune", "-f"], environment: [:]),
                                     caution: nil, suggested: true))
        }
        let stopped = (reclaimable["Containers"] ?? 0) + (reclaimable["Images"] ?? 0)
        if stopped > 0 {
            items.append(ToolCleanup(id: "docker-prune", tool: "Docker", title: "Stopped containers and unused images",
                                     detail: "Same as `docker system prune -a`. Volumes (your data) are kept.",
                                     bytes: stopped, action: .command(executable: docker, arguments: ["system", "prune", "-a", "-f"], environment: [:]),
                                     caution: "Images are downloaded again the next time you need them.", suggested: false))
        }
        return items
    }

    // MARK: AI models

    static func ollama() -> [ToolCleanup] {
        guard let ollama = which("ollama") else { return [] }
        let list = shell(ollama, ["list"], environment: [:], timeout: 30)
        guard list.status == 0 else { return [] }
        return list.output.split(separator: "\n").dropFirst().compactMap { line in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 4, let name = columns.first else { return nil }
            let bytes = parseBytes("\(columns[2]) \(columns[3])")
            let modified = columns.dropFirst(4).joined(separator: " ")
            return ToolCleanup(id: "ollama-\(name)", tool: "Ollama", title: String(name), detail: "Model, updated \(modified).",
                               bytes: bytes, action: .command(executable: ollama, arguments: ["rm", String(name)], environment: [:]),
                               caution: "Download it again with `ollama pull \(name)`.", suggested: false)
        }
    }

    static func modelFolders(home: String, now: Date) -> [ToolCleanup] {
        let fm = FileManager.default
        var items: [ToolCleanup] = []
        // Hugging Face: one folder per model or dataset.
        let hub = home + "/.cache/huggingface/hub"
        for entry in (try? fm.contentsOfDirectory(atPath: hub)) ?? [] where entry.hasPrefix("models--") || entry.hasPrefix("datasets--") {
            let path = hub + "/" + entry
            let bytes = DiskUsage.freeableBytes(at: path)
            guard bytes > 100_000_000 else { continue }
            let name = entry.split(separator: "--", omittingEmptySubsequences: true).dropFirst().joined(separator: "/")
            let used = modificationDate(path + "/refs") ?? modificationDate(path) ?? now
            let idle = Int(now.timeIntervalSince(used) / 86_400)
            items.append(ToolCleanup(id: "hf-\(entry)", tool: "Hugging Face", title: name,
                                     detail: (entry.hasPrefix("datasets") ? "Dataset" : "Model") + ", last updated \(Format.idle(since: used, now: now).lowercased()).",
                                     bytes: bytes, action: .trash([path]), caution: "Downloaded again the next time code loads it.",
                                     suggested: idle > 90))
        }
        // LM Studio: publisher/model folders.
        for base in [home + "/.lmstudio/models", home + "/.cache/lm-studio/models"] {
            for publisher in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where !publisher.hasPrefix(".") {
                for model in (try? fm.contentsOfDirectory(atPath: base + "/" + publisher)) ?? [] where !model.hasPrefix(".") {
                    let path = base + "/" + publisher + "/" + model
                    let bytes = DiskUsage.freeableBytes(at: path)
                    guard bytes > 100_000_000 else { continue }
                    items.append(ToolCleanup(id: "lms-\(publisher)/\(model)", tool: "LM Studio", title: "\(publisher)/\(model)",
                                             detail: "Local model.", bytes: bytes, action: .trash([path]),
                                             caution: "Download it again from LM Studio.", suggested: false))
                }
            }
        }
        return items
    }

    // MARK: Language version managers

    static func versionManagers(home: String) -> [ToolCleanup] {
        let fm = FileManager.default
        var items: [ToolCleanup] = []

        // nvm: every Node version except the default alias and the one on PATH.
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm), versions.count > 1 {
            let alias = (try? String(contentsOfFile: home + "/.nvm/alias/default", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let current = which("node").flatMap { Paths.isInside($0, nvm) ? $0.split(separator: "/").first { $0.hasPrefix("v") }.map(String.init) : nil }
            let newest = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.first
            for version in versions where version != current && version != newest && !version.hasPrefix("v" + alias) && version != alias {
                let path = nvm + "/" + version
                items.append(ToolCleanup(id: "nvm-\(version)", tool: "Node (nvm)", title: "Node \(version)",
                                         detail: "Not your default or newest Node version.", bytes: DiskUsage.freeableBytes(at: path),
                                         action: .trash([path]), caution: "Projects pinned to it (.nvmrc) need `nvm install`.", suggested: false))
            }
        }

        // pyenv: every Python except the global one.
        let pyenv = home + "/.pyenv/versions"
        if let versions = try? fm.contentsOfDirectory(atPath: pyenv), versions.count > 1 {
            let global = (try? String(contentsOfFile: home + "/.pyenv/version", encoding: .utf8))?
                .split(whereSeparator: \.isNewline).map(String.init) ?? []
            for version in versions where !global.contains(version) && !version.hasPrefix(".") {
                let path = pyenv + "/" + version
                items.append(ToolCleanup(id: "pyenv-\(version)", tool: "Python (pyenv)", title: "Python \(version)",
                                         detail: "Not your global Python version.", bytes: DiskUsage.freeableBytes(at: path),
                                         action: .trash([path]), caution: "Projects with a .python-version for it, and virtual environments made from it, stop working.",
                                         suggested: false))
            }
        }

        // rustup: toolchains other than the default.
        let toolchains = home + "/.rustup/toolchains"
        if let installed = try? fm.contentsOfDirectory(atPath: toolchains), installed.count > 1, let rustup = which("rustup") {
            let settings = (try? String(contentsOfFile: home + "/.rustup/settings.toml", encoding: .utf8)) ?? ""
            let fallback = settings.split(separator: "\n").first { $0.hasPrefix("default_toolchain") }?
                .split(separator: "\"").dropFirst().first.map(String.init) ?? ""
            for name in installed where name != fallback && !name.hasPrefix(".") {
                items.append(ToolCleanup(id: "rustup-\(name)", tool: "Rust", title: "Toolchain \(name)",
                                         detail: "Not your default Rust toolchain.", bytes: DiskUsage.freeableBytes(at: toolchains + "/" + name),
                                         action: .command(executable: rustup, arguments: ["toolchain", "uninstall", name], environment: [:]),
                                         caution: "Projects with a rust-toolchain file for it reinstall it on the next build.", suggested: false))
            }
        }

        // Gradle wrapper: keep the newest distribution.
        let dists = home + "/.gradle/wrapper/dists"
        if let versions = try? fm.contentsOfDirectory(atPath: dists), versions.count > 1 {
            for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }).dropFirst() where !version.hasPrefix(".") {
                let path = dists + "/" + version
                items.append(ToolCleanup(id: "gradle-\(version)", tool: "Gradle", title: version,
                                         detail: "An older Gradle distribution downloaded by a project's wrapper.",
                                         bytes: DiskUsage.freeableBytes(at: path), action: .trash([path]), caution: nil, suggested: true))
            }
        }
        return items.filter { ($0.bytes ?? 1) > 0 }
    }

    // MARK: Running tools

    /// Finds a tool on the PATH a login shell would have (apps don't inherit it).
    public static func which(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.cargo/bin", home + "/.local/bin", home + "/.orbstack/bin",
               "/Applications/Docker.app/Contents/Resources/bin", "/usr/bin"]
        return dirs.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func shell(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval)
        -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", NSHomeDirectory() + "/.cargo/bin", env["PATH"] ?? ""]
            .joined(separator: ":")
        env.merge(environment) { $1 }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }

        var output = Data()
        let reader = DispatchQueue(label: "devsweep.shell")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            return (-2, "Timed out")
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
