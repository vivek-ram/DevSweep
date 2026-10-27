import CoreServices
import Foundation
import Security

/// Decides which folders in ~/Library/Caches DevSweep may tick for you.
///
/// macOS lets an app keep anything in its Caches folder, and some keep things there that are
/// hard or impossible to get back: downloaded artwork, offline media, game data. So a cache is
/// only ticked, and only ever cleaned automatically, when DevSweep knows the app rebuilds it.
/// Other caches are listed unticked with the reason, and caches of apps you build yourself
/// aren't listed at all.
public enum CacheSafety {
    public enum Verdict: Equatable, Sendable {
        /// A cache DevSweep knows the app rebuilds on its own.
        case known
        /// An app DevSweep knows nothing about: listed, not ticked.
        case unknown
        /// Holds this many pictures, videos or sounds: listed, not ticked, with a warning.
        case holdsMedia(Int)
        /// An app built on this Mac or signed with your own certificate: not listed.
        case yourApp
    }

    /// Classifies one folder in ~/Library/Caches. Blocking: it may look inside the folder and
    /// read the app's code signature.
    public static func verdict(name: String, path: String) -> Verdict {
        if isKnown(name) { return .known }
        if let app = appURL(bundleID: name), isYourApp(app) { return .yourApp }
        let media = mediaFiles(in: path)
        return media >= mediaThreshold ? .holdsMedia(media) : .unknown
    }

    // MARK: Known caches

    /// Caches DevSweep knows are disposable: browsers, updaters, chat and meeting apps, editors
    /// and developer tools. They're all rebuilt (or re-downloaded) the next time they're needed.
    static let knownNames: Set<String> = [
        // Browsers
        "Google", "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "Chromium", "org.chromium.Chromium",
        "Firefox", "Mozilla", "org.mozilla.firefox", "com.microsoft.edgemac", "Microsoft Edge", "com.brave.Browser",
        "BraveSoftware", "company.thebrowser.Browser", "Arc", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "Vivaldi",
        // Updaters and crash reporters
        "com.google.GoogleUpdater", "com.google.Keystone", "com.google.SoftwareUpdate", "org.sparkle-project.Sparkle",
        "com.microsoft.autoupdate2", "com.microsoft.autoupdate.fba", "com.plausiblelabs.crashreporter.data",
        "com.crashlytics.data", "io.sentry", "SentryCrash", "KSCrash",
        // Chat, meetings and everyday Electron apps
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
        "com.figma.Desktop", "notion.id", "com.anthropic.claudefordesktop", "com.openai.chat", "com.spotify.client",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "tv.parsec.www", "com.microsoft.Word", "com.microsoft.Excel",
        "com.microsoft.Powerpoint", "com.microsoft.onenote.mac",
        // Editors and developer tools
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "com.github.GitHubClient", "com.postmanlabs.mac", "com.docker.docker", "JetBrains", "com.sublimetext.4",
        "dev.zed.Zed", "org.swift.swiftpm", "Homebrew", "pip", "pip-tools", "pypoetry", "node-gyp", "Yarn", "yarn",
        "typescript", "go-build", "golangci-lint", "deno", "CocoaPods", "org.carthage.CarthageKit", "electron",
        "electron-builder", "sccache",
    ]

    static func isKnown(_ name: String) -> Bool {
        // Squirrel (".ShipIt") keeps an app's downloaded updates; they're fetched again if needed.
        knownNames.contains(name) || name.hasSuffix(".ShipIt")
    }

    // MARK: Pictures, videos and sounds

    static let mediaExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "tif", "tiff", "bmp", "svg", "icns",
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "mp3", "m4a", "aac", "wav", "flac", "ogg", "aiff", "pdf",
    ]
    /// A few icons are normal in any cache; this many pictures is a collection.
    static let mediaThreshold = 20

    /// How many pictures, videos and sounds a folder holds (counting stops at a few thousand files).
    static func mediaFiles(in path: String, limit: Int = 5_000) -> Int {
        guard let files = FileManager.default.enumerator(atPath: path) else { return 0 }
        var media = 0, seen = 0
        while let file = files.nextObject() as? String, seen < limit {
            seen += 1
            if mediaExtensions.contains((file as NSString).pathExtension.lowercased()) { media += 1 }
        }
        return media
    }

    // MARK: Your own apps

    /// The app a bundle-id-named cache belongs to, if macOS knows where it is.
    static func appURL(bundleID: String) -> URL? {
        guard bundleID.contains("."),
              let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL]
        else { return nil }
        return urls.first
    }

    /// Built on this Mac (unsigned, ad-hoc or development signed), or signed with a Developer ID
    /// whose certificate is in your keychain: an app you make, whose cache may hold your work.
    static func isYourApp(_ app: URL) -> Bool {
        guard let signer = signer(of: app) else { return true }
        return signer.local || signer.team.map(yourTeams.contains) == true
    }

    struct Signer: Equatable {
        /// Ad-hoc or development signed: built on a Mac, not released.
        var local: Bool
        var team: String?
    }

    /// Who signed an app; nil when it isn't signed at all.
    static func signer(of app: URL) -> Signer? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any], info[kSecCodeInfoIdentifier as String] != nil
        else { return nil }
        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let summary = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? ""
        return Signer(local: flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || isDevelopmentCertificate(summary),
                      team: info[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    static func isDevelopmentCertificate(_ summary: String) -> Bool {
        ["Apple Development:", "Mac Developer:", "iPhone Developer:"].contains { summary.hasPrefix($0) }
    }

    /// Team IDs of the signing certificates in your keychain ("Developer ID Application: Name (TEAMID)").
    static let yourTeams: Set<String> = {
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let certificates = result as? [SecCertificate] else { return [] }
        return Set(certificates.compactMap { certificate in
            guard let summary = SecCertificateCopySubjectSummary(certificate) as String? else { return nil }
            return team(fromCertificate: summary)
        })
    }()

    /// "Developer ID Application: Jane Doe (AB12CD34EF)" → "AB12CD34EF".
    static func team(fromCertificate summary: String) -> String? {
        let signing = ["Developer ID Application:", "Apple Development:", "Apple Distribution:", "Mac Developer:", "3rd Party Mac Developer Application:"]
        guard signing.contains(where: summary.hasPrefix), summary.hasSuffix(")"),
              let open = summary.lastIndex(of: "(") else { return nil }
        let team = summary[summary.index(after: open)..<summary.index(before: summary.endIndex)]
        return team.count == 10 && team.allSatisfy({ $0.isUppercase || $0.isNumber }) ? String(team) : nil
    }
}
