#if DEBUG
import Foundation

/// Made-up but realistic data for the README screenshots, so no real projects, files, apps or
/// names end up in them. Paths sit under the home folder (they show as ~/…) but don't exist.
/// Debug builds only.
public enum DemoData {
    static let gb: Int64 = 1_000_000_000
    static let mb: Int64 = 1_000_000
    static var home: String { Paths.home }
    static func ago(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }

    public static var disk: VolumeSpace { VolumeSpace(total: 494_380_000_000, available: 61_240_000_000) }

    public static var projectRoot: String { home + "/Developer" }

    // MARK: Projects

    public static func projects() -> [Project] {
        func project(_ name: String, edited: Double, opened: Double? = nil, editor: String? = nil,
                     _ artifacts: [(String, ArtifactKind, Int64)]) -> Project {
            let path = projectRoot + "/" + name
            return Project(path: path, root: projectRoot,
                           artifacts: artifacts.map { Artifact(path: path + "/" + $0.0, kind: $0.1, bytes: $0.2, modified: ago(edited + 2)) },
                           lastEdited: ago(edited), lastOpened: opened.map(ago), openedWith: editor,
                           lastBuilt: ago(edited + 1), isGitRepo: true)
        }
        return [
            project("rust-cli", edited: 2, opened: 0.2, editor: "Visual Studio Code", [("target", .rustTarget, 6_840 * mb)]),
            project("ml-experiments", edited: 94, [(".venv", .pythonVenv, 3_120 * mb), ("src/__pycache__", .pythonCache, 14 * mb)]),
            project("api-gateway", edited: 1, opened: 0.1, editor: "Cursor", [("target", .rustTarget, 2_410 * mb)]),
            project("ios-habit-tracker", edited: 9, opened: 3, editor: "Xcode", [(".build", .swiftBuild, 1_870 * mb), ("Pods", .cocoaPods, 520 * mb)]),
            project("weather-app", edited: 63, [("node_modules", .nodeModules, 1_420 * mb), (".next", .jsBuildCache, 380 * mb)]),
            project("chat-bot", edited: 41, [(".venv", .pythonVenv, 1_180 * mb), ("web/node_modules", .nodeModules, 450 * mb)]),
            project("flutter-notes", edited: 24, opened: 12, editor: "Visual Studio Code", [(".dart_tool", .dartTool, 1_090 * mb)]),
            project("old-dashboard", edited: 212, [("node_modules", .nodeModules, 980 * mb)]),
            project("data-pipeline", edited: 17, opened: 5, editor: "Visual Studio Code", [(".venv", .pythonVenv, 860 * mb)]),
            project("game-jam-2024", edited: 140, [("build", .gradleBuild, 730 * mb)]),
            project("portfolio-site", edited: 0.3, opened: 0.1, editor: "Cursor", [("node_modules", .nodeModules, 640 * mb), (".next", .jsBuildCache, 210 * mb)]),
        ]
    }

    // MARK: Junk

    public static func junk() -> [JunkItem] {
        let caches = home + "/Library/Caches"
        let support = home + "/Library/Application Support"
        var items: [JunkItem] = [
            JunkItem(category: .appCaches, path: caches + "/com.google.Chrome", bytes: 2_840 * mb, modified: ago(1), suggested: true),
            JunkItem(category: .appCaches, path: caches + "/com.spotify.client", bytes: 1_620 * mb, modified: ago(3), suggested: true, label: "Spotify"),
            JunkItem(category: .appCaches, path: caches + "/com.tinyspeck.slackmacgap", bytes: 910 * mb, modified: ago(1), suggested: true, label: "Slack"),
            JunkItem(category: .appCaches, path: caches + "/com.figma.Desktop", bytes: 760 * mb, modified: ago(6), suggested: true, label: "Figma"),
            JunkItem(category: .appCaches, path: caches + "/com.microsoft.VSCode.ShipIt", bytes: 640 * mb, modified: ago(12), suggested: true),
            JunkItem(category: .appCaches, path: caches + "/us.zoom.xos", bytes: 420 * mb, modified: ago(9), suggested: true, label: "Zoom"),
            JunkItem(category: .appCaches, path: caches + "/org.mozilla.firefox", bytes: 380 * mb, modified: ago(2), suggested: true),
            JunkItem(category: .aiClutter, path: support + "/Claude/Cache", bytes: 640 * mb, modified: ago(1), suggested: true, label: "Claude · Cache"),
            JunkItem(category: .aiClutter, path: support + "/Cursor/Code Cache", bytes: 410 * mb, modified: ago(1), suggested: true, label: "Cursor · Code Cache"),
            JunkItem(category: .aiClutter, path: support + "/ChatGPT/GPUCache", bytes: 120 * mb, modified: ago(4), suggested: true, label: "ChatGPT · GPUCache"),
            JunkItem(category: .aiClutter, path: home + "/.codex/log", bytes: 22 * mb, modified: ago(2), suggested: true, label: "Codex · Logs"),
            JunkItem(category: .logs, path: home + "/Library/Logs/DiagnosticReports", bytes: 184 * mb, modified: ago(5), suggested: true),
            JunkItem(category: .logs, path: home + "/Library/Logs/JetBrains", bytes: 92 * mb, modified: ago(30), suggested: true),
            JunkItem(category: .brokenPreferences, path: home + "/Library/Preferences/com.oldvendor.helper.plist", bytes: 4_096, modified: ago(400), suggested: true),
            JunkItem(category: .installers, path: home + "/Downloads/Docker.dmg", bytes: 612 * mb, modified: ago(88), suggested: true),
            JunkItem(category: .installers, path: home + "/Downloads/zoomusInstallerFull.pkg", bytes: 121 * mb, modified: ago(140), suggested: true),
            JunkItem(category: .installers, path: home + "/Downloads/node-v22.11.0.pkg", bytes: 79 * mb, modified: ago(6), suggested: false),
            JunkItem(category: .deviceUpdates, path: home + "/Library/iTunes/iPhone Software Updates/iPhone16,1_18.1_Restore.ipsw",
                     bytes: 7_240 * mb, modified: ago(160), suggested: true),
            JunkItem(category: .archives, path: home + "/Downloads/photos-export.zip", bytes: 1_380 * mb, modified: ago(48), suggested: false),
            JunkItem(category: .archives, path: home + "/Downloads/dataset-2025.tar.gz", bytes: 640 * mb, modified: ago(75), suggested: false),
            JunkItem(category: .trash, path: home + "/.Trash", bytes: 2_310 * mb, modified: ago(1), suggested: true),
        ]
        var backup = JunkItem(category: .deviceBackups, path: support + "/MobileSync/Backup/00008110-DEMO", bytes: 9_820 * mb,
                              modified: ago(210), suggested: false, label: "iPhone · 12 Mar 2026")
        backup.caution = "An older backup; the newest backup of this iPhone is kept"
        items.append(backup)
        return items
    }

    // MARK: Developer caches

    public static func caches() -> [DevCache] {
        let sizes: [String: Int64] = [
            "derived-data": 9_420 * mb, "device-support": 4_810 * mb, "simulator-caches": 1_230 * mb, "npm": 2_160 * mb,
            "pnpm": 1_370 * mb, "yarn": 640 * mb, "pip": 1_810 * mb, "uv": 920 * mb, "cargo-registry": 1_540 * mb,
            "gradle": 1_290 * mb, "homebrew": 1_120 * mb, "huggingface": 3_880 * mb, "playwright": 870 * mb, "cocoapods": 410 * mb,
        ]
        return CacheCatalog.all(home: home)
            .compactMap { cache in sizes[cache.id].map { var c = cache; c.bytes = $0; return c } }
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    // MARK: Storage map

    public static func storage() -> StorageScanResult {
        func file(_ name: String, in folder: String, _ size: Int64, days: Double = 30) -> StorageNode {
            let node = StorageNode(name: name, path: folder + "/" + name, isDirectory: false, size: size, modified: ago(days))
            node.fileCount = 1
            return node
        }
        func folder(_ name: String, in parent: String, extra: Int64 = 0, files: Int, package: Bool = false,
                    kind: ArtifactKind? = nil, _ children: (String) -> [StorageNode] = { _ in [] }) -> StorageNode {
            let path = parent + "/" + name
            let node = StorageNode(name: name, path: path, isDirectory: true, isPackage: package, size: extra, modified: ago(3))
            node.fileCount = files
            node.artifactKind = kind
            for child in children(path) { node.add(child) }
            node.finalize()
            return node
        }

        let root = StorageNode(name: "Home", path: home, isDirectory: true, size: 640 * mb, modified: ago(0))
        root.fileCount = 2_400
        let library = folder("Library", in: home, extra: 3_100 * mb, files: 412_000) { p in [
            folder("Application Support", in: p, extra: 4_200 * mb, files: 98_000) { p in [
                folder("Google", in: p, extra: 3_400 * mb, files: 21_000),
                folder("Slack", in: p, extra: 2_100 * mb, files: 9_800),
                folder("Spotify", in: p, extra: 1_900 * mb, files: 4_100),
                folder("Code", in: p, extra: 1_300 * mb, files: 12_000),
                folder("Claude", in: p, extra: 1_100 * mb, files: 3_900),
                folder("MobileSync", in: p, extra: 9_820 * mb, files: 41_000),
            ] },
            folder("Caches", in: p, extra: 2_900 * mb, files: 140_000) { p in [
                folder("com.google.Chrome", in: p, extra: 2_840 * mb, files: 18_000),
                folder("com.spotify.client", in: p, extra: 1_620 * mb, files: 2_300),
                folder("Homebrew", in: p, extra: 1_120 * mb, files: 300),
                folder("pip", in: p, extra: 1_810 * mb, files: 9_100),
            ] },
            folder("Developer", in: p, extra: 600 * mb, files: 160_000) { p in [
                folder("Xcode", in: p, extra: 14_230 * mb, files: 88_000),
                folder("CoreSimulator", in: p, extra: 8_740 * mb, files: 51_000),
            ] },
            folder("Containers", in: p, extra: 3_200 * mb, files: 22_000),
            folder("Mail", in: p, extra: 1_700 * mb, files: 31_000),
        ] }
        let developer = folder("Developer", in: home, extra: 1_900 * mb, files: 380_000) { p in
            projects().map { project in
                folder(project.name, in: p, extra: 180 * mb, files: 4_000) { p in
                    project.artifacts.map { artifact in
                        folder(project.relativePath(of: artifact), in: p, extra: artifact.bytes, files: 12_000, kind: artifact.kind)
                    }
                }
            }
        }
        let movies = folder("Movies", in: home, extra: 600 * mb, files: 140) { p in [
            file("Iceland trip 4K.mov", in: p, 8_420 * mb, days: 210),
            folder("Screen Recordings", in: p, extra: 3_240 * mb, files: 46),
            file("Conference talk 2025.mp4", in: p, 2_910 * mb, days: 300),
            folder("Final Cut Projects", in: p, extra: 6_100 * mb, files: 2_300),
        ] }
        let downloads = folder("Downloads", in: home, extra: 2_300 * mb, files: 860) { p in [
            file("Xcode_16.2.xip", in: p, 3_120 * mb, days: 95),
            file("ubuntu-24.04-desktop-arm64.iso", in: p, 2_760 * mb, days: 120),
            file("photos-export.zip", in: p, 1_380 * mb, days: 48),
            file("Docker.dmg", in: p, 612 * mb, days: 88),
            folder("Course videos", in: p, extra: 4_100 * mb, files: 64),
            file("dataset-2025.tar.gz", in: p, 640 * mb, days: 75),
        ] }
        let pictures = folder("Pictures", in: home, extra: 500 * mb, files: 1_900) { p in [
            folder("Photos Library.photoslibrary", in: p, extra: 12_900 * mb, files: 48_000, package: true),
            folder("Exports", in: p, extra: 1_100 * mb, files: 840),
        ] }
        let documents = folder("Documents", in: home, extra: 1_400 * mb, files: 12_000) { p in [
            folder("Work", in: p, extra: 3_300 * mb, files: 4_100),
            folder("Design assets", in: p, extra: 2_600 * mb, files: 1_900),
            folder("Taxes", in: p, extra: 420 * mb, files: 310),
        ] }
        let music = folder("Music", in: home, extra: 5_200 * mb, files: 3_800)
        let desktop = folder("Desktop", in: home, extra: 1_240 * mb, files: 210)
        let hidden = [
            folder(".rustup", in: home, extra: 2_430 * mb, files: 66_000),
            folder(".cargo", in: home, extra: 1_610 * mb, files: 39_000),
            folder(".gradle", in: home, extra: 1_290 * mb, files: 21_000),
            folder(".npm", in: home, extra: 2_160 * mb, files: 41_000),
            folder(".cache", in: home, extra: 4_800 * mb, files: 9_000),
            folder(".ollama", in: home, extra: 8_900 * mb, files: 40),
        ]
        for node in [library, developer, movies, downloads, pictures, documents, music, desktop] + hidden { root.add(node) }
        root.finalize()

        let largeFiles: [LargeFile] = [
            LargeFile(path: home + "/Movies/Iceland trip 4K.mov", size: 8_420 * mb, modified: ago(210), place: .media),
            LargeFile(path: home + "/Downloads/Xcode_16.2.xip", size: 3_120 * mb, modified: ago(95), place: .downloads),
            LargeFile(path: home + "/Movies/Conference talk 2025.mp4", size: 2_910 * mb, modified: ago(300), place: .media),
            LargeFile(path: home + "/Downloads/ubuntu-24.04-desktop-arm64.iso", size: 2_760 * mb, modified: ago(120), place: .downloads),
            LargeFile(path: home + "/Documents/Design assets/brand-shoot-raw.zip", size: 1_840 * mb, modified: ago(260), place: .documents),
            LargeFile(path: home + "/Downloads/photos-export.zip", size: 1_380 * mb, modified: ago(48), place: .downloads),
            LargeFile(path: home + "/Movies/Screen Recordings/Product demo.mov", size: 1_210 * mb, modified: ago(33), place: .media),
            LargeFile(path: home + "/Developer/ml-experiments/data/train.parquet", size: 980 * mb, modified: ago(94), place: .other),
            LargeFile(path: home + "/Documents/Work/Q3 all-hands recording.mp4", size: 940 * mb, modified: ago(70), place: .documents),
            LargeFile(path: home + "/Downloads/dataset-2025.tar.gz", size: 640 * mb, modified: ago(75), place: .downloads),
            LargeFile(path: home + "/Downloads/Docker.dmg", size: 612 * mb, modified: ago(88), place: .downloads),
            LargeFile(path: home + "/Music/Podcast masters/Episode 42.wav", size: 540 * mb, modified: ago(150), place: .media),
            LargeFile(path: home + "/Desktop/Wallpapers 8K.zip", size: 410 * mb, modified: ago(400), place: .documents),
            LargeFile(path: home + "/Documents/Taxes/2025 scans.pdf", size: 210 * mb, modified: ago(190), place: .documents),
        ]
        return StorageScanResult(root: root, largeFiles: largeFiles, date: ago(0.01), duration: 14.2, restricted: [])
    }

    // MARK: Apps

    /// Apps whose real icons exist on most Macs that have them; sizes are made up.
    public static func apps() -> [(app: InstalledApp, files: [AppFile])] {
        let library = home + "/Library"
        func app(_ path: String, _ name: String, _ id: String, version: String, bytes: Int64, used: Double?, store: Bool = false,
                 _ files: [(String, AppFile.Kind, Int64)]) -> (app: InstalledApp, files: [AppFile]) {
            (InstalledApp(path: path, name: name, bundleID: id, bundleName: name, version: version, isAppStore: store,
                          appBytes: bytes, lastUsed: used.map(ago)),
             files.map { AppFile(path: library + "/" + $0.0, kind: $0.1, bytes: $0.2) })
        }
        return [
            app("/Applications/Xcode.app", "Xcode", "com.apple.dt.Xcode", version: "16.2", bytes: 12_930 * mb, used: 1, store: true, [
                ("Developer/Xcode/UserData", .appSupport, 210 * mb), ("Caches/com.apple.dt.Xcode", .caches, 1_240 * mb),
                ("Preferences/com.apple.dt.Xcode.plist", .preferences, 1 * mb),
            ]),
            app("/Applications/Google Chrome.app", "Google Chrome", "com.google.Chrome", version: "131.0", bytes: 1_310 * mb, used: 0.1, [
                ("Application Support/Google/Chrome", .appSupport, 3_120 * mb), ("Caches/com.google.Chrome", .caches, 820 * mb),
                ("HTTPStorages/com.google.Chrome", .webData, 9 * mb), ("Saved Application State/com.google.Chrome.savedState", .savedState, 2 * mb),
                ("Preferences/com.google.Chrome.plist", .preferences, 12_000),
            ]),
            app("/Applications/Visual Studio Code.app", "Visual Studio Code", "com.microsoft.VSCode", version: "1.96.2", bytes: 620 * mb, used: 0.2, [
                ("Application Support/Code", .appSupport, 1_090 * mb), ("Caches/com.microsoft.VSCode.ShipIt", .caches, 640 * mb),
                ("Preferences/com.microsoft.VSCode.plist", .preferences, 8_000),
            ]),
            app("/Applications/Firefox.app", "Firefox", "org.mozilla.firefox", version: "133.0", bytes: 390 * mb, used: 6, [
                ("Application Support/Firefox", .appSupport, 820 * mb), ("Caches/org.mozilla.firefox", .caches, 380 * mb),
            ]),
            app("/Applications/Obsidian.app", "Obsidian", "md.obsidian", version: "1.7.7", bytes: 330 * mb, used: 2, [
                ("Application Support/obsidian", .appSupport, 140 * mb),
            ]),
            app("/Applications/The Unarchiver.app", "The Unarchiver", "com.macpaw.site.theunarchiver", version: "4.3.8", bytes: 61 * mb,
                used: 120, store: true, [("Containers/com.macpaw.site.theunarchiver", .containers, 12 * mb)]),
        ]
    }

    public static func leftovers() -> [Leftover] {
        let library = home + "/Library"
        return [
            Leftover(identifier: "com.spotify.client", files: [
                AppFile(path: library + "/Caches/com.spotify.client", kind: .caches, bytes: 1_120 * mb),
                AppFile(path: library + "/Application Support/Spotify", kind: .appSupport, bytes: 240 * mb),
            ], vendorStillInstalled: false),
            Leftover(identifier: "com.figma.Desktop", files: [
                AppFile(path: library + "/Application Support/Figma", kind: .appSupport, bytes: 380 * mb),
                AppFile(path: library + "/Preferences/com.figma.Desktop.plist", kind: .preferences, bytes: 6_000),
            ], vendorStillInstalled: false),
            Leftover(identifier: "com.tinyspeck.slackmacgap", files: [
                AppFile(path: library + "/Containers/com.tinyspeck.slackmacgap", kind: .containers, bytes: 910 * mb),
            ], vendorStillInstalled: false),
        ]
    }

    // MARK: Duplicates

    public static func duplicates() -> [DuplicateGroup] {
        func group(_ size: Int64, _ files: [(String, Double)]) -> DuplicateGroup {
            DuplicateGroup(id: files[0].0, size: size, files: files.map { DuplicateFile(path: home + "/" + $0.0, modified: ago($0.1)) })
        }
        return [
            group(8_420 * mb, [("Movies/Iceland trip 4K.mov", 210), ("Desktop/Iceland trip 4K.mov", 190)]),
            group(3_120 * mb, [("Downloads/Xcode_16.2.xip", 95), ("Documents/Installers/Xcode_16.2.xip", 94)]),
            group(980 * mb, [("Developer/ml-experiments/data/train.parquet", 94), ("Developer/ml-experiments-copy/data/train.parquet", 96),
                             ("Downloads/train.parquet", 97)]),
            group(48 * mb, [("Pictures/Exports/IMG_4821.HEIC", 40), ("Downloads/IMG_4821.HEIC", 39), ("Desktop/IMG_4821.HEIC", 38)]),
            group(18 * mb, [("Documents/Work/Quarterly report 2026.pdf", 22), ("Downloads/Quarterly report 2026.pdf", 22)]),
            group(12 * mb, [("Documents/Design assets/logo-final.psd", 120), ("Desktop/logo-final.psd", 118)]),
        ]
    }

    // MARK: Toolchains

    public static func toolCleanups() -> [ToolCleanup] {
        [
            ToolCleanup(id: "sim-unavailable", tool: "Xcode", title: "Unavailable simulators",
                        detail: "Simulators for iOS versions this Xcode no longer has.", bytes: 6_240 * mb,
                        action: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"], environment: [:]),
                        caution: nil, suggested: true),
            ToolCleanup(id: "runtime-ios17", tool: "Xcode", title: "iOS 17.5 simulator runtime",
                        detail: "Not used by any simulator for 4 months.", bytes: 7_120 * mb,
                        action: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", "iOS 17.5"], environment: [:]),
                        caution: "Downloaded again if you pick that iOS version in Xcode.", suggested: false),
            ToolCleanup(id: "brew-cleanup", tool: "Homebrew", title: "Old versions and downloads",
                        detail: "Outdated formula versions and cached downloads.", bytes: 1_840 * mb,
                        action: .command(executable: "/opt/homebrew/bin/brew", arguments: ["cleanup", "--prune=all"], environment: [:]),
                        caution: nil, suggested: true),
            ToolCleanup(id: "docker-builder", tool: "Docker", title: "Build cache",
                        detail: "Layers Docker keeps to speed up builds.", bytes: 4_310 * mb,
                        action: .command(executable: "/usr/local/bin/docker", arguments: ["builder", "prune", "-f"], environment: [:]),
                        caution: nil, suggested: true),
            ToolCleanup(id: "ollama-mixtral", tool: "Ollama", title: "mixtral:8x7b",
                        detail: "Downloaded model, not used for 74 days.", bytes: 26_400 * mb,
                        action: .command(executable: "/usr/local/bin/ollama", arguments: ["rm", "mixtral:8x7b"], environment: [:]),
                        caution: "A big download if you need it again.", suggested: false),
            ToolCleanup(id: "nvm-16", tool: "Node", title: "Node 16.20.2 (nvm)",
                        detail: "No project uses this version.", bytes: 212 * mb,
                        action: .trash([home + "/.nvm/versions/node/v16.20.2"]), caution: nil, suggested: true),
            ToolCleanup(id: "rust-nightly", tool: "Rust", title: "nightly-2025-11-02 toolchain",
                        detail: "Not the default and not pinned by any project.", bytes: 1_210 * mb,
                        action: .command(executable: home + "/.cargo/bin/rustup", arguments: ["toolchain", "uninstall", "nightly-2025-11-02"], environment: [:]),
                        caution: nil, suggested: false),
        ]
    }

    // MARK: Login items

    public static func launchItems() -> [LaunchItem] {
        func item(_ label: String, _ scope: LaunchItem.Scope, program: String, exists: Bool = true, disabled: Bool = false) -> LaunchItem {
            let folder = scope == .user ? home + "/Library/LaunchAgents" : scope == .allUsers ? "/Library/LaunchAgents" : "/Library/LaunchDaemons"
            return LaunchItem(label: label, plistPath: folder + "/" + label + ".plist", scope: scope, program: program, runsAtLoad: true,
                              keepsAlive: false, modified: ago(60), programExists: exists, isDisabled: disabled,
                              isLoaded: scope == .user ? !disabled : nil)
        }
        return [
            item("com.google.keystone.agent", .user, program: home + "/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/Resources/GoogleSoftwareUpdateAgent.app"),
            item("com.spotify.webhelper", .user, program: "/Applications/Spotify.app/Contents/MacOS/SpotifyWebHelper", exists: false),
            item("com.dropbox.dropboxmacupdate.agent", .user, program: "/Applications/Dropbox.app/Contents/Frameworks/DropboxMacUpdate.app", disabled: true),
            item("com.microsoft.update.agent", .allUsers, program: "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"),
            item("com.docker.socket", .system, program: "/Library/PrivilegedHelperTools/com.docker.socket"),
            item("com.adobe.ARMDC.SMJobBlessHelper", .system, program: "/Library/PrivilegedHelperTools/com.adobe.ARMDC.SMJobBlessHelper", exists: false),
        ]
    }

    // MARK: Privacy

    public static func privacyItems() -> [PrivacyItem] {
        let support = home + "/Library/Application Support"
        func items(_ browser: Browser, profile: String, name: String, _ sizes: [(PrivacyKind, Int64)]) -> [PrivacyItem] {
            sizes.map { PrivacyItem(browser: browser, profile: profile, profileName: name, kind: $0.0, paths: [profile + "/" + $0.0.rawValue],
                                    database: nil, bytes: $0.1) }
        }
        return items(.chrome, profile: support + "/Google/Chrome/Default", name: "Personal",
                     [(.history, 48 * mb), (.cookies, 6 * mb), (.sessions, 9 * mb), (.siteData, 612 * mb), (.autofill, 140_000)])
            + items(.chrome, profile: support + "/Google/Chrome/Profile 1", name: "Work",
                    [(.history, 21 * mb), (.cookies, 3 * mb), (.siteData, 288 * mb)])
            + items(.firefox, profile: support + "/Firefox/Profiles/demo.default-release", name: "default-release",
                    [(.history, 12 * mb), (.cookies, 2 * mb), (.sessions, 1 * mb), (.siteData, 74 * mb)])
            + items(.safari, profile: home + "/Library/Safari", name: "Safari", [(.history, 22 * mb), (.sessions, 1 * mb)])
    }

    public static func recentItemsLists() -> [RecentItemsList] {
        let folder = home + "/Library/Application Support/com.apple.sharedfilelist"
        return [RecentItemsList(title: "Recent applications", path: folder + "/RecentApplications.sfl3"),
                RecentItemsList(title: "Recent documents", path: folder + "/RecentDocuments.sfl3"),
                RecentItemsList(title: "Recent servers", path: folder + "/RecentServers.sfl3")]
    }

    public static func permissions() -> [AppPermission] {
        func grant(_ service: String, _ client: String, days: Double, system: Bool = false) -> AppPermission {
            AppPermission(service: service, client: client, isBundleID: true, allowed: true, lastModified: ago(days), systemWide: system)
        }
        return [
            grant("kTCCServiceCamera", "com.google.Chrome", days: 40), grant("kTCCServiceCamera", "us.zoom.xos", days: 120),
            grant("kTCCServiceMicrophone", "us.zoom.xos", days: 120), grant("kTCCServiceMicrophone", "com.google.Chrome", days: 40),
            grant("kTCCServiceScreenCapture", "us.zoom.xos", days: 90, system: true),
            grant("kTCCServiceSystemPolicyAllFiles", "com.microsoft.VSCode", days: 200, system: true),
            grant("kTCCServiceAccessibility", "com.raycast.macos", days: 300, system: true),
        ]
    }

    public static func security() -> SecurityStatus {
        SecurityStatus(checks: [
            .init(id: "xprotect", title: "XProtect malware definitions", detail: "Version 5368, updated 2 days ago", symbol: "shield.lefthalf.filled", isOn: true),
            .init(id: "gatekeeper", title: "Gatekeeper", detail: "Checks apps from the internet before they first open", symbol: "checkmark.shield.fill", isOn: true),
            .init(id: "filevault", title: "FileVault", detail: "Encrypts the startup disk", symbol: "lock.fill", isOn: true),
            .init(id: "firewall", title: "Firewall", detail: "Blocks unwanted incoming connections", symbol: "flame.fill", isOn: true),
        ])
    }

    // MARK: Updates

    public static func updates() -> [AppUpdate] {
        [
            AppUpdate(appPath: "/Applications/Visual Studio Code.app", name: "Visual Studio Code", installedVersion: "1.96.2", newVersion: "1.97.0",
                      source: .sparkle(download: nil), releaseNotes: "Copilot edits in multiple files, faster search across large workspaces, and terminal improvements.",
                      releaseDate: ago(3)),
            AppUpdate(appPath: "/Applications/Firefox.app", name: "Firefox", installedVersion: "133.0", newVersion: "134.0.1",
                      source: .homebrew(token: "firefox"), releaseNotes: "Security fixes and better tab grouping.", releaseDate: ago(5)),
            AppUpdate(appPath: "/Applications/Obsidian.app", name: "Obsidian", installedVersion: "1.7.7", newVersion: "1.8.4",
                      source: .sparkle(download: nil), releaseNotes: "Web viewer, faster graph view and new core plugins.", releaseDate: ago(8)),
            AppUpdate(appPath: "/Applications/Xcode.app", name: "Xcode", installedVersion: "16.2", newVersion: "16.3",
                      source: .appStore(page: "macappstore://apps.apple.com/app/id497799835"), releaseNotes: "SDKs for the latest Apple platforms.",
                      releaseDate: ago(10)),
        ]
    }

    // MARK: Cloud and Downloads

    public static func cloudLocations() -> [CloudLocation] {
        [CloudLocation(provider: .iCloud, path: home + "/Library/Mobile Documents/com~apple~CloudDocs", account: nil),
         CloudLocation(provider: .dropbox, path: home + "/Library/CloudStorage/Dropbox", account: nil),
         CloudLocation(provider: .googleDrive, path: home + "/Library/CloudStorage/GoogleDrive-demo", account: nil)]
    }

    public static func cloudFiles() -> [CloudFile] {
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        let dropbox = home + "/Library/CloudStorage/Dropbox"
        let drive = home + "/Library/CloudStorage/GoogleDrive-demo/My Drive"
        return [
            CloudFile(path: iCloud + "/Videos/Wedding film final.mov", provider: .iCloud, bytes: 6_140 * mb, modified: ago(300), lastOpened: ago(280)),
            CloudFile(path: dropbox + "/Clients/Design assets 2025.zip", provider: .dropbox, bytes: 2_310 * mb, modified: ago(160), lastOpened: ago(150)),
            CloudFile(path: iCloud + "/Backups/Old MacBook.sparsebundle.zip", provider: .iCloud, bytes: 1_920 * mb, modified: ago(500), lastOpened: nil),
            CloudFile(path: drive + "/Research/survey-raw-data.csv", provider: .googleDrive, bytes: 884 * mb, modified: ago(90), lastOpened: ago(85)),
            CloudFile(path: dropbox + "/Photos/2024 trip.zip", provider: .dropbox, bytes: 712 * mb, modified: ago(220), lastOpened: ago(200)),
            CloudFile(path: iCloud + "/Documents/Book draft.pages", provider: .iCloud, bytes: 140 * mb, modified: ago(40), lastOpened: ago(12)),
        ]
    }

    public static func downloads() -> [DownloadItem] {
        func item(_ name: String, _ bytes: Int64, _ source: String, _ site: String?, days: Double, opened: Bool = false, folder: Bool = false) -> DownloadItem {
            DownloadItem(path: home + "/Downloads/" + name, bytes: bytes, source: source, website: site, added: ago(days),
                         lastOpened: opened ? ago(days - 1) : nil, isFolder: folder)
        }
        return [
            item("Xcode_16.2.xip", 3_120 * mb, "Google Chrome", "developer.apple.com", days: 95, opened: true),
            item("ubuntu-24.04-desktop-arm64.iso", 2_760 * mb, "Google Chrome", "ubuntu.com", days: 120),
            item("photos-export.zip", 1_380 * mb, "Google Chrome", "photos.google.com", days: 48),
            item("Docker.dmg", 612 * mb, "Google Chrome", "docker.com", days: 88, opened: true),
            item("dataset-2025.tar.gz", 640 * mb, "Firefox", "kaggle.com", days: 75),
            item("Course videos", 4_100 * mb, "Safari", "university.example", days: 30, folder: true),
            item("Invoice-1042.pdf", 1 * mb, "Safari", "billing.example", days: 12, opened: true),
            item("IMG_4821.HEIC", 48 * mb, "AirDrop", nil, days: 39, opened: true),
            item("Screen Recording 2026-09-14.mov", 410 * mb, "AirDrop", nil, days: 40),
            item("node-v22.11.0.pkg", 79 * mb, "Firefox", "nodejs.org", days: 6, opened: true),
        ]
    }

    // MARK: Memory

    /// Apps by memory, for the Memory page and menu bar. pids are made up.
    public static func appUsage() -> [AppUsage] {
        func app(_ pid: Int32, _ name: String, _ path: String?, _ memory: Int64, cpu: Double, watts: Double, processes: Int) -> AppUsage {
            AppUsage(id: path ?? name, name: name, bundlePath: path, pid: pid, memory: memory, cpu: cpu, processCount: processes, watts: watts)
        }
        return [
            app(9001, "Google Chrome", "/Applications/Google Chrome.app", 3_410 * mb, cpu: 0.124, watts: 2.4, processes: 38),
            app(9002, "Xcode", "/Applications/Xcode.app", 2_880 * mb, cpu: 1.62, watts: 6.8, processes: 7),
            app(9003, "Visual Studio Code", "/Applications/Visual Studio Code.app", 1_820 * mb, cpu: 0.061, watts: 0.9, processes: 19),
            app(9004, "Safari", "/Applications/Safari.app", 1_240 * mb, cpu: 0.018, watts: 0.4, processes: 11),
            app(9005, "Firefox", "/Applications/Firefox.app", 960 * mb, cpu: 0.022, watts: 0.5, processes: 9),
            app(9006, "node", nil, 640 * mb, cpu: 0.43, watts: 1.7, processes: 3),
            app(9007, "Obsidian", "/Applications/Obsidian.app", 520 * mb, cpu: 0.004, watts: 0.05, processes: 5),
            app(9008, "Music", "/System/Applications/Music.app", 310 * mb, cpu: 0.009, watts: 0.2, processes: 2),
            app(9009, "Mail", "/System/Applications/Mail.app", 284 * mb, cpu: 0.002, watts: 0.03, processes: 3),
            app(9010, "Finder", "/System/Library/CoreServices/Finder.app", 162 * mb, cpu: 0.003, watts: 0.02, processes: 2),
            app(9011, "Messages", "/System/Applications/Messages.app", 151 * mb, cpu: 0.001, watts: 0.01, processes: 2),
            app(9012, "python3.12", nil, 118 * mb, cpu: 0.0, watts: 0, processes: 1),
        ]
    }

    /// The apps above that get a Quit button (Finder and the command-line tools don't).
    public static var quittablePIDs: Set<Int32> { [9001, 9002, 9003, 9004, 9005, 9007, 9008, 9009, 9011] }

    public static func memorySnapshot() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.cpu = 0.18
        snapshot.memoryTotal = 17_179_869_184
        snapshot.memoryUsed = 10_920 * mb
        snapshot.memoryApp = 6_140 * mb
        snapshot.memoryWired = 2_380 * mb
        snapshot.memoryCompressed = 2_400 * mb
        snapshot.memoryCached = 3_120 * mb
        snapshot.swapUsed = 412 * mb
        snapshot.pressure = .normal
        snapshot.networkIn = 182_000
        snapshot.networkOut = 24_000
        snapshot.battery = SystemSnapshot.Battery(percent: 82, charging: false, onPower: false, minutesLeft: 312, cycleCount: 211, health: 94)
        return snapshot
    }

    public static func thermal() -> ThermalSnapshot {
        var snapshot = ThermalSnapshot()
        snapshot.state = .fair
        snapshot.cpu = 71.4
        snapshot.hottest = 76.2
        snapshot.battery = 31.5
        snapshot.sensors = [("PMU tdie1", 76.2), ("PMU tdie4", 72.8), ("pACC MTR Temp Sensor2", 70.9), ("eACC MTR Temp Sensor0", 64.1),
                            ("SOC MTR Temp Sensor1", 61.7), ("PMGR SOC Die Temp Sensor0", 59.8), ("GPU MTR Temp Sensor1", 54.3),
                            ("ANE MTR Temp Sensor1", 41.0), ("NAND CH0 temp", 39.6), ("gas gauge battery", 31.5)]
            .map { ThermalSnapshot.Sensor(name: $0.0, celsius: $0.1) }
        return snapshot
    }

    // MARK: Drives

    public static func volumes() -> [MountedVolume] {
        [MountedVolume(path: "/Volumes/Backup SSD", name: "Backup SSD", total: 1_000_000_000_000, available: 412_000_000_000, ejectable: true),
         MountedVolume(path: "/Volumes/Camera Card", name: "Camera Card", total: 128_000_000_000, available: 91_000_000_000, ejectable: true)]
    }

    // MARK: History

    /// Ten weeks of cleaning, for My Activity.
    public static func history() -> [CleanupRecord] {
        func record(_ days: Double, _ kind: String, _ item: String, _ bytes: Int64, project: String? = nil, auto: Bool = false,
                    snapshot: String? = nil) -> CleanupRecord {
            let path = home + "/" + item
            return CleanupRecord(date: ago(days), projectPath: project.map { projectRoot + "/" + $0 } ?? Paths.parent(path), itemPath: path,
                                 kind: kind, bytes: bytes, mode: .trash, outcome: .removed, trashPath: nil, snapshotPath: snapshot, automatic: auto)
        }
        return [
            record(1, "junk:appCaches", "Library/Caches/com.google.Chrome", 1_910 * mb, auto: true),
            record(1, "junk:logs", "Library/Logs/DiagnosticReports", 210 * mb, auto: true),
            record(4, "nodeModules", "Developer/old-dashboard/node_modules", 980 * mb, project: "old-dashboard"),
            record(4, "pythonVenv", "Developer/ml-experiments/.venv", 3_120 * mb, project: "ml-experiments",
                   snapshot: projectRoot + "/ml-experiments/requirements.txt"),
            record(9, "cache:derived-data", "Library/Developer/Xcode/DerivedData", 7_800 * mb),
            record(15, "junk:aiClutter", "Library/Application Support/Claude/Cache", 540 * mb, auto: true),
            record(15, "junk:appCaches", "Library/Caches/com.spotify.client", 1_200 * mb, auto: true),
            record(22, "rustTarget", "Developer/game-engine/target", 5_400 * mb, project: "game-engine"),
            record(29, "junk:installers", "Downloads/Figma.dmg", 290 * mb, auto: true),
            record(30, "file", "Movies/Old screen recording.mov", 2_200 * mb),
            record(36, "cache:npm", ".npm/_cacache", 1_900 * mb),
            record(43, "app", "Applications/Old Game.app", 3_800 * mb),
            record(43, "junk:appCaches", "Library/Caches/us.zoom.xos", 380 * mb, auto: true),
            record(50, "nodeModules", "Developer/landing-page/node_modules", 720 * mb, project: "landing-page"),
            record(57, "tool:docker-builder", "Docker build cache", 4_100 * mb),
            record(64, "junk:deviceUpdates", "Library/iTunes/iPhone Software Updates/old.ipsw", 6_900 * mb),
            record(71, "junk:appCaches", "Library/Caches/com.tinyspeck.slackmacgap", 860 * mb, auto: true),
        ]
    }
}

extension CacheCatalog {
    /// Every cache DevSweep knows, whether it exists or not (for demo screenshots).
    static func all(home: String) -> [DevCache] {
        specs.map { DevCache(id: $0.id, name: $0.name, tool: $0.tool, path: home + "/" + $0.relativePath, detail: $0.detail,
                             caution: $0.caution, bytes: nil) }
    }
}
#endif
