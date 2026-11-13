import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

final class SandboxUXTests: XCTestCase {
    private let outsideA = URL(filePath: "/Users/tester/Downloads/a.zip")
    private let outsideB = URL(filePath: "/Users/tester/Downloads/b.zip")
    private var insideC: URL { TestSandbox.defaultRoot.appendingPathComponent("c.txt") }

    func testOutsideListsOnlyRefusedItems() {
        let policy = SandboxPolicy.standard
        XCTAssertEqual(TestSandbox.outside([outsideA, insideC, outsideB], policy: policy), [outsideA, outsideB])
        XCTAssertTrue(TestSandbox.outside([outsideA], policy: .off).isEmpty)
    }

    func testPreflightWording() {
        XCTAssertEqual(SandboxPreflight(outside: 4, total: 6, allowsSkip: true).headline,
                       "4 items are outside the test sandbox and will be skipped")
        XCTAssertEqual(SandboxPreflight(outside: 3, total: 3, allowsSkip: false).headline,
                       "All 3 selected items are outside the test sandbox")
        XCTAssertEqual(SandboxPreflight(outside: 1, total: 1, allowsSkip: false).headline,
                       "The selected item is outside the test sandbox")
        XCTAssertTrue(SandboxPreflight(outside: 1, total: 2, allowsSkip: true).detail.hasPrefix(SandboxText.banner))
    }

    func testReportCollapsesRepeatedSandboxLines() {
        let refusal = TestSandbox.refusal(for: outsideA, policy: .standard)!
        let messages = (1...4).map { "Skipped /Users/tester/Downloads/f\($0).zip: \(refusal)" }
        let report = TrashReport.summarize(movedCount: 0, messages: messages)
        XCTAssertEqual(report.headline, "Nothing was moved to Trash")
        XCTAssertEqual(report.summary, "Skipped 4 items: 4 outside the test sandbox.")
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups[0].paths.count, 4)
        XCTAssertEqual(report.detailText.components(separatedBy: refusal).count - 1, 1, "The reason appears once, not per file")
        XCTAssertTrue(report.detailText.contains("f3.zip"))
    }

    func testReportKeepsMixedReasonsAndNotes() {
        let report = TrashReport.summarize(movedCount: 2, messages: [
            "Skipped /x/a: protected by your exclusions.",
            "Skipped /x/b: protected by your exclusions.",
            "Skipped /x/c: the item changed since the scan.",
            "History update failed; check the pending record before retrying: disk full"
        ])
        XCTAssertEqual(report.headline, "Moved 2 items to Trash")
        XCTAssertEqual(report.summary, "Moved 2 items. Skipped 3 items: 2 excluded, 1 the item changed since the scan. 1 note to review.")
        XCTAssertEqual(report.otherMessages.count, 1)
        XCTAssertTrue(report.hasDetails)
        XCTAssertFalse(TrashReport.summarize(movedCount: 1, messages: []).hasDetails)
    }

    @MainActor
    func testCancelAtPreflightIssuesNoConfirmation() {
        let model = AppModel(confirmation: { _, _ in XCTFail("No confirm should be shown"); return false })
        var asked: [SandboxPreflight] = []
        model.sandboxPreflight = { asked.append($0); return .cancel }
        var cancelled = false, approved = false
        model.requestConfirmation(summary: "Move 2 items to Trash", detail: "", urls: [outsideA, outsideB], allowsSandboxSkip: true,
                                  onCancel: { cancelled = true }) { _ in approved = true }
        XCTAssertEqual(asked, [SandboxPreflight(outside: 2, total: 2, allowsSkip: false)])
        XCTAssertTrue(cancelled); XCTAssertFalse(approved)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertTrue(model.sandboxEnabled)
    }

    @MainActor
    func testSkipOutsideConfirmsOnlyInsideItems() {
        var summaries: [String] = []
        let model = AppModel(confirmation: { _, detail in summaries.append(detail); return true })
        model.sandboxPreflight = { XCTAssertTrue($0.allowsSkip); return .skipOutside }
        var paths: [String] = []
        model.requestConfirmation(summary: "Move 3 items to Trash", detail: "d", urls: [outsideA, insideC, outsideB],
                                  allowsSandboxSkip: true) { grant in paths = grant.paths }
        XCTAssertEqual(paths, [insideC.path])
        XCTAssertTrue(summaries.first?.hasPrefix("Move 1 items to Trash") ?? false)
        XCTAssertTrue(model.sandboxEnabled)
    }

    @MainActor
    func testSkipIsRefusedForFlowsThatMustMatchTheirPlan() {
        let model = AppModel(confirmation: { _, _ in true })
        model.sandboxPreflight = { XCTAssertFalse($0.allowsSkip); return .skipOutside }
        var cancelled = false, approved = false
        model.requestConfirmation(summary: "Move App to Trash", detail: "", urls: [outsideA, insideC],
                                  onCancel: { cancelled = true }) { _ in approved = true }
        XCTAssertTrue(cancelled); XCTAssertFalse(approved)
    }

    @MainActor
    func testTurnOffNeedsItsOwnConfirmAndThenKeepsAllItems() {
        var titles: [String] = []
        var allow = false
        let model = AppModel(confirmation: { title, _ in titles.append(title); return allow })
        model.sandboxPreflight = { _ in .turnOffSandbox }
        var approved: [String] = []
        model.requestConfirmation(summary: "Move 2 items to Trash", detail: "", urls: [outsideA, outsideB]) { approved = $0.paths }
        XCTAssertTrue(model.sandboxEnabled, "Declining the sandbox confirm keeps it on")
        XCTAssertTrue(approved.isEmpty)
        XCTAssertEqual(titles, ["Do you really want to do this action?"])

        allow = true
        model.requestConfirmation(summary: "Move 2 items to Trash", detail: "", urls: [outsideA, outsideB]) { approved = $0.paths }
        XCTAssertFalse(model.sandboxEnabled)
        XCTAssertEqual(approved, [outsideA.path, outsideB.path])
    }

    @MainActor
    func testScriptedRunsWithoutAPreflightStillShowTheOutsideCount() {
        let model = AppModel()
        model.requestConfirmation(summary: "Move 2 items", detail: "", urls: [outsideA, insideC]) { _ in }
        XCTAssertEqual(model.pendingConfirmation?.outsideSandbox, 1)
        model.cancelPendingConfirmation()
    }

    func testEnforcementIsUnchangedForOutsideItems() {
        XCTAssertNotNil(TestSandbox.refusal(for: outsideA, policy: .standard))
    }
}
