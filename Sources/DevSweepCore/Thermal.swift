import Darwin
import Foundation

/// How hot the Mac is: its temperature sensors and macOS's own thermal state.
public struct ThermalSnapshot: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable {
        case nominal, fair, serious, critical

        public var title: String {
            switch self {
            case .nominal: "Cool"
            case .fair: "Warm"
            case .serious: "Hot"
            case .critical: "Very hot"
            }
        }

        /// What it means for you.
        public var detail: String {
            switch self {
            case .nominal: "Running normally."
            case .fair: "Warming up. Fans may speed up."
            case .serious: "Hot. macOS is slowing things down to cool off."
            case .critical: "Very hot. macOS is slowing everything down a lot."
            }
        }
    }

    public struct Sensor: Sendable, Equatable, Codable, Identifiable {
        public var id: String { name }
        public let name: String
        public let celsius: Double
    }

    /// Sensors grouped into the parts of the Mac they sit in, hottest reading per part.
    public struct Group: Sendable, Equatable, Identifiable {
        public var id: String { title }
        public let title: String
        public let symbol: String
        public let celsius: Double
    }

    public var date = Date()
    /// Average of the processor's die sensors, in °C.
    public var cpu: Double?
    /// The hottest sensor right now.
    public var hottest: Double?
    public var battery: Double?
    public var sensors: [Sensor] = []
    public var state: State = .nominal

    public init() {}

    public var groups: [Group] {
        let parts: [(title: String, symbol: String, matches: (String) -> Bool)] = [
            ("CPU cores", "cpu", { $0.contains("tdie") || $0.contains("acc mtr") || $0.hasPrefix("cpu") }),
            ("Chip", "memorychip", { $0.contains("soc") || $0.contains("pmgr") || $0.contains("tdev") }),
            ("Graphics", "cube.transparent", { $0.contains("gpu") }),
            ("Neural Engine", "brain", { $0.contains("ane") }),
            ("SSD", "internaldrive", { $0.contains("nand") || $0.contains("ssd") }),
            ("Battery", "battery.75percent", { $0.contains("battery") || $0.contains("gas gauge") }),
        ]
        return parts.compactMap { part in
            let readings = sensors.filter { sensor in
                let name = sensor.name.lowercased()
                return part.matches(name) && !name.contains("tcal")
            }
            return readings.map(\.celsius).max().map { Group(title: part.title, symbol: part.symbol, celsius: $0) }
        }
    }
}

/// Reads temperature sensors through IOKit's HID event system, the way macOS's own tools do.
/// The calls are private but stable; anything missing just means no reading.
public enum ThermalSensors {
    public static func read() -> ThermalSnapshot {
        var snapshot = ThermalSnapshot()
        snapshot.state = currentState()
        let sensors = HIDSensors.shared?.temperatures() ?? []
        snapshot.sensors = sensors.sorted { $0.celsius > $1.celsius }
        // Die sensors are the processor ("PMU tdie…", "pACC/eACC MTR Temp…"); calibration ones aren't real readings.
        let dies = sensors.filter { sensor in
            let name = sensor.name.lowercased()
            return (name.contains("tdie") || name.contains("acc mtr") || name.contains("cpu")) && !name.contains("tcal")
        }
        if !dies.isEmpty { snapshot.cpu = dies.map(\.celsius).reduce(0, +) / Double(dies.count) }
        let plausible = sensors.filter { !$0.name.lowercased().contains("tcal") }
        snapshot.hottest = plausible.map(\.celsius).max()
        let batteries = sensors.filter { $0.name.lowercased().contains("battery") || $0.name.lowercased().contains("gas gauge") }
        if !batteries.isEmpty { snapshot.battery = batteries.map(\.celsius).max() }
        if snapshot.cpu == nil { snapshot.cpu = snapshot.hottest }
        return snapshot
    }

    public static func currentState() -> ThermalSnapshot.State {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}

/// The handful of IOHIDEventSystemClient functions needed, looked up at run time.
private final class HIDSensors: @unchecked Sendable {
    static let shared = HIDSensors()

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias FloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let floatValue: FloatValueFn
    private let client: CFTypeRef
    private let lock = NSLock()

    private static let temperatureEvent: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16       // its level field

    private init?() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(iokit, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = load("IOHIDEventSystemClientCreate", as: CreateFn.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let floatValue = load("IOHIDEventGetFloatValue", as: FloatValueFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // Apple's vendor usage page, temperature sensor usage.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(client, matching)
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.floatValue = floatValue
        self.client = client
    }

    func temperatures() -> [ThermalSnapshot.Sensor] {
        lock.lock()
        defer { lock.unlock() }
        guard let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        var seen: [String: Double] = [:]
        for service in services {
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let celsius = floatValue(event, Self.temperatureField)
            // Ignore sensors that aren't reporting (0 or nonsense values).
            guard celsius > 5, celsius < 130 else { continue }
            seen[name] = max(seen[name] ?? 0, celsius)
        }
        return seen.map { ThermalSnapshot.Sensor(name: $0.key, celsius: $0.value) }
    }
}
