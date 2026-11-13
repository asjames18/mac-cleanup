import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

final class ExclusionTests: XCTestCase {
    func testExcludedDescendantProtectsWholeFolderAndFinalMover() throws {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Keep")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("important")
        try Data("preserve".utf8).write(to: file)
        let journal = CleanupJournal(directory: root.appendingPathComponent("journal"))
        var moved = false
        try ProtectionRules.$excludedURLs.withValue([file]) {
            XCTAssertTrue(ProtectionRules.isExcluded(folder))
            XCTAssertTrue(ProtectionRules.isExcluded(file))
            XCTAssertTrue(ProtectionRules.isExcluded(file.appendingPathComponent("child")))
            XCTAssertFalse(ProtectionRules.isExcluded(root.appendingPathComponent("KeepOther")))
            XCTAssertThrowsError(try CleanupSafety.validate(folder, protectRecentFiles: false))
            let result = CleanupSafety.moveWithJournal(folder, journal: journal) { _ in
                moved = true; return nil
            }
            XCTAssertTrue(result.moved.isEmpty)
            XCTAssertTrue(result.messages.joined().contains("exclusions"))
        }
        XCTAssertFalse(moved)
        XCTAssertEqual(try Data(contentsOf: file), Data("preserve".utf8))
        XCTAssertTrue(try journal.entries().isEmpty)
        XCTAssertFalse(ProtectionRules.isExcluded(file), "Task-local scope must not leak to other jobs")
    }

    func testScannerOmitsExcludedDownloadButFindsSibling() throws {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        let downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let excluded = downloads.appendingPathComponent("keep.zip")
        let other = downloads.appendingPathComponent("review.zip")
        for file in [excluded, other] {
            try Data(repeating: 1, count: 4096).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: file.path)
        }
        let report = ProtectionRules.$excludedURLs.withValue([excluded]) {
            CleanerScanner.scan(customFolders: [], preset: .quick, home: root, temporaryDirectory: root.appendingPathComponent("Temp"))
        }
        XCTAssertFalse(report.items.contains { $0.url == excluded })
        XCTAssertTrue(report.items.contains { $0.url == other })
        let app = InstalledApp(id: "fixture", url: excluded, name: "Fixture", bundleIdentifier: nil, version: nil, size: 0)
        ProtectionRules.$excludedURLs.withValue([excluded]) {
            XCTAssertTrue(CleanupSafety.appRemovalRestriction(app)?.contains("exclusions") == true)
        }
    }

    @MainActor
    func testPersistedExclusionsReachDetachedJobsAndCannotChangeWhileBusy() async throws {
        let suite = "MacSweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = URL(fileURLWithPath: "/fixture/excluded")
        let preferences = ScanPreferences(defaults: defaults)
        let first = AppModel(scanPreferences: preferences)
        first.addExclusions([file, file])
        XCTAssertEqual(first.excludedFolders.count, 1)
        first.selectedPreset = .deep
        let model = AppModel(cleanerScan: { _, _ in
            ScanReport(items: [], storageItems: [], messages: [], coverageSummary: ProtectionRules.isExcluded(file) ? "protected" : "missing scope")
        }, scanPreferences: preferences)
        XCTAssertEqual(model.excludedFolders.map(\.path), [file.path])
        model.scan()
        model.removeExclusion(file)
        XCTAssertEqual(model.excludedFolders.map(\.path), [file.path])
        for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.scanSummary.contains("protected"))
        model.removeExclusion(file)
        XCTAssertTrue(AppModel(scanPreferences: preferences).excludedFolders.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.lastScanDate)
    }
}
