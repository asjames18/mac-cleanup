import Foundation
import MacSweepCore
import XCTest
@testable import MacSweep

final class HealthCheckRunnerTests: XCTestCase {
    /// Runs the real read-only checks on this Mac. Values depend on the Mac; only readability is asserted.
    func testRealChecksAreReadableWithoutAdminRights() {
        let started = Date()
        let r = HealthCheckRunner.run()
        XCTAssertNotNil(r.sip, "csrutil status")
        XCTAssertNotNil(r.gatekeeper, "spctl --status")
        XCTAssertNotNil(r.firewall, "socketfilterfw --getglobalstate")
        XCTAssertNotNil(r.uptime)
        XCTAssertNotNil(r.startupItemsAtLogin)
        XCTAssertNotNil(r.unsignedStartupItems)
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
        // Each check maps to a nudge observation (or is skipped when unknown).
        XCTAssertFalse(HealthCheckEvaluator.observations(r).isEmpty)
    }

    func testSignatureStates() throws {
        XCTAssertEqual(HealthCheckRunner.signatureState("/bin/ls"), .valid)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("unsigned-tool")
        try Data([0xCF, 0xFA, 0xED, 0xFE] + [UInt8](repeating: 0, count: 64)).write(to: tool)
        XCTAssertNotEqual(HealthCheckRunner.signatureState(tool.path), .valid)
    }

    func testFullDiskAccessProbeNeverThrows() {
        // Under swift test this usually reports false (no FDA for the test runner); either answer is fine.
        _ = HealthCheckRunner.hasFullDiskAccess()
    }
}
