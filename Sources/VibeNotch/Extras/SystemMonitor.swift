import Darwin
import Foundation

struct SystemStats: Equatable {
    var cpu: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    /// What VibeNotch itself uses, so people can see it stays light.
    var ownMemory: UInt64 = 0

    var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    var diskFraction: Double { diskTotal > 0 ? 1 - Double(diskFree) / Double(diskTotal) : 0 }
}

/// Samples only while a card that shows it is on screen.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var stats = SystemStats()
    private var watchers = 0
    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?

    func watch() {
        watchers += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { SystemMonitor.shared.sample() }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
        lastTicks = nil
    }

    private static let queue = DispatchQueue(label: "vibenotch.system-monitor", qos: .utility)

    /// The disk query alone can take tens of milliseconds, so everything is read off the main thread.
    private func sample() {
        let previous = stats, last = lastTicks
        Self.queue.async {
            let (s, ticks) = Self.measure(previous, last)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let monitor = SystemMonitor.shared
                    guard monitor.timer != nil else { return }
                    if let ticks { monitor.lastTicks = ticks }
                    if s != monitor.stats { monitor.stats = s }
                }
            }
        }
    }

    private nonisolated static func measure(_ previous: SystemStats, _ last: (busy: UInt64, total: UInt64)?)
        -> (SystemStats, (busy: UInt64, total: UInt64)?) {
        var s = previous
        let ticks = cpuTicks()
        if let ticks, let last, ticks.total > last.total {
            s.cpu = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
        }
        s.memoryUsed = memoryUsed() ?? s.memoryUsed
        s.ownMemory = footprint() ?? s.ownMemory
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            s.diskFree = v.volumeAvailableCapacityForImportantUsage ?? s.diskFree
            s.diskTotal = Int64(v.volumeTotalCapacity ?? 0)
        }
        return (s, ticks)
    }

    private nonisolated static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Same notion as Activity Monitor's "Memory Used": app memory + wired + compressed.
    private nonisolated static func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    private nonisolated static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
