import Darwin
import Foundation
import XCTest
@testable import MacSweepCore

final class BoundedFileReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let temporaryPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporaryPath) }
        root = URL(fileURLWithPath: String(cString: temporaryPath))
            .appendingPathComponent("BoundedFileReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testReadsAFileAtTheExactLimit() throws {
        let url = root.appendingPathComponent("exact")
        let expected = Data(repeating: 0x5a, count: 1_024)
        try expected.write(to: url)

        XCTAssertEqual(try BoundedFileReader.read(url, maximumBytes: 1_024), expected)
    }

    func testRejectsFilesOverTheLimit() throws {
        let url = root.appendingPathComponent("large")
        try Data(repeating: 1, count: 1_025).write(to: url)

        XCTAssertThrowsError(try BoundedFileReader.read(url, maximumBytes: 1_024)) {
            XCTAssertEqual($0 as? BoundedFileReadError, .tooLarge(maximumBytes: 1_024))
        }
    }

    func testRejectsInvalidURLsAndLimits() throws {
        XCTAssertThrowsError(try BoundedFileReader.read(URL(string: "https://example.com/file")!)) {
            XCTAssertEqual($0 as? BoundedFileReadError, .invalidURL)
        }
        XCTAssertThrowsError(try BoundedFileReader.read(root.appendingPathComponent("file"), maximumBytes: -1)) {
            XCTAssertEqual($0 as? BoundedFileReadError, .invalidMaximumBytes)
        }
    }

    func testRejectsFIFOWithoutWaitingForAWriter() throws {
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = ContinuousClock.now

        XCTAssertThrowsError(try BoundedFileReader.read(fifo)) {
            XCTAssertEqual($0 as? BoundedFileReadError, .unsupportedFileType)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testRejectsLeafAndAncestorSymlinks() throws {
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("file")
        try Data("fixture".utf8).write(to: file)
        let leafLink = root.appendingPathComponent("leaf-link")
        try FileManager.default.createSymbolicLink(at: leafLink, withDestinationURL: file)

        XCTAssertThrowsError(try BoundedFileReader.read(leafLink)) {
            XCTAssertEqual($0 as? BoundedFileReadError, .symbolicLink)
        }

        let ancestorLink = root.appendingPathComponent("ancestor-link")
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: directory)
        XCTAssertThrowsError(try BoundedFileReader.read(ancestorLink.appendingPathComponent("file"))) {
            XCTAssertEqual($0 as? BoundedFileReadError, .symbolicLink)
        }
    }

    func testCancellationStopsBeforeReturningData() throws {
        let url = root.appendingPathComponent("file")
        try Data(repeating: 2, count: 128_000).write(to: url)
        var checks = 0

        XCTAssertThrowsError(try BoundedFileReader.read(url, isCancelled: {
            checks += 1
            return checks > 1
        })) {
            XCTAssertEqual($0 as? BoundedFileReadError, .cancelled)
        }
    }

    func testRejectsAFileThatGrowsBeyondTheLimitDuringRead() throws {
        let url = root.appendingPathComponent("growing")
        try Data(repeating: 3, count: 100_000).write(to: url)

        XCTAssertThrowsError(try BoundedFileReader.read(url, maximumBytes: 128_000, afterChunk: { chunk in
            guard chunk == 1 else { return }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 4, count: 30_000))
            try handle.close()
        })) {
            XCTAssertEqual($0 as? BoundedFileReadError, .tooLarge(maximumBytes: 128_000))
        }
    }

    func testRejectsContentMutationDuringRead() throws {
        let mutable = root.appendingPathComponent("mutable")
        try Data(repeating: 3, count: 128_000).write(to: mutable)
        XCTAssertThrowsError(try BoundedFileReader.read(mutable, afterChunk: { chunk in
            guard chunk == 1 else { return }
            let handle = try FileHandle(forWritingTo: mutable)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([4]))
            try handle.close()
        })) {
            XCTAssertEqual($0 as? BoundedFileReadError, .changedDuringRead)
        }
    }

    func testRejectsPathReplacementDuringRead() throws {
        let replaceable = root.appendingPathComponent("replaceable")
        let retained = root.appendingPathComponent("retained")
        try Data(repeating: 5, count: 128_000).write(to: replaceable)
        XCTAssertThrowsError(try BoundedFileReader.read(replaceable, afterChunk: { chunk in
            guard chunk == 1 else { return }
            try FileManager.default.moveItem(at: replaceable, to: retained)
            try Data(repeating: 5, count: 128_000).write(to: replaceable)
        })) {
            XCTAssertEqual($0 as? BoundedFileReadError, .changedDuringRead)
        }
    }

    func testRejectsAncestorReplacementBeforeDescriptorTraversal() throws {
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("file")
        try Data("original".utf8).write(to: url)
        let retained = root.appendingPathComponent("retained", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try Data("redirected".utf8).write(to: replacement.appendingPathComponent("file"))

        XCTAssertThrowsError(try BoundedFileReader.read(url, beforeDescriptorTraversal: {
            try FileManager.default.moveItem(at: directory, to: retained)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: replacement)
        }, afterChunk: { _ in })) {
            XCTAssertTrue($0 is BoundedFileReadError)
        }
    }
}
