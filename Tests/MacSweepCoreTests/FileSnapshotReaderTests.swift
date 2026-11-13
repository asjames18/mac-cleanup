import Foundation
import Darwin
import XCTest
@testable import MacSweepCore

final class FileSnapshotReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // Foundation can shorten /private/var back to the /var symlink even after
        // resolvingSymlinksInPath. Canonicalize only this trusted fixture root.
        let temporaryPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporaryPath) }
        root = URL(fileURLWithPath: String(cString: temporaryPath))
            .appendingPathComponent("MacSweepCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func file(_ name: String, text: String = "fixture") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testCaptureStableFileAndDirectoryWithoutContentDigest() throws {
        let url = try file("sample")
        let snapshot = try FileSnapshotReader.capture(url)
        XCTAssertEqual(snapshot.logicalBytes, 7)
        XCTAssertNil(snapshot.contentDigest)
        XCTAssertNotNil(snapshot.changedAt)
        XCTAssertEqual(FileSnapshotReader.validate(expected: snapshot, at: url), .unchanged)
        let directory = try FileSnapshotReader.capture(root)
        XCTAssertEqual(FileSnapshotReader.validate(expected: directory, at: root), .unchanged)
    }

    func testHardLinksShareIdentityAcrossDifferentPaths() throws {
        let url = try file("original")
        let link = root.appendingPathComponent("OtherName")
        try FileManager.default.linkItem(at: url, to: link)
        XCTAssertEqual(try FileSnapshotReader.capture(url).identity, try FileSnapshotReader.capture(link).identity)
    }

    func testReplacementWithSameSizeAndModificationTimeRequiresRescan() throws {
        let url = try file("original")
        let before = try FileSnapshotReader.capture(url)
        // Keep the old inode alive so this fixture cannot accidentally recycle it.
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("retained"))
        try Data("changed".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: before.modifiedAt], ofItemAtPath: url.path)
        let after = try FileSnapshotReader.capture(url)
        XCTAssertEqual(before.logicalBytes, after.logicalBytes)
        XCTAssertEqual(before.modifiedAt.timeIntervalSince1970, after.modifiedAt.timeIntervalSince1970, accuracy: 0.00001)
        XCTAssertNotEqual(before.identity, after.identity)
        XCTAssertEqual(FileSnapshotReader.validate(expected: before, at: url), .needsRescan)
    }

    func testChangedFileRequiresRescan() throws {
        let url = try file("original")
        let before = try FileSnapshotReader.capture(url)
        try Data("longer fixture".utf8).write(to: url)
        XCTAssertEqual(FileSnapshotReader.validate(expected: before, at: url), .needsRescan)
    }

    func testMissingTargetIsUnavailable() throws {
        let url = try file("original")
        let before = try FileSnapshotReader.capture(url)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try FileSnapshotReader.capture(url))
        XCTAssertEqual(FileSnapshotReader.validate(expected: before, at: url), .unavailable)
    }

    func testFinalSymlinkIsRejected() throws {
        let url = try file("original")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try FileSnapshotReader.capture(link))
        XCTAssertEqual(FileSnapshotReader.validate(expected: try FileSnapshotReader.capture(url), at: link), .unavailable)
    }

    func testSymlinkParentIsRejected() throws {
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let actual = folder.appendingPathComponent("sample")
        try Data("hello".utf8).write(to: actual)
        let link = root.appendingPathComponent("parent-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertThrowsError(try FileSnapshotReader.capture(link.appendingPathComponent("sample")))
    }

    func testSymlinkFollowedByDotDotIsRejected() throws {
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("parent-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        _ = try file("sample")
        let path = URL(fileURLWithPath: root.path + "/parent-link/../sample")
        XCTAssertThrowsError(try FileSnapshotReader.capture(path))
    }

    func testNonFileURLIsRejected() {
        XCTAssertThrowsError(try FileSnapshotReader.capture(URL(string: "https://example.com/file")!))
    }
}
