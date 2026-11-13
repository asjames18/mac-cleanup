import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

final class LeftoverEligibilityTests: XCTestCase {
    func testManagedContainersExplainRestriction() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in ["Library/Containers/com.apple.Chess", "Library/Group Containers/group.fixture"] {
            XCTAssertNotNil(AppScanner.leftoverRestriction(home.appendingPathComponent(path)))
        }
        XCTAssertNil(AppScanner.leftoverRestriction(home.appendingPathComponent("Library/Caches/org.example.app")))
        XCTAssertNil(AppScanner.leftoverRestriction(home.appendingPathComponent("Library/Preferences/org.example.app.plist")))
    }

    @MainActor
    func testBulkSelectionAndStaleSelectedFlagsExcludeUnavailableItems() throws {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try Data("fixture".utf8).write(to: cache)
        let model = AppModel()
        let blocked = AppLeftoverItem(id: "blocked", url: URL(fileURLWithPath: "/fixture/container"), location: "Containers", size: 100,
            reason: "Fixture", isSelected: true, blockedReason: "Managed container")
        let allowed = AppLeftoverItem(id: "allowed", url: cache, location: "Caches", size: 10,
            reason: "Fixture", isSelected: false, snapshot: try FileSnapshotReader.capture(cache))
        model.appLeftovers = [blocked, allowed]
        XCTAssertTrue(model.selectedAppLeftovers.isEmpty)
        model.setLeftoverSelection(true)
        XCTAssertEqual(model.selectedAppLeftovers.map(\.id), ["allowed"])
        XCTAssertFalse(model.appLeftovers[0].isSelected)
        model.toggleLeftover(blocked)
        XCTAssertEqual(model.selectedAppLeftovers.map(\.id), ["allowed"])
    }
    func testBackendRejectsManagedContainerWithSpecificReason() {
        let container = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.apple.Chess")
        XCTAssertThrowsError(try CleanupSafety.validate(container, protectRecentFiles: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("macOS-managed app container"))
        }
    }

    func testReportedChessContainerWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MACSWEEP_CHECK_CHESS"] == "1" else { throw XCTSkip("Read-only check of the reported container.") }
        let app = InstalledApp(id: "chess", url: URL(fileURLWithPath: "/System/Applications/Chess.app"), name: "Chess", bundleIdentifier: "com.apple.Chess", version: nil, size: 0)
        let items = AppScanner.scanLeftovers(for: app)
        let container = try XCTUnwrap(items.first { $0.name == "com.apple.Chess" && $0.location == "Containers" })
        XCTAssertFalse(container.canSelect)
        XCTAssertNotNil(container.blockedReason)
        XCTAssertFalse(container.isSelected)
    }

}
