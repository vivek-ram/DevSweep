import Foundation

/// JSON files under ~/Library/Application Support/DevSweep.
public struct Storage: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// Debug builds (the screenshot renderer cleans throwaway fixtures and loads made-up history)
    /// keep their own folder, so they can never overwrite the installed app's history.
    #if DEBUG
    static let folderName = "DevSweep-Debug"
    #else
    static let folderName = "DevSweep"
    #endif

    private var historyURL: URL { directory.appendingPathComponent("history.json") }
    private var scanURL: URL { directory.appendingPathComponent("last-scan.json") }

    /// Newest first, capped so the file stays small. One record this version can't read doesn't
    /// lose the rest: they're kept, and the original file is copied aside first, because the
    /// next save rewrites it.
    public func loadHistory() -> [CleanupRecord] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        if let records: [CleanupRecord] = decode(data) { return records }
        let backup = directory.appendingPathComponent("history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: historyURL, to: backup)
        let lenient: [Lenient<CleanupRecord>]? = decode(data)
        return lenient?.compactMap(\.value) ?? []
    }

    public func saveHistory(_ records: [CleanupRecord]) {
        save(Array(records.prefix(5_000)), to: historyURL)
    }

    public func loadScan() -> ScanResult? { load(scanURL) }

    public func saveScan(_ result: ScanResult) { save(result, to: scanURL) }

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    private func decode<T: Decodable>(_ data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Decodes a value if it can and nil if it can't, so one bad element doesn't fail a whole array.
struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
