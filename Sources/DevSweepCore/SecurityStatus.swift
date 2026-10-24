import Foundation

/// The protections macOS already has, read without changing anything. DevSweep doesn't ship
/// its own malware scanner; it shows whether the built-in one is on and up to date.
public struct SecurityStatus: Sendable, Equatable {
    public struct Check: Identifiable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var detail: String
        public var symbol: String
        /// nil when it couldn't be read.
        public var isOn: Bool?
    }

    public var checks: [Check]

    public static func read() -> SecurityStatus {
        var checks: [Check] = []

        let xprotect = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"
        let info = FileManager.default.contents(atPath: xprotect)
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let version = info?["CFBundleShortVersionString"] as? String
        let updated = (try? FileManager.default.attributesOfItem(atPath: xprotect))?[.modificationDate] as? Date
        checks.append(Check(id: "xprotect", title: "XProtect malware definitions",
                            detail: version.map { v in "Version \(v)" + (updated.map { ", updated \(Format.idle(since: $0).lowercased())" } ?? "") }
                                ?? "Couldn't read its version",
                            symbol: "shield.lefthalf.filled", isOn: version != nil))

        let gatekeeper = DevTools.shell("/usr/sbin/spctl", ["--status"], environment: [:], timeout: 10)
        checks.append(Check(id: "gatekeeper", title: "Gatekeeper",
                            detail: "Checks apps from the internet before they first open",
                            symbol: "checkmark.shield.fill", isOn: parse(gatekeeper, on: "assessments enabled", off: "assessments disabled")))

        let fileVault = DevTools.shell("/usr/bin/fdesetup", ["status"], environment: [:], timeout: 10)
        checks.append(Check(id: "filevault", title: "FileVault",
                            detail: "Encrypts the startup disk, so a lost Mac doesn't expose your files",
                            symbol: "lock.fill", isOn: parse(fileVault, on: "FileVault is On", off: "FileVault is Off")))

        let firewall = DevTools.shell("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], environment: [:], timeout: 10)
        checks.append(Check(id: "firewall", title: "Firewall",
                            detail: "Blocks unwanted incoming connections",
                            symbol: "flame.fill", isOn: parse(firewall, on: "enabled", off: "disabled")))

        return SecurityStatus(checks: checks)
    }

    static func parse(_ result: (status: Int32, output: String), on: String, off: String) -> Bool? {
        guard result.status == 0 else { return nil }
        let text = result.output.lowercased()
        if text.contains(off.lowercased()) { return false }
        if text.contains(on.lowercased()) { return true }
        return nil
    }
}
