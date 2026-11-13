import Foundation
import XCTest
@testable import MacSweepCore

final class HealthChecksTests: XCTestCase {
    private func find(_ list: [NudgeObservation], _ kind: NudgeKind) -> NudgeObservation? { list.first { $0.kind == kind } }

    func testToolParsers() {
        XCTAssertEqual(HealthCheckParsers.sip("System Integrity Protection status: enabled.\n"), true)
        XCTAssertEqual(HealthCheckParsers.sip("System Integrity Protection status: disabled.\n"), false)
        XCTAssertNil(HealthCheckParsers.sip("command not found"))
        XCTAssertEqual(HealthCheckParsers.gatekeeper("assessments enabled\n"), true)
        XCTAssertEqual(HealthCheckParsers.gatekeeper("assessments disabled\n"), false)
        XCTAssertEqual(HealthCheckParsers.fileVault("FileVault is On.\n"), true)
        XCTAssertEqual(HealthCheckParsers.fileVault("FileVault is Off.\n"), false)
        XCTAssertEqual(HealthCheckParsers.fileVault("Encryption in progress: Percent completed = 12"), true)
        XCTAssertEqual(HealthCheckParsers.firewall("Firewall is enabled. (State = 1)\n"), true)
        XCTAssertEqual(HealthCheckParsers.firewall("Firewall is disabled. (State = 0)\n"), false)
        XCTAssertEqual(HealthCheckParsers.smartStatus("   Device Location:  Internal\n   SMART Status:             Verified\n"), "Verified")
        XCTAssertNil(HealthCheckParsers.smartStatus("Could not find disk"))
    }

    func testUpdatePlistAndCrashNames() {
        let plist: [String: Any] = ["RecommendedUpdates": [["Display Name": "macOS Tahoe 26.7", "Display Version": "26.7"],
                                                           ["Display Name": "Safari", "Display Version": "26.1"]]]
        XCTAssertEqual(HealthCheckParsers.pendingUpdates(plist), ["macOS Tahoe 26.7", "Safari 26.1"])
        XCTAssertEqual(HealthCheckParsers.pendingUpdates(["LastRecommendedUpdatesAvailable": 0]), [])
        XCTAssertNil(HealthCheckParsers.pendingUpdates([:]))
        XCTAssertEqual(HealthCheckParsers.crashAppName("Google Chrome Helper-2026-10-31-101500.ips"), "Google Chrome Helper")
        XCTAssertEqual(HealthCheckParsers.crashAppName("MacSweep_2026-10-31-101500.ips"), "MacSweep")
        XCTAssertNil(HealthCheckParsers.crashAppName("JetsamEvent.ips"))
        XCTAssertNil(HealthCheckParsers.crashAppName("Safari-2026-10-31-101500.crash"))
    }

    func testSecurityPosture() {
        var r = HealthCheckResults()
        r.sip = false; r.gatekeeper = true; r.fileVault = false; r.firewall = false
        let o = HealthCheckEvaluator.observations(r)
        XCTAssertEqual(find(o, .sip)?.condition, .trigger); XCTAssertEqual(find(o, .sip)?.severity, .bad)
        XCTAssertEqual(find(o, .gatekeeper)?.condition, .clear)
        XCTAssertEqual(find(o, .fileVault)?.severity, .warn)
        XCTAssertEqual(find(o, .firewall)?.severity, .info, "Firewall off is the macOS default; card only")
        XCTAssertNil(find(HealthCheckEvaluator.observations(HealthCheckResults()), .sip), "Unknown means no nudge")
    }

    func testDriveAndBattery() {
        var r = HealthCheckResults()
        r.smartStatus = "Failing"
        r.battery = BatteryInfo(cycleCount: 1200, maxCapacity: 7000, designCapacity: 8790, condition: "Normal")
        var o = HealthCheckEvaluator.observations(r)
        XCTAssertEqual(find(o, .driveHealth)?.condition, .trigger)
        XCTAssertTrue(find(o, .driveHealth)?.urgent ?? false)
        XCTAssertEqual(find(o, .battery)?.severity, .warn)
        XCTAssertTrue(find(o, .battery)?.message.contains("1200 cycles") ?? false)
        r.battery = BatteryInfo(cycleCount: 300, maxCapacity: 8500, designCapacity: 8790, condition: "Service Recommended")
        o = HealthCheckEvaluator.observations(r)
        XCTAssertEqual(find(o, .battery)?.severity, .bad)
        r.battery = BatteryInfo(cycleCount: 300, maxCapacity: 8500, designCapacity: 8790, condition: "Good")
        r.smartStatus = "Verified"
        o = HealthCheckEvaluator.observations(r)
        XCTAssertEqual(find(o, .battery)?.condition, .clear)
        XCTAssertEqual(find(o, .driveHealth)?.condition, .clear)
        XCTAssertEqual(BatteryInfo(maxCapacity: 87, designCapacity: 8790).health, 0.87)
    }

    func testUptimeXProtectAndUpdates() {
        var r = HealthCheckResults()
        r.uptime = 20 * 86400; r.pendingUpdates = ["macOS 26.7"]; r.xprotectAge = 50 * 86400; r.xprotectVersion = "5300"
        var o = HealthCheckEvaluator.observations(r)
        XCTAssertEqual(find(o, .uptime)?.severity, .info)
        XCTAssertTrue(find(o, .uptime)?.message.contains("waiting updates") ?? false)
        XCTAssertEqual(find(o, .xprotect)?.condition, .trigger)
        XCTAssertEqual(find(o, .updates)?.message, "A macOS update is waiting: macOS 26.7.")
        r.uptime = 31 * 86400; r.pendingUpdates = []; r.xprotectAge = 3 * 86400
        o = HealthCheckEvaluator.observations(r)
        XCTAssertEqual(find(o, .uptime)?.severity, .warn)
        XCTAssertEqual(find(o, .updates)?.condition, .clear)
        XCTAssertEqual(find(o, .xprotect)?.condition, .clear)
        r.uptime = 2 * 86400
        XCTAssertEqual(find(HealthCheckEvaluator.observations(r), .uptime)?.condition, .clear)
    }

    func testCrashesStartupItemsAndFullDiskAccess() {
        var r = HealthCheckResults()
        r.crashCounts = ["Safari": 4, "Mail": 1]; r.recentPanics = nil
        r.startupItemsAtLogin = 18; r.missingStartupPrograms = []; r.unsignedStartupItems = ["helper"]
        r.fullDiskAccess = false
        var o = HealthCheckEvaluator.observations(r)
        XCTAssertEqual(find(o, .crashes)?.message.hasPrefix("Safari crashed 4 times today"), true)
        XCTAssertEqual(find(o, .loginItems)?.severity, .info)
        XCTAssertEqual(find(o, .unsignedAgent)?.condition, .trigger)
        XCTAssertEqual(find(o, .fullDiskAccess)?.severity, .info)
        r.recentPanics = 1; r.missingStartupPrograms = ["Old Updater"]; r.fullDiskAccess = true; r.unsignedStartupItems = []
        o = HealthCheckEvaluator.observations(r)
        XCTAssertEqual(find(o, .crashes)?.severity, .bad)
        XCTAssertEqual(find(o, .loginItems)?.severity, .warn)
        XCTAssertEqual(find(o, .fullDiskAccess)?.condition, .clear)
        XCTAssertEqual(find(o, .unsignedAgent)?.condition, .clear)
        r.crashCounts = [:]; r.recentPanics = 0
        XCTAssertEqual(find(HealthCheckEvaluator.observations(r), .crashes)?.condition, .clear)
    }
}
