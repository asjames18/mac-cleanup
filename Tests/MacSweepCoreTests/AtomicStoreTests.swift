import Foundation
import XCTest
@testable import MacSweepCore

final class AtomicStoreTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSaveLoadAndBackups() throws {
        let store = try AtomicJSONStore(root: try root(), backupLimit: 3)
        XCTAssertEqual(store.load("settings.json", as: MacSweepSettings.self, default: MacSweepSettings()).value, MacSweepSettings())
        let start = Date(timeIntervalSince1970: 2_000_000)
        for index in 0..<6 {
            try store.save("settings.json", value: MacSweepSettings(sandboxEnabled: index % 2 == 0), backupReason: "change \(index)", now: start.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(store.load("settings.json", as: MacSweepSettings.self, default: MacSweepSettings()).value.sandboxEnabled, false)
        XCTAssertEqual(store.backups(for: "settings.json").count, 3, "Only the newest backups are kept")
        let mode = try FileManager.default.attributesOfItem(atPath: store.root.appendingPathComponent("settings.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testCorruptFileIsMovedToBakAndDefaultsUsed() throws {
        let store = try AtomicJSONStore(root: try root())
        let file = store.root.appendingPathComponent("settings.json")
        try Data("{ not json".utf8).write(to: file)
        let result = store.load("settings.json", as: MacSweepSettings.self, default: MacSweepSettings())
        XCTAssertEqual(result.value, MacSweepSettings())
        XCTAssertEqual(result.recoveredBackup?.lastPathComponent, "settings.json.bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: store.root.appendingPathComponent("settings.json.bak"), encoding: .utf8), "{ not json")
    }

    func testBOMAndMissingKeysDecodeToSafeDefaults() throws {
        let store = try AtomicJSONStore(root: try root())
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"{"version": 1}"#.utf8))
        try data.write(to: store.root.appendingPathComponent("settings.json"))
        let result = store.load("settings.json", as: MacSweepSettings.self, default: MacSweepSettings(sandboxEnabled: false))
        XCTAssertNil(result.recoveredBackup)
        XCTAssertTrue(result.value.sandboxEnabled, "A missing sandbox key means on")
    }

    func testActionLogAppendsNewestFirstAndRotates() throws {
        let folder = try root()
        let log = try ActionLog(directory: folder, maxBytes: 1_024)
        let start = Date(timeIntervalSince1970: 3_000_000)
        log.append(kind: "trash", message: "Moved: /a\nsecond line | pipe", now: start)
        log.append(kind: "sandbox", message: "on", now: start.addingTimeInterval(1))
        let entries = log.recent()
        XCTAssertEqual(entries.map(\.kind), ["sandbox", "trash"])
        XCTAssertEqual(entries.last?.message, "Moved: /a second line / pipe")
        XCTAssertEqual(entries.last?.time, start)
        for index in 0..<40 { log.append(kind: "fill", message: String(repeating: "x", count: 40) + "\(index)", now: start) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.fileURL.appendingPathExtension("1").path))
        let size = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, 1_024)
    }

    func testSafeReasonAndStamp() {
        XCTAssertEqual(AtomicJSONStore.safeReason("sandbox off!"), "sandbox-off")
        XCTAssertEqual(AtomicJSONStore.safeReason("../.."), "change")
        XCTAssertEqual(AtomicJSONStore.stamp(Date(timeIntervalSince1970: 0)), "19700101-000000-000")
    }
}
