import Foundation
import Darwin
import XCTest
@testable import MacSweep

final class AppScannerTests: XCTestCase {
    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [AppInventoryUpdate] = []
        func append(_ update: AppInventoryUpdate) { lock.lock(); defer { lock.unlock() }; recorded.append(update) }
        var values: [AppInventoryUpdate] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory)
            .appendingPathComponent("macsweep-app-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func app(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Fixture App", "CFBundleIdentifier": "test.fixture", "CFBundleShortVersionString": "1.2"], format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    func testNestedInventoryPublishesMetadataAndSkipsHelpersPackagesAndLinks() throws {
        let root = try fixture()
        try app(root.appendingPathComponent("Utilities/Outer.app"))
        try app(root.appendingPathComponent("Utilities/Outer.app/Contents/Helper.app"))
        try app(root.appendingPathComponent("Archive.bundle/Hidden.app"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked.app"), withDestinationURL: root.appendingPathComponent("Utilities/Outer.app"))
        let outside = try fixture()
        try app(outside.appendingPathComponent("Outside.app"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("LinkedFolder"), withDestinationURL: outside)
        let updates = Updates()
        let result = AppScanner.inventory(roots: [root, root], progress: { updates.append($0) })
        XCTAssertEqual(result.apps.count, 1)
        XCTAssertEqual(result.apps.first?.name, "Fixture App")
        XCTAssertEqual(result.apps.first?.bundleIdentifier, "test.fixture")
        XCTAssertEqual(result.apps.first?.version, "1.2")
        XCTAssertEqual(result.apps.first?.size, 0)
        XCTAssertFalse(try XCTUnwrap(result.apps.first).sizeIsKnown)
        XCTAssertTrue(updates.values.contains { $0.apps.count == 1 && $0.detail.contains("Found") })
    }

    func testMissingRootAndUnreadableDirectoryAreReported() throws {
        let root = try fixture()
        let denied = root.appendingPathComponent("Denied")
        try app(denied.appendingPathComponent("Hidden.app"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        let result = AppScanner.inventory(roots: [root, root.appendingPathComponent("Missing")])
        XCTAssertTrue(result.apps.isEmpty)
        XCTAssertTrue(result.messages.contains { $0.contains("Denied") })
        XCTAssertTrue(result.messages.contains { $0.contains("Missing") })
        XCTAssertTrue(result.messages.contains { $0.contains("partial coverage") })
    }

    func testBudgetAndDepthReportPartialCoverage() throws {
        let root = try fixture()
        try app(root.appendingPathComponent("One/Two/Three/Four/Five/Deep.app"))
        let deep = AppScanner.inventory(roots: [root])
        XCTAssertTrue(deep.apps.isEmpty)
        XCTAssertTrue(deep.messages.contains { $0.contains("depth") })
        let limited = AppScanner.inventory(roots: [root], limit: ScanLimit(seconds: 10, entries: 1))
        XCTAssertTrue(limited.messages.contains { $0.contains("limit") && $0.contains("partial coverage") })
        let timeout = AppScanner.inventory(roots: [root], limit: ScanLimit(seconds: 0, entries: 100))
        XCTAssertTrue(timeout.apps.isEmpty)
        XCTAssertTrue(timeout.messages.contains { $0.contains("limit") })
    }

    func testCancelledTaskReportsPartialCoverage() async throws {
        let root = try fixture()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return AppScanner.inventory(roots: [root])
        }
        let result = await task.value
        XCTAssertTrue(result.apps.isEmpty)
        XCTAssertTrue(result.messages.contains { $0.contains("Cancelled") && $0.contains("partial coverage") })
    }

    func testSpecialAndOversizedMetadataFallBackWithoutBlocking() throws {
        let root = try fixture()
        let fifoApp = root.appendingPathComponent("FIFO.app")
        let largeApp = root.appendingPathComponent("Oversized.app")
        try app(fifoApp)
        try app(largeApp)
        let fifoPlist = fifoApp.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.removeItem(at: fifoPlist)
        XCTAssertEqual(mkfifo(fifoPlist.path, 0o600), 0)
        try Data(repeating: 65, count: 1_048_577).write(to: largeApp.appendingPathComponent("Contents/Info.plist"))
        let started = ProcessInfo.processInfo.systemUptime
        let result = AppScanner.inventory(roots: [root])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        XCTAssertEqual(Set(result.apps.map(\.name)), ["FIFO", "Oversized"])
        XCTAssertTrue(result.apps.allSatisfy { $0.bundleIdentifier == nil && !$0.sizeIsKnown })
        XCTAssertTrue(result.messages.contains { $0.contains("FIFO.app/Contents/Info.plist") })
        XCTAssertTrue(result.messages.contains { $0.contains("Oversized.app/Contents/Info.plist") })
        XCTAssertTrue(result.messages.contains { $0.contains("2 read errors") && $0.contains("partial coverage") })
    }

    func testRealInventoryWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["MACSWEEP_REAL_APPS"] == "1" else {
            throw XCTSkip("Opt-in read-only app inventory benchmark on the current Mac.")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let updates = Updates()
        let result = AppScanner.inventory(progress: { updates.append($0) })
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print("REAL_APP_INVENTORY seconds=\(elapsed) apps=\(result.apps.count) updates=\(updates.values.count)")
        print(result.messages.joined(separator: "\n"))
        XCTAssertLessThan(elapsed, 30)
        XCTAssertTrue(result.apps.allSatisfy { !$0.sizeIsKnown && $0.size == 0 })
    }
}
