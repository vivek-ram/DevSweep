import Foundation

/// A newer version of an installed app.
public struct AppUpdate: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// The app's own Sparkle updater; `download` is the new build.
        case sparkle(download: String?)
        /// Mac App Store; `page` opens the app's store page.
        case appStore(page: String)
        /// A Homebrew cask (`brew upgrade --cask <token>`).
        case homebrew(token: String)
    }

    public var id: String { appPath + "|" + newVersion }
    public let appPath: String
    public let name: String
    public let installedVersion: String
    public let newVersion: String
    public let source: Source
    public let releaseNotes: String?
    public let releaseDate: Date?

    public var sourceTitle: String {
        switch source {
        case .sparkle: "Developer"
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        }
    }
}

public enum UpdateChecker {
    /// Checks every app that has a way to tell: Sparkle feeds, the App Store and Homebrew.
    /// Network failures just mean that app isn't listed.
    public static func check(_ apps: [InstalledApp]) async -> [AppUpdate] {
        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            config.httpAdditionalHeaders = ["User-Agent": "DevSweep/1.0"]
            return config
        }())
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        var updates = await withTaskGroup(of: AppUpdate?.self) { group in
            for app in apps where !app.isApple || app.isAppStore {
                group.addTask {
                    if app.isAppStore { return await appStore(app, region: region, session: session) }
                    if let feed = app.feedURL { return await sparkle(app, feed: feed, session: session) }
                    return nil
                }
            }
            var found: [AppUpdate] = []
            for await update in group { if let update { found.append(update) } }
            return found
        }
        let known = Set(updates.map(\.appPath))
        updates += homebrew(apps).filter { !known.contains($0.appPath) }
        return updates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// True if `candidate` is a later version than `installed` ("1.10" > "1.9").
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let clean = { (v: String) in v.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? v }
        return clean(candidate).compare(clean(installed), options: .numeric) == .orderedDescending
    }

    // MARK: App Store

    static func appStore(_ app: InstalledApp, region: String, session: URLSession) async -> AppUpdate? {
        guard let installed = app.version,
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(app.bundleID)&country=\(region)&entity=macSoftware"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (json["results"] as? [[String: Any]])?.first,
              let latest = result["version"] as? String, isNewer(latest, than: installed) else { return nil }
        let page = (result["trackViewUrl"] as? String)?.replacingOccurrences(of: "https://", with: "macappstore://") ?? "macappstore://"
        let date = (result["currentVersionReleaseDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return AppUpdate(appPath: app.path, name: app.name, installedVersion: installed, newVersion: latest,
                         source: .appStore(page: page), releaseNotes: result["releaseNotes"] as? String, releaseDate: date)
    }

    // MARK: Sparkle

    static func sparkle(_ app: InstalledApp, feed: String, session: URLSession) async -> AppUpdate? {
        guard let url = URL(string: feed), url.scheme == "https" || url.scheme == "http",
              let (data, _) = try? await session.data(from: url) else { return nil }
        let items = AppcastParser.parse(data)
        // Newest entry that this Mac can run, compared on the build number Sparkle uses.
        guard let newest = items.max(by: { $0.build.compare($1.build, options: .numeric) == .orderedAscending }),
              let installedBuild = app.buildVersion, isNewer(newest.build, than: installedBuild) else { return nil }
        return AppUpdate(appPath: app.path, name: app.name, installedVersion: app.version ?? installedBuild,
                         newVersion: newest.shortVersion ?? newest.build, source: .sparkle(download: newest.download),
                         releaseNotes: newest.notes, releaseDate: newest.date)
    }

    // MARK: Homebrew

    static func homebrew(_ apps: [InstalledApp]) -> [AppUpdate] {
        guard let brew = DevTools.which("brew") else { return [] }
        let result = DevTools.shell(brew, ["outdated", "--cask", "--greedy", "--json=v2"],
                                    environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], timeout: 120)
        guard result.status == 0, let start = result.output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(result.output[start...].utf8)) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return [] }
        return casks.compactMap { cask in
            guard let token = cask["name"] as? String, let latest = cask["current_version"] as? String else { return nil }
            let installed = (cask["installed_versions"] as? [String])?.first ?? "?"
            // Match the cask to an installed app by name when possible.
            let app = apps.first { $0.name.lowercased().replacingOccurrences(of: " ", with: "-") == token }
            return AppUpdate(appPath: app?.path ?? "brew:\(token)", name: app?.name ?? token, installedVersion: installed,
                             newVersion: latest, source: .homebrew(token: token), releaseNotes: nil, releaseDate: nil)
        }
    }

    /// Runs `brew upgrade --cask` for one cask. Blocking.
    public static func upgradeCask(_ token: String) -> String? {
        guard let brew = DevTools.which("brew") else { return "Homebrew isn't installed" }
        let result = DevTools.shell(brew, ["upgrade", "--cask", token], environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], timeout: 1_800)
        return result.status == 0 ? nil : (result.output.split(separator: "\n").last.map(String.init) ?? "brew reported an error")
    }
}

/// Reads the items of a Sparkle appcast (RSS with sparkle: attributes).
enum AppcastParser {
    struct Item {
        var build = ""
        var shortVersion: String?
        var download: String?
        var notes: String?
        var date: Date?
        var minimumSystem: String?
    }

    static func parse(_ data: Data) -> [Item] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return delegate.items.filter { item in
            !item.build.isEmpty && (item.minimumSystem.map { $0.compare(current, options: .numeric) != .orderedDescending } ?? true)
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var current: Item?
        private var text = ""
        private static let dates: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz"].map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = $0
            return f
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if name == "item" { current = Item() }
            if name == "enclosure", current != nil {
                if let build = attributes["sparkle:version"] { current?.build = build }
                if let short = attributes["sparkle:shortVersionString"] { current?.shortVersion = short }
                current?.download = attributes["url"]
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "sparkle:version" where !value.isEmpty: current?.build = value
            case "sparkle:shortVersionString" where !value.isEmpty: current?.shortVersion = value
            case "sparkle:minimumSystemVersion": current?.minimumSystem = value
            case "pubDate": current?.date = Self.dates.lazy.compactMap { $0.date(from: value) }.first
            case "description" where current != nil: current?.notes = value.strippingTags
            case "item":
                if let item = current { items.append(item) }
                current = nil
            default: break
            }
        }
    }
}

extension String {
    /// Release notes are often HTML; keep the words.
    var strippingTags: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
