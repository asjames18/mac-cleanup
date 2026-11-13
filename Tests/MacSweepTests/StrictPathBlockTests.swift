import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

final class StrictPathBlockTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeOld(_ url: URL, bytes: Int = 64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: url.path)
    }

    func testDotFoldersAndToolFoldersAreProtected() throws {
        let root = try fixture()
        for path in ["proj/.git/config", "proj/.cache/blob", "proj/node_modules/pkg/index.js", "proj/venv/bin/python",
                     "proj/.venv/lib/x", "proj/lib/__pycache__/m.pyc", "proj/lib/site-packages/m.py"] {
            let file = root.appendingPathComponent(path)
            try makeOld(file)
            XCTAssertTrue(ProtectionRules.isProtected(file, protectRecentFiles: false), path)
            XCTAssertThrowsError(try CleanupSafety.validate(file, protectRecentFiles: false), path)
        }
        XCTAssertTrue(ProtectionRules.isProtected(root.appendingPathComponent("proj/node_modules"), protectRecentFiles: false))
        let ordinary = root.appendingPathComponent("proj/node_modules_backup/old.zip")
        try makeOld(ordinary)
        XCTAssertFalse(ProtectionRules.isProtected(ordinary, protectRecentFiles: false))
        let dotFile = root.appendingPathComponent("proj/notes/.hidden.txt")
        try makeOld(dotFile)
        XCTAssertFalse(ProtectionRules.hasDotFolder(dotFile, isDirectory: false), "A hidden file is not a dot-folder")
    }

    func testFolderContainingToolFolderCannotBeCleaned() throws {
        let root = try fixture()
        let project = root.appendingPathComponent("project")
        try makeOld(project.appendingPathComponent("node_modules/pkg/index.js"))
        try makeOld(project.appendingPathComponent("readme.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: project.path)
        XCTAssertFalse(ProtectionRules.isProtected(project, protectRecentFiles: false))
        XCTAssertThrowsError(try CleanupSafety.validate(project, protectRecentFiles: false))
    }

    func testAppBundleContentsAreExemptFromToolRules() throws {
        let root = try fixture()
        let app = root.appendingPathComponent("Electron.app")
        try makeOld(app.appendingPathComponent("Contents/Resources/app.asar.unpacked/node_modules/pkg/index.node"))
        try makeOld(app.appendingPathComponent("Contents/Resources/.hidden-folder/data"))
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.electron", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNoThrow(try CleanupSafety.validate(app, protectRecentFiles: false))
    }

    func testVolumeRootsAreNeverTargets() {
        for path in ["/", "/Volumes", "/Volumes/Backup", "/Volumes/Backup/"] {
            XCTAssertTrue(ProtectionRules.isVolumeRoot(URL(fileURLWithPath: path)), path)
            XCTAssertTrue(ProtectionRules.isProtected(URL(fileURLWithPath: path), protectRecentFiles: false), path)
        }
        XCTAssertFalse(ProtectionRules.isVolumeRoot(URL(fileURLWithPath: "/Volumes/Backup/old.zip")))
    }

    func testDatalessFlagDetection() throws {
        XCTAssertTrue(ProtectionRules.isDatalessFlags(0x4000_0000))
        XCTAssertTrue(ProtectionRules.isDatalessFlags(0x4000_0020))
        XCTAssertFalse(ProtectionRules.isDatalessFlags(0x20))
        let root = try fixture()
        let file = root.appendingPathComponent("local.bin")
        try makeOld(file)
        XCTAssertFalse(ProtectionRules.isDataless(file), "A normal local file is not a placeholder")
    }

    func testScannerSkipsToolFoldersInAddedFolders() throws {
        let root = try fixture()
        let added = root.appendingPathComponent("Added")
        try makeOld(added.appendingPathComponent("node_modules/pkg/index.js"))
        try makeOld(added.appendingPathComponent("venv/bin/python"))
        try makeOld(added.appendingPathComponent("old-installer.dmg"))
        let report = CleanerScanner.scan(customFolders: [added], preset: .quick, home: root.appendingPathComponent("home"),
                                         temporaryDirectory: root.appendingPathComponent("Temp"))
        let names = Set(report.items.map(\.url.lastPathComponent))
        XCTAssertTrue(names.contains("old-installer.dmg"))
        XCTAssertFalse(names.contains("node_modules"))
        XCTAssertFalse(names.contains("venv"))
    }

    func testVolumeCrossingDetection() {
        XCTAssertFalse(CleanerScanner.crossesVolume(nil, rootVolume: NSString(string: "a")))
        XCTAssertFalse(CleanerScanner.crossesVolume(nil, rootVolume: nil))
    }
}
