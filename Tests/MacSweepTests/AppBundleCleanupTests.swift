import Foundation
import XCTest
import MacSweepCore
import Darwin
@testable import MacSweep

final class AppBundleCleanupTests: XCTestCase {
    /// Fixtures live in the temporary directory, so the sandbox stays on but is rooted there.
    override func invokeTest() {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory)
        TestSandbox.$policy.withValue(SandboxPolicy(enabled: true, root: root)) { super.invokeTest() }
    }

    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Example.app")
        let version = app.appendingPathComponent("Contents/Frameworks/Example.framework/Versions/A")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: version.appendingPathComponent("Example"))
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.fixture", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let framework = app.appendingPathComponent("Contents/Frameworks/Example.framework")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Example").path, withDestinationPath: "Versions/Current/Example")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return app
    }

    func testInternalFrameworkLinksAllowWholeBundleValidation() throws {
        let app = try fixture()
        XCTAssertNoThrow(try CleanupSafety.validate(app, protectRecentFiles: false))
    }

    func testExternalBundleLinkRemainsRejected() throws {
        let app = try fixture()
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("external").path, withDestinationPath: "/System")
        XCTAssertThrowsError(try CleanupSafety.validate(app, protectRecentFiles: false))
    }

    func testSelectedBundleSymlinkRemainsRejected() throws {
        let app = try fixture()
        let link = app.deletingLastPathComponent().appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        XCTAssertThrowsError(try CleanupSafety.validate(link, protectRecentFiles: false))
    }

    func testOrdinaryFolderWithInternalLinkRemainsRejected() throws {
        let app = try fixture()
        let folder = app.deletingLastPathComponent().appendingPathComponent("ordinary")
        try FileManager.default.moveItem(at: app, to: folder)
        XCTAssertThrowsError(try CleanupSafety.validate(folder, protectRecentFiles: false))
    }

    func testActualOnVUEValidationWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MACSWEEP_VALIDATE_ONVUE"] == "1" else { throw XCTSkip("Opt-in read-only validation of reported apps.") }
        for name in ["OnVUE.app", "OnVUE 2.app"] {
            let app = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").appendingPathComponent(name)
            XCTAssertNoThrow(try CleanupSafety.validate(app), name)
        }
    }
    func testRunningAndSelfBundlesRemainRejected() throws {
        let app = try fixture()
        XCTAssertThrowsError(try CleanupSafety.validate(app, protectRecentFiles: false, runningURLs: [app]))
        XCTAssertThrowsError(try CleanupSafety.validate(app, protectRecentFiles: false, selfURL: app))
    }

    func testDanglingBundleLinkRemainsRejected() throws {
        let app = try fixture()
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("missing").path, withDestinationPath: "nowhere")
        XCTAssertThrowsError(try CleanupSafety.validate(app, protectRecentFiles: false))
    }

    func testReplacedInventoriedAppWithSameIdentifierIsRejected() throws {
        let app = try fixture()
        let root = app.deletingLastPathComponent()
        let reviewed = try XCTUnwrap(AppScanner.inventory(roots: [root]).apps.first)
        try FileManager.default.moveItem(at: app, to: root.appendingPathComponent("Original.app"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("Original.app"), to: app)
        XCTAssertThrowsError(try CleanupSafety.validateApp(reviewed, runningURLs: [], selfURL: root.appendingPathComponent("Self.app"), allowedRoots: [root]))
        let journal = CleanupJournal(directory: root.appendingPathComponent("journal"))
        let result = CleanupSafety.uninstall(.init(app: reviewed, support: []), runningURLs: [], selfURL: root.appendingPathComponent("Self.app"), allowedRoots: [root], journal: journal) { _ in
            XCTFail("The replacement must never reach the mover")
            return nil
        }
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(try journal.entries().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    func testReviewedNestedAppMovesOnlyFixtureAndJournalsIntentFirst() throws {
        let app = try fixture()
        let root = app.deletingLastPathComponent()
        let nested = root.appendingPathComponent("Utilities/Example.app")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: app, to: nested)
        let reviewed = try XCTUnwrap(AppScanner.inventory(roots: [root]).apps.first)
        XCTAssertNil(CleanupSafety.appRemovalRestriction(reviewed, allowedRoots: [root]))
        let journal = CleanupJournal(directory: root.appendingPathComponent("journal"))
        var calls: [URL] = []
        let result = CleanupSafety.uninstall(.init(app: reviewed, support: []), runningURLs: [], selfURL: root.appendingPathComponent("Self.app"), allowedRoots: [root], journal: journal) { source in
            calls.append(source)
            XCTAssertFalse(try journal.entries().isEmpty)
            let destination = root.appendingPathComponent("FixtureTrash.app")
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        XCTAssertEqual(calls.map(\.path), [nested.path])
        XCTAssertEqual(result.moved.map(\.path), [nested.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
    }

    func testReplacedSupportIsRetainedAndNeverJournaled() throws {
        let app = try fixture()
        let root = app.deletingLastPathComponent()
        let url = root.appendingPathComponent("org.example.fixture.plist")
        try Data("original".utf8).write(to: url)
        let item = AppLeftoverItem(id: url.path, url: url, location: "fixture", size: 8, reason: "fixture", isSelected: true, snapshot: try FileSnapshotReader.capture(url))
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("old"))
        try Data("replacement".utf8).write(to: url)
        let journal = CleanupJournal(directory: root.appendingPathComponent("journal"))
        let result = CleanupSafety.trashSupport([item], runningURLs: [], selfURL: app, journal: journal) { _ in
            XCTFail("A replaced target must never reach the mover")
            return nil
        }
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(result.messages.contains { $0.contains("rescan") })
        XCTAssertEqual(try Data(contentsOf: url), Data("replacement".utf8))
        XCTAssertTrue(try journal.entries().isEmpty)
    }

    func testUnchangedSupportMovesExactFixture() throws {
        let app = try fixture()
        let root = app.deletingLastPathComponent()
        let url = root.appendingPathComponent("org.example.fixture.plist")
        try Data("original".utf8).write(to: url)
        let item = AppLeftoverItem(id: url.path, url: url, location: "fixture", size: 8, reason: "fixture", isSelected: true, snapshot: try FileSnapshotReader.capture(url))
        let result = CleanupSafety.trashSupport([item], runningURLs: [], selfURL: app, journal: CleanupJournal(directory: root.appendingPathComponent("journal"))) { source in
            XCTAssertEqual(source, url)
            let destination = root.appendingPathComponent("TrashedFixture")
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        XCTAssertEqual(result.moved, [url])
    }

    func testMissingEvidenceIsUnavailable() throws {
        let app = try fixture()
        let item = InstalledApp(id: app.path, url: app, name: "Fixture", bundleIdentifier: "org.example.fixture", version: nil, size: 0)
        XCTAssertNotNil(CleanupSafety.appRemovalRestriction(item, allowedRoots: [app.deletingLastPathComponent()]))
        XCTAssertFalse(AppLeftoverItem(id: app.path, url: app, location: "fixture", size: 0, reason: "fixture", isSelected: true).canSelect)
    }

    func testSubstitutedMetadataIsBoundedlyRejected() throws {
        for kind in ["fifo", "oversized", "symlink"] {
            let app = try fixture()
            let root = app.deletingLastPathComponent()
            let reviewed = try XCTUnwrap(AppScanner.inventory(roots: [root]).apps.first)
            let plist = app.appendingPathComponent("Contents/Info.plist")
            try FileManager.default.removeItem(at: plist)
            if kind == "fifo" { XCTAssertEqual(mkfifo(plist.path, 0o600), 0) }
            else if kind == "oversized" { try Data(repeating: 65, count: 1_048_577).write(to: plist) }
            else { try FileManager.default.createSymbolicLink(atPath: plist.path, withDestinationPath: "/System") }
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try CleanupSafety.validateApp(reviewed, runningURLs: [], selfURL: root.appendingPathComponent("Self.app"), allowedRoots: [root]))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        }
    }

    func testBundleWithSpecialDescendantIsRejected() throws {
        let app = try fixture()
        XCTAssertEqual(mkfifo(app.appendingPathComponent("Contents/pipe").path, 0o600), 0)
        XCTAssertThrowsError(try CleanupSafety.validate(app, protectRecentFiles: false))
    }

    func testSupportReplacementAfterAppMoveIsNotMoved() throws {
        let app = try fixture()
        let root = app.deletingLastPathComponent()
        let url = root.appendingPathComponent("org.example.fixture.plist")
        try Data("original".utf8).write(to: url)
        let item = AppLeftoverItem(id: url.path, url: url, location: "fixture", size: 8, reason: "fixture", isSelected: true, snapshot: try FileSnapshotReader.capture(url))
        let reviewed = try XCTUnwrap(AppScanner.inventory(roots: [root]).apps.first)
        var calls: [String] = []
        let result = CleanupSafety.uninstall(.init(app: reviewed, support: [item]), runningURLs: [], selfURL: root.appendingPathComponent("Self.app"), allowedRoots: [root], journal: CleanupJournal(directory: root.appendingPathComponent("journal"))) { source in
            calls.append(source.path)
            XCTAssertEqual(source.path, app.path)
            let destination = root.appendingPathComponent("Trashed.app")
            try FileManager.default.moveItem(at: source, to: destination)
            try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("original-support"))
            try Data("replacement".utf8).write(to: url)
            return destination
        }
        XCTAssertEqual(calls, [app.path])
        XCTAssertEqual(result.moved.map(\.path), [app.path])
        XCTAssertEqual(try Data(contentsOf: url), Data("replacement".utf8))
        XCTAssertTrue(result.messages.contains { $0.contains("rescan") })
    }

    func testStructuralValidationCancellationAndLimit() async throws {
        let app = try fixture()
        XCTAssertThrowsError(try CleanupSafety.validate(app, protectRecentFiles: false, limit: ScanLimit(seconds: 10, entries: 1)))
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try CleanupSafety.validate(app, protectRecentFiles: false); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(cancelled)
    }

    func testRealInstalledAppStructuralReviewWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MACSWEEP_VALIDATE_INSTALLED"] == "1" else { throw XCTSkip("Opt-in read-only validation; never calls a mover.") }
        let app = try XCTUnwrap(AppScanner.inventory().apps.first { $0.url.path == "/Applications/The Unarchiver.app" })
        XCTAssertThrowsError(try CleanupSafety.validate(app.url, protectRecentFiles: false))
        XCTAssertNoThrow(try CleanupSafety.validateApp(app, runningURLs: [], selfURL: Bundle.main.bundleURL))
    }

}
