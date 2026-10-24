import Foundation

/// A machine-wide download or build cache kept by a developer tool.
public struct DevCache: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let tool: String
    public let path: String
    public let detail: String
    /// Shown when removing it has a real cost (large re-downloads, slower first builds).
    public let caution: String?
    public var bytes: Int64?

    public var displayPath: String { Paths.abbreviate(path) }
}

public enum CacheCatalog {
    struct Spec {
        let id, name, tool, relativePath, detail: String
        var caution: String? = nil
    }

    static let specs: [Spec] = [
        Spec(id: "pip", name: "pip download cache", tool: "Python", relativePath: "Library/Caches/pip",
             detail: "Wheels pip has downloaded. Re-downloaded when needed."),
        Spec(id: "uv", name: "uv cache", tool: "Python", relativePath: ".cache/uv",
             detail: "uv's package cache. Environments made by uv may share files with it, so less space can come back than shown."),
        Spec(id: "poetry", name: "Poetry cache", tool: "Python", relativePath: "Library/Caches/pypoetry",
             detail: "Poetry's downloaded packages and its own virtualenvs.",
             caution: "Also holds environments Poetry created for your projects."),
        Spec(id: "npm", name: "npm cache", tool: "JavaScript", relativePath: ".npm/_cacache",
             detail: "Tarballs npm has downloaded. Same as `npm cache clean --force`."),
        Spec(id: "pnpm", name: "pnpm store", tool: "JavaScript", relativePath: "Library/pnpm/store",
             detail: "pnpm's content-addressed store. Installed projects keep working; their files are hard-linked.",
             caution: "Space shared with existing node_modules folders is only freed once those are removed too."),
        Spec(id: "yarn", name: "Yarn cache", tool: "JavaScript", relativePath: "Library/Caches/Yarn",
             detail: "Packages Yarn has downloaded."),
        Spec(id: "bun", name: "Bun cache", tool: "JavaScript", relativePath: ".bun/install/cache",
             detail: "Packages Bun has downloaded."),
        Spec(id: "playwright", name: "Playwright browsers", tool: "JavaScript", relativePath: "Library/Caches/ms-playwright",
             detail: "Browser builds for Playwright tests.", caution: "Run `npx playwright install` to get them back."),
        Spec(id: "puppeteer", name: "Puppeteer browsers", tool: "JavaScript", relativePath: ".cache/puppeteer",
             detail: "Chrome builds downloaded by Puppeteer."),
        Spec(id: "electron", name: "Electron downloads", tool: "JavaScript", relativePath: "Library/Caches/electron",
             detail: "Electron binaries fetched during installs."),
        Spec(id: "node-gyp", name: "node-gyp headers", tool: "JavaScript", relativePath: "Library/Caches/node-gyp",
             detail: "Node headers for compiling native modules."),
        Spec(id: "cargo-registry", name: "Cargo registry", tool: "Rust", relativePath: ".cargo/registry",
             detail: "Downloaded and unpacked crates. Fetched again on the next build."),
        Spec(id: "cargo-git", name: "Cargo git checkouts", tool: "Rust", relativePath: ".cargo/git",
             detail: "Crates pulled from git repositories."),
        Spec(id: "go-build", name: "Go build cache", tool: "Go", relativePath: "Library/Caches/go-build",
             detail: "Compiled Go packages. Same as `go clean -cache`."),
        Spec(id: "gradle", name: "Gradle caches", tool: "JVM", relativePath: ".gradle/caches",
             detail: "Dependencies and build caches for Gradle and Android projects."),
        Spec(id: "maven", name: "Maven repository", tool: "JVM", relativePath: ".m2/repository",
             detail: "Downloaded Maven dependencies."),
        Spec(id: "derived-data", name: "Xcode DerivedData", tool: "Xcode", relativePath: "Library/Developer/Xcode/DerivedData",
             detail: "Build products and indexes. Xcode rebuilds them; the first build afterwards is slower."),
        Spec(id: "device-support", name: "iOS DeviceSupport", tool: "Xcode", relativePath: "Library/Developer/Xcode/iOS DeviceSupport",
             detail: "Symbols copied from devices you've connected. Copied again on the next connect."),
        Spec(id: "simulator-caches", name: "Simulator caches", tool: "Xcode", relativePath: "Library/Developer/CoreSimulator/Caches",
             detail: "Dyld and runtime caches for the iOS Simulator."),
        Spec(id: "cocoapods", name: "CocoaPods cache", tool: "Xcode", relativePath: "Library/Caches/CocoaPods",
             detail: "Pod sources CocoaPods has downloaded."),
        Spec(id: "homebrew", name: "Homebrew downloads", tool: "Homebrew", relativePath: "Library/Caches/Homebrew",
             detail: "Bottles and source archives. Same as `brew cleanup --prune=all`."),
        Spec(id: "huggingface", name: "Hugging Face hub", tool: "ML", relativePath: ".cache/huggingface",
             detail: "Downloaded models and datasets.", caution: "Models can be many GB to download again."),
        Spec(id: "torch", name: "PyTorch hub", tool: "ML", relativePath: ".cache/torch",
             detail: "Model weights downloaded by torch.hub and torchvision.", caution: "Weights are downloaded again on next use."),
        Spec(id: "pre-commit", name: "pre-commit environments", tool: "Python", relativePath: ".cache/pre-commit",
             detail: "Hook environments pre-commit builds. Rebuilt on the next commit."),
    ]

    /// Caches that exist on this Mac (sizes not yet measured).
    public static func installed(home: String = NSHomeDirectory()) -> [DevCache] {
        specs.compactMap { spec in
            let path = home + "/" + spec.relativePath
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return DevCache(id: spec.id, name: spec.name, tool: spec.tool, path: path, detail: spec.detail,
                            caution: spec.caution, bytes: nil)
        }
    }

    static func knownPaths(home: String = NSHomeDirectory()) -> Set<String> {
        Set(specs.map { home + "/" + $0.relativePath })
    }
}
