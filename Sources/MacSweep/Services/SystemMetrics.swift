import Darwin
import Foundation

struct SystemSnapshot: Sendable, Equatable {
    var cpuUsage: Double?
    var memoryUsed: Int64?
    var memoryTotal: Int64
    var memoryPressure: String
    var diskFree: Int64?
    var diskTotal: Int64?
    var uptime: TimeInterval
    var updatedAt: Date?

    static let unavailable = SystemSnapshot(
        cpuUsage: nil,
        memoryUsed: nil,
        memoryTotal: 0,
        memoryPressure: "Unavailable",
        diskFree: nil,
        diskTotal: nil,
        uptime: 0,
        updatedAt: nil
    )
}

struct CPUTicks: Sendable, Equatable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

struct MemoryPageCounts: Sendable {
    let active: UInt64
    let inactive: UInt64
    let wired: UInt64
    let compressed: UInt64
    let purgeable: UInt64
    let external: UInt64
    let pageSize: UInt64
}

struct SystemMetricSample: Sendable {
    let cpuTicks: CPUTicks?
    let memoryUsed: Int64?
    let memoryTotal: Int64
    let memoryPressure: String
    let diskFree: Int64?
    let diskTotal: Int64?
    let uptime: TimeInterval
    let sampledAt: Date
}

enum SystemMetrics {
    static func cpuUsage(previous: CPUTicks?, current: CPUTicks?) -> Double? {
        guard let previous, let current,
              current.user >= previous.user,
              current.system >= previous.system,
              current.idle >= previous.idle,
              current.nice >= previous.nice else {
            return nil
        }

        let user = current.user - previous.user
        let system = current.system - previous.system
        let idle = current.idle - previous.idle
        let nice = current.nice - previous.nice
        let (busyWithoutNice, overflow1) = user.addingReportingOverflow(system)
        let (busy, overflow2) = busyWithoutNice.addingReportingOverflow(nice)
        let (total, overflow3) = busy.addingReportingOverflow(idle)
        guard !overflow1, !overflow2, !overflow3, total > 0 else { return nil }

        return min(max(Double(busy) / Double(total), 0), 1)
    }

    static func memoryUsed(total: Int64, pages: MemoryPageCounts?) -> Int64? {
        guard total > 0, let pages else { return nil }
        let residentValues = [pages.active, pages.inactive, pages.wired, pages.compressed]
        let reclaimableValues = [pages.purgeable, pages.external]
        guard let resident = checkedSum(residentValues),
              let reclaimable = checkedSum(reclaimableValues) else { return nil }
        let usedPages = resident >= reclaimable ? resident - reclaimable : 0
        let (usedBytes, overflow) = usedPages.multipliedReportingOverflow(by: pages.pageSize)
        guard !overflow, usedBytes <= UInt64(Int64.max) else { return nil }
        return min(total, Int64(usedBytes))
    }

    static func sample() -> SystemMetricSample {
        let total = physicalMemory()
        let pages = memoryPages()
        let disk = diskCapacity()
        return SystemMetricSample(
            cpuTicks: cpuTicks(),
            memoryUsed: memoryUsed(total: total, pages: pages),
            memoryTotal: total,
            memoryPressure: memoryPressure(),
            diskFree: disk?.free,
            diskTotal: disk?.total,
            uptime: ProcessInfo.processInfo.systemUptime,
            sampledAt: Date()
        )
    }

    private static func cpuTicks() -> CPUTicks? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    private static func physicalMemory() -> Int64 {
        let value = ProcessInfo.processInfo.physicalMemory
        return value <= UInt64(Int64.max) ? Int64(value) : 0
    }

    private static func memoryPages() -> MemoryPageCounts? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryPageCounts(
            active: UInt64(statistics.active_count),
            inactive: UInt64(statistics.inactive_count),
            wired: UInt64(statistics.wire_count),
            compressed: UInt64(statistics.compressor_page_count),
            purgeable: UInt64(statistics.purgeable_count),
            external: UInt64(statistics.external_page_count),
            pageSize: UInt64(getpagesize())
        )
    }

    private static func checkedSum(_ values: [UInt64]) -> UInt64? {
        var total: UInt64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private static func memoryPressure() -> String {
        var level: Int32 = 0
        var size = MemoryLayout.size(ofValue: level)
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return "Unavailable"
        }
        switch level {
        case 1: return "Normal"
        case 2: return "Warning"
        case 4: return "Critical"
        default: return "Unavailable"
        }
    }

    private static func diskCapacity() -> (free: Int64, total: Int64)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]), let free = values.volumeAvailableCapacityForImportantUsage,
              let totalValue = values.volumeTotalCapacity else {
            return nil
        }
        return (max(0, free), max(0, Int64(totalValue)))
    }
}
