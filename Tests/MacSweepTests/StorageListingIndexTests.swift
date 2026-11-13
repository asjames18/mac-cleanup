import Foundation
import XCTest
@testable import MacSweep

final class StorageListingIndexTests: XCTestCase {
    private func entry(_ name: String, bytes: Int64, kind: StorageEntry.Kind = .file) -> StorageEntry {
        StorageEntry(url: URL(fileURLWithPath: "/fixture/" + name), kind: kind, logicalBytes: bytes, allocatedBytes: bytes)
    }
    func testNaturalOrderingFileSizeAndSearchAreCachedConsistently() {
        let rows = [entry("file10", bytes: 100), entry("file2", bytes: 20), entry("Folder", bytes: 0, kind: .folder), entry("Café", bytes: 100)]
        let index = StorageListingIndex(entries: rows)
        XCTAssertEqual(index.matching("", largestFirst: false).map(\.url.lastPathComponent), ["Folder", "Café", "file2", "file10"])
        XCTAssertEqual(index.matching("", largestFirst: true).map(\.url.lastPathComponent), ["Folder", "Café", "file10", "file2"])
        XCTAssertEqual(index.matching("CAFE", largestFirst: true).map(\.url.lastPathComponent), ["Café"])
        XCTAssertEqual(index.matching("FILE", largestFirst: false).map(\.url.lastPathComponent), ["file2", "file10"])
        XCTAssertTrue(StorageListingIndex.empty.matching("", largestFirst: true).isEmpty)
    }

    func testOptIn25000EntryRenderPreparationComparison() throws {
        guard ProcessInfo.processInfo.environment["MACSWEEP_INDEX_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in generated in-memory render-path diagnostic")
        }
        let rows = (0..<25_000).reversed().map { entry("file-\($0).dat", bytes: Int64(($0 * 7919) % 4096)) }
        let clock = ContinuousClock()
        var oldDurations: [Double] = []
        var expected: [String] = []
        for _ in 0..<3 {
            let start = clock.now
            let ordered = rows.sorted {
                if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            oldDurations.append(seconds(start.duration(to: clock.now)))
            expected = ordered.map(\.id)
        }
        let buildStart = clock.now
        let index = StorageListingIndex(entries: rows)
        let prepare = seconds(buildStart.duration(to: clock.now))
        var cachedDurations: [Double] = []
        for _ in 0..<3 {
            let start = clock.now
            let result = index.matching("", largestFirst: true)
            cachedDurations.append(seconds(start.duration(to: clock.now)))
            XCTAssertEqual(result.map(\.id), expected)
        }
        print("STORAGE_INDEX_DIAGNOSTIC entries=25000 old_redraw_seconds=\(oldDurations) background_prepare_seconds=\(prepare) cached_redraw_seconds=\(cachedDurations)")
        let start = clock.now
        let found = index.matching("FILE-123", largestFirst: true)
        print("STORAGE_INDEX_DIAGNOSTIC search_seconds=\(seconds(start.duration(to: clock.now))) matches=\(found.count)")
        XCTAssertEqual(Set(found.map(\.id)), Set(rows.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains("FILE-123") }.map(\.id)))
    }
    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
