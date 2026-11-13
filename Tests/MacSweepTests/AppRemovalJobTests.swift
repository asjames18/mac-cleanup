import Foundation
import XCTest
@testable import MacSweep

final class AppRemovalJobTests: XCTestCase {
    @MainActor
    func testCancelledBlockedPreflightNeverContinuesToConfirmation() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let model = AppModel(removalPreflight: { gate.wait() })
        let app = InstalledApp(id: "fixture", url: URL(fileURLWithPath: "/fixture/Example.app"), name: "Fixture", bundleIdentifier: "org.example.fixture", version: nil, size: 0)
        model.installedApps = [app]
        model.selectedAppID = app.id
        model.uninstallSelectedApp()
        XCTAssertTrue(model.isBusy)
        // Returning to this actor while the worker is blocked establishes responsiveness.
        try await Task.sleep(for: .milliseconds(20))
        model.cancelScan()
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.waitingForFilesystem)
        gate.signal()
        for _ in 0..<200 where model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.waitingForFilesystem)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.installedApps.map(\.id), [app.id])
        XCTAssertTrue(model.logText.contains("cancelled"))
    }

    @MainActor
    func testTimedOutPreflightDiscardsLateResult() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let model = AppModel(scanTimeout: .milliseconds(20), removalPreflight: { gate.wait() })
        let app = InstalledApp(id: "fixture", url: URL(fileURLWithPath: "/fixture/Example.app"), name: "Fixture", bundleIdentifier: "org.example.fixture", version: nil, size: 0)
        model.installedApps = [app]
        model.selectedAppID = app.id
        model.uninstallSelectedApp()
        for _ in 0..<200 where !model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.waitingForFilesystem)
        XCTAssertFalse(model.isBusy)
        gate.signal()
        for _ in 0..<200 where model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.waitingForFilesystem)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.installedApps.map(\.id), [app.id])
    }
}
