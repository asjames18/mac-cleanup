import Foundation
import XCTest
@testable import MacSweepCore

final class TrashPlanValidatorTests: XCTestCase {
    func testReplacedFileRequiresRescanEvenWithMatchingMetadata() {
        let before = FileSnapshot(identity: FileIdentity(volumeKey: "volume-a", resourceKey: "inode-1"), logicalBytes: 20, modifiedAt: Date(timeIntervalSince1970: 100), contentDigest: nil)
        let replacement = FileSnapshot(identity: FileIdentity(volumeKey: "volume-a", resourceKey: "inode-2"), logicalBytes: 20, modifiedAt: before.modifiedAt, contentDigest: nil)
        XCTAssertEqual(TrashPlanValidator.validate(expected: before, current: replacement), .needsRescan)
        XCTAssertEqual(TrashPlanValidator.validate(expected: before, current: nil), .unavailable)
        XCTAssertEqual(TrashPlanValidator.validate(expected: before, current: before), .unchanged)
    }

    func testPlanRoundTripsWithImmutableExpectedSnapshots() throws {
        let snapshot = FileSnapshot(identity: FileIdentity(volumeKey: "device-1", resourceKey: "inode-2"), logicalBytes: 42, modifiedAt: Date(timeIntervalSince1970: 100), contentDigest: nil, changedAt: Date(timeIntervalSince1970: 101))
        let plan = TrashPlan(scanID: UUID(), ruleVersion: "1", targets: [TrashTarget(url: URL(fileURLWithPath: "/fixture"), expected: snapshot)])
        let decoded = try JSONDecoder().decode(TrashPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded.id, plan.id)
        XCTAssertEqual(decoded.scanID, plan.scanID)
        XCTAssertEqual(decoded.ruleVersion, "1")
        XCTAssertEqual(decoded.targets, plan.targets)
    }
}
