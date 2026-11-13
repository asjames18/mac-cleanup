import Foundation
import ServiceManagement
import XCTest
@testable import MacSweep

final class NudgeSpikeTests: XCTestCase {
    func testTestsNeverTouchTheRealNotificationCenter() async {
        XCTAssertFalse(NudgeRuntime.isAppBundle)
        let auth = await NotificationService.shared.authorization()
        XCTAssertEqual(auth, .unavailable)
        let error = await NotificationService.shared.post(id: "t", title: "t", body: "t")
        XCTAssertNotNil(error)
    }

    func testLoginItemStatusMapping() {
        XCTAssertEqual(LoginItemService.map(.enabled), .enabled)
        XCTAssertEqual(LoginItemService.map(.notRegistered), .notRegistered)
        XCTAssertEqual(LoginItemService.map(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItemService.map(.notFound), .notFound)
    }

    @MainActor
    func testReportRoundTripsAsJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var report = NudgeSpikeReport()
        report.signature = "adhoc"
        report.requestTimedOut = true
        let url = try NudgeSpike.write(report, to: dir)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(NudgeSpikeReport.self, from: Data(contentsOf: url))
        XCTAssertEqual(back.signature, "adhoc")
        XCTAssertTrue(back.requestTimedOut)
    }
}
