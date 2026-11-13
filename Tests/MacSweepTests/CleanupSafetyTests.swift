import XCTest
@testable import MacSweep

final class CleanupSafetyTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func item(_ url: URL, category: CleanupCategory = .custom, group: String? = nil, size: Int64 = 10) -> CleanupItem {
        CleanupItem(id: category.rawValue + url.path, url: url, category: category, size: size,
                    modifiedAt: .distantPast, kind: "File", reason: "Fixture", safetyNote: "", duplicateGroupID: group, isSelected: true)
    }

    func testProtectedRootsAndSensitiveAncestors() {
        for path in ["/", "/System", "/Library", "/Applications", NSHomeDirectory(), NSHomeDirectory() + "/Library",
                     NSHomeDirectory() + "/Library/Mail", NSHomeDirectory() + "/Library/Containers/com.apple.mail"] {
            XCTAssertTrue(ProtectionRules.isProtected(URL(fileURLWithPath: path), protectRecentFiles: false), path)
        }
    }

    func testNestedAndRepeatedTargetsHaveOneTotal() throws {
        let root = try fixture()
        let items = [item(root, size: 30), item(root.appendingPathComponent("child")), item(root, category: .downloads, size: 30)]
        XCTAssertEqual(CleanupSafety.uniqueItems(items).count, 1)
        XCTAssertEqual(CleanupSafety.uniqueItems(items).reduce(0) { $0 + $1.size }, 30)
        XCTAssertFalse(ProtectionRules.contains(root, root.appendingPathExtension("sibling")))
    }

    func testRetainedDuplicateCannotBeSelectedThroughOtherCategoryOrParent() throws {
        let root = try fixture()
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        let items = [item(a, category: .duplicates, group: "hash"), item(b, category: .duplicates, group: "hash"),
                     item(a, category: .downloads), item(root)]
        XCTAssertEqual(CleanupSafety.selection(items).map(\.url), [b])
    }

    func testSymlinkAndNewSensitiveDescendantRejected() throws {
        let root = try fixture()
        let directory = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CleanupSafety.validate(directory, protectRecentFiles: false)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertThrowsError(try CleanupSafety.validate(link, protectRecentFiles: false))
        XCTAssertTrue(ProtectionRules.hasSymlinkComponent(link.appendingPathComponent("missing")))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Photos.photoslibrary"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try CleanupSafety.validate(directory, protectRecentFiles: false))
    }

    func testMissingOrChangedRetainedDuplicateRejected() throws {
        let root = try fixture()
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        try Data("identical".utf8).write(to: a)
        try Data("identical".utf8).write(to: b)
        let hash = try XCTUnwrap(CleanerScanner.sha256(a))
        let items = [item(a, group: hash), item(b, group: hash)]
        try CleanupSafety.validateDuplicates(target: b, allItems: items)
        try Data("changed".utf8).write(to: a)
        XCTAssertThrowsError(try CleanupSafety.validateDuplicates(target: b, allItems: items))
        try FileManager.default.removeItem(at: a)
        XCTAssertThrowsError(try CleanupSafety.validateDuplicates(target: b, allItems: items))
    }

    func testChangedDuplicateTargetWithPreservedDateIsRejected() throws {
        let root = try fixture()
        let retained = root.appendingPathComponent("a")
        let target = root.appendingPathComponent("b")
        try Data("identical".utf8).write(to: retained)
        try Data("identical".utf8).write(to: target)
        let hash = try XCTUnwrap(CleanerScanner.sha256(retained))
        let items = [item(retained, group: hash), item(target, group: hash)]
        try Data("now unique".utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: target.path)
        XCTAssertThrowsError(try CleanupSafety.validateDuplicates(target: target, allItems: items))
        XCTAssertTrue(ProtectionRules.isProtected(URL(fileURLWithPath: "/system/Library"), protectRecentFiles: false))
    }

    func testSupportMatchingDistinguishesExactAndAdvisory() {
        let app = InstalledApp(id: "test", url: URL(fileURLWithPath: "/Applications/Test.app"), name: "Test", bundleIdentifier: "org.example.test", version: nil, size: 0)
        XCTAssertTrue(AppScanner.matchReason(URL(fileURLWithPath: "/fixture/org.example.test.plist"), app: app)?.hasPrefix("Exact") == true)
        XCTAssertTrue(AppScanner.matchReason(URL(fileURLWithPath: "/fixture/Test-cache"), app: app)?.hasPrefix("Advisory") == true)
        XCTAssertNil(AppScanner.matchReason(URL(fileURLWithPath: "/fixture/Contest"), app: app))
    }

    func testUninstallRejectsRunningSelfSystemAndChangedIdentity() throws {
        let root = try fixture()
        let url = root.appendingPathComponent("Example.app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist")
        func writeID(_ id: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            try data.write(to: plist)
        }
        try writeID("org.example.fixture")
        let app = try XCTUnwrap(AppScanner.inventory(roots: [root]).apps.first)
        let other = root.appendingPathComponent("Other.app")
        try CleanupSafety.validateApp(app, runningURLs: [], selfURL: other, allowedRoots: [root])
        XCTAssertThrowsError(try CleanupSafety.validateApp(app, runningURLs: [url], selfURL: other, allowedRoots: [root]))
        XCTAssertThrowsError(try CleanupSafety.validateApp(app, runningURLs: [], selfURL: url, allowedRoots: [root]))
        try writeID("com.apple.Fixture")
        XCTAssertThrowsError(try CleanupSafety.validateApp(app, runningURLs: [], selfURL: other, allowedRoots: [root]))
    }

    func testOldRegularFileIsEligibleForCleanup() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("old")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        try CleanupSafety.validate(file)
    }

    func testRecentDescendantBlocksDirectoryCleanup() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("recent")
        try Data("new".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: root.path)
        XCTAssertThrowsError(try CleanupSafety.validate(root))
    }

    @MainActor
    func testCancelledScanCannotOverwriteNewScan() async throws {
        let model = AppModel(cleanerScan: { _, preset in
            if preset == .quick {
                let deadline = Date().addingTimeInterval(0.2)
                while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                return ScanReport(items: [], storageItems: [], messages: ["stale"])
            }
            return ScanReport(items: [], storageItems: [], messages: ["fresh"])
        })
        model.scan()
        model.cancelScan()
        for _ in 0..<100 where model.waitingForFilesystem { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.waitingForFilesystem)
        model.selectedPreset = .duplicatesOnly
        model.scan()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.logText, "fresh")
        XCTAssertEqual(model.status, .complete)
        XCTAssertNotNil(model.lastScanDate)
    }

    func testCancelledHashDoesNotReturnDigest() async throws {
        let root = try fixture()
        let file = root.appendingPathComponent("hash")
        try Data(repeating: 1, count: 4_000_000).write(to: file)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return CleanerScanner.sha256(file)
        }
        let result = await task.value
        XCTAssertNil(result)
    }

    func testReadErrorsMakeOverallCoveragePartial() {
        let session = ScanSession(limit: .quick, progress: { _ in })
        session.recordError(URL(fileURLWithPath: "/fixture/unreadable"), error: CocoaError(.fileReadNoPermission))
        XCTAssertTrue(session.summary.contains("partial coverage"))
        XCTAssertTrue(session.summary.contains("1 read errors"))
    }

    func testSparseAndAllocatedDuplicatesUseLogicalSize() throws {
        let root = try fixture()
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let sparse = documents.appendingPathComponent("sparse")
        let full = documents.appendingPathComponent("full")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 2_000_000)
        try handle.close()
        try Data(repeating: 0, count: 2_000_000).write(to: full)
        for file in [sparse, full] {
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        }
        let report = CleanerScanner.scan(customFolders: [], preset: .duplicatesOnly, home: root)
        XCTAssertEqual(Set(report.items.map(\.url)), Set([sparse, full]))
        XCTAssertEqual(Set(report.items.compactMap(\.duplicateGroupID)).count, 1)
    }

    func testDuplicateScanFixturesStartUnselectedAndDeduplicateRoots() throws {
        let root = try fixture()
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for name in ["a", "b"] {
            let file = documents.appendingPathComponent(name)
            try Data(repeating: 1, count: 2_000_000).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        }
        let report = CleanerScanner.scan(customFolders: [documents, root], preset: .duplicatesOnly, home: root)
        XCTAssertEqual(report.items.count, 2)
        XCTAssertTrue(report.messages.contains { $0.contains("Files below 1 MB") })
        XCTAssertTrue(report.messages.contains { $0.contains("2 files hashed") })
        XCTAssertTrue(report.items.allSatisfy { !$0.isSelected })
    }
}
