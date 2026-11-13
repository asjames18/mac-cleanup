import XCTest
@testable import MacSweep

final class ActivityPreviewTests: XCTestCase {
    func testShortAndBoundaryReportsStayIntact() {
        for text in ["", "Ready.", String(repeating: "a", count: 16_384)] {
            let preview = ActivityPreview(text)
            XCTAssertEqual(preview.text, text)
            XCTAssertFalse(preview.truncated)
        }
    }

    @MainActor
    func testLongUnicodeReportKeepsTailAndPreservesExportSource() {
        let tail = "\nLast error: /fixture/报告/é/🧑🏽‍💻.txt"
        let report = String(repeating: "previous error\n", count: 100_000) + tail
        let model = AppModel()
        model.logText = report
        XCTAssertTrue(model.activityPreview.truncated)
        XCTAssertLessThanOrEqual(model.activityPreview.text.unicodeScalars.count, 16_384)
        XCTAssertTrue(model.activityPreview.text.hasSuffix(tail))
        XCTAssertEqual(model.logText, report, "Copy/Save must retain the complete report")
        model.logText = "New scan"
        XCTAssertFalse(model.activityPreview.truncated)
        XCTAssertEqual(model.activityPreview.text, "New scan")
    }
}
