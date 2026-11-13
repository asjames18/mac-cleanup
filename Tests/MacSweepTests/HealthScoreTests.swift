import Foundation
import XCTest
@testable import MacSweep

final class HealthScoreTests: XCTestCase {
    private let gb = HealthScore.gigabyte

    func testHealthyMacScoresFullMarks() {
        let summary = HealthScore.summarize(diskFree: 400 * gb, diskTotal: 1_000 * gb, duplicateWaste: 0, oldDownloadBytes: 0, memoryPressure: "Normal", scanned: true)
        XCTAssertEqual(summary.score, 100)
        XCTAssertEqual(summary.label, "Looking good")
        XCTAssertTrue(summary.issues.isEmpty)
    }

    func testDeductionsAndDestinations() {
        let summary = HealthScore.summarize(diskFree: 50 * gb, diskTotal: 1_000 * gb, duplicateWaste: 2 * gb, oldDownloadBytes: 3 * gb, memoryPressure: "Critical", scanned: true)
        XCTAssertEqual(summary.score, 100 - 20 - 20 - 6 - 5)
        XCTAssertEqual(summary.issues.map(\.destination), [.storage, .overview, .cleanup, .cleanup])
        XCTAssertEqual(summary.issues.first?.severity, .bad)
    }

    func testLookingGoodBand() {
        let summary = HealthScore.summarize(diskFree: 150 * gb, diskTotal: 1_000 * gb, duplicateWaste: 2 * gb, oldDownloadBytes: 0, memoryPressure: "Normal", scanned: true)
        XCTAssertEqual(summary.score, 86)
        XCTAssertEqual(summary.label, "Looking good")
    }

    func testReviewBand() {
        let warnings = HealthScore.summarize(diskFree: 150 * gb, diskTotal: 1_000 * gb, duplicateWaste: 0, oldDownloadBytes: 0, memoryPressure: "Warning", scanned: false)
        XCTAssertEqual(warnings.score, 84)
        XCTAssertEqual(warnings.label, "A few things to review")
        XCTAssertEqual(warnings.issues.last?.severity, .info, "No-scan hint does not lower the score")
        XCTAssertEqual(warnings.issues.count, 3)
        let oneSeriousProblem = HealthScore.summarize(diskFree: 10 * gb, diskTotal: 1_000 * gb, duplicateWaste: 0, oldDownloadBytes: 0, memoryPressure: nil, scanned: true)
        XCTAssertEqual(oneSeriousProblem.score, 70)
        XCTAssertEqual(oneSeriousProblem.label, "A few things to review")
    }

    func testNeedsAttentionBand() {
        let fullAndStrained = HealthScore.summarize(diskFree: 10 * gb, diskTotal: 1_000 * gb, duplicateWaste: 0, oldDownloadBytes: 0, memoryPressure: "Critical", scanned: true)
        XCTAssertEqual(fullAndStrained.score, 50)
        XCTAssertEqual(fullAndStrained.label, "Needs attention")
        let fullAndCluttered = HealthScore.summarize(diskFree: 10 * gb, diskTotal: 1_000 * gb, duplicateWaste: 20 * gb, oldDownloadBytes: 0, memoryPressure: nil, scanned: true)
        XCTAssertEqual(fullAndCluttered.score, 58)
        XCTAssertEqual(fullAndCluttered.label, "Needs attention")
        let worst = HealthScore.summarize(diskFree: 1 * gb, diskTotal: 1_000 * gb, duplicateWaste: 20 * gb, oldDownloadBytes: 20 * gb, memoryPressure: "Critical", scanned: true)
        XCTAssertEqual(worst.score, 28)
        XCTAssertEqual(worst.label, "Needs attention")
    }

    func testBandBoundaries() {
        XCTAssertEqual(HealthScore.label(for: 100), "Looking good")
        XCTAssertEqual(HealthScore.label(for: 85), "Looking good")
        XCTAssertEqual(HealthScore.label(for: 84), "A few things to review")
        XCTAssertEqual(HealthScore.label(for: 60), "A few things to review")
        XCTAssertEqual(HealthScore.label(for: 59), "Needs attention")
        XCTAssertEqual(HealthScore.label(for: 0), "Needs attention")
    }

    func testUnavailableMetricsDoNotPenalize() {
        let summary = HealthScore.summarize(diskFree: nil, diskTotal: nil, duplicateWaste: 0, oldDownloadBytes: 0, memoryPressure: nil, scanned: true)
        XCTAssertEqual(summary.score, 100)
    }

    func testDuplicateWasteExcludesRetainedCopy() {
        func item(_ path: String, _ date: Date) -> CleanupItem {
            CleanupItem(id: path, url: URL(fileURLWithPath: path), category: .duplicates, size: 100, modifiedAt: date,
                        kind: "File", reason: "", safetyNote: "", duplicateGroupID: "g", isSelected: false)
        }
        let items = [item("/f/a", .distantPast), item("/f/b", Date()), item("/f/c", Date())]
        XCTAssertEqual(HealthScore.duplicateWaste(items), 200)
    }
}
