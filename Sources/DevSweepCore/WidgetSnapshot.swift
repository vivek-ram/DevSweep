import Foundation

/// What the desktop widgets show. The app writes it; the widget extension (sandboxed, so it
/// can't look at disks or processes itself) only reads it.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct App: Codable, Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var watts: Double
        public var cpu: Double
        public var memory: Int64
        /// A small PNG of the app's icon in the widget folder, if there is one.
        public var iconFile: String?

        public init(name: String, watts: Double, cpu: Double, memory: Int64, iconFile: String?) {
            self.name = name
            self.watts = watts
            self.cpu = cpu
            self.memory = memory
            self.iconFile = iconFile
        }
    }

    public var date: Date
    public var healthScore: Int?
    /// MacHealth.Status raw value.
    public var healthStatus: String?
    public var healthReasons: [String]
    public var freeBytes: Int64
    public var totalBytes: Int64
    public var junkBytes: Int64
    public var idleProjectBytes: Int64
    public var idleProjects: Int
    public var updates: Int
    public var memoryUsed: Int64
    public var memoryTotal: Int64
    public var cpuTemperature: Double?
    /// ThermalSnapshot.State raw value.
    public var thermalState: String
    /// Apps drawing the most power, hottest first.
    public var hotApps: [App]
    public var freedThisMonth: Int64

    public init(date: Date = Date(), healthScore: Int? = nil, healthStatus: String? = nil, healthReasons: [String] = [],
                freeBytes: Int64 = 0, totalBytes: Int64 = 0, junkBytes: Int64 = 0, idleProjectBytes: Int64 = 0, idleProjects: Int = 0,
                updates: Int = 0, memoryUsed: Int64 = 0, memoryTotal: Int64 = 0, cpuTemperature: Double? = nil,
                thermalState: String = "nominal", hotApps: [App] = [], freedThisMonth: Int64 = 0) {
        self.date = date
        self.healthScore = healthScore
        self.healthStatus = healthStatus
        self.healthReasons = healthReasons
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.junkBytes = junkBytes
        self.idleProjectBytes = idleProjectBytes
        self.idleProjects = idleProjects
        self.updates = updates
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.cpuTemperature = cpuTemperature
        self.thermalState = thermalState
        self.hotApps = hotApps
        self.freedThisMonth = freedThisMonth
    }

    public var readyToFree: Int64 { junkBytes + idleProjectBytes }

    // MARK: Where it lives

    /// ~/Library/Application Support/DevSweep/Widget, using the real home folder even inside the
    /// widget's sandbox (its entitlements allow reading exactly this folder).
    public static var folder: String {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return home + "/Library/Application Support/DevSweep/Widget"
    }

    static var file: String { folder + "/snapshot.json" }

    public static func load() -> WidgetSnapshot? {
        FileManager.default.contents(atPath: file).flatMap(decode)
    }

    public func save() throws {
        try FileManager.default.createDirectory(atPath: Self.folder, withIntermediateDirectories: true)
        try encoded().write(to: URL(fileURLWithPath: Self.file), options: .atomic)
    }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    /// The icon's full path (a bare file name lives in the widget folder).
    public func iconPath(_ app: App) -> String? { app.iconFile.map { $0.hasPrefix("/") ? $0 : Self.folder + "/" + $0 } }

    /// What the widget gallery shows before DevSweep has written anything.
    public static let sample = WidgetSnapshot(
        healthScore: 82, healthStatus: "good", healthReasons: ["19 GB of junk"], freeBytes: 61_240_000_000, totalBytes: 494_380_000_000,
        junkBytes: 19_320_000_000, idleProjectBytes: 8_270_000_000, idleProjects: 5, updates: 4, memoryUsed: 10_920_000_000,
        memoryTotal: 17_179_869_184, cpuTemperature: 58, thermalState: "nominal",
        hotApps: [App(name: "Xcode", watts: 6.8, cpu: 1.6, memory: 2_880_000_000, iconFile: nil),
                  App(name: "Google Chrome", watts: 2.4, cpu: 0.12, memory: 3_410_000_000, iconFile: nil),
                  App(name: "node", watts: 1.7, cpu: 0.43, memory: 640_000_000, iconFile: nil)],
        freedThisMonth: 21_160_000_000)
}
