import Foundation
import XCTest
@testable import MacSweep

final class BackgroundModeTests: XCTestCase {
    func testLaunchModeDecision() {
        XCTAssertTrue(BackgroundMode.shouldStartInBackground(arguments: ["MacSweep", "--background"], launchedAsLoginItem: false))
        XCTAssertTrue(BackgroundMode.shouldStartInBackground(arguments: ["MacSweep"], launchedAsLoginItem: true))
        XCTAssertFalse(BackgroundMode.shouldStartInBackground(arguments: ["MacSweep", "--foreground"], launchedAsLoginItem: true))
        XCTAssertFalse(BackgroundMode.shouldStartInBackground(arguments: ["MacSweep"], launchedAsLoginItem: false))
    }

    @MainActor
    func testNotALoginItemUnderTests() {
        XCTAssertFalse(BackgroundMode.launchedAsLoginItem)
    }
}
