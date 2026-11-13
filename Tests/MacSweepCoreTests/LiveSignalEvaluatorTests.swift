import Foundation
import XCTest
@testable import MacSweepCore

final class LiveSignalEvaluatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let gb = LiveSignalEvaluator.gigabyte

    private func obs(_ list: [NudgeObservation], _ kind: NudgeKind, key: String = "") -> NudgeObservation? {
        list.first { $0.kind == kind && $0.key == key }
    }

    func testCPUThresholdsHaveHysteresis() {
        var e = LiveSignalEvaluator()
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, cpu: 0.9)), .cpuSustained)?.condition, .trigger)
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, cpu: 0.7)), .cpuSustained)?.condition, .hold)
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, cpu: 0.5)), .cpuSustained)?.condition, .clear)
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, cpu: 0.9)), .cpuSustained)?.sustain, 600)
    }

    func testCPUMessageNamesTheBusiestProcess() {
        var e = LiveSignalEvaluator()
        let s = LiveSample(at: t0, cpu: 0.95, processes: [ProcessSample(pid: 9, name: "ffmpeg", cpu: 3.2, residentBytes: 1)])
        XCTAssertTrue(obs(e.evaluate(s), .cpuSustained)?.message.contains("ffmpeg at 320%") ?? false)
    }

    func testMemoryPressureLevels() {
        var e = LiveSignalEvaluator()
        let critical = obs(e.evaluate(LiveSample(at: t0, memoryPressureLevel: 4)), .memoryPressure)
        XCTAssertEqual(critical?.severity, .bad); XCTAssertEqual(critical?.sustain, 60)
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, memoryPressureLevel: 2)), .memoryPressure)?.sustain, 300)
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, memoryPressureLevel: 1)), .memoryPressure)?.condition, .clear)
    }

    func testSwapGrowthNeedsHalfAWindowOfHistory() {
        var e = LiveSignalEvaluator()
        XCTAssertNil(obs(e.evaluate(LiveSample(at: t0, swapUsed: gb)), .swapGrowth))
        XCTAssertNil(obs(e.evaluate(LiveSample(at: t0 + 600, swapUsed: 2 * gb)), .swapGrowth))
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0 + 900, swapUsed: 3 * gb + 1)), .swapGrowth)?.condition, .trigger)
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0 + 1000, swapUsed: 2 * gb)), .swapGrowth)?.condition, .hold)
        // After the window passes with flat swap, it clears.
        _ = e.evaluate(LiveSample(at: t0 + 2000, swapUsed: 2 * gb))
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0 + 3000, swapUsed: 2 * gb)), .swapGrowth)?.condition, .clear)
    }

    func testThermalAndThrottling() {
        var e = LiveSignalEvaluator()
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, thermal: 0)), .thermal)?.condition, .clear)
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, thermal: 1)), .thermal)?.condition, .hold)
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, thermal: 1, speedLimit: 60)), .thermal)?.condition, .trigger)
        let serious = obs(e.evaluate(LiveSample(at: t0, thermal: 2, speedLimit: 80)), .thermal)
        XCTAssertEqual(serious?.condition, .trigger)
        XCTAssertTrue(serious?.message.contains("limited to 80%") ?? false)
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, thermal: 3)), .thermal)?.severity, .bad)
    }

    func testRunawayGroupsByNameAndClearsWhenGone() {
        var e = LiveSignalEvaluator()
        let hot = [ProcessSample(pid: 1, name: "yes", cpu: 0.99, residentBytes: 1_000),
                   ProcessSample(pid: 2, name: "Helper", cpu: 0.45, residentBytes: 1),
                   ProcessSample(pid: 3, name: "Helper", cpu: 0.45, residentBytes: 1),
                   ProcessSample(pid: 4, name: "idle", cpu: 0.0, residentBytes: 1)]
        let first = e.evaluate(LiveSample(at: t0, processes: hot))
        XCTAssertEqual(obs(first, .runawayProcess, key: "yes")?.condition, .trigger)
        XCTAssertTrue(obs(first, .runawayProcess, key: "yes")?.message.contains("PID 1") ?? false)
        XCTAssertEqual(obs(first, .runawayProcess, key: "Helper")?.condition, .trigger, "0.45 + 0.45 cores")
        XCTAssertNil(obs(first, .runawayProcess, key: "idle"), "Cool processes that never triggered are not reported")
        XCTAssertNil(e.evaluate(LiveSample(at: t0 + 30)).first { $0.kind == .runawayProcess }, "No scan this tick: no change")
        let gone = e.evaluate(LiveSample(at: t0 + 60, processes: [ProcessSample(pid: 4, name: "idle", cpu: 0, residentBytes: 1)]))
        XCTAssertEqual(obs(gone, .runawayProcess, key: "yes")?.condition, .clear)
        XCTAssertEqual(obs(gone, .runawayProcess, key: "Helper")?.condition, .clear)
        XCTAssertTrue(e.evaluate(LiveSample(at: t0 + 90, processes: [])).filter { $0.kind == .runawayProcess }.isEmpty)
    }

    func testRunawayByMemory() {
        var e = LiveSignalEvaluator()
        let big = obs(e.evaluate(LiveSample(at: t0, processes: [ProcessSample(pid: 7, name: "Chrome", cpu: 0.1, residentBytes: 5 * gb)])),
                      .runawayProcess, key: "Chrome")
        XCTAssertEqual(big?.condition, .trigger)
        XCTAssertTrue(big?.message.contains("of memory") ?? false)
        let mid = obs(e.evaluate(LiveSample(at: t0 + 30, processes: [ProcessSample(pid: 7, name: "Chrome", cpu: 0.1, residentBytes: 3 * gb + gb / 2)])),
                      .runawayProcess, key: "Chrome")
        XCTAssertEqual(mid?.condition, .hold)
    }

    func testDiskLowBands() {
        var e = LiveSignalEvaluator()
        let total = 500 * gb
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, diskFree: 100 * gb, diskTotal: total)), .diskLow)?.condition, .clear)
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, diskFree: 60 * gb, diskTotal: total)), .diskLow)?.condition, .hold)
        let warn = obs(e.evaluate(LiveSample(at: t0, diskFree: 40 * gb, diskTotal: total)), .diskLow)
        XCTAssertEqual(warn?.condition, .trigger); XCTAssertEqual(warn?.severity, .warn)
        let bad = obs(e.evaluate(LiveSample(at: t0, diskFree: 20 * gb, diskTotal: total)), .diskLow)
        XCTAssertEqual(bad?.severity, .bad); XCTAssertEqual(bad?.urgent, false)
        XCTAssertEqual(obs(e.evaluate(LiveSample(at: t0, diskFree: gb, diskTotal: total)), .diskLow)?.urgent, true)
    }

    func testDiskTrendProjectsDaysToFull() {
        var e = LiveSignalEvaluator()
        let total = 500 * gb
        var free = 30 * gb
        var last: NudgeObservation?
        for hour in 0...8 {
            last = obs(e.evaluate(LiveSample(at: t0 + Double(hour) * 3600, diskFree: free, diskTotal: total)), .diskTrend)
            free -= gb   // 1 GB an hour: about a day left
        }
        XCTAssertEqual(last?.condition, .trigger)
        XCTAssertTrue(last?.message.contains("fills in about") ?? false)
        var steady = LiveSignalEvaluator()
        for hour in 0...8 {
            last = obs(steady.evaluate(LiveSample(at: t0 + Double(hour) * 3600, diskFree: 200 * gb, diskTotal: total)), .diskTrend)
        }
        XCTAssertEqual(last?.condition, .clear)
    }

    func testPmsetAndPSParsers() {
        XCTAssertEqual(PmsetTherm.speedLimit("Note: No thermal warning level has been recorded\nCPU_Scheduler_Limit \t= 100\nCPU_Available_CPUs \t= 12\nCPU_Speed_Limit \t= 78\n"), 78)
        XCTAssertNil(PmsetTherm.speedLimit("Note: No thermal warning level has been recorded"))
        let ps = "  101  98.5  20480 /usr/bin/yes\n  202   0.0   1024 /Applications/Safari.app/Contents/MacOS/Safari\n  303 12.0 10 own\nbad line\n"
        let parsed = PSOutput.parse(ps, excluding: 303)
        XCTAssertEqual(parsed.map(\.name), ["yes", "Safari"])
        XCTAssertEqual(parsed[0].cpu, 0.985, accuracy: 0.0001)
        XCTAssertEqual(parsed[0].residentBytes, 20480 * 1024)
    }
}
