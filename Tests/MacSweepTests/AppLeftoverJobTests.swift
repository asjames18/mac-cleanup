import Foundation
import XCTest
@testable import MacSweep

final class AppLeftoverJobTests: XCTestCase {
    private let app = InstalledApp(id: "fixture", url: URL(fileURLWithPath: "/Applications/Fixture.app"), name: "Fixture",
                                   bundleIdentifier: "org.example.fixture", version: nil, size: 0)

    @MainActor
    func testProgressSurvivesCancellationAndIsMarkedPartial() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let item = AppLeftoverItem(id: "item", url: URL(fileURLWithPath: "/fixture/item"), location: "Caches", size: 4,
                                   reason: "Fixture", isSelected: false)
        let model = AppModel(leftoverScan: { _, progress in
            progress(AppLeftoverUpdate(items: [item], detail: "Found item", examined: 1, elapsed: 0.01))
            gate.wait()
            return AppLeftoverReport(items: [], messages: ["late"], coverageComplete: true, cancelled: false,
                                     examined: 1, readErrorCount: 0, skippedSymlinkCount: 0)
        })
        model.installedApps = [app]
        model.selectedAppID = app.id

        model.scanSelectedAppLeftovers()
        for _ in 0..<200 where model.appLeftovers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        model.cancelScan()

        XCTAssertEqual(model.appLeftovers.map(\.id), ["item"])
        XCTAssertTrue(model.appLeftoverScanPerformed)
        XCTAssertTrue(model.appLeftoverCoverage.contains("partial"))
        gate.signal()
        for _ in 0..<200 where model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.appLeftovers.map(\.id), ["item"])
    }

    @MainActor
    func testCompletedEmptyReportIsDistinguishedFromNotScanned() async throws {
        let model = AppModel(leftoverScan: { _, _ in
            AppLeftoverReport(items: [], messages: ["Finished accessible related-file locations."], coverageComplete: true,
                              cancelled: false, examined: 0, readErrorCount: 0, skippedSymlinkCount: 0)
        })
        model.installedApps = [app]
        model.selectedAppID = app.id
        XCTAssertFalse(model.appLeftoverScanPerformed)

        model.scanSelectedAppLeftovers()
        for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertTrue(model.appLeftoverScanPerformed)
        XCTAssertTrue(model.appLeftovers.isEmpty)
        XCTAssertTrue(model.appLeftoverCoverage.contains("Finished"))
    }
}
