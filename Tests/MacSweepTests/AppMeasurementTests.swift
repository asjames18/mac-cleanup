import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

final class AppMeasurementTests: XCTestCase {
    private func fixture() throws -> InstalledApp {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: app.appendingPathComponent("payload"))
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("link"), withDestinationURL: app.appendingPathComponent("payload"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return InstalledApp(id: app.path, url: app, name: "Example", bundleIdentifier: "org.example.fixture", version: "1", size: 0,
                            snapshot: try FileSnapshotReader.capture(app), sizeIsKnown: false)
    }

    @MainActor
    func testMeasuresSelectedAppAndClearsAfterExclusionsChange() async throws {
        let app = try fixture()
        let model = AppModel()
        model.installedApps = [app]; model.selectApp(app)
        model.measureSelectedApp()
        for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let size = try XCTUnwrap(model.appMeasurements[app.id])
        XCTAssertEqual(size.logicalBytes, 8192)
        XCTAssertEqual(size.files, 1)
        XCTAssertTrue(size.partial, "Internal links are skipped rather than followed")
        XCTAssertTrue(model.scanSummary.contains("Partial"))
        model.addExclusions([app.url])
        XCTAssertTrue(model.appMeasurements.isEmpty)
    }

    @MainActor
    func testChangedAppRequiresFreshInventory() async throws {
        let app = try fixture()
        try Data("new".utf8).write(to: app.url.appendingPathComponent("new file"))
        let model = AppModel()
        model.installedApps = [app]; model.selectApp(app)
        model.measureSelectedApp()
        for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.appMeasurements.isEmpty)
        XCTAssertTrue(model.scanSummary.contains("scan again"))
    }

    @MainActor
    func testMetadataChangesBeforeOrDuringMeasurementRequireRescan() async throws {
        for changeDuringMeasurement in [false, true] {
            var app = try fixture()
            let contents = app.url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
            let metadata = contents.appendingPathComponent("Info.plist")
            try Data("original metadata".utf8).write(to: metadata)
            app.snapshot = try FileSnapshotReader.capture(app.url)
            app.metadataSnapshot = try FileSnapshotReader.capture(metadata)
            if !changeDuringMeasurement { try Data("updated metadata".utf8).write(to: metadata) }
            XCTAssertEqual(FileSnapshotReader.validate(expected: try XCTUnwrap(app.snapshot), at: app.url), .unchanged)
            let model = AppModel(appMeasurement: { _, _ in
                if changeDuringMeasurement { try Data("updated metadata".utf8).write(to: metadata) }
                return StorageMeasurement(logicalBytes: 1, allocatedBytes: 1, files: 1, folders: 1, skipped: 0, partial: false)
            })
            model.installedApps = [app]; model.selectApp(app)
            model.measureSelectedApp()
            for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(model.appMeasurements.isEmpty)
            XCTAssertTrue(model.scanSummary.contains("scan again"))
        }
    }

    @MainActor
    func testCancellationAndTimeoutGateOtherJobsAndRejectLateSize() async throws {
        for explicitCancel in [true, false] {
            let app = try fixture()
            let gate = AppMeasurementGate()
            defer { gate.release() }
            let model = AppModel(scanTimeout: explicitCancel ? nil : .milliseconds(50), appMeasurement: { _, _ in
                gate.block()
                return StorageMeasurement(logicalBytes: 1, allocatedBytes: 1, files: 1, folders: 1, skipped: 0, partial: false)
            })
            model.installedApps = [app]; model.selectApp(app)
            model.measureSelectedApp()
            for _ in 0..<200 where gate.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(gate.calls, 1)
            if explicitCancel { model.cancelScan() }
            else {
                for _ in 0..<200 where !model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(model.scanSummary.contains("timed out"))
            }
            XCTAssertTrue(model.waitingForFilesystem)
            model.scanInstalledApps()
            XCTAssertEqual(model.installedApps.map(\.id), [app.id])
            gate.release()
            for _ in 0..<200 where model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.waitingForFilesystem)
            XCTAssertTrue(model.appMeasurements.isEmpty)
        }
    }
}

private final class AppMeasurementGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false
    private var count = 0
    var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
    func block() { condition.lock(); defer { condition.unlock() }; count += 1; while !opened { condition.wait() } }
    func release() { condition.lock(); defer { condition.unlock() }; opened = true; condition.broadcast() }
}
