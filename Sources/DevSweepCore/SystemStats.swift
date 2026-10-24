import Darwin
import Foundation
import IOKit
import IOKit.ps

public struct SystemSnapshot: Sendable, Equatable {
    public enum Pressure: Sendable { case normal, warning, critical }

    public struct Battery: Sendable, Equatable {
        public var percent: Int
        public var charging: Bool
        public var onPower: Bool
        public var minutesLeft: Int?
        public var cycleCount: Int?
        /// Maximum capacity as a share of the original design capacity.
        public var health: Int?
    }

    public var date = Date()
    /// 0...1 across all cores.
    public var cpu: Double = 0
    public var memoryUsed: Int64 = 0
    public var memoryTotal: Int64 = 0
    /// What "Memory Used" is made of, plus the file cache macOS gives back on demand.
    public var memoryApp: Int64 = 0
    public var memoryWired: Int64 = 0
    public var memoryCompressed: Int64 = 0
    public var memoryCached: Int64 = 0
    public var pressure: Pressure = .normal
    public var swapUsed: Int64 = 0
    /// Bytes per second.
    public var networkIn: Double = 0
    public var networkOut: Double = 0
    public var battery: Battery?

    public init() {}
}

/// Reads CPU, memory, network and battery. CPU and network are rates, so each sample is
/// relative to the previous one; keep one sampler and call `sample()` on a timer.
public final class SystemSampler: @unchecked Sendable {
    private var lastTicks: [UInt64]?
    private var lastNetwork: (date: Date, bytesIn: UInt64, bytesOut: UInt64)?

    public init() {}

    public func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.cpu = cpuUsage()
        (snapshot.memoryUsed, snapshot.memoryTotal) = memory()
        if let parts = memoryParts() {
            (snapshot.memoryApp, snapshot.memoryWired, snapshot.memoryCompressed, snapshot.memoryCached) = parts
        }
        snapshot.pressure = pressure()
        snapshot.swapUsed = swap()
        (snapshot.networkIn, snapshot.networkOut) = network()
        snapshot.battery = battery()
        return snapshot
    }

    // MARK: CPU

    private func cpuUsage() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }

        // user, system, idle, nice per core
        var ticks = [UInt64](repeating: 0, count: 4)
        for core in 0..<Int(count) {
            for state in 0..<4 {
                ticks[state] += UInt64(UInt32(bitPattern: info[core * Int(CPU_STATE_MAX) + state]))
            }
        }
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return 0 }
        let delta = zip(ticks, last).map { $0 &- $1 }
        let busy = delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_SYSTEM)] + delta[Int(CPU_STATE_NICE)]
        let total = busy + delta[Int(CPU_STATE_IDLE)]
        return total == 0 ? 0 : Double(busy) / Double(total)
    }

    // MARK: Memory

    /// Like Activity Monitor's "Memory Used": app memory + wired + compressed.
    private func memory() -> (Int64, Int64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = Int64(vm_kernel_page_size)
        let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let used = (app + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    private func memoryParts() -> (app: Int64, wired: Int64, compressed: Int64, cached: Int64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Int64(vm_kernel_page_size)
        return ((Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * page,
                Int64(stats.wire_count) * page,
                Int64(stats.compressor_page_count) * page,
                (Int64(stats.external_page_count) + Int64(stats.purgeable_count)) * page)
    }

    private func pressure() -> SystemSnapshot.Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return level >= 4 ? .critical : level >= 2 ? .warning : .normal
    }

    private func swap() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(usage.xsu_used)
    }

    // MARK: Network

    private func network() -> (Double, Double) {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (0, 0) }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            // Wi-Fi and Ethernet only; VPN tunnels would count the same traffic twice.
            guard name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            bytesIn += UInt64(stats.ifi_ibytes)
            bytesOut += UInt64(stats.ifi_obytes)
        }
        let now = Date()
        defer { lastNetwork = (now, bytesIn, bytesOut) }
        guard let last = lastNetwork else { return (0, 0) }
        let seconds = now.timeIntervalSince(last.date)
        guard seconds > 0 else { return (0, 0) }
        // The kernel's counters are 32-bit and wrap around.
        func delta(_ new: UInt64, _ old: UInt64) -> Double {
            Double(new >= old ? new - old : (new &+ (1 << 32)) &- old)
        }
        return (delta(bytesIn, last.bytesIn) / seconds, delta(bytesOut, last.bytesOut) / seconds)
    }

    // MARK: Battery

    private func battery() -> SystemSnapshot.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            var battery = SystemSnapshot.Battery(
                percent: current * 100 / max,
                charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                onPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesLeft: (description[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil })
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func property(_ key: String) -> Int? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
                }
                battery.cycleCount = property("CycleCount")
                if let raw = property("AppleRawMaxCapacity") ?? property("NominalChargeCapacity"),
                   let design = property("DesignCapacity"), design > 0 {
                    battery.health = min(100, raw * 100 / design)
                }
            }
            return battery
        }
        return nil
    }
}
