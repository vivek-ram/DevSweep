import Foundation

public struct SpaceSample: Codable, Hashable, Sendable {
    public let date: Date
    public let free: Int64
    public let total: Int64
}

/// Sizes of the bigger folders at one moment, from a storage scan.
public struct FolderSnapshot: Codable, Hashable, Sendable {
    public let date: Date
    public let sizes: [String: Int64]
}

/// A folder that grew noticeably between two snapshots.
public struct Growth: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let before: Int64
    public let after: Int64
    public let since: Date

    public var delta: Int64 { after - before }
    public var name: String { (path as NSString).lastPathComponent }
}

/// Free space over time plus folder sizes from past scans, so growth can be spotted early.
public struct SpaceHistory: Codable, Sendable {
    public private(set) var samples: [SpaceSample] = []
    public private(set) var snapshots: [FolderSnapshot] = []
    /// Folders already alerted about, so the same growth isn't announced twice.
    public var alerted: [String: Date] = [:]

    public init() {}

    /// Keeps one sample per hour for two weeks, then one per day for six months.
    public mutating func record(free: Int64, total: Int64, at date: Date = Date()) {
        if let last = samples.last, date.timeIntervalSince(last.date) < 50 * 60 {
            samples[samples.count - 1] = SpaceSample(date: date, free: free, total: total)
        } else {
            samples.append(SpaceSample(date: date, free: free, total: total))
        }
        let hourlyCutoff = date.addingTimeInterval(-14 * 86_400)
        let oldest = date.addingTimeInterval(-180 * 86_400)
        var seenDays = Set<Int>()
        samples = samples.filter { sample in
            if sample.date < oldest { return false }
            if sample.date >= hourlyCutoff { return true }
            return seenDays.insert(Int(sample.date.timeIntervalSince1970 / 86_400)).inserted
        }
    }

    /// Records folders of at least 50 MB, four levels deep, from a storage scan. At most one
    /// snapshot per 12 hours (a newer one replaces it); the last 60 are kept.
    public mutating func record(_ root: StorageNode, at date: Date = Date()) {
        var sizes: [String: Int64] = [:]
        func walk(_ node: StorageNode, depth: Int) {
            guard node.size >= 50_000_000 else { return }
            sizes[node.path] = node.size
            guard depth < 4, node.isDirectory, !node.isPackage else { return }
            for child in node.children where child.isDirectory { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        record(sizes: sizes, at: date)
    }

    /// Records folder sizes measured some other way.
    public mutating func record(sizes: [String: Int64], at date: Date = Date()) {
        let snapshot = FolderSnapshot(date: date, sizes: sizes)
        if let last = snapshots.last, date.timeIntervalSince(last.date) < 12 * 3_600 {
            snapshots[snapshots.count - 1] = snapshot
        } else {
            snapshots.append(snapshot)
        }
        if snapshots.count > 60 { snapshots.removeFirst(snapshots.count - 60) }
    }

    /// Folders that grew by at least `minimum` since the newest snapshot at least `days` old.
    /// Only the most specific culprit is reported: a folder whose growth is mostly explained by
    /// one of its subfolders gives way to that subfolder.
    public func growth(minimum: Int64 = 1_000_000_000, overAtLeast days: Double = 3, now: Date = Date()) -> [Growth] {
        guard let latest = snapshots.last,
              let baseline = snapshots.last(where: { latest.date.timeIntervalSince($0.date) >= days * 86_400 })
        else { return [] }
        var grown: [String: Growth] = [:]
        for (path, after) in latest.sizes {
            let before = baseline.sizes[path] ?? 0
            if after - before >= minimum {
                grown[path] = Growth(path: path, before: before, after: after, since: baseline.date)
            }
        }
        let culprits = grown.values.filter { parent in
            !grown.values.contains { child in
                child.path != parent.path && Paths.isInside(child.path, parent.path) && Double(child.delta) >= Double(parent.delta) * 0.8
            }
        }
        return culprits.sorted { $0.delta > $1.delta }
    }

    /// Growth not alerted about in the last week.
    public mutating func newAlerts(minimum: Int64 = 2_000_000_000, now: Date = Date()) -> [Growth] {
        let fresh = growth(minimum: minimum, now: now).filter { item in
            alerted[item.path].map { now.timeIntervalSince($0) > 7 * 86_400 } ?? true
        }
        for item in fresh { alerted[item.path] = now }
        return fresh
    }

    public var lastSnapshotDate: Date? { snapshots.last?.date }
}

extension Storage {
    private var spaceHistoryURL: URL { directory.appendingPathComponent("space-history.json") }

    public func loadSpaceHistory() -> SpaceHistory {
        guard let data = try? Data(contentsOf: spaceHistoryURL) else { return SpaceHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(SpaceHistory.self, from: data)) ?? SpaceHistory()
    }

    public func saveSpaceHistory(_ history: SpaceHistory) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(history) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: spaceHistoryURL, options: .atomic)
    }
}
