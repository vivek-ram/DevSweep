import Darwin
import Foundation

/// Memory and CPU used by one app, counting its helper processes too (browser tabs, Electron
/// renderers, language servers it started…), the way you'd think of it when deciding what to quit.
public struct AppUsage: Identifiable, Sendable, Equatable {
    /// The app bundle's path, or the process name for things that aren't apps.
    public var id: String
    public var name: String
    public var bundlePath: String?
    /// The process that owns the group; quitting it quits the app.
    public var pid: Int32
    /// Physical footprint, the "Memory" column in Activity Monitor.
    public var memory: Int64
    /// Share of one core (1.0 = one core fully busy).
    public var cpu: Double
    public var processCount: Int
    /// Power drawn right now, in watts, from the energy macOS accounts to each process. This is
    /// what heats the Mac up; 0 where macOS doesn't report energy.
    public var watts: Double = 0
}

/// Samples every process this user can read and groups them by app. CPU is a rate, so keep
/// one sampler and call `sample()` on a timer.
public final class ProcessSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastCPU: [Int32: (cpu: UInt64, energy: UInt64, wall: UInt64)] = [:]
    private var bundleNames: [String: String] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    public init() {}

    public func sample() -> [AppUsage] {
        lock.lock()
        defer { lock.unlock() }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var groups: [String: AppUsage] = [:]
        var seen: [Int32: (cpu: UInt64, energy: UInt64, wall: UInt64)] = [:]

        for pid in Self.allPIDs() where pid > 0 {
            guard let usage = Self.rusage(pid) else { continue }   // other users' and system processes
            // proc_pid_rusage reports CPU time in mach ticks on Apple silicon.
            let cpuTime = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom
            seen[pid] = (cpuTime, usage.ri_energy_nj, now)
            var cpu = 0.0
            var watts = 0.0
            if let last = lastCPU[pid], now > last.wall {
                let seconds = Double(now - last.wall) / 1e9
                if cpuTime >= last.cpu { cpu = Double(cpuTime - last.cpu) / Double(now - last.wall) }
                if usage.ri_energy_nj >= last.energy { watts = Double(usage.ri_energy_nj - last.energy) / 1e9 / seconds }
            }

            let owner = Self.responsiblePID(pid) ?? pid
            let ownerPath = Self.path(owner) ?? Self.path(pid)
            let bundle = ownerPath.flatMap(Self.outerApp) ?? Self.path(pid).flatMap(Self.outerApp)
            let key = bundle ?? Self.name(pid) ?? "pid \(pid)"
            var group = groups[key] ?? AppUsage(id: key, name: bundle.map(displayName) ?? key, bundlePath: bundle,
                                                pid: owner, memory: 0, cpu: 0, processCount: 0)
            group.memory += Int64(usage.ri_phys_footprint)
            group.cpu += cpu
            group.watts += watts
            group.processCount += 1
            if pid == owner { group.pid = pid }
            groups[key] = group
        }
        lastCPU = seen
        return groups.values.sorted { $0.memory > $1.memory }
    }

    private func displayName(_ bundle: String) -> String {
        if let cached = bundleNames[bundle] { return cached }
        let info = Bundle(path: bundle)?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
            ?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        bundleNames[bundle] = name
        return name
    }

    // MARK: Process info

    static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<Int32>.size))
        }
        return Array(pids.prefix(Int(max(filled, 0))))
    }

    static func rusage(_ pid: Int32) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return result == 0 ? info : nil
    }

    static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    static func name(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Helper" → "/Applications/Google Chrome.app".
    static func outerApp(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private typealias ResponsibleFunction = @convention(c) (Int32) -> Int32
    private static let responsible: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    /// The app macOS holds responsible for a process (Safari for its web pages, an editor for
    /// the language servers it started).
    static func responsiblePID(_ pid: Int32) -> Int32? {
        guard let responsible else { return nil }
        let owner = responsible(pid)
        return owner > 0 ? owner : nil
    }
}
