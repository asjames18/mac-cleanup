import Darwin
import Foundation
import XCTest
@testable import MacSweepCore

final class CleanupJournalTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        // Foundation can shorten /private/var back to the /var alias. Resolve only
        // this trusted test root through Darwin before constructing fixture URLs.
        let temporaryPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporaryPath) }
        let root = URL(fileURLWithPath: String(cString: temporaryPath))
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testIntentPersistsAndPendingSurvivesRestart() throws {
        try fixture { root in
            let directory = root.appendingPathComponent("History")
            let source = root.appendingPathComponent("source")
            let id = try CleanupJournal(directory: directory).recordIntent(source: source)
            let reloaded = try CleanupJournal(directory: directory).entries()
            XCTAssertEqual(reloaded.count, 1)
            XCTAssertEqual(reloaded.first?.id, id)
            XCTAssertEqual(reloaded.first?.source, source)
            XCTAssertEqual(reloaded.first?.state, .pending)
            XCTAssertNil(reloaded.first?.destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            let record = directory.appendingPathComponent(id.uuidString + ".json")
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: record.path)
            XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testSuccessAndFailureOutcomesReplacePendingRecords() throws {
        try fixture { root in
            let journal = CleanupJournal(directory: root.appendingPathComponent("History"))
            let first = try journal.recordIntent(source: root.appendingPathComponent("first"))
            let second = try journal.recordIntent(source: root.appendingPathComponent("second"))
            let destination = root.appendingPathComponent("Trash/first")
            try journal.recordOutcome(id: first, destination: destination, failure: nil)
            try journal.recordOutcome(id: second, destination: nil, failure: "Permission denied")
            let entries = try journal.entries()
            XCTAssertEqual(entries.count, 2)
            XCTAssertEqual(entries.first(where: { $0.id == first })?.state, .moved)
            XCTAssertEqual(entries.first(where: { $0.id == first })?.destination, destination)
            XCTAssertEqual(entries.first(where: { $0.id == second })?.state, .failed)
            XCTAssertEqual(entries.first(where: { $0.id == second })?.error, "Permission denied")
            XCTAssertThrowsError(try journal.recordOutcome(id: first, destination: nil, failure: "retry"))
        }
    }

    func testMultipleEntriesAreNewestFirst() throws {
        try fixture { root in
            let journal = CleanupJournal(directory: root.appendingPathComponent("History"))
            for index in 0..<5 { _ = try journal.recordIntent(source: root.appendingPathComponent("source-\(index)")) }
            let entries = try journal.entries()
            XCTAssertEqual(entries.count, 5)
            XCTAssertEqual(Set(entries.map(\.id)).count, 5)
            XCTAssertEqual(entries.map(\.date), entries.map(\.date).sorted(by: >))
        }
    }

    func testCorruptionFailsClosedWithoutOverwritingRecord() throws {
        try fixture { root in
            let directory = root.appendingPathComponent("History")
            let journal = CleanupJournal(directory: directory)
            let id = try journal.recordIntent(source: root.appendingPathComponent("source"))
            let record = directory.appendingPathComponent(id.uuidString + ".json")
            let corrupt = Data("not JSON".utf8)
            try corrupt.write(to: record)
            XCTAssertThrowsError(try journal.entries())
            XCTAssertThrowsError(try journal.recordOutcome(id: id, destination: nil, failure: "failed"))
            XCTAssertThrowsError(try journal.recordIntent(source: root.appendingPathComponent("second")))
            XCTAssertEqual(try Data(contentsOf: record), corrupt)
        }
    }

    func testSymlinkFolderIsRejected() throws {
        try fixture { root in
            let target = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let link = root.appendingPathComponent("History")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try CleanupJournal(directory: link).recordIntent(source: root.appendingPathComponent("source")))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }
    }

    func testSymlinkAncestorIsRejectedBeforeCreationAndLeavesTargetUnchanged() throws {
        try fixture { root in
            let target = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o755])
            let marker = target.appendingPathComponent("marker")
            let contents = Data("untouched".utf8)
            try contents.write(to: marker)
            let link = root.appendingPathComponent("linked-parent")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let journal = CleanupJournal(directory: link.appendingPathComponent("new-parent/History"))
            XCTAssertThrowsError(try journal.recordIntent(source: root.appendingPathComponent("source")))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["marker"])
            XCTAssertEqual(try Data(contentsOf: marker), contents)
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        }
    }

    func testExistingAncestorPermissionsRemainUnchanged() throws {
        try fixture { root in
            let parent = root.appendingPathComponent("parent")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o755])
            _ = try CleanupJournal(directory: parent.appendingPathComponent("History"))
                .recordIntent(source: root.appendingPathComponent("source"))
            let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        }
    }

    func testSymlinkRecordCannotBeReadOrOverwritten() throws {
        try fixture { root in
            let directory = root.appendingPathComponent("History")
            let journal = CleanupJournal(directory: directory)
            let id = try journal.recordIntent(source: root.appendingPathComponent("source"))
            let record = directory.appendingPathComponent(id.uuidString + ".json")
            let target = root.appendingPathComponent("external")
            let contents = Data("untouched".utf8)
            try contents.write(to: target)
            try FileManager.default.removeItem(at: record)
            try FileManager.default.createSymbolicLink(at: record, withDestinationURL: target)
            XCTAssertThrowsError(try journal.entries())
            XCTAssertThrowsError(try journal.recordOutcome(id: id, destination: nil, failure: "failed"))
            XCTAssertEqual(try Data(contentsOf: target), contents)
        }
    }

    func testInvalidAndOversizedInputDoesNotCreateIntent() throws {
        try fixture { root in
            let journal = CleanupJournal(directory: root.appendingPathComponent("History"))
            XCTAssertThrowsError(try journal.recordIntent(source: URL(string: "https://example.com")!))
            let id = try journal.recordIntent(source: root.appendingPathComponent("source"))
            XCTAssertThrowsError(try journal.recordOutcome(id: id, destination: nil, failure: String(repeating: "x", count: 8_193)))
            XCTAssertEqual(try journal.entries().first?.state, .pending)
            XCTAssertThrowsError(try journal.recordOutcome(id: UUID(), destination: nil, failure: nil))
        }
    }
}
