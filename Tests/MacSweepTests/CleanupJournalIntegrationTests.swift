import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

final class CleanupJournalIntegrationTests: XCTestCase {
    /// Fixtures live in the temporary directory, so the sandbox stays on but is rooted there.
    override func invokeTest() {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory)
        TestSandbox.$policy.withValue(SandboxPolicy(enabled: true, root: root)) { super.invokeTest() }
    }

    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testIntentExistsBeforeMoveAndDestinationSurvivesReload() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("fixture-trash")
        let journalURL = root.appendingPathComponent("history")
        let journal = CleanupJournal(directory: journalURL)
        try Data("fixture".utf8).write(to: source)
        let result = CleanupSafety.moveWithJournal(source, journal: journal) { url in
            XCTAssertEqual(try journal.entries().first?.state, .pending)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        XCTAssertEqual(result.moved, [source])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let entry = try XCTUnwrap(CleanupJournal(directory: journalURL).entries().first)
        XCTAssertEqual(entry.state, .moved)
        XCTAssertEqual(entry.destination, destination)
    }

    func testMoverErrorRemainsUnknownEvenWhenSourceStillExists() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("source")
        try Data("fixture".utf8).write(to: source)
        let journal = CleanupJournal(directory: root.appendingPathComponent("history"))
        let result = CleanupSafety.moveWithJournal(source, journal: journal) { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try journal.entries().first?.state, .pending)
        XCTAssertTrue(result.messages.joined().contains("Privacy & Security"))
        XCTAssertTrue(try journal.entries().first?.error?.contains("NSCocoaErrorDomain") == true)
    }

    func testMoverThatMovesThenThrowsKeepsPendingAndBlocksOverlappingRetry() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("fixture-trash")
        try Data("fixture".utf8).write(to: source)
        let journal = CleanupJournal(directory: root.appendingPathComponent("history"))
        let result = CleanupSafety.moveWithJournal(source, journal: journal) { url in
            try FileManager.default.moveItem(at: url, to: destination)
            throw CocoaError(.fileWriteUnknown)
        }
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(result.messages.joined().contains("Outcome unknown"))
        let reloaded = CleanupJournal(directory: journal.storageDirectory)
        XCTAssertEqual(try reloaded.entries().first?.state, .pending)
        XCTAssertNotNil(try reloaded.entries().first?.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("fixture".utf8))
        for target in [source, source.appendingPathComponent("child"), root] {
            XCTAssertThrowsError(try reloaded.recordIntent(source: target), "Target: \(target.standardizedFileURL.path); source: \(source.standardizedFileURL.path)") {
                XCTAssertEqual($0 as? CleanupJournalError, .pendingConflict)
            }
        }
        _ = try reloaded.recordIntent(source: root.appendingPathComponent("unrelated"))
    }

    func testJournalFailurePreventsMove() throws {
        let root = try fixture()
        let invalidJournal = root.appendingPathComponent("not-directory")
        try Data("fixture".utf8).write(to: invalidJournal)
        let result = CleanupSafety.moveWithJournal(root.appendingPathComponent("source"), journal: CleanupJournal(directory: invalidJournal)) { _ in
            XCTFail("Must not mutate without a durable intent")
            return nil
        }
        XCTAssertTrue(result.moved.isEmpty)
    }
    func testJournalAndContainingTargetCannotBeMoved() throws {
        let root = try fixture()
        let history = root.appendingPathComponent("history")
        let journal = CleanupJournal(directory: history)
        for source in [root, history, history.appendingPathComponent("entry.json")] {
            let result = CleanupSafety.moveWithJournal(source, journal: journal) { _ in
                XCTFail("The history store must never be moved by its own operation")
                return nil
            }
            XCTAssertTrue(result.moved.isEmpty)
        }
        XCTAssertTrue(try journal.entries().isEmpty)
        let actual = ProtectionRules.historyDirectory
        XCTAssertTrue(ProtectionRules.isProtected(actual, protectRecentFiles: false))
        XCTAssertTrue(ProtectionRules.isProtected(actual.deletingLastPathComponent(), protectRecentFiles: false))
        XCTAssertTrue(ProtectionRules.isProtected(actual.appendingPathComponent("record.json"), protectRecentFiles: false))
    }

    func testFinalRevalidationRunsAfterIntentAndFailureNeverCallsMover() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("source")
        try Data("fixture".utf8).write(to: source)
        let journal = CleanupJournal(directory: root.appendingPathComponent("history"))
        var revalidations = 0
        var moves = 0
        let result = CleanupSafety.moveWithJournal(source, journal: journal, revalidate: {
            revalidations += 1
            XCTAssertEqual(try journal.entries().first?.state, .pending)
            throw CleanupSafety.Rejection.changedSinceScan
        }) { _ in moves += 1; return nil }
        XCTAssertEqual(revalidations, 1)
        XCTAssertEqual(moves, 0)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(try journal.entries().first?.state, .failed)
        XCTAssertEqual(try Data(contentsOf: source), Data("fixture".utf8))
    }

    func testFinalSnapshotCheckPreservesReplacementIntroducedAfterIntent() throws {
        let root = try fixture()
        let source = root.appendingPathComponent("source")
        let retained = root.appendingPathComponent("retained")
        try Data("original".utf8).write(to: source)
        let expected = try FileSnapshotReader.capture(source)
        let journal = CleanupJournal(directory: root.appendingPathComponent("history"))
        var moves = 0
        let result = CleanupSafety.moveWithJournal(source, journal: journal, revalidate: {
            XCTAssertEqual(try journal.entries().first?.state, .pending)
            try FileManager.default.moveItem(at: source, to: retained)
            try Data("replacement".utf8).write(to: source)
            guard FileSnapshotReader.validate(expected: expected, at: source) == .unchanged else {
                throw CleanupSafety.Rejection.changedSinceScan
            }
        }) { _ in moves += 1; return nil }
        XCTAssertEqual(moves, 0)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(try journal.entries().first?.state, .failed)
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: retained), Data("original".utf8))
    }

}
