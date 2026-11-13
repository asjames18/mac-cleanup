import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

final class ScanResponsivenessTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory)
            .appendingPathComponent("macsweep-scan-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testQuickScanDoesNotAnalyzeUnrelatedDocuments() throws {
        let root = try fixture()
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: documents.appendingPathComponent("unrelated"))
        let report = CleanerScanner.scan(customFolders: [], preset: .quick, home: root, temporaryDirectory: root.appendingPathComponent("Temp"))
        XCTAssertTrue(report.storageItems.isEmpty, "Quick Scan must not perform a whole-home storage analysis before cleanup.")
    }
    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ScanUpdate] = []
        func append(_ value: ScanUpdate) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
        var values: [ScanUpdate] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    private func oldFile(_ url: URL, bytes: Int = 4096) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: url.path)
    }

    func testFirstCandidatePublishesBeforeScanFinishes() throws {
        let root = try fixture()
        try oldFile(root.appendingPathComponent("Downloads/archive.zip"))
        let updates = Updates()
        let report = CleanerScanner.scan(customFolders: [], preset: .quick, home: root,
            temporaryDirectory: root.appendingPathComponent("Temp"), progress: { updates.append($0) })
        XCTAssertEqual(report.items.count, 1)
        XCTAssertNotNil(report.items.first?.snapshot)
        XCTAssertTrue(updates.values.contains { !$0.items.isEmpty && $0.stage != "Finishing scan" })
        XCTAssertEqual(updates.values.first?.examined, 0)
    }

    func testBudgetExcludesUnfinishedCleanupDirectory() throws {
        let root = try fixture()
        let cache = root.appendingPathComponent("Library/Caches/large-cache")
        for index in 0..<20 { try oldFile(cache.appendingPathComponent("item-\(index)"), bytes: 100_000) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: cache.path)
        let updates = Updates()
        let report = CleanerScanner.scan(customFolders: [], preset: .quick, home: root,
            temporaryDirectory: root.appendingPathComponent("Temp"), limit: ScanLimit(seconds: 10, entries: 5),
            progress: { updates.append($0) })
        XCTAssertTrue(report.items.isEmpty, "An unfinished folder must not appear with a misleading complete cleanup size.")
        XCTAssertTrue(report.messages.contains { $0.contains("partial coverage") })
        XCTAssertLessThanOrEqual(updates.values.last?.examined ?? 100, 5)
    }

    func testStorageAnalysisIsSeparateAndPublishesFolderTotals() throws {
        let root = try fixture()
        try oldFile(root.appendingPathComponent("Documents/document"))
        let updates = Updates()
        let report = CleanerScanner.analyzeStorage(customFolders: [], home: root, progress: { updates.append($0) })
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(report.storageItems.map(\.title), ["Documents"])
        XCTAssertTrue(updates.values.contains { $0.storage.count == 1 })
    }

    func testStorageAnalysisCountsHardLinkedFileOncePerRoot() throws {
        let root = try fixture()
        let original = root.appendingPathComponent("Documents/original")
        try oldFile(original)
        let baseline = try XCTUnwrap(CleanerScanner.analyzeStorage(customFolders: [], home: root).storageItems.first)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("Documents/another-name"))
        let measured = try XCTUnwrap(CleanerScanner.analyzeStorage(customFolders: [], home: root).storageItems.first)
        XCTAssertEqual(measured.fileCount, 1)
        XCTAssertEqual(measured.size, baseline.size)
    }

    func testUnavailableCustomStorageRootIsExplained() throws {
        let root = try fixture()
        let missing = root.appendingPathComponent("Chosen folder that disappeared")
        let report = CleanerScanner.analyzeStorage(customFolders: [missing], home: root)
        XCTAssertTrue(report.storageItems.isEmpty)
        XCTAssertTrue(report.coverageSummary.contains("partial coverage"))
        XCTAssertTrue(report.messages.contains { $0.contains(missing.path) && $0.contains("unavailable") })
    }

    func testEmptyStorageFolderIsReportedAsMeasuredZero() throws {
        let root = try fixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let report = CleanerScanner.analyzeStorage(customFolders: [], home: root)
        let item = try XCTUnwrap(report.storageItems.first)
        XCTAssertEqual(item.title, "Documents")
        XCTAssertEqual(item.size, 0)
        XCTAssertEqual(item.fileCount, 0)
        XCTAssertEqual(item.folderCount, 1)
    }

    func testZeroPartialStorageTotalIsNotSilentlyDropped() throws {
        let root = try fixture()
        try oldFile(root.appendingPathComponent("Documents/file"))
        let report = CleanerScanner.analyzeStorage(customFolders: [], home: root, limit: ScanLimit(seconds: 10, entries: 1))
        let item = try XCTUnwrap(report.storageItems.first)
        XCTAssertEqual(item.title, "Documents (partial)")
        XCTAssertEqual(item.size, 0)
        XCTAssertTrue(report.coverageSummary.contains("partial coverage"))
    }

    func testStorageBudgetLabelsPartialRoot() throws {
        let root = try fixture()
        for index in 0..<10 { try oldFile(root.appendingPathComponent("Documents/item-\(index)")) }
        let report = CleanerScanner.analyzeStorage(customFolders: [], home: root, limit: ScanLimit(seconds: 10, entries: 3))
        XCTAssertEqual(report.storageItems.first?.title, "Documents (partial)")
        XCTAssertTrue(report.messages.contains { $0.contains("partial coverage") })
    }

    func testCleanupSnapshotRejectsReplacementWithoutTrashing() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("Downloads/archive.zip")
        try oldFile(file)
        let report = CleanerScanner.scan(customFolders: [], preset: .quick, home: root,
            temporaryDirectory: root.appendingPathComponent("Temp"))
        try CleanupSafety.validateSnapshot(file, allItems: report.items)
        try FileManager.default.removeItem(at: file)
        try oldFile(file)
        XCTAssertThrowsError(try CleanupSafety.validateSnapshot(file, allItems: report.items))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRealQuickScanWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["MACSWEEP_REAL_SCAN"] == "1" else {
            throw XCTSkip("Opt-in read-only benchmark on the current Mac.")
        }
        let updates = Updates()
        let start = ProcessInfo.processInfo.systemUptime
        let report = CleanerScanner.scan(customFolders: [], preset: .quick, progress: { updates.append($0) })
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("REAL_QUICK_SCAN seconds=\(elapsed) candidates=\(report.items.count) firstUpdate=\(updates.values.first?.elapsed ?? -1) firstCandidate=\(updates.values.first(where: { !$0.items.isEmpty })?.elapsed ?? -1)")
        print(report.messages.joined(separator: "\n"))
        XCTAssertTrue(report.storageItems.isEmpty)
        XCTAssertLessThan(elapsed, 30, "Quick Scan should yield within its 20-second cooperative budget on this local filesystem.")
    }

    func testManySiblingTargetsAreDeduplicatedWithoutQuadraticWork() {
        let root = URL(fileURLWithPath: "/fixture")
        let urls = (0..<25_000).map { root.appendingPathComponent("file-\($0)") }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(CleanupSafety.uniqueURLs(urls + urls).count, 25_000)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
        XCTAssertEqual(CleanupSafety.uniqueURLs(urls + [root]), [root])
    }

    func testUnreadableDownloadFolderIsExcludedAndStorageRootIsPartial() throws {
        let root = try fixture()
        let downloads = root.appendingPathComponent("Downloads")
        let candidate = downloads.appendingPathComponent("old-folder")
        let denied = candidate.appendingPathComponent("denied")
        try oldFile(candidate.appendingPathComponent("visible"))
        try oldFile(denied.appendingPathComponent("hidden-by-permission"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: candidate.path)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        let report = CleanerScanner.scan(customFolders: [], preset: .quick, home: root,
            temporaryDirectory: root.appendingPathComponent("Temp"))
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertTrue(report.coverageSummary.contains("1 read errors"))
        let storage = CleanerScanner.analyzeStorage(customFolders: [], home: root)
        XCTAssertEqual(storage.storageItems.first?.title, "Downloads (partial)")
    }

    @MainActor
    func testIndependentTimeoutReleasesUIAndRejectsBlockedWorkersLateReport() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let model = AppModel(cleanerScan: { _, _ in
            gate.wait() // Simulate an OS call that ignores Task cancellation.
            return ScanReport(items: [], storageItems: [], messages: ["late report"])
        }, scanTimeout: .milliseconds(30))
        model.scan()
        for _ in 0..<200 where !model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.waitingForFilesystem)
        XCTAssertTrue(model.scanSummary.contains("timed out"))
        model.scan() // A pending blocked operation must not cause unbounded new workers.
        XCTAssertFalse(model.isBusy)
        gate.signal()
        for _ in 0..<200 where model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.waitingForFilesystem)
        XCTAssertNotEqual(model.logText, "late report")
        XCTAssertNil(model.lastScanDate)
    }

    @MainActor
    func testCancelBeforeTimeoutKeepsBlockedWorkerGuard() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let model = AppModel(cleanerScan: { _, _ in
            gate.wait()
            return ScanReport(items: [], storageItems: [], messages: ["cancelled late report"])
        })
        model.scan()
        model.cancelScan()
        XCTAssertTrue(model.waitingForFilesystem)
        XCTAssertFalse(model.isBusy)
        model.scan()
        XCTAssertFalse(model.isBusy)
        gate.signal()
        for _ in 0..<200 where model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.waitingForFilesystem)
        XCTAssertNotEqual(model.logText, "cancelled late report")
    }

}
