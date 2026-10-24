import CoreServices
import Foundation

/// Spotlight metadata with a time limit. When the Spotlight server is slow, a lookup can
/// block for minutes; after one slow answer DevSweep stops asking for the rest of the session
/// and callers fall back to plain file dates.
enum Spotlight {
    private static let lock = NSLock()
    private static var unavailable = false

    static func date(_ path: String, _ attribute: CFString, budget: TimeInterval = 0.75) -> Date? {
        lock.lock()
        let skip = unavailable
        lock.unlock()
        if skip { return nil }

        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.value = MDItemCreate(nil, path as CFString).flatMap { MDItemCopyAttribute($0, attribute) as? Date }
            done.signal()
        }
        if done.wait(timeout: .now() + budget) == .timedOut {
            lock.lock()
            unavailable = true
            lock.unlock()
            return nil
        }
        return box.value
    }

    private final class Box: @unchecked Sendable {
        var value: Date?
    }
}
