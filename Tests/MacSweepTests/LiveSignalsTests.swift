import Foundation
import MacSweepCore
import XCTest
@testable import MacSweep

final class LiveSignalsTests: XCTestCase {
    func testCheapSystemReadsWork() {
        XCTAssertNotNil(SystemSignals.swapUsed())
        XCTAssertNotNil(SystemSignals.load1())
        XCTAssertNotNil(SystemSignals.pressureLevel())
        XCTAssertGreaterThan(SystemSignals.cores, 0)
        XCTAssertTrue((0...3).contains(SystemSignals.thermal))
    }

    func testBackgroundIntervals() {
        XCTAssertEqual(SystemMonitor.backgroundInterval(onBattery: false, lowPower: false), 30)
        XCTAssertEqual(SystemMonitor.backgroundInterval(onBattery: true, lowPower: false), 60)
        XCTAssertEqual(SystemMonitor.backgroundInterval(onBattery: false, lowPower: true), 60)
    }

    func testRunTimesOutAndStopsItsOwnChild() {
        let started = Date()
        XCTAssertNil(SystemSignals.run("/bin/sleep", ["5"], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(SystemSignals.run("/bin/echo", ["hi"])?.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
        XCTAssertNil(SystemSignals.run("/nonexistent/tool", []))
    }

    /// Spawns its own `yes > /dev/null`, checks the scanner and rules flag it, then stops it.
    func testScannerFindsASpawnedBusyProcessAndRulesFlagIt() throws {
        let busy = Process()
        busy.executableURL = URL(filePath: "/usr/bin/yes")
        busy.standardOutput = FileHandle.nullDevice
        busy.standardError = FileHandle.nullDevice
        try busy.run()
        defer { if busy.isRunning { busy.terminate() }; busy.waitUntilExit() }
        let pid = busy.processIdentifier

        let scanner = ProcessScanner()
        _ = scanner.scan()
        Thread.sleep(forTimeInterval: 2)
        let sample = try XCTUnwrap(scanner.scan().first { $0.pid == pid }, "The spawned process is readable")
        XCTAssertEqual(sample.name, "yes")
        XCTAssertGreaterThan(sample.cpu, 0.5)
        XCTAssertFalse(scanner.scan().contains { $0.pid == getpid() }, "MacSweep never reports itself")

        var thresholds = LiveSignalEvaluator.Thresholds()
        thresholds.processSustain = 0
        thresholds.processCPUTrigger = 0.5
        var evaluator = LiveSignalEvaluator(thresholds: thresholds)
        let observations = evaluator.evaluate(LiveSample(at: Date(), processes: [sample]))
        let runaway = try XCTUnwrap(observations.first { $0.kind == .runawayProcess && $0.key == "yes" })
        XCTAssertEqual(runaway.condition, .trigger)

        var engine = NudgeEngine()
        var noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        XCTAssertEqual(engine.ingest(observations, now: noon).active.map(\.id), ["runawayProcess:yes"])

        busy.terminate()
        busy.waitUntilExit()
        noon += 30
        let after = evaluator.evaluate(LiveSample(at: noon, processes: scanner.scan()))
        XCTAssertEqual(after.first { $0.key == "yes" }?.condition, .clear)
        // Other busy apps on the Mac may show up too; only the spawned process matters here.
        XCTAssertFalse(engine.ingest(after.filter { $0.key == "yes" }, now: noon).active.contains { $0.key == "yes" })
    }
}
