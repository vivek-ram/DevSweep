import Foundation

/// The language / toolchain family an artifact belongs to.
public enum Ecosystem: String, Codable, CaseIterable, Sendable, Identifiable {
    case python, node, rust, swift, gradle, flutter, cocoapods

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .python: "Python"
        case .node: "JavaScript"
        case .rust: "Rust"
        case .swift: "Swift"
        case .gradle: "Gradle"
        case .flutter: "Flutter"
        case .cocoapods: "CocoaPods"
        }
    }

    public var shortLabel: String {
        switch self {
        case .python: "Py"
        case .node: "JS"
        case .rust: "Rust"
        case .swift: "Swift"
        case .gradle: "JVM"
        case .flutter: "Dart"
        case .cocoapods: "Pods"
        }
    }
}

/// A kind of folder that tools regenerate on demand and that is therefore safe to remove.
public enum ArtifactKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case pythonVenv
    case pythonCache
    case nodeModules
    case jsBuildCache
    case rustTarget
    case swiftBuild
    case gradleBuild
    case cocoaPods
    case dartTool

    public var id: String { rawValue }

    public var ecosystem: Ecosystem {
        switch self {
        case .pythonVenv, .pythonCache: .python
        case .nodeModules, .jsBuildCache: .node
        case .rustTarget: .rust
        case .swiftBuild: .swift
        case .gradleBuild: .gradle
        case .cocoaPods: .cocoapods
        case .dartTool: .flutter
        }
    }

    public var displayName: String {
        switch self {
        case .pythonVenv: "Python virtual environments"
        case .pythonCache: "Python caches"
        case .nodeModules: "node_modules"
        case .jsBuildCache: "JS framework caches"
        case .rustTarget: "Rust build output"
        case .swiftBuild: "SwiftPM build output"
        case .gradleBuild: "Gradle build output"
        case .cocoaPods: "CocoaPods"
        case .dartTool: "Flutter / Dart build output"
        }
    }

    /// The folder names this kind matches, for display.
    public var folderNames: String {
        switch self {
        case .pythonVenv: ".venv, venv, env, … (any folder with pyvenv.cfg)"
        case .pythonCache: "__pycache__, .pytest_cache, .mypy_cache, .ruff_cache, .tox"
        case .nodeModules: "node_modules"
        case .jsBuildCache: ".next, .nuxt, .svelte-kit, .turbo, .parcel-cache, .angular"
        case .rustTarget: "target (next to Cargo.toml)"
        case .swiftBuild: ".build (next to Package.swift)"
        case .gradleBuild: "build, .gradle (next to build.gradle)"
        case .cocoaPods: "Pods (next to Podfile)"
        case .dartTool: ".dart_tool, build (next to pubspec.yaml)"
        }
    }

    /// How to get the folder back.
    public var restoreHint: String {
        switch self {
        case .pythonVenv: "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
        case .pythonCache: "Recreated automatically when you run your code"
        case .nodeModules: "npm install (or yarn / pnpm / bun install)"
        case .jsBuildCache: "Recreated by your next dev server or build"
        case .rustTarget: "cargo build"
        case .swiftBuild: "swift build"
        case .gradleBuild: "./gradlew build"
        case .cocoaPods: "pod install"
        case .dartTool: "flutter pub get"
        }
    }

    /// Dependency installs (as opposed to build output or caches).
    public var isDependencyInstall: Bool {
        switch self {
        case .pythonVenv, .nodeModules, .cocoaPods: true
        default: false
        }
    }
}

/// Rules for recognising artifact folders and project roots while walking the disk.
public enum ArtifactRules {
    /// Files whose presence marks a directory as the root of a project.
    public static let projectMarkers: Set<String> = [
        "package.json", "pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile",
        "environment.yml", "Cargo.toml", "Package.swift", "go.mod", "pom.xml", "build.gradle",
        "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "pubspec.yaml", "Gemfile",
        "Podfile", "composer.json", "deno.json",
    ]

    /// Dropping this file into a folder protects it (and everything below it) from cleaning.
    public static let keepMarker = ".devsweep-keep"

    /// Files that change without the user doing anything meaningful.
    static let noiseFiles: Set<String> = [".DS_Store", ".localized", "Icon\r"]

    static let pythonCacheNames: Set<String> = [
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".hypothesis", ".pytype", ".tox", ".nox",
    ]
    static let jsCacheNames: Set<String> = [
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular", ".docusaurus", ".expo",
    ]

    /// Directory names that are never descended into: version control internals, global package
    /// installs and app bundles. Anything below them is not a project's own artifact.
    static let opaqueNames: Set<String> = ["site-packages", "dist-packages", ".Trash", ".Trashes"]
    /// Top-level folders of the home directory that hold apps, system data or tool installs
    /// (the Go module cache lives in ~/go), skipped when the whole home folder is scanned.
    static let homeOnlySkips: Set<String> = ["Library", "Applications", "go", "Pictures", "Music", "Movies"]
    static let opaqueSuffixes = [".app", ".photoslibrary", ".musiclibrary", ".tvlibrary", ".fcpbundle", ".xcarchive", ".framework"]

    /// Classifies a directory given its name and full path. Returns nil if it is not an artifact.
    public static func classify(name: String, path: String) -> ArtifactKind? {
        let parent = (path as NSString).deletingLastPathComponent
        switch name {
        case "node_modules":
            return .nodeModules
        case _ where pythonCacheNames.contains(name):
            return .pythonCache
        case _ where jsCacheNames.contains(name):
            return exists(parent, "package.json") ? .jsBuildCache : nil
        case "target":
            if exists(parent, "Cargo.toml") { return .rustTarget }
        case ".build":
            if exists(parent, "Package.swift") { return .swiftBuild }
        case "build":
            if exists(parent, "build.gradle") || exists(parent, "build.gradle.kts") { return .gradleBuild }
            if exists(parent, "pubspec.yaml") { return .dartTool }
        case ".gradle":
            if exists(parent, "build.gradle") || exists(parent, "build.gradle.kts")
                || exists(parent, "settings.gradle") || exists(parent, "settings.gradle.kts") { return .gradleBuild }
        case "Pods":
            if exists(parent, "Podfile") { return .cocoaPods }
        case ".dart_tool":
            if exists(parent, "pubspec.yaml") { return .dartTool }
        default:
            break
        }
        if exists(path, "pyvenv.cfg") { return .pythonVenv }
        return nil
    }

    /// True for directories the walker should not enter and that are not artifacts either.
    static func isOpaque(name: String, path: String) -> Bool {
        if opaqueNames.contains(name) { return true }
        if opaqueSuffixes.contains(where: { name.hasSuffix($0) }) { return true }
        // Hidden folders (.vscode, .cache, .nvm, …) belong to tools, not to the project's own deps.
        if name.hasPrefix(".") { return true }
        // A conda installation or environment: its packages are not regenerable from the project.
        if exists(path, "conda-meta") { return true }
        return false
    }

    @inline(__always)
    static func exists(_ dir: String, _ child: String) -> Bool {
        access(dir + "/" + child, F_OK) == 0
    }
}
