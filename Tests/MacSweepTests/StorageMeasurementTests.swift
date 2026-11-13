import Darwin
import Foundation
import XCTest
@testable import MacSweep

final class StorageMeasurementTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testTotalsCountHardLinkedFilesOnceAcrossFolders() throws {
        let root = try fixture()
        let child = root.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Original")
        try Data(repeating: 7, count: 4096).write(to: original)
        try FileManager.default.linkItem(at: original, to: child.appendingPathComponent("HardLink"))
        try Data(repeating: 1, count: 100).write(to: child.appendingPathComponent("Other"))
        let result = try StorageFolderMeasurer.measure(root)
        XCTAssertEqual(result.files, 2)
        XCTAssertEqual(result.logicalBytes, 4196)
        XCTAssertEqual(result.folders, 1)
        XCTAssertGreaterThan(result.allocatedBytes, 0)
        XCTAssertFalse(result.partial)
    }
    func testExcludedAndLinkedContentNeverInflatesTotals() throws {
        let root = try fixture()
        let excluded = root.appendingPathComponent("Excluded")
        try Data(repeating: 1, count: 4096).write(to: excluded)
        try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("Included"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: root)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("Pipe").path, 0o600), 0)
        let result = try StorageFolderMeasurer.measure(root, exclusions: [excluded])
        XCTAssertEqual(result.logicalBytes, 100)
        XCTAssertEqual(result.files, 1)
        XCTAssertEqual(result.skipped, 3)
        XCTAssertTrue(result.partial)
        XCTAssertThrowsError(try StorageFolderMeasurer.measure(root, exclusions: [root]))
    }
    func testBudgetAndUnreadableFolderReportPartial() throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("Denied")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: folder.appendingPathComponent("file"))
        XCTAssertTrue(try StorageFolderMeasurer.measure(root, limit: ScanLimit(seconds: 5, entries: 1)).partial)
        guard geteuid() != 0 else { return }
        XCTAssertEqual(chmod(folder.path, 0), 0)
        defer { chmod(folder.path, 0o700) }
        let result = try StorageFolderMeasurer.measure(root)
        XCTAssertTrue(result.partial)
        XCTAssertEqual(result.files, 0)
        XCTAssertEqual(result.skipped, 1)
    }
    @MainActor
    func testMeasurementPublishesInExplorerAndExclusionChangeClearsIt() async throws {
        let root = try fixture()
        try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("file"))
        let store = StorageBrowserStore()
        store.measure(root, exclusions: [])
        for _ in 0..<200 where !store.canNavigate { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.canNavigate)
        XCTAssertEqual(store.measurements[root.path]?.logicalBytes, 100)
        store.exclusionsChanged()
        XCTAssertTrue(store.measurements.isEmpty)
    }
}
