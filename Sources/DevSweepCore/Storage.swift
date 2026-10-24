import Foundation

/// JSON files under ~/Library/Application Support/DevSweep.
public struct Storage: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevSweep", isDirectory: true)
    }

    private var historyURL: URL { directory.appendingPathComponent("history.json") }
    private var scanURL: URL { directory.appendingPathComponent("last-scan.json") }

    /// Newest first, capped so the file stays small.
    public func loadHistory() -> [CleanupRecord] { load(historyURL) ?? [] }

    public func saveHistory(_ records: [CleanupRecord]) {
        save(Array(records.prefix(5_000)), to: historyURL)
    }

    public func loadScan() -> ScanResult? { load(scanURL) }

    public func saveScan(_ result: ScanResult) { save(result, to: scanURL) }

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
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
