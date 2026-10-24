import CoreServices
import DevSweepCore
import Foundation

let usage = """
usage: devsweep-cli <command> [options]

commands:
  scan <folder>...        List projects and how much each can free
  clean <folder>...       Clean projects idle longer than the retention period
                          (prints a plan; add --yes to actually clean)
  snapshot <venv>         Print a venv's packages as requirements.txt
  caches                  List global developer caches and their sizes
  storage [folder]        What's using space (default: your home folder)
  junk                    App caches, logs, old installers and other junk
  apps                    Installed apps with their support files
  leftovers               Support files of apps that are no longer installed
  dupes [folder]...       Duplicate files (default: Desktop, Documents, Downloads, …)
  tools                   Cleanups offered by Xcode, Homebrew, Docker, Ollama, …
  login-items             Background items that start with your Mac
  stats                   CPU, memory, network and battery right now
  top                     Apps using the most memory and CPU (helpers included)
  privacy                 Browser history, cookies and site data, per browser
  updates                 Apps with a newer version (App Store, Sparkle, Homebrew)
  cloud                   Cloud files that also take space on this Mac
  downloads               Downloads grouped by the app or site they came from
  similar                 Similar photos in Pictures, Desktop, Documents, Downloads
  maintenance             Purgeable space and local Time Machine snapshots

options:
  --days N                Retention period in days (default 30)
  --permanent             Delete instead of moving to the Trash
  --yes                   Really clean (clean only)
  --include-venvs         Also remove Python virtual environments (clean only;
                          they are kept unless you ask, packages saved first)
  --json                  Machine-readable output (scan only)
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

guard !args.isEmpty else { fail(usage) }
let command = args.removeFirst()
let days = Int(option("--days") ?? "30") ?? 30
let permanent = flag("--permanent")
let confirmed = flag("--yes")
let includeVenvs = flag("--include-venvs")
let json = flag("--json")
let policy = RetentionPolicy(days: days, lowSpaceBoost: false)

func scan(_ folders: [String]) async throws -> ScanResult {
    guard !folders.isEmpty else { fail("Give at least one folder to scan.") }
    return try await ProjectScanner().scan(roots: folders)
}

switch command {
case "scan":
    let result = try await scan(args)
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
        break
    }
    print(pad("PROJECT", 44), pad("LAST ACTIVE", 16), pad("STATUS", 14), lpad("SIZE", 10), " CONTENTS")
    for project in result.projects {
        let status: String
        switch policy.status(of: project) {
        case .protected: status = "protected"
        case .stale(let idle): status = "stale (\(idle)d)"
        case .active(let left): status = "active (\(left)d)"
        }
        let kinds = Set(project.artifacts.map(\.kind.ecosystem.shortLabel)).sorted().joined(separator: ",")
        print(pad(project.displayPath, 44), pad(Format.idle(since: project.lastActivity), 16), pad(status, 14),
              lpad(Format.bytes(project.totalBytes), 10), " " + kinds)
    }
    let total = result.projects.reduce(0) { $0 + $1.totalBytes }
    let stale = result.projects.filter { policy.status(of: $0).isStale }.reduce(0) { $0 + $1.totalBytes }
    print("\n\(result.projects.count) projects · \(Format.bytes(total)) regenerable · \(Format.bytes(stale)) idle > \(days) days · \(result.foldersVisited) folders in \(String(format: "%.1f", result.duration))s")

case "clean":
    let result = try await scan(args)
    let stale = result.projects.filter { policy.status(of: $0).isStale }
    guard !stale.isEmpty else { print("Nothing idle for more than \(days) days."); break }
    let options = CleanOptions(mode: permanent ? .permanent : .trash, dryRun: !confirmed)
    var freed: Int64 = 0
    for project in stale {
        print("\(project.displayPath)  (idle since \(Format.idle(since: project.lastActivity)))")
        let all = policy.cleanableArtifacts(of: project)
        let approved = Set(includeVenvs ? all.filter { $0.kind == .pythonVenv }.map(\.path) : [])
        for venv in all where venv.kind == .pythonVenv && !approved.contains(venv.path) {
            print("  \(pad("kept", 13)) \(lpad(Format.bytes(venv.bytes), 10))  \(project.relativePath(of: venv))  (virtual environment: add --include-venvs to remove)")
        }
        let chosen = Cleaner.applyingVenvApproval(all, askBeforeVenvs: true, approvedVenvs: approved)
        for record in Cleaner.clean(chosen, in: project, options: options) {
            let state = confirmed ? record.outcome.rawValue : "would remove"
            var line = "  \(pad(state, 13)) \(lpad(Format.bytes(record.bytes), 10))  \(project.relativePath(record.itemPath))"
            if let snapshot = record.snapshotPath { line += "  → saved \((snapshot as NSString).lastPathComponent)" }
            if let message = record.message, confirmed || record.message != "Dry run" { line += "  (\(message))" }
            print(line)
            if record.outcome == .removed { freed += record.bytes }
        }
    }
    if confirmed {
        print("\nFreed \(Format.bytes(freed))\(permanent ? "" : " (moved to the Trash)").")
    } else {
        print("\nDry run. Re-run with --yes to clean.")
    }

case "snapshot":
    guard let venv = args.first else { fail("Give the path of a virtual environment.") }
    let path = Paths.normalize(venv)
    let env = try PythonSnapshot.inspect(venv: path)
    print(PythonSnapshot.render(env, venvName: (path as NSString).lastPathComponent, fileName: "requirements.txt"), terminator: "")

case "caches":
    var total: Int64 = 0
    for cache in CacheCatalog.installed() {
        let bytes = DiskUsage.freeableBytes(at: cache.path)
        total += bytes
        print(lpad(Format.bytes(bytes), 10), " ", pad(cache.name, 26), cache.displayPath)
    }
    print("\n\(Format.bytes(total)) in developer caches")

case "storage":
    let root = Paths.normalize(args.first ?? NSHomeDirectory())
    let result = try await StorageScanner().scan(root: root)
    print("\(Format.bytes(result.root.size)) in \(result.root.fileCount.formatted()) files under \(Paths.display(root)) (\(String(format: "%.1f", result.duration))s)\n")
    func show(_ node: StorageNode, depth: Int) {
        for child in node.children.prefix(depth == 0 ? 15 : 5) {
            var line = String(repeating: "  ", count: depth) + lpad(Format.bytes(child.size), 10) + "  " + child.name
            if child.note == .needsFullDiskAccess { line += "  (needs Full Disk Access)" }
            if let kind = child.artifactKind { line += "  [\(kind.displayName)]" }
            print(line)
            if depth == 0, child.isDirectory, !child.isPackage { show(child, depth: 1) }
        }
    }
    show(result.root, depth: 0)
    print("\nLargest files:")
    for file in result.largeFiles.prefix(10) {
        print(lpad(Format.bytes(file.size), 10), " ", Paths.display(file.path))
    }
    if !result.restricted.isEmpty {
        print("\nNot measured without Full Disk Access: " + result.restricted.map(Paths.display).joined(separator: ", "))
    }

case "junk":
    let items = JunkScanner.scan()
    for category in JunkCategory.allCases {
        let group = items.filter { $0.category == category }
        guard !group.isEmpty else { continue }
        print("\(category.title): \(Format.bytes(group.reduce(0) { $0 + $1.bytes }))")
        for item in group.prefix(8) {
            print("  \(item.suggested ? "•" : " ") \(lpad(Format.bytes(item.bytes), 10))  \(Paths.display(item.path))")
        }
    }

case "apps":
    for var app in AppInventory.installedApps() {
        app.appBytes = DiskUsage.freeableBytes(at: app.path)
        let files = AppInventory.files(for: app)
        let support = files.reduce(0) { $0 + $1.bytes }
        let used = AppInventory.lastUsed(app, files: files).map { Format.idle(since: $0) } ?? "never"
        print(lpad(Format.bytes(app.appBytes), 10), "+", lpad(Format.bytes(support), 9), " ", pad(app.name, 26), pad(used, 14), "\(files.count) support items")
    }

case "leftovers":
    let installed = AppInventory.installedApps()
    let leftovers = AppInventory.leftovers(installed: installed, isInstalled: { id in
        LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() != nil
    })
    for leftover in leftovers {
        print(lpad(Format.bytes(leftover.bytes), 10), " ", pad(leftover.identifier, 44), leftover.vendorStillInstalled ? "(vendor still installed)" : "")
        for file in leftover.files.prefix(4) { print("             ", Paths.display(file.path)) }
    }

case "dupes":
    let roots = args.isEmpty ? DuplicateFinder.defaultFolders() : args.map(Paths.normalize)
    let started = Date()
    let groups = try await DuplicateFinder().find(in: roots)
    for group in groups.prefix(15) {
        print("\(Format.bytes(group.wasted)) wasted · \(group.files.count) × \(Format.bytes(group.size))  \(group.files[0].name)")
        for file in group.files { print("    ", Paths.display(file.path)) }
    }
    print("\n\(groups.count) groups · \(Format.bytes(groups.reduce(0) { $0 + $1.wasted })) could be freed · \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

case "tools":
    for item in await DevTools.discover() {
        print(lpad(item.bytes.map(Format.bytes) ?? "?", 10), " ", pad(item.tool, 16), pad(item.title, 40), item.suggested ? "suggested" : "")
    }

case "login-items":
    for item in LaunchItems.list() {
        var flags: [String] = []
        if item.isBroken { flags.append("BROKEN (program missing)") }
        if item.isDisabled { flags.append("disabled") }
        if item.isLoaded == true { flags.append("running") }
        print(pad(item.scope.rawValue, 9), pad(item.label, 50), flags.joined(separator: ", "))
    }

case "stats":
    let sampler = SystemSampler()
    _ = sampler.sample()
    try await Task.sleep(for: .seconds(1))
    let s = sampler.sample()
    print("CPU \(Int(s.cpu * 100))% · Memory \(Format.bytes(s.memoryUsed)) of \(Format.bytes(s.memoryTotal)) (\(s.pressure)) · Swap \(Format.bytes(s.swapUsed))")
    print("Network ↓ \(Format.bytes(Int64(s.networkIn)))/s ↑ \(Format.bytes(Int64(s.networkOut)))/s")
    if let b = s.battery {
        print("Battery \(b.percent)%\(b.charging ? " charging" : "") · cycles \(b.cycleCount.map(String.init) ?? "?") · health \(b.health.map { "\($0)%" } ?? "?")")
    }

case "privacy":
    for item in PrivacyScanner.scan() {
        print(lpad(Format.bytes(item.bytes), 10), " ", pad(item.browser.name, 16), pad(item.profileName, 14), item.kind.title)
    }
    for list in PrivacyScanner.recentItemsLists() { print("   recent:", list.title) }
    if let permissions = Permissions.list() {
        print("\n\(permissions.count) app permissions:")
        for p in permissions.prefix(15) { print("  ", pad(p.serviceTitle, 22), p.allowed ? "allowed" : "denied ", p.client) }
    } else {
        print("\nApp permissions: needs Full Disk Access")
    }

case "updates":
    let started = Date()
    let updates = await UpdateChecker.check(AppInventory.installedApps())
    for u in updates { print(pad(u.name, 26), pad(u.installedVersion, 14), "→", pad(u.newVersion, 14), u.sourceTitle) }
    print("\n\(updates.count) updates · \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

case "cloud":
    for location in CloudCleanup.locations() {
        let files = (try? CloudCleanup.localCopies(in: location)) ?? []
        print("\(location.provider.title) (\(Paths.display(location.path))): \(files.count) local copies, \(Format.bytes(files.reduce(0) { $0 + $1.bytes }))")
        for f in files.prefix(5) { print("   ", lpad(Format.bytes(f.bytes), 10), f.name) }
    }

case "downloads":
    let items = DownloadsAnalyzer.scan()
    for (source, group) in Dictionary(grouping: items, by: \.source).sorted(by: { $0.value.count > $1.value.count }) {
        print("\(source): \(group.count) items, \(Format.bytes(group.reduce(0) { $0 + $1.bytes }))")
    }

case "similar":
    let roots = args.isEmpty ? [NSHomeDirectory() + "/Pictures", NSHomeDirectory() + "/Desktop", NSHomeDirectory() + "/Downloads"] : args.map(Paths.normalize)
    let started = Date()
    let groups = try await SimilarImageFinder().find(in: roots)
    for g in groups.prefix(8) {
        print("\(g.images.count) similar · \(Format.bytes(g.reclaimable)) · keep \((g.best as NSString).lastPathComponent)")
        for i in g.images { print("    ", i.flaw == nil ? " " : "~", Paths.display(i.path)) }
    }
    print("\n\(groups.count) groups · \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

case "top":
    let sampler = ProcessSampler()
    _ = sampler.sample()
    if args.contains("--bench") {
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }
        let before = cpuSeconds(), started = Date()
        for _ in 0..<10 { _ = sampler.sample() }
        print(String(format: "per sample: %.1f ms CPU, %.1f ms wall", (cpuSeconds() - before) * 100, Date().timeIntervalSince(started) * 100))
        exit(0)
    }
    try await Task.sleep(for: .seconds(1))
    let apps = sampler.sample()
    let snapshot = SystemSampler().sample()
    print("Memory used \(Format.bytes(snapshot.memoryUsed)) of \(Format.bytes(snapshot.memoryTotal)) · apps \(Format.bytes(snapshot.memoryApp)) · wired \(Format.bytes(snapshot.memoryWired)) · compressed \(Format.bytes(snapshot.memoryCompressed)) · cached \(Format.bytes(snapshot.memoryCached))")
    for app in apps.prefix(15) {
        print(String(format: "%10@  %5.1f%% CPU  %3d proc  %@", Format.bytes(app.memory), app.cpu * 100, app.processCount, app.name))
    }
case "maintenance":
    print("Purgeable:", Maintenance.purgeableBytes().map(Format.bytes) ?? "?")
    print("Local snapshots:", Maintenance.localSnapshots().count)
    for v in Volumes.external() { print("Drive:", v.name, Format.bytes(v.available), "free of", Format.bytes(v.total), v.ejectable ? "(ejectable)" : "") }

default:
    fail(usage)
}
