import AppKit
import SwiftUI
import XCTest
@testable import MacSweep

final class StorageMapTests: XCTestCase {
    private func entry(_ name: String, _ kind: StorageEntry.Kind = .file, bytes: Int64 = 512) -> StorageEntry {
        StorageEntry(url: URL(fileURLWithPath: "/fixture/" + name), kind: kind, logicalBytes: bytes, allocatedBytes: bytes)
    }
    @MainActor
    func testSizeMapFixtureLayout() async throws {
        let rows = [entry("Project archives", .folder), entry("Movie.mov", bytes: 3_000_000), entry("Photos", .folder), entry("Notes.pdf", bytes: 100_000), entry("Unmeasured folder", .folder)]
        let map = StorageMap.prepare(rows, measurements: [
            "/fixture/Project archives": StorageMeasurement(logicalBytes: 7_000_000, allocatedBytes: 7_000_000, files: 20, folders: 1, skipped: 0, partial: false),
            "/fixture/Photos": StorageMeasurement(logicalBytes: 1_500_000, allocatedBytes: 1_500_000, files: 5, folders: 1, skipped: 1, partial: true)
        ])
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: StorageTreemapView(map: map, canNavigate: true, onOpen: { _ in }, onShowList: {}).padding(20))
        window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.bounds.height, 480)
        if let folder = ProcessInfo.processInfo.environment["MACSWEEP_PREVIEW_DIR"] {
            let output = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), output.appendingPathComponent("storage-map.png").path]
            try capture.run(); capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
    }

    func testUnknownAndPartialFoldersAreNotPresentedAsEmpty() {
        let measured = StorageMeasurement(logicalBytes: 20, allocatedBytes: 20, files: 1, folders: 1, skipped: 1, partial: true)
        let emptyPartial = StorageMeasurement(logicalBytes: 0, allocatedBytes: 0, files: 0, folders: 1, skipped: 1, partial: true)
        let map = StorageMap.prepare([entry("unknown", .folder), entry("partial", .folder), entry("unreadable", .folder), entry("zero", bytes: 0), entry("link", .link)], measurements: ["/fixture/partial": measured, "/fixture/unreadable": emptyPartial])
        XCTAssertEqual(map.unknown, 3)
        XCTAssertEqual(map.zero, 1)
        XCTAssertEqual(map.items.count, 1)
        XCTAssertTrue(map.items[0].partial)
        XCTAssertEqual(map.items[0].bytes, 20)
    }
    func testGroupingPreservesAllPositiveRecordedSizes() {
        let map = StorageMap.prepare((1...30).map { entry("file-\($0)", bytes: Int64($0)) }, measurements: [:])
        XCTAssertEqual(map.items.count, 13)
        XCTAssertEqual(map.items.reduce(0) { $0 + $1.bytes }, 465)
        XCTAssertEqual(map.items.reduce(0) { $0 + $1.count }, 30)
        XCTAssertNil(map.items.last?.entry)
        XCTAssertEqual(map.items.last?.count, 18)
    }
    func testTilesPreserveAreaAndProportionsWithoutOverlap() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 320)
        let weights: [Double] = [90, 30, 10, 5, 1]
        let tiles = StorageMapLayout.tiles(weights: weights, in: bounds)
        XCTAssertEqual(tiles.count, weights.count)
        for tile in tiles {
            XCTAssertTrue(bounds.contains(tile.rect))
            XCTAssertEqual(tile.rect.width * tile.rect.height / (bounds.width * bounds.height), weights[tile.index] / 136, accuracy: 0.000001)
            for other in tiles where other.index != tile.index {
                let overlap = tile.rect.intersection(other.rect)
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.000001)
            }
        }
        XCTAssertTrue(StorageMapLayout.tiles(weights: [0, -1, .infinity, .nan], in: bounds).isEmpty)
        XCTAssertEqual(StorageMapLayout.tiles(weights: [.greatestFiniteMagnitude, .greatestFiniteMagnitude], in: bounds).count, 2)
    }
}
