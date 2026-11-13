import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

final class SettingsStoreTests: XCTestCase {
    private func root() -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor
    func testSandboxSettingPersistsInSettingsFileAndIsLogged() throws {
        let folder = root()
        let model = AppModel(confirmation: { _, _ in true }, settingsStore: try SettingsStore(root: folder))
        XCTAssertTrue(model.sandboxEnabled)
        XCTAssertTrue(model.setSandboxEnabled(false))
        let reopened = try SettingsStore(root: folder)
        XCTAssertFalse(reopened.settings.sandboxEnabled)
        XCTAssertFalse(AppModel(settingsStore: reopened).sandboxEnabled)
        let text = try String(contentsOf: folder.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"sandboxEnabled\" : false"))
        let log = reopened.log.recent()
        XCTAssertTrue(log.contains { $0.kind == "sandbox" && $0.message.contains("off") })
    }

    @MainActor
    func testCorruptSettingsRecoverToSandboxOn() throws {
        let folder = root()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: folder.appendingPathComponent("settings.json"))
        let store = try SettingsStore(root: folder)
        XCTAssertTrue(store.settings.sandboxEnabled)
        XCTAssertNotNil(store.recoveryNote)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("settings.json.bak").path))
        let model = AppModel(settingsStore: store)
        XCTAssertTrue(model.sandboxEnabled)
        XCTAssertTrue(model.logText.contains("reset to safe defaults"))
    }

    @MainActor
    func testLegacySandboxPreferenceMigratesOnce() throws {
        let suite = "MacSweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SandboxPreferences.key)
        let folder = root()
        XCTAssertFalse(try SettingsStore(root: folder, legacyDefaults: defaults).settings.sandboxEnabled)
        defaults.set(true, forKey: SandboxPreferences.key)
        XCTAssertFalse(try SettingsStore(root: folder, legacyDefaults: defaults).settings.sandboxEnabled, "Once settings.json exists it wins")
    }

    @MainActor
    func testConfirmationsAreWrittenToTheActionLog() throws {
        let folder = root()
        let store = try SettingsStore(root: folder)
        let model = AppModel(settingsStore: store)
        model.requestConfirmation(summary: "Move 1 items to Trash", detail: "", urls: [URL(fileURLWithPath: "/fixture/a")]) { _ in }
        model.cancelPendingConfirmation()
        XCTAssertTrue(store.log.recent().contains { $0.kind == "confirm" && $0.message.hasPrefix("Cancelled") })
    }

    func testOwnSettingsFilesAreProtected() {
        let support = ProtectionRules.historyDirectory.deletingLastPathComponent()
        for name in ["settings.json", "backups/settings.json.x", "logs/actions.log"] {
            XCTAssertTrue(ProtectionRules.isProtected(support.appendingPathComponent(name), protectRecentFiles: false), name)
        }
        XCTAssertTrue(ProtectionRules.isProtected(support, protectRecentFiles: false))
    }
}
