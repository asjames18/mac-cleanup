import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import MacSweep

final class StorageBrowserTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testShallowListingShowsSparseFileLinksAndSpecialItemsWithoutOpeningThem() throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a top-level entry".utf8).write(to: folder.appendingPathComponent("Nested"))
        let sparse = root.appendingPathComponent("Sparse")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 10_000_000); try handle.close()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: folder)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("Pipe").path, 0o600), 0)
        let report = try StorageDirectoryReader.read(root)
        XCTAssertFalse(report.partial)
        XCTAssertEqual(report.entries.count, 4)
        XCTAssertEqual(report.entries.first(where: { $0.url == sparse })?.logicalBytes, 10_000_000)
        XCTAssertLessThan(try XCTUnwrap(report.entries.first(where: { $0.url == sparse })?.allocatedBytes), 10_000_000)
        XCTAssertTrue(report.entries.contains { $0.kind == .folder })
        XCTAssertTrue(report.entries.contains { $0.kind == .link })
        XCTAssertTrue(report.entries.contains { $0.kind == .other })
        XCTAssertFalse(report.entries.contains { $0.url.lastPathComponent == "Nested" })
        XCTAssertThrowsError(try StorageDirectoryReader.read(root.appendingPathComponent("Link")))
        XCTAssertThrowsError(try StorageDirectoryReader.fileEntry(root.appendingPathComponent("Link")))
        XCTAssertThrowsError(try StorageDirectoryReader.fileEntry(root.appendingPathComponent("Pipe")))
        let single = try StorageDirectoryReader.fileEntry(sparse)
        XCTAssertEqual(single.logicalBytes, 10_000_000)
        XCTAssertNotNil(single.identity)
    }

    func testExclusionsDoNotHideUnexcludedSiblingsAndBudgetsRemainPartial() throws {
        let root = try fixture()
        let excluded = root.appendingPathComponent("Keep")
        let sibling = root.appendingPathComponent("Other")
        for url in [excluded, sibling] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let report = try StorageDirectoryReader.read(root, exclusions: [excluded])
        XCTAssertEqual(report.entries.map(\.url.path), [sibling.path])
        XCTAssertEqual(report.skipped, 1)
        XCTAssertThrowsError(try StorageDirectoryReader.read(excluded, exclusions: [excluded]))
        let bounded = try StorageDirectoryReader.read(root, limit: ScanLimit(seconds: 10, entries: 1))
        XCTAssertTrue(bounded.partial)
        XCTAssertEqual(bounded.entries.count, 1)
        XCTAssertThrowsError(try StorageDirectoryReader.read(root.appendingPathComponent("missing")))
    }

    @MainActor
    func testNavigationAndReturnToParent() async throws {
        let root = try fixture()
        let child = root.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let store = StorageBrowserStore()
        store.open(root, exclusions: [])
        for _ in 0..<200 where !store.canNavigate { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.entries.map(\.url.path), [child.path])
        store.open(child, exclusions: [])
        for _ in 0..<200 where !store.canNavigate { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.current, child)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.listingIndex.matching("", largestFirst: true).isEmpty)
        store.back(exclusions: [])
        for _ in 0..<200 where !store.canNavigate { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.current, root)
        XCTAssertEqual(store.trail.count, 1)
    }

    @MainActor
    func testTimeoutKeepsWorkerGateAndRejectsLateListing() async throws {
        let gate = StorageReadGate()
        defer { gate.release() }
        let store = StorageBrowserStore(timeout: .milliseconds(50), read: { _, _ in
            gate.block(); return StorageDirectoryReport(entries: [], partial: false, skipped: 0)
        })
        store.open(URL(fileURLWithPath: "/fixture"), exclusions: [])
        for _ in 0..<200 where !store.waiting { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.waiting)
        XCTAssertTrue(store.summary.contains("timed out"))
        store.open(URL(fileURLWithPath: "/other"), exclusions: [])
        XCTAssertEqual(gate.calls, 1)
        XCTAssertEqual(store.current?.path, "/fixture")
        gate.release()
        for _ in 0..<200 where !store.canNavigate { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.canNavigate)
        XCTAssertTrue(store.summary.contains("stopped"))
    }

    @MainActor
    func testChangingExclusionsClearsCachedAndInFlightResults() async throws {
        let gate = StorageReadGate()
        defer { gate.release() }
        let row = StorageEntry(url: URL(fileURLWithPath: "/fixture/item"), kind: .file, logicalBytes: 1, allocatedBytes: 512)
        let store = StorageBrowserStore(read: { url, _ in
            if url.lastPathComponent == "blocked" { gate.block() }
            return StorageDirectoryReport(entries: [row], partial: false, skipped: 0)
        })
        store.open(URL(fileURLWithPath: "/fixture"), exclusions: [])
        for _ in 0..<200 where !store.canNavigate { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.entries.count, 1)
        store.exclusionsChanged()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.listingIndex.matching("", largestFirst: true).isEmpty)
        store.open(URL(fileURLWithPath: "/blocked"), exclusions: [])
        for _ in 0..<200 where gate.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        store.exclusionsChanged()
        XCTAssertTrue(store.waiting)
        gate.release()
        for _ in 0..<200 where !store.canNavigate { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.canNavigate)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.listingIndex.matching("", largestFirst: true).isEmpty)
    }

    @MainActor
    func testSearchAcceptsLatestQueryAndClearsOnExclusions() async throws {
        let rows = ["Alpha", "Beta"].map {
            StorageEntry(url: URL(fileURLWithPath: "/fixture/" + $0), kind: .file, logicalBytes: 1, allocatedBytes: 512)
        }
        let store = StorageBrowserStore(read: { _, _ in
            StorageDirectoryReport(entries: rows, partial: false, skipped: 0)
        })
        store.open(URL(fileURLWithPath: "/fixture"), exclusions: [])
        for _ in 0..<200 where !store.canNavigate || store.searching { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.matches.count, 2)
        store.search("Alpha", largestFirst: true)
        store.search("BETA", largestFirst: false)
        XCTAssertTrue(store.searching)
        XCTAssertTrue(store.matches.isEmpty)
        XCTAssertTrue(store.sizeMap.items.isEmpty)
        for _ in 0..<200 where store.searching { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.matches.map(\.url.lastPathComponent), ["Beta"])
        store.search("Alpha", largestFirst: true)
        store.exclusionsChanged()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(store.searching)
        XCTAssertTrue(store.matches.isEmpty)
        XCTAssertTrue(store.sizeMap.items.isEmpty)
    }

    @MainActor
    func testLateSearchCannotReplaceNewQueryOrNewFolder() async throws {
        let gate = StorageReadGate()
        defer { gate.release() }
        let stale = StorageEntry(url: URL(fileURLWithPath: "/old/stale"), kind: .file, logicalBytes: 1, allocatedBytes: 512)
        let store = StorageBrowserStore(match: { index, query, order in
            if query == "blocked" { gate.block(); return [stale] }
            return index.matching(query, largestFirst: order)
        }, read: { url, _ in
            StorageDirectoryReport(entries: [StorageEntry(url: url.appendingPathComponent("fresh"), kind: .file, logicalBytes: 1, allocatedBytes: 512)], partial: false, skipped: 0)
        })
        store.search("blocked", largestFirst: true, debounce: false)
        for _ in 0..<200 where gate.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gate.calls, 1)
        store.search("fresh", largestFirst: false, debounce: false)
        store.open(URL(fileURLWithPath: "/new"), exclusions: [])
        for _ in 0..<200 where !store.canNavigate || store.searching { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.matches.map(\.url.path), ["/new/fresh"])
        XCTAssertEqual(store.sizeMap.items.map(\.entry?.url.path), ["/new/fresh"])
        gate.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.matches.map(\.url.path), ["/new/fresh"])
        XCTAssertEqual(store.sizeMap.items.map(\.entry?.url.path), ["/new/fresh"])
    }

    @MainActor
    func testSearchCancellationCannotRepopulateDismissedListing() async throws {
        let store = StorageBrowserStore()
        store.search("anything", largestFirst: true)
        XCTAssertTrue(store.searching)
        store.cancel()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(store.searching)
        XCTAssertTrue(store.matches.isEmpty)
        XCTAssertTrue(store.sizeMap.items.isEmpty)
    }

    @MainActor
    func testFolderMeasurementUpdatesSizeMap() async throws {
        let root = try fixture()
        let child = root.appendingPathComponent("Measured child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: child.appendingPathComponent("file"))
        let store = StorageBrowserStore()
        store.open(root, exclusions: [])
        for _ in 0..<200 where !store.canNavigate || store.searching { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.sizeMap.unknown, 1)
        XCTAssertTrue(store.sizeMap.items.isEmpty)
        store.measure(child, exclusions: [])
        for _ in 0..<200 where !store.canNavigate || store.searching { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.sizeMap.unknown, 0)
        XCTAssertEqual(store.sizeMap.items.first?.entry?.url.path, child.path)
        XCTAssertGreaterThan(store.sizeMap.items.first?.bytes ?? 0, 0)
        store.measure(child, exclusions: [])
        XCTAssertTrue(store.sizeMap.items.isEmpty, "A fresh measurement must not display the old map value")
        for _ in 0..<200 where !store.canNavigate || store.searching { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.sizeMap.items.first?.entry?.url.path, child.path)
        store.exclusionsChanged()
        XCTAssertTrue(store.sizeMap.items.isEmpty)
    }

    @MainActor
    func testExplorerFixtureLayout() async throws {
        let root = try fixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Project files"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 65_536).write(to: root.appendingPathComponent("Example.txt"))
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let store = StorageBrowserStore()
        store.open(root, exclusions: [])
        for _ in 0..<200 where !store.canNavigate { try await Task.sleep(for: .milliseconds(5)) }
        store.measure(root, exclusions: [])
        for _ in 0..<200 where !store.canNavigate { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.measurements[root.path]?.logicalBytes, 65_536)
        let host = NSHostingView(rootView: StorageBrowserView(root: root, model: AppModel(), store: store))
        window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.bounds.height, 540)
        if let folder = ProcessInfo.processInfo.environment["MACSWEEP_PREVIEW_DIR"] {
            let output = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), output.appendingPathComponent("storage-browser.png").path]
            try capture.run(); capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
    }
}

private final class StorageReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false
    private var count = 0
    var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
    func block() { condition.lock(); defer { condition.unlock() }; count += 1; while !opened { condition.wait() } }
    func release() { condition.lock(); defer { condition.unlock() }; opened = true; condition.broadcast() }
}
