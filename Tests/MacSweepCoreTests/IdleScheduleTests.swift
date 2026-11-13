import MacSweepCore
import XCTest

final class IdleScheduleTests: XCTestCase {
    func testSampleIntervals() {
        XCTAssertEqual(IdleSchedule.sampleInterval(visible: true, constrained: true), 3)
        XCTAssertEqual(IdleSchedule.sampleInterval(visible: false, constrained: false), 30)
        XCTAssertEqual(IdleSchedule.sampleInterval(visible: false, constrained: true), 60)
    }

    func testProcessScanBacksOffWhileHiddenAndQuiet() {
        XCTAssertEqual(IdleSchedule.processScanInterval(visible: true, quietScans: 9, constrained: true), 30)
        XCTAssertEqual(IdleSchedule.processScanInterval(visible: false, quietScans: 0, constrained: false), 60)
        XCTAssertEqual(IdleSchedule.processScanInterval(visible: false, quietScans: 1, constrained: false), 120)
        XCTAssertEqual(IdleSchedule.processScanInterval(visible: false, quietScans: 3, constrained: false), 480)
        XCTAssertEqual(IdleSchedule.processScanInterval(visible: false, quietScans: 4, constrained: false), 600, "Capped at 10 minutes")
        XCTAssertEqual(IdleSchedule.processScanInterval(visible: false, quietScans: 50, constrained: true), 900, "Capped at 15 minutes on battery")
        XCTAssertEqual(IdleSchedule.processScanInterval(visible: false, quietScans: -2, constrained: false), 60)
    }

    func testQuietMeansCalmMacAndNoHotProcess() {
        XCTAssertTrue(IdleSchedule.isQuiet(totalCPU: 0.1, busiestProcessCores: 0.2))
        XCTAssertTrue(IdleSchedule.isQuiet(totalCPU: nil, busiestProcessCores: 0))
        XCTAssertFalse(IdleSchedule.isQuiet(totalCPU: 0.7, busiestProcessCores: 0.1), "A busy Mac resets the backoff")
        XCTAssertFalse(IdleSchedule.isQuiet(totalCPU: 0.2, busiestProcessCores: 0.9), "A hot process resets the backoff")
    }

    func testHealthChecksRunRarely() {
        XCTAssertEqual(IdleSchedule.healthCheckInterval(constrained: false), 6 * 3600)
        XCTAssertEqual(IdleSchedule.healthCheckInterval(constrained: true), 12 * 3600)
        XCTAssertEqual(IdleSchedule.firstHealthCheckDelay(visible: true), 60)
        XCTAssertEqual(IdleSchedule.firstHealthCheckDelay(visible: false), 300)
    }

    func testToleranceIsGenerousButBounded() {
        XCTAssertEqual(IdleSchedule.tolerance(for: 1), 0.5)
        XCTAssertEqual(IdleSchedule.tolerance(for: 30), 6)
        XCTAssertEqual(IdleSchedule.tolerance(for: 600), 60)
    }
}
