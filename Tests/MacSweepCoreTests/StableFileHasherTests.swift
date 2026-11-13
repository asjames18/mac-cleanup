import Darwin
import Foundation
import XCTest
@testable import MacSweepCore

final class StableFileHasherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let temporaryPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporaryPath) }
        root = URL(fileURLWithPath: String(cString: temporaryPath))
            .appendingPathComponent("StableFileHasherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testStreamsAStableFileAndReturnsKnownDigest() throws {
        let url = root.appendingPathComponent("large")
        try Data(repeating: Character("a").asciiValue!, count: 1_100_000).write(to: url)

        XCTAssertEqual(
            try StableFileHasher.sha256(url),
            "6aafaf4ef7899e48a5590041668ae9a810e9156a9924ea484e3594072192fbd4"
        )
    }

    func testRejectsLeafAndAncestorSymlinks() throws {
        let file = root.appendingPathComponent("file")
        try Data("fixture".utf8).write(to: file)
        let leafLink = root.appendingPathComponent("leaf-link")
        try FileManager.default.createSymbolicLink(at: leafLink, withDestinationURL: file)

        XCTAssertThrowsError(try StableFileHasher.sha256(leafLink)) {
            XCTAssertEqual($0 as? StableFileHashError, .symbolicLink)
        }

        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let nested = directory.appendingPathComponent("nested")
        try Data("fixture".utf8).write(to: nested)
        let ancestorLink = root.appendingPathComponent("ancestor-link")
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: directory)

        XCTAssertThrowsError(try StableFileHasher.sha256(ancestorLink.appendingPathComponent("nested"))) {
            XCTAssertEqual($0 as? StableFileHashError, .symbolicLink)
        }
    }

    func testRejectsFIFOWithoutWaitingForAWriter() throws {
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = ContinuousClock.now

        XCTAssertThrowsError(try StableFileHasher.sha256(fifo)) {
            XCTAssertEqual($0 as? StableFileHashError, .unsupportedFileType)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testCancellationStopsBeforeReturningADigest() throws {
        let url = root.appendingPathComponent("large")
        try Data(repeating: 1, count: 2_000_000).write(to: url)
        var checks = 0

        XCTAssertThrowsError(try StableFileHasher.sha256(url, isCancelled: {
            checks += 1
            return checks > 1
        })) {
            XCTAssertEqual($0 as? StableFileHashError, .cancelled)
        }
    }

    func testRejectsContentMutationDuringHash() throws {
        let url = root.appendingPathComponent("mutable")
        try Data(repeating: 2, count: 2_000_000).write(to: url)

        XCTAssertThrowsError(try StableFileHasher.sha256(url, afterChunk: { chunk in
            guard chunk == 1 else { return }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([3]))
            try handle.close()
        })) {
            XCTAssertEqual($0 as? StableFileHashError, .changedDuringRead)
        }
    }

    func testRejectsPathReplacementDuringHash() throws {
        let url = root.appendingPathComponent("replaceable")
        try Data(repeating: 4, count: 2_000_000).write(to: url)
        let retained = root.appendingPathComponent("retained")

        XCTAssertThrowsError(try StableFileHasher.sha256(url, afterChunk: { chunk in
            guard chunk == 1 else { return }
            try FileManager.default.moveItem(at: url, to: retained)
            try Data(repeating: 4, count: 2_000_000).write(to: url)
        })) {
            XCTAssertEqual($0 as? StableFileHashError, .changedDuringRead)
        }
    }

    func testRejectsAncestorSubstitutionBeforeDescriptorTraversal() throws {
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("file")
        try Data("original".utf8).write(to: url)
        let retained = root.appendingPathComponent("retained", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try Data("redirected".utf8).write(to: replacement.appendingPathComponent("file"))
        var readChunks = 0

        XCTAssertThrowsError(try StableFileHasher.sha256(url, beforeDescriptorTraversal: {
            try FileManager.default.moveItem(at: directory, to: retained)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: replacement)
        }, afterChunk: { _ in readChunks += 1 }))
        XCTAssertEqual(readChunks, 0)
    }
}
