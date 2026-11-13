import Darwin
import Foundation
import XCTest
@testable import MacSweep

final class CleanupFailureTests: XCTestCase {
    func testAppPermissionFailureSuggestsAppManagementWithoutClaimingExactCause() {
        let message = CleanupFailure.describe(CocoaError(.fileWriteNoPermission), target: URL(fileURLWithPath: "/Applications/Fixture.app"))
        XCTAssertTrue(message.contains("App Management"))
        XCTAssertTrue(message.contains("does not identify the exact restriction"))
        XCTAssertTrue(message.contains("NSCocoaErrorDomain"))
    }

    func testUnderlyingPermissionFailureUsesFolderGuidance() {
        let error = NSError(domain: "FixtureWrapper", code: 42, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        let message = CleanupFailure.describe(error, target: URL(fileURLWithPath: "/fixture/cache"))
        XCTAssertTrue(message.contains("Sharing & Permissions"))
        XCTAssertTrue(message.contains("Full Disk Access"))
        XCTAssertTrue(message.contains("FixtureWrapper (42)"))
        XCTAssertFalse(message.contains("App Management"))
    }

    func testReadOnlyAndSpaceFailuresDoNotRecommendPrivacyGrants() {
        for code in [EROFS, ENOSPC] {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            let message = CleanupFailure.describe(error, target: URL(fileURLWithPath: "/fixture"))
            XCTAssertFalse(message.contains("Full Disk Access"))
            XCTAssertTrue(message.contains(code == EROFS ? "read-only volume" : "insufficient free space"))
        }
    }

    func testLocalizedTextNeverDeterminesPermissionClassification() {
        let error = NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission denied App Management"])
        XCTAssertEqual(CleanupFailure.describe(error, target: URL(fileURLWithPath: "/fixture")), error.localizedDescription)
        let canceled = CleanupFailure.describe(CocoaError(.userCancelled), target: URL(fileURLWithPath: "/fixture"))
        XCTAssertFalse(canceled.contains("Full Disk Access"))
        XCTAssertTrue(canceled.contains("was canceled"))
    }
}
