import Foundation
import XCTest
@testable import MacSweep

final class AppInventoryJobTests: XCTestCase {
    @MainActor
    func testInventoryProgressSurvivesCancellationWithoutLateOverwrite() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let app = InstalledApp(id: "fixture", url: URL(fileURLWithPath: "/fixture/Example.app"), name: "Example", bundleIdentifier: "org.example.fixture", version: "1", size: 0, sizeIsKnown: false)
        let model = AppModel(inventoryScan: { progress in
            progress(AppInventoryUpdate(apps: [app], detail: "Discovered Example"))
            gate.wait()
            return AppInventoryReport(apps: [], messages: ["late report"])
        })
        model.scanInstalledApps()
        for _ in 0..<200 where model.installedApps.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.installedApps.map(\.id), ["fixture"])
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.installedApps.first?.sizeDescription, "Not measured")
        model.cancelScan()
        XCTAssertTrue(model.waitingForFilesystem)
        model.scanInstalledApps()
        XCTAssertFalse(model.isBusy)
        gate.signal()
        for _ in 0..<200 where model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.waitingForFilesystem)
        XCTAssertEqual(model.installedApps.map(\.id), ["fixture"])
        XCTAssertNotEqual(model.logText, "late report")
    }

    @MainActor
    func testInventoryHasIndependentAccessTimeout() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let model = AppModel(scanTimeout: .milliseconds(30), inventoryScan: { _ in
            gate.wait()
            return AppInventoryReport(apps: [], messages: ["late report"])
        })
        model.scanInstalledApps()
        for _ in 0..<200 where !model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.waitingForFilesystem)
        XCTAssertTrue(model.scanSummary.contains("timed out"))
        gate.signal()
        for _ in 0..<200 where model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.waitingForFilesystem)
        XCTAssertNotEqual(model.logText, "late report")
    }
}
