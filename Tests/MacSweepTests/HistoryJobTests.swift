import Foundation
import XCTest
@testable import MacSweepCore
@testable import MacSweep

final class HistoryJobTests: XCTestCase {
    @MainActor
    func testRestoreOutcomeReviewRequiresConfirmationAndRefreshesHistory() async throws {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("item")
        let trash = root.appendingPathComponent("fixture-trash-item")
        try Data("fixture".utf8).write(to: source)
        let journal = CleanupJournal(directory: root.appendingPathComponent("journal"))
        let id = try journal.recordIntent(source: source)
        try FileManager.default.moveItem(at: source, to: trash)
        try journal.recordOutcome(id: id, destination: trash, failure: nil)
        let plan = try RestoreEngine(journal: journal).review(id: id)
        XCTAssertThrowsError(try journal.commitRestore(plan) {
            try FileManager.default.moveItem(at: trash, to: source)
            throw RestoreError.io(5)
        })
        let store = HistoryStore(journal: journal)
        await store.refresh()
        await store.reviewRestoreOutcome(id: id)
        XCTAssertNotNil(store.reviewedReconciliation)
        XCTAssertEqual(try journal.entries().first?.restore?.state, .pending)
        store.cancelReview()
        await store.confirmRestoreOutcome()
        XCTAssertEqual(try journal.entries().first?.restore?.state, .pending)
        await store.reviewRestoreOutcome(id: id)
        await store.confirmRestoreOutcome()
        XCTAssertNil(store.reviewedReconciliation)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.rows.first?.entry.restore?.state, .restored)
        XCTAssertNotNil(store.rows.first?.entry.restore?.reconciledAt)
        XCTAssertEqual(try Data(contentsOf: source), Data("fixture".utf8))
    }

    @MainActor
    func testTimeoutReleasesLoadingButGatesRetryUntilWorkerReturns() async throws {
        let gate = HistoryReadGate()
        defer { gate.release() }
        let journal = CleanupJournal(directory: URL(fileURLWithPath: "/unused-history-fixture"))
        let store = HistoryStore(journal: journal, loadEntries: { gate.block(); return [] }, readTimeout: .milliseconds(30))
        let task = Task { await store.refresh() }
        for _ in 0..<200 where !store.waitingForFilesystem { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.waitingForFilesystem)
        XCTAssertFalse(store.loading)
        XCTAssertFalse(store.canCancel)
        XCTAssertTrue(store.error?.contains("timed out") == true)
        await store.refresh()
        await store.review(id: UUID())
        XCTAssertEqual(gate.calls, 1)
        gate.release()
        await task.value
        XCTAssertFalse(store.busy)
        XCTAssertNotNil(store.error, "Late success must not erase the cancellation notice")
        await store.refresh()
        XCTAssertNil(store.error)
        XCTAssertEqual(gate.calls, 2)
    }

    @MainActor
    func testCanceledReviewCannotPublishLateConfirmation() async throws {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("item")
        let trash = root.appendingPathComponent("fixture-trash-item")
        try Data("fixture".utf8).write(to: source)
        let journal = CleanupJournal(directory: root.appendingPathComponent("journal"))
        let id = try journal.recordIntent(source: source)
        try FileManager.default.moveItem(at: source, to: trash)
        try journal.recordOutcome(id: id, destination: trash, failure: nil)
        let plan = try RestoreEngine(journal: journal).review(id: id)
        let gate = HistoryReadGate()
        defer { gate.release() }
        let store = HistoryStore(journal: journal, reviewPlan: { _, _ in gate.block(); return plan })
        let task = Task { await store.review(id: id) }
        for _ in 0..<200 where gate.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gate.calls, 1)
        store.cancelReview()
        XCTAssertTrue(store.waitingForFilesystem)
        gate.release()
        await task.value
        XCTAssertNil(store.reviewedPlan)
        XCTAssertFalse(store.busy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testParentTaskCancellationReleasesUIAndDiscardsRead() async throws {
        let gate = HistoryReadGate()
        defer { gate.release() }
        let store = HistoryStore(journal: CleanupJournal(directory: URL(fileURLWithPath: "/unused-history-fixture")),
                                 loadEntries: { gate.block(); return [] })
        let task = Task { await store.refresh() }
        for _ in 0..<200 where gate.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        for _ in 0..<200 where !store.waitingForFilesystem { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.waitingForFilesystem)
        gate.release()
        await task.value
        XCTAssertFalse(store.busy)
        XCTAssertNotNil(store.error)
    }
}

private final class HistoryReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false
    private var count = 0
    var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
    func block() {
        condition.lock(); defer { condition.unlock() }
        count += 1
        while !opened { condition.wait() }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        opened = true; condition.broadcast()
    }
}
