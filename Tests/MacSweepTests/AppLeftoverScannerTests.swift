import Foundation
import Darwin
import XCTest
@testable import MacSweep

final class AppLeftoverScannerTests: XCTestCase {
    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [AppLeftoverUpdate] = []
        func append(_ value: AppLeftoverUpdate) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [AppLeftoverUpdate] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func fixture() throws -> URL {
        let url = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory)
            .appendingPathComponent("macsweep-leftovers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var app: InstalledApp {
        InstalledApp(id: "fixture", url: URL(fileURLWithPath: "/Applications/Fixture App.app"), name: "Fixture App",
                     bundleIdentifier: "org.example.fixture", version: nil, size: 0)
    }

    func testSuccessfulCandidateHasMeasuredSizeAndStreamsIncrementally() throws {
        let root = try fixture()
        let candidate = root.appendingPathComponent("org.example.fixture")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: candidate.appendingPathComponent("data"))
        let updates = Updates()

        let report = AppScanner.scanLeftoversReport(for: app, home: root,
            roots: [AppLeftoverRoot(location: "Fixture", url: root)], limit: ScanLimit(seconds: 10, entries: 100),
            progress: { updates.append($0) })

        XCTAssertEqual(report.items.count, 1)
        XCTAssertTrue(report.items[0].sizeIsKnown)
        XCTAssertTrue(report.items[0].canSelect)
        XCTAssertGreaterThan(report.items[0].size, 0)
        XCTAssertTrue(report.coverageComplete)
        XCTAssertTrue(updates.values.contains { $0.items.count == 1 })
    }

    func testSharedEntryBudgetMakesInterruptedFolderMeasurementUnavailable() throws {
        let root = try fixture()
        let candidate = root.appendingPathComponent("org.example.fixture")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try Data([1]).write(to: candidate.appendingPathComponent("one"))
        try Data([2]).write(to: candidate.appendingPathComponent("two"))

        let report = AppScanner.scanLeftoversReport(for: app, home: root,
            roots: [AppLeftoverRoot(location: "Fixture", url: root)], limit: ScanLimit(seconds: 10, entries: 2))

        XCTAssertEqual(report.items.count, 1)
        XCTAssertFalse(report.items[0].sizeIsKnown)
        XCTAssertFalse(report.items[0].canSelect)
        XCTAssertTrue(report.items[0].blockedReason?.contains("incomplete") == true)
        XCTAssertFalse(report.coverageComplete)
        XCTAssertTrue(report.messages.contains { $0.contains("limit") && $0.contains("partial coverage") })
    }

    func testMissingAndUnreadableRootsAreExplicit() throws {
        let root = try fixture()
        let denied = root.appendingPathComponent("Denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }

        let report = AppScanner.scanLeftoversReport(for: app, home: root, roots: [
            AppLeftoverRoot(location: "Denied", url: denied),
            AppLeftoverRoot(location: "Missing", url: root.appendingPathComponent("Missing"))
        ], limit: ScanLimit(seconds: 10, entries: 100))

        XCTAssertFalse(report.coverageComplete)
        XCTAssertEqual(report.readErrorCount, 2)
        XCTAssertTrue(report.messages.contains { $0.contains("Denied") })
        XCTAssertTrue(report.messages.contains { $0.contains("Missing") })
    }

    func testNestedSymlinkIsExcludedFromMeasurement() throws {
        let root = try fixture()
        let outside = try fixture()
        try Data(repeating: 7, count: 4096).write(to: outside.appendingPathComponent("large"))
        let candidate = root.appendingPathComponent("org.example.fixture")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try Data([1]).write(to: candidate.appendingPathComponent("local"))
        try FileManager.default.createSymbolicLink(at: candidate.appendingPathComponent("linked"), withDestinationURL: outside)

        let report = AppScanner.scanLeftoversReport(for: app, home: root,
            roots: [AppLeftoverRoot(location: "Fixture", url: root)], limit: ScanLimit(seconds: 10, entries: 100))

        XCTAssertEqual(report.items.count, 1)
        XCTAssertFalse(report.items[0].sizeIsKnown)
        XCTAssertFalse(report.items[0].canSelect)
        XCTAssertTrue(report.messages.contains { $0.contains("symbolic link") })
    }

    func testSpecialFileMakesCandidateUnavailable() throws {
        let root = try fixture()
        let candidate = root.appendingPathComponent("org.example.fixture")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(candidate.appendingPathComponent("pipe").path, 0o600), 0)

        let report = AppScanner.scanLeftoversReport(for: app, home: root,
            roots: [AppLeftoverRoot(location: "Fixture", url: root)], limit: ScanLimit(seconds: 10, entries: 100))

        XCTAssertFalse(try XCTUnwrap(report.items.first).canSelect)
        XCTAssertFalse(report.coverageComplete)
    }

    func testFileUnreadableByOwnerMakesCandidateUnavailable() throws {
        let root = try fixture()
        let candidate = root.appendingPathComponent("org.example.fixture")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let denied = candidate.appendingPathComponent("denied")
        try Data([1]).write(to: denied)
        try FileManager.default.setAttributes([.posixPermissions: 0o004], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path) }

        let report = AppScanner.scanLeftoversReport(for: app, home: root,
            roots: [AppLeftoverRoot(location: "Fixture", url: root)], limit: ScanLimit(seconds: 10, entries: 100))

        XCTAssertFalse(try XCTUnwrap(report.items.first).canSelect)
        XCTAssertFalse(report.coverageComplete)
    }

    func testAlreadyCancelledScanReturnsPartialCoverage() async throws {
        let root = try fixture()
        let fixtureApp = app
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return AppScanner.scanLeftoversReport(for: fixtureApp, home: root,
                roots: [AppLeftoverRoot(location: "Fixture", url: root)], limit: .quick)
        }
        let report = await task.value
        XCTAssertFalse(report.coverageComplete)
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.messages.contains { $0.contains("Cancelled") && $0.contains("partial coverage") })
    }
}
