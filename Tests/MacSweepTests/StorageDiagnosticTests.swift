import Foundation
import XCTest
@testable import MacSweep

final class StorageDiagnosticTests: XCTestCase {
    func testOptInStorageIdentityCost() throws {
        guard ProcessInfo.processInfo.environment["MACSWEEP_STORAGE_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Opt-in generated storage timing diagnostic.")
        }
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory)
            .appendingPathComponent("MacSweep-storage-diagnostic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Library/Application Support", "Library/Developer", "Library/Caches"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let documents = root.appendingPathComponent("Documents")
        for index in 0..<1000 {
            let file = documents.appendingPathComponent("file-\(index).bin")
            try Data(repeating: UInt8(index % 251), count: 4096).write(to: file)
            if index < 500 {
                try FileManager.default.linkItem(at: file, to: documents.appendingPathComponent("alias-\(index).bin"))
            }
        }
        print("STORAGE_DIAGNOSTIC fixture=\(root.path) originals=1000 hard_links=500 bytes_per_file=4096 warmup=none order=main_then_folder")
        var mainTimes: [Double] = [], folderTimes: [Double] = []
        for _ in 0..<5 {
            var start = ProcessInfo.processInfo.systemUptime
            let report = CleanerScanner.analyzeStorage(customFolders: [], home: root)
            mainTimes.append(ProcessInfo.processInfo.systemUptime - start)
            let item = try XCTUnwrap(report.storageItems.first { $0.url == documents })
            XCTAssertEqual(item.fileCount, 1000)
            XCTAssertEqual(item.title, "Documents")
            start = ProcessInfo.processInfo.systemUptime
            let measurement = try StorageFolderMeasurer.measure(documents)
            folderTimes.append(ProcessInfo.processInfo.systemUptime - start)
            XCTAssertEqual(measurement.files, 1000)
            XCTAssertEqual(measurement.allocatedBytes, item.size)
            XCTAssertFalse(measurement.partial)
        }
        print("STORAGE_DIAGNOSTIC main_seconds=\(mainTimes) folder_seconds=\(folderTimes)")
    }
}
