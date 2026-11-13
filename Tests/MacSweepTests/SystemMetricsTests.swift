import XCTest
@testable import MacSweep

final class SystemMetricsTests: XCTestCase {
    func testFirstCPUSampleIsUnavailable() {
        XCTAssertNil(SystemMetrics.cpuUsage(
            previous: nil,
            current: CPUTicks(user: 10, system: 10, idle: 80, nice: 0)
        ))
    }

    func testCPUUsageUsesDeltaAcrossAllTickCategories() {
        let previous = CPUTicks(user: 100, system: 20, idle: 300, nice: 10)
        let current = CPUTicks(user: 130, system: 30, idle: 360, nice: 10)
        XCTAssertEqual(
            SystemMetrics.cpuUsage(previous: previous, current: current) ?? -1,
            0.4,
            accuracy: 0.000_001
        )
    }

    func testCPUUsageRejectsNoElapsedTicks() {
        let ticks = CPUTicks(user: 1, system: 2, idle: 3, nice: 4)
        XCTAssertNil(SystemMetrics.cpuUsage(previous: ticks, current: ticks))
    }

    func testCPUUsageRejectsCounterReset() {
        let previous = CPUTicks(user: 100, system: 20, idle: 300, nice: 10)
        let reset = CPUTicks(user: 1, system: 2, idle: 3, nice: 4)
        XCTAssertNil(SystemMetrics.cpuUsage(previous: previous, current: reset))
    }

    func testCPUUsageRejectsOverflowingDeltaTotal() {
        let previous = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let current = CPUTicks(user: UInt64.max, system: 1, idle: 0, nice: 0)
        XCTAssertNil(SystemMetrics.cpuUsage(previous: previous, current: current))
    }

    func testMemoryUsedCountsResidentPagesMinusReclaimableCaches() {
        let pages = MemoryPageCounts(
            active: 4,
            inactive: 3,
            wired: 2,
            compressed: 2,
            purgeable: 1,
            external: 2,
            pageSize: 4_096
        )
        XCTAssertEqual(SystemMetrics.memoryUsed(total: 65_536, pages: pages), 32_768)
    }

    func testMemoryUsedClampsInconsistentCountersToZero() {
        let pages = MemoryPageCounts(
            active: 1,
            inactive: 0,
            wired: 0,
            compressed: 0,
            purgeable: 2,
            external: 0,
            pageSize: 4_096
        )
        XCTAssertEqual(SystemMetrics.memoryUsed(total: 1_024, pages: pages), 0)
    }

    func testMemoryUsedRejectsUnavailableAndOverflowingPageCounts() {
        XCTAssertNil(SystemMetrics.memoryUsed(total: 1_024, pages: nil))
        let overflow = MemoryPageCounts(
            active: UInt64.max,
            inactive: 1,
            wired: 0,
            compressed: 0,
            purgeable: 0,
            external: 0,
            pageSize: 4_096
        )
        XCTAssertNil(SystemMetrics.memoryUsed(total: Int64.max, pages: overflow))
    }
}
