import Foundation
import XCTest
@testable import MacSweep

final class ScanPreferencesTests: XCTestCase {
    @MainActor
    func testRelaunchPreservesPresetFoldersAndRemoval() throws {
        let suite = "MacSweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ScanPreferences(defaults: defaults)
        let first = AppModel(scanPreferences: preferences)
        let folder = URL(fileURLWithPath: "/missing/Scan Folder", isDirectory: true)
        first.addCustomFolders([folder, folder.appendingPathComponent(".")])
        first.selectedPreset = .developer
        let relaunched = AppModel(scanPreferences: preferences)
        XCTAssertEqual(relaunched.customFolders.map(\.path), [folder.path])
        XCTAssertEqual(relaunched.selectedPreset, .developer)
        relaunched.removeCustomFolder(relaunched.customFolders[0])
        XCTAssertTrue(AppModel(scanPreferences: preferences).customFolders.isEmpty)
        // Test models without an injected store never inherit personal preferences.
        XCTAssertEqual(AppModel().selectedPreset, .quick)
        XCTAssertTrue(AppModel().customFolders.isEmpty)
    }

    @MainActor
    func testMalformedPreferencesAndRemoteURLs() throws {
        let suite = "MacSweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ScanPreferences(defaults: defaults)
        defaults.set(["folders": ["relative", "/valid/../folder", "/folder", "/bad\0path"], "preset": "future-preset"], forKey: ScanPreferences.key)
        XCTAssertEqual(preferences.load().folders.map(\.path), ["/folder"])
        XCTAssertEqual(preferences.load().preset, .quick)
        defaults.set(["folders": 42, "preset": false], forKey: ScanPreferences.key)
        XCTAssertTrue(preferences.load().folders.isEmpty)
        let model = AppModel(scanPreferences: preferences)
        model.addCustomFolders([try XCTUnwrap(URL(string: "https://example.com/folder"))])
        XCTAssertTrue(model.customFolders.isEmpty)
        model.waitingForFilesystem = true
        model.addCustomFolders([URL(fileURLWithPath: "/folder")])
        XCTAssertTrue(model.customFolders.isEmpty)
    }
}
