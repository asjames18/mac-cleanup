import Darwin
import Foundation
import XCTest
@testable import MacSweepCore

final class RestoreEngineTests: XCTestCase {
    private func fixture(_ body: (URL, CleanupJournal, URL, UUID) throws -> Void) throws {
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("SimulatedTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let item = trash.appendingPathComponent("report.txt")
        let original = root.appendingPathComponent("report.txt")
        try Data("original contents".utf8).write(to: original)
        let journal = CleanupJournal(directory: root.appendingPathComponent("History"))
        let id = try journal.recordIntent(source: root.appendingPathComponent("report.txt"))
        try FileManager.default.moveItem(at: original, to: item)
        try journal.recordOutcome(id: id, destination: item, failure: nil)
        try body(root, journal, item, id)
    }

    func testReconciliationRecordsCompletedRestoreWithoutMovingAnything() throws {
        try fixture { root, journal, item, id in
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id)
            XCTAssertThrowsError(try journal.commitRestore(plan) {
                try FileManager.default.moveItem(at: item, to: plan.destination)
                throw RestoreError.io(EIO)
            })
            XCTAssertEqual(try journal.entries().first?.restore?.state, .pending)
            let review = try engine.reviewReconciliation(id: id)
            XCTAssertEqual(try journal.entries().first?.restore?.state, .pending, "Review must not update the journal")
            try engine.confirmReconciliation(review)
            XCTAssertEqual(try journal.entries().first?.restore?.state, .restored)
            XCTAssertNotNil(try journal.entries().first?.restore?.reconciledAt)
            XCTAssertEqual(try Data(contentsOf: plan.destination), Data("original contents".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
            XCTAssertThrowsError(try engine.confirmReconciliation(review))
            _ = try journal.recordIntent(source: plan.destination)
        }
    }

    func testReconciliationRejectsAmbiguousAndChangedEvidence() throws {
        try fixture { root, journal, item, id in
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id)
            XCTAssertThrowsError(try journal.commitRestore(plan) { throw RestoreError.io(EIO) })
            XCTAssertThrowsError(try engine.reviewReconciliation(id: id), "File remains in Trash") {
                XCTAssertEqual($0 as? RestoreOutcomeError, .missingDestination)
            }
            try FileManager.default.moveItem(at: item, to: plan.destination)
            try Data("new occupant".utf8).write(to: item)
            XCTAssertThrowsError(try engine.reviewReconciliation(id: id), "Both locations are occupied") {
                XCTAssertEqual($0 as? RestoreOutcomeError, .occupiedTrashLocation)
            }
            try FileManager.default.removeItem(at: item)
            let reviewed = try engine.reviewReconciliation(id: id)
            try Data("edited after review".utf8).write(to: plan.destination)
            XCTAssertThrowsError(try engine.confirmReconciliation(reviewed)) {
                XCTAssertEqual($0 as? RestoreOutcomeError, .changedDestination)
            }
            XCTAssertEqual(try journal.entries().first?.restore?.state, .pending)
        }
    }

    func testReconciliationRejectsFormerTrashParentReplacementAfterReview() throws {
        try fixture { root, journal, item, id in
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id)
            XCTAssertThrowsError(try journal.commitRestore(plan) {
                try FileManager.default.moveItem(at: item, to: plan.destination)
                throw RestoreError.io(EIO)
            })
            let review = try engine.reviewReconciliation(id: id)
            let parent = item.deletingLastPathComponent()
            try FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("OldTrashFolder"))
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            XCTAssertThrowsError(try engine.confirmReconciliation(review))
            XCTAssertEqual(try journal.entries().first?.restore?.state, .pending)
            XCTAssertEqual(try Data(contentsOf: plan.destination), Data("original contents".utf8))
        }
    }

    func testReconciliationRejectsSymlinkAtRestoredPath() throws {
        try fixture { root, journal, item, id in
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id)
            XCTAssertThrowsError(try journal.commitRestore(plan) { throw RestoreError.io(EIO) })
            try FileManager.default.createSymbolicLink(at: plan.destination, withDestinationURL: item)
            XCTAssertThrowsError(try engine.reviewReconciliation(id: id))
            XCTAssertEqual(try journal.entries().first?.restore?.state, .pending)
        }
    }

    func testReviewedRestoreMovesExactContentsAndRecordsOutcome() throws {
        try fixture { root, journal, item, id in
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.path), "Review must not move files")
            try engine.restore(plan)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("report.txt")), Data("original contents".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
            XCTAssertEqual(try journal.entries().first?.restore?.state, .restored)
            XCTAssertThrowsError(try engine.restore(plan))
        }
    }

    func testCollisionAfterReviewNeverOverwrites() throws {
        try fixture { root, journal, item, id in
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id)
            let target = root.appendingPathComponent("report.txt")
            try Data("keep me".utf8).write(to: target)
            XCTAssertThrowsError(try engine.restore(plan))
            XCTAssertEqual(try Data(contentsOf: target), Data("keep me".utf8))
            XCTAssertEqual(try Data(contentsOf: item), Data("original contents".utf8))
        }
    }

    func testMissingAndReplacedTrashObjectAreRefused() throws {
        try fixture { root, journal, item, id in
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id)
            try FileManager.default.moveItem(at: item, to: root.appendingPathComponent("kept"))
            XCTAssertThrowsError(try engine.review(id: id)) { XCTAssertEqual($0 as? RestoreError, .missingTrash) }
            try Data("replacement".utf8).write(to: item)
            XCTAssertThrowsError(try engine.restore(plan)) { XCTAssertEqual($0 as? RestoreError, .changedObject) }
            XCTAssertEqual(try Data(contentsOf: item), Data("replacement".utf8))
        }
    }

    func testSymlinkDestinationParentAndJournalOverlapAreRefused() throws {
        try fixture { root, journal, _, id in
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            let engine = RestoreEngine(journal: journal)
            XCTAssertThrowsError(try engine.review(id: id, destination: link.appendingPathComponent("other")))
            XCTAssertThrowsError(try engine.review(id: id, destination: journal.storageDirectory.appendingPathComponent("other")))
            XCTAssertThrowsError(try engine.review(id: id, destination: root))
        }
    }

    func testJournalFailurePreventsMove() throws {
        try fixture { root, journal, item, id in
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id)
            try Data("corrupt".utf8).write(to: journal.storageDirectory.appendingPathComponent(id.uuidString + ".json"))
            XCTAssertThrowsError(try engine.restore(plan))
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("report.txt").path))
        }
    }

    func testInterruptedMutationLeavesDurablePendingAndCannotRetry() throws {
        try fixture { _, journal, item, id in
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id)
            XCTAssertThrowsError(try journal.commitRestore(plan) { throw RestoreError.io(EIO) })
            let reloaded = CleanupJournal(directory: journal.storageDirectory)
            XCTAssertEqual(try reloaded.entries().first?.restore?.state, .pending)
            XCTAssertThrowsError(try RestoreEngine(journal: reloaded).review(id: id))
            XCTAssertThrowsError(try engine.restore(plan))
            XCTAssertEqual(try Data(contentsOf: item), Data("original contents".utf8))
        }
    }

    func testAlternateExistingFolderResolvesConflictWithoutChangingExistingFile() throws {
        try fixture { root, journal, _, id in
            let original = root.appendingPathComponent("report.txt")
            try Data("existing".utf8).write(to: original)
            let folder = root.appendingPathComponent("Recovered")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let engine = RestoreEngine(journal: journal)
            XCTAssertThrowsError(try engine.review(id: id)) { XCTAssertEqual($0 as? RestoreError, .conflict) }
            let destination = folder.appendingPathComponent("report.txt")
            try engine.restore(engine.review(id: id, destination: destination))
            XCTAssertEqual(try Data(contentsOf: original), Data("existing".utf8))
            XCTAssertEqual(try Data(contentsOf: destination), Data("original contents".utf8))
        }
    }

    func testDestinationSymlinkAfterReviewNeverFollowsOrReplacesLink() throws {
        try fixture { root, journal, item, id in
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id)
            let other = root.appendingPathComponent("other")
            try Data("keep".utf8).write(to: other)
            try FileManager.default.createSymbolicLink(at: plan.destination, withDestinationURL: other)
            XCTAssertThrowsError(try engine.restore(plan))
            XCTAssertEqual(try Data(contentsOf: other), Data("keep".utf8))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: plan.destination.path), other.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
        }
    }

    func testReplacementBetweenMoveAndOutcomeIsNeverVerified() throws {
        try fixture { root, journal, _, _ in
            let original = root.appendingPathComponent("other.txt")
            let destination = root.appendingPathComponent("SimulatedTrash/other.txt")
            try Data("original".utf8).write(to: original)
            let id = try journal.recordIntent(source: original)
            try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("retained-original"))
            try Data("replacement".utf8).write(to: destination)
            try journal.recordOutcome(id: id, destination: destination, failure: nil)
            let entry = try XCTUnwrap(journal.entries().first(where: { $0.id == id }))
            XCTAssertNil(entry.destinationSnapshot)
            XCTAssertThrowsError(try RestoreEngine(journal: journal).review(id: id)) { XCTAssertEqual($0 as? RestoreError, .changedObject) }
            XCTAssertEqual(try Data(contentsOf: destination), Data("replacement".utf8))
        }
    }

    func testReplacingReviewedDestinationFolderRequiresNewReview() throws {
        try fixture { root, journal, item, id in
            let folder = root.appendingPathComponent("ReviewedFolder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id, destination: folder.appendingPathComponent("report.txt"))
            try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("OriginalFolder"))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            XCTAssertThrowsError(try engine.restore(plan))
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        }
    }

    func testMissingDestinationEvidenceCanBeVerifiedOnExplicitReview() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission fixture requires an unprivileged process") }
        try fixture { root, journal, item, _ in
            let original = root.appendingPathComponent("delayed.txt")
            let parent = item.deletingLastPathComponent()
            let destination = parent.appendingPathComponent("delayed.txt")
            try Data("delayed fixture".utf8).write(to: original)
            let id = try journal.recordIntent(source: original)
            try FileManager.default.moveItem(at: original, to: destination)
            XCTAssertEqual(chmod(parent.path, 0), 0)
            defer { chmod(parent.path, 0o700) }
            try journal.recordOutcome(id: id, destination: destination, failure: nil)
            XCTAssertNil(try journal.entries().first(where: { $0.id == id })?.destinationSnapshot)
            let engine = RestoreEngine(journal: journal)
            XCTAssertThrowsError(try engine.review(id: id)) { XCTAssertEqual($0 as? RestoreError, .accessDenied) }
            XCTAssertEqual(chmod(parent.path, 0o700), 0)
            try engine.assess(try XCTUnwrap(journal.entries().first(where: { $0.id == id })))
            XCTAssertNil(try journal.entries().first(where: { $0.id == id })?.destinationSnapshot, "Viewing availability must not rewrite the record")
            let plan = try engine.review(id: id)
            XCTAssertNotNil(try journal.entries().first(where: { $0.id == id })?.destinationSnapshot, "Explicit review must durably save verified evidence")
            try engine.restore(plan)
            XCTAssertEqual(try Data(contentsOf: original), Data("delayed fixture".utf8))
        }
    }

    func testDelayedVerificationRejectsEditedTrashContents() throws {
        try fixture { _, journal, item, id in
            let record = journal.storageDirectory.appendingPathComponent(id.uuidString + ".json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
            json.removeValue(forKey: "destinationSnapshot")
            try JSONSerialization.data(withJSONObject: json).write(to: record)
            try Data("changed contents with different size".utf8).write(to: item)
            XCTAssertThrowsError(try RestoreEngine(journal: journal).review(id: id)) { XCTAssertEqual($0 as? RestoreError, .changedObject) }
            XCTAssertNil(try journal.entries().first?.destinationSnapshot)
            XCTAssertEqual(try Data(contentsOf: item), Data("changed contents with different size".utf8))
        }
    }

    func testDeniedTrashDirectoryHasSpecificAccessReason() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission fixture requires an unprivileged process") }
        try fixture { _, journal, item, id in
            let parent = item.deletingLastPathComponent()
            XCTAssertEqual(chmod(parent.path, 0), 0)
            defer { chmod(parent.path, 0o700) }
            XCTAssertThrowsError(try RestoreEngine(journal: journal).review(id: id)) { XCTAssertEqual($0 as? RestoreError, .accessDenied) }
        }
    }

    func testDeniedRenameRecordsNoMoveAndRequiresFreshReviewForRetry() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission fixture requires an unprivileged process") }
        try fixture { root, journal, item, id in
            let folder = root.appendingPathComponent("ReadOnlyDestination")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id, destination: folder.appendingPathComponent("report.txt"))
            XCTAssertEqual(chmod(folder.path, 0o555), 0)
            defer { chmod(folder.path, 0o700) }
            XCTAssertThrowsError(try engine.restore(plan)) { XCTAssertEqual($0 as? RestoreError, .accessDenied) }
            XCTAssertEqual(try journal.entries().first?.restore?.state, .failed)
            XCTAssertNotNil(try journal.entries().first?.restore?.error)
            XCTAssertEqual(chmod(folder.path, 0o700), 0)
            XCTAssertThrowsError(try engine.restore(plan)) { XCTAssertEqual($0 as? RestoreError, .invalidState) }
            let reloaded = CleanupJournal(directory: journal.storageDirectory)
            let retry = try RestoreEngine(journal: reloaded).review(id: id, destination: plan.destination)
            try engine.restore(retry)
            XCTAssertEqual(try journal.entries().first?.restore?.state, .restored)
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
            XCTAssertEqual(try Data(contentsOf: plan.destination), Data("original contents".utf8))
        }
    }

    func testFailureAfterMoveKeepsUnknownOutcomeAndCannotRetry() throws {
        try fixture { _, journal, item, id in
            let engine = RestoreEngine(journal: journal)
            let plan = try engine.review(id: id)
            XCTAssertThrowsError(try journal.commitRestore(plan) {
                try FileManager.default.moveItem(at: item, to: plan.destination)
                throw RestoreError.io(EIO)
            })
            let reloaded = CleanupJournal(directory: journal.storageDirectory)
            XCTAssertEqual(try reloaded.entries().first?.restore?.state, .pending)
            XCTAssertNil(try reloaded.entries().first?.restore?.error)
            for target in [plan.destination, item] {
                XCTAssertThrowsError(try reloaded.recordIntent(source: target)) {
                    XCTAssertEqual($0 as? CleanupJournalError, .pendingConflict)
                }
            }
            XCTAssertThrowsError(try RestoreEngine(journal: reloaded).review(id: id)) {
                XCTAssertEqual($0 as? RestoreError, .invalidState)
            }
            XCTAssertEqual(try Data(contentsOf: plan.destination), Data("original contents".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
        }
    }

    func testOptInGeneratedFixtureThroughFinderTrashAndRestore() throws {
        guard ProcessInfo.processInfo.environment["MACSWEEP_RESTORE_FIXTURE"] == "1" else {
            throw XCTSkip("Set MACSWEEP_RESTORE_FIXTURE=1 to exercise Finder Trash with one generated fixture.")
        }
        try fixture { root, journal, _, _ in
            let original = root.appendingPathComponent("MacSweep-restore-fixture-" + UUID().uuidString + ".txt")
            let content = Data("Generated MacSweep restore integration fixture".utf8)
            try content.write(to: original)
            print("RESTORE FIXTURE stage=before-intent original=\(original.absoluteString)")
            traceFixtureDirectory(original.deletingLastPathComponent())
            let identity = try RestoreSnapshot.capture(original)
            let id = try journal.recordIntent(source: original)
            var trashed: NSURL?
            defer {
                // This opt-in test owns only the freshly generated object. Never
                // clean up a replacement that happens to occupy its Trash path.
                if let destination = trashed as URL?,
                   let current = try? RestoreSnapshot.capture(destination), current.isSameObject(as: identity) {
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            print("RESTORE FIXTURE stage=before-trash")
            try FileManager.default.trashItem(at: original, resultingItemURL: &trashed)
            let destination = try XCTUnwrap(trashed as URL?)
            print("RESTORE FIXTURE stage=after-trash returned=\(destination.absoluteString) path=\(destination.path)")
            traceFixtureDirectory(destination.deletingLastPathComponent())
            try journal.recordOutcome(id: id, destination: destination, failure: nil)
            let engine = RestoreEngine(journal: journal)
            print("RESTORE FIXTURE stage=after-outcome verified=\(try journal.entries().first(where: { $0.id == id })?.destinationSnapshot != nil)")
            do {
                let plan = try engine.review(id: id)
                print("RESTORE FIXTURE stage=after-review source=\(plan.source.absoluteString) target=\(plan.destination.absoluteString)")
                try engine.restore(plan)
                print("RESTORE FIXTURE stage=after-restore")
            } catch {
                print("RESTORE FIXTURE failure=\(error)")
                traceFixtureDirectory(original.deletingLastPathComponent())
                traceFixtureDirectory(destination.deletingLastPathComponent())
                throw error
            }
            XCTAssertEqual(try Data(contentsOf: original), content)
            XCTAssertEqual(try journal.entries().first(where: { $0.id == id })?.restore?.state, .restored)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testLegacyRecordWithoutSnapshotStaysManual() throws {
        try fixture { _, journal, item, id in
            let file = journal.storageDirectory.appendingPathComponent(id.uuidString + ".json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            json.removeValue(forKey: "destinationSnapshot")
            json.removeValue(forKey: "sourceSnapshot")
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            XCTAssertEqual(try journal.entries().count, 1)
            XCTAssertThrowsError(try RestoreEngine(journal: journal).review(id: id)) { XCTAssertEqual($0 as? RestoreError, .legacyRecord) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
        }
    }
    /// Opt-in diagnostic only, walking the generated fixture's two parents with
    /// the same no-follow flags. No directory enumeration or user files are read.
    private func traceFixtureDirectory(_ url: URL) {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { print("RESTORE FIXTURE root-open errno=\(errno)"); return }
        defer { close(fd) }
        var path = ""
        for part in url.path.split(separator: "/") {
            path += "/" + part
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let code = errno
                print("RESTORE FIXTURE parent-open path=\(path) errno=\(code) message=\(String(cString: strerror(code)))")
                return
            }
            close(fd); fd = next
        }
        print("RESTORE FIXTURE parent-open success path=\(url.path)")
    }

}
