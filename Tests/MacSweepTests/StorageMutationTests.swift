import Foundation
import XCTest
@testable import MacSweep

final class StorageMutationTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testRootReplacementAfterListingRejectsOldContents() throws {
        let parent = try fixture()
        let root = parent.appendingPathComponent("Root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: root.appendingPathComponent("item"))
        XCTAssertThrowsError(try StorageDirectoryReader.read(root, beforeFinish: {
            try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("OldRoot"))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("replacement".utf8).write(to: root.appendingPathComponent("other"))
        })) { XCTAssertTrue($0 is StorageReadError) }
    }

    func testChangedContentsRemainUsefulButPartial() throws {
        let root = try fixture()
        try Data("old".utf8).write(to: root.appendingPathComponent("old"))
        let report = try StorageDirectoryReader.read(root, beforeFinish: {
            try Data("new".utf8).write(to: root.appendingPathComponent("new"))
        })
        XCTAssertTrue(report.partial)
        XCTAssertEqual(report.entries.map(\.url.lastPathComponent), ["old"])
        XCTAssertFalse(try StorageDirectoryReader.verify(root, expected: XCTUnwrap(report.stamp)))
    }

    func testDiscoveredFolderIdentityRejectsReplacementBeforeDescent() throws {
        let root = try fixture()
        let child = root.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let identity = try XCTUnwrap(StorageDirectoryReader.read(root).entries.first?.identity)
        try FileManager.default.moveItem(at: child, to: root.appendingPathComponent("Original"))
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertThrowsError(try StorageDirectoryReader.read(child, expectedIdentity: identity)) {
            XCTAssertTrue($0 is StorageReadError)
        }
    }

    func testAncestorReplacedWithLinkAfterListingIsRejected() throws {
        let parent = try fixture()
        let root = parent.appendingPathComponent("Root")
        let child = root.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let retained = parent.appendingPathComponent("Retained")
        XCTAssertThrowsError(try StorageDirectoryReader.read(child, beforeFinish: {
            try FileManager.default.moveItem(at: root, to: retained)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: retained)
        })) { XCTAssertTrue($0 is StorageReadError) }
    }
}
