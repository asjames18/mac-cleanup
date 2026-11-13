import Darwin
import Foundation
import XCTest
@testable import MacSweep

final class FolderAccessTests: XCTestCase {
    func testDirectFolderMissingFileAndLinksHaveDistinctResults() throws {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file")
        try Data("fixture".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertEqual(FolderAccessChecker.check(folder).status, .readable)
        XCTAssertEqual(FolderAccessChecker.check(root.appendingPathComponent("absent")).status, .missing)
        XCTAssertEqual(FolderAccessChecker.check(file).status, .unsupportedPath)
        XCTAssertEqual(FolderAccessChecker.check(link).status, .unsupportedPath)
        XCTAssertEqual(FolderAccessChecker.check(link.appendingPathComponent("child")).status, .unsupportedPath)
        XCTAssertEqual(FolderAccessChecker.check(try XCTUnwrap(URL(string: "https://example.com"))).status, .unsupportedPath)
        XCTAssertEqual(try Data(contentsOf: file), Data("fixture".utf8))
    }

    func testUnreadableFolderIsDeniedAndCanBeRechecked() throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires an unprivileged permission fixture") }
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, 0), 0)
        XCTAssertEqual(FolderAccessChecker.check(root).status, .denied)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertEqual(FolderAccessChecker.check(root).status, .readable)
    }

    @MainActor
    func testTimeoutGatesRetryAndDiscardsLateResult() async throws {
        let gate = AccessProbeGate()
        defer { gate.release() }
        let store = FolderAccessStore(timeout: .milliseconds(50), probe: { url in
            gate.block(); return FolderAccessResult(url: url, status: .readable)
        })
        let urls = [URL(fileURLWithPath: "/fixture")]
        store.check(urls)
        for _ in 0..<200 where !store.waiting { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.waiting)
        XCTAssertFalse(store.checking)
        XCTAssertTrue(store.message.contains("timed out"))
        store.check(urls)
        XCTAssertEqual(gate.calls, 1)
        gate.release()
        for _ in 0..<200 where store.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.busy)
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertNil(store.checkedAt)
        store.check(urls)
        for _ in 0..<200 where store.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.results.count, 1)
        XCTAssertNotNil(store.checkedAt)
    }

    @MainActor
    func testCancelPreservesPartialResultsAndNeverPublishesBlockedProbe() async throws {
        let gate = AccessProbeGate()
        defer { gate.release() }
        let store = FolderAccessStore(probe: { url in
            if url.lastPathComponent == "blocked" { gate.block() }
            return FolderAccessResult(url: url, status: .readable)
        })
        store.check([URL(fileURLWithPath: "/first"), URL(fileURLWithPath: "/blocked")])
        for _ in 0..<200 where gate.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.results.map(\.url.path), ["/first"])
        store.cancel()
        XCTAssertTrue(store.waiting)
        gate.release()
        for _ in 0..<200 where store.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.results.map(\.url.path), ["/first"])
        XCTAssertNil(store.checkedAt)
    }
}

private final class AccessProbeGate: @unchecked Sendable {
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
