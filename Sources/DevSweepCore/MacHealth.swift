import Foundation

/// A 0–100 score for how your Mac is doing, with the reasons it isn't 100.
public struct MacHealth: Sendable, Equatable {
    public enum Status: String, Sendable {
        case excellent, good, fair, needsAttention, critical

        public var title: String {
            switch self {
            case .excellent: "Excellent"
            case .good: "Good"
            case .fair: "Fair"
            case .needsAttention: "Needs attention"
            case .critical: "Critical"
            }
        }
    }

    public struct Factor: Identifiable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var detail: String
        public var symbol: String
        public var penalty: Int
    }

    public struct Input: Sendable {
        public var freeBytes: Int64
        public var totalBytes: Int64
        public var junkBytes: Int64 = 0
        public var idleProjectBytes: Int64 = 0
        public var memoryPressure: SystemSnapshot.Pressure?
        public var swapBytes: Int64?
        public var batteryHealth: Int?
        public var brokenLaunchItems = 0
        public var trashedBytes: Int64 = 0

        public init(freeBytes: Int64, totalBytes: Int64) {
            self.freeBytes = freeBytes
            self.totalBytes = totalBytes
        }
    }

    public var score: Int
    public var status: Status
    /// What cost points, worst first.
    public var factors: [Factor]

    public static func evaluate(_ input: Input) -> MacHealth {
        var factors: [Factor] = []
        func add(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ penalty: Int) {
            if penalty > 0 { factors.append(Factor(id: id, title: title, detail: detail, symbol: symbol, penalty: penalty)) }
        }

        let free = input.totalBytes > 0 ? Double(input.freeBytes) / Double(input.totalBytes) : 1
        let freeText = "\(Format.bytes(input.freeBytes)) free (\(Int(free * 100))%)"
        add("space", "Low on storage", freeText, "internaldrive.fill",
            free < 0.05 ? 40 : free < 0.10 ? 28 : free < 0.15 ? 16 : free < 0.20 ? 8 : 0)

        let gb: Int64 = 1_000_000_000
        add("junk", "Junk is piling up", "\(Format.bytes(input.junkBytes)) of caches, logs and installers", "trash.fill",
            input.junkBytes > 20 * gb ? 15 : input.junkBytes > 10 * gb ? 10 : input.junkBytes > 2 * gb ? 5 : 0)
        add("projects", "Idle projects", "\(Format.bytes(input.idleProjectBytes)) of rebuildable files in idle projects", "folder.fill",
            input.idleProjectBytes > 10 * gb ? 8 : input.idleProjectBytes > 2 * gb ? 4 : 0)

        var memory = 0
        switch input.memoryPressure {
        case .critical: memory += 15
        case .warning: memory += 8
        default: break
        }
        if let swap = input.swapBytes { memory += swap > 8 * gb ? 6 : swap > 2 * gb ? 3 : 0 }
        add("memory", "Memory is tight", input.swapBytes.map { "\(Format.bytes($0)) of swap in use" } ?? "Memory pressure is high",
            "memorychip.fill", memory)

        if let health = input.batteryHealth {
            add("battery", "Battery is wearing", "Holds \(health)% of its original charge", "battery.50percent",
                health < 70 ? 10 : health < 80 ? 6 : 0)
        }
        add("launch", "Broken background items", "\(input.brokenLaunchItems) point to programs that no longer exist", "exclamationmark.triangle.fill",
            input.brokenLaunchItems > 0 ? 3 : 0)
        add("trash", "Full Trash", "\(Format.bytes(input.trashedBytes)) waiting in the Trash", "trash.circle.fill",
            input.trashedBytes > 5 * gb ? 3 : 0)

        let score = max(0, 100 - factors.reduce(0) { $0 + $1.penalty })
        let status: Status = score >= 85 ? .excellent : score >= 70 ? .good : score >= 55 ? .fair : score >= 35 ? .needsAttention : .critical
        return MacHealth(score: score, status: status, factors: factors.sorted { $0.penalty > $1.penalty })
    }
}
