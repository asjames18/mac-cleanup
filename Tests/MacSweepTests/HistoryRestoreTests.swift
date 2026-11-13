import AppKit
import Darwin
import SwiftUI
import XCTest
import MacSweepCore
@testable import MacSweep

final class HistoryRestoreTests: XCTestCase {
    @MainActor
    func testFixtureHistoryShowsRecoveryStatesAndReviewDoesNotMove() async throws {
        let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("SimulatedTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let journal = CleanupJournal(directory: root.appendingPathComponent("History"))
        var ids: [UUID] = []
        for name in ["Available.txt", "Conflict.txt", "Missing.txt", "Legacy.txt"] {
            let item = trash.appendingPathComponent(name)
            let original = root.appendingPathComponent(name)
            if name != "Legacy.txt" { try Data("fixture contents".utf8).write(to: original) }
            let id = try journal.recordIntent(source: root.appendingPathComponent(name))
            if name != "Legacy.txt" { try FileManager.default.moveItem(at: original, to: item) }
            try journal.recordOutcome(id: id, destination: item, failure: nil)
            ids.append(id)
        }
        try Data("preserve this".utf8).write(to: root.appendingPathComponent("Conflict.txt"))
        try FileManager.default.removeItem(at: trash.appendingPathComponent("Missing.txt"))
        let store = HistoryStore(journal: journal)
        await store.refresh()
        XCTAssertEqual(store.rows.count, 4)
        XCTAssertTrue(try XCTUnwrap(store.rows.first(where: { $0.id == ids[0] })).canRestore)
        XCTAssertEqual(store.rows.first(where: { $0.id == ids[1] })?.unavailable, .conflict)
        XCTAssertEqual(store.rows.first(where: { $0.id == ids[2] })?.unavailable, .missingTrash)
        XCTAssertEqual(store.rows.first(where: { $0.id == ids[3] })?.unavailable, .legacyRecord)
        let missingLocation = await store.finderLocation(for: trash.appendingPathComponent("Missing.txt"))
        XCTAssertEqual(missingLocation?.url.path, trash.path)
        XCTAssertEqual(missingLocation?.openFolder, true)
        let absentLocation = await store.finderLocation(for: root.appendingPathComponent("absent/item"))
        XCTAssertNil(absentLocation)
        await store.review(id: ids[0])
        XCTAssertNotNil(store.reviewedPlan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Available.txt").path))
        store.cancelReview()
        XCTAssertNil(store.reviewedPlan)

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 850),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: HistoryView(store: store))
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.bounds.height, 700)
        if let folder = ProcessInfo.processInfo.environment["MACSWEEP_PREVIEW_DIR"] {
            let output = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), output.appendingPathComponent("history-fixtures.png").path]
            try capture.run(); capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
        await store.review(id: ids[0])
        let collision = root.appendingPathComponent("Available.txt")
        try Data("new occupant".utf8).write(to: collision)
        await store.confirmRestore()
        XCTAssertNotNil(store.error, "Automatic refresh must retain the restore failure")
        XCTAssertEqual(try Data(contentsOf: collision), Data("new occupant".utf8))
        try FileManager.default.removeItem(at: collision)
        await store.refresh()
        XCTAssertNil(store.error, "Successful manual refresh clears the stale failure")
        await store.review(id: ids[0])
        await store.confirmRestore()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Available.txt")), Data("fixture contents".utf8))
        XCTAssertEqual(store.rows.first(where: { $0.id == ids[0] })?.entry.restore?.state, .restored)
    }
    @MainActor
    func testOlderPagesUseOneCoherentListingAndRefreshResetsIt() async throws {
        let source = URL(fileURLWithPath: "/generated-fixture-history/item")
        let data = try JSONSerialization.data(withJSONObject: (0..<401).map { index in
            ["id": UUID().uuidString, "date": Double(401 - index),
             "source": source.absoluteString, "state": "moved"] as [String: Any]
        })
        let entries = try JSONDecoder().decode([CleanupJournalEntry].self, from: data)
        let listing = HistoryListingFixture(entries: entries)
        let journal = CleanupJournal(directory: URL(fileURLWithPath: "/unused-injected-history"))
        let store = HistoryStore(journal: journal, loadEntries: { listing.read() })
        await store.refresh()
        XCTAssertEqual(store.rows.map(\.id), Array(entries.prefix(200)).map(\.id))
        XCTAssertTrue(store.hasOlderEntries)
        // A changed backing listing must not splice different generations together
        // as the user pages through their current snapshot.
        listing.replace(with: [])
        await store.loadOlder()
        XCTAssertEqual(store.rows.map(\.id), Array(entries.prefix(400)).map(\.id))
        await store.loadOlder()
        XCTAssertEqual(store.rows.map(\.id), entries.map(\.id))
        XCTAssertFalse(store.hasOlderEntries)
        await store.loadOlder()
        XCTAssertEqual(listing.readCount, 1, "Paging must never reload the full journal")
        await store.refresh()
        XCTAssertEqual(listing.readCount, 2)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.totalCount, 0)
        XCTAssertFalse(store.hasOlderEntries)
    }

}

private final class HistoryListingFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CleanupJournalEntry]
    private var count = 0
    init(entries: [CleanupJournalEntry]) { self.entries = entries }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func read() -> [CleanupJournalEntry] { lock.lock(); defer { lock.unlock() }; count += 1; return entries }
    func replace(with entries: [CleanupJournalEntry]) { lock.lock(); defer { lock.unlock() }; self.entries = entries }
}
