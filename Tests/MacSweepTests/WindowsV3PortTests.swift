import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

/// Cleaner categories, review-only items, files in use, keep newest/oldest, broken startup items and the
/// space breakdown. Every file lives in a temporary fixture; nothing outside it is moved.
final class WindowsV3PortTests: XCTestCase {
    override func invokeTest() {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory)
        TestSandbox.$policy.withValue(SandboxPolicy(enabled: true, root: root)) { super.invokeTest() }
    }

    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func write(_ url: URL, bytes: Int = 64, daysOld: Double = 400) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
        return url
    }

    /// Folders get a fresh date when files are written; scans protect anything changed in the last day.
    private func ageTree(_ root: URL, days: Double = 400) {
        let date = Date().addingTimeInterval(-days * 86_400)
        let all = [root] + (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
        for url in all where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    private func item(_ url: URL, _ category: CleanupCategory, size: Int64 = 100, group: String? = nil, modified: Date? = nil) -> CleanupItem {
        CleanupItem(id: category.rawValue + url.path, url: url, category: category, size: size, modifiedAt: modified,
                    kind: "File", reason: "", safetyNote: "", duplicateGroupID: group, isSelected: false)
    }

    // MARK: Cleaner categories

    func testNewCategoriesAndReviewOnlyInstallers() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        try write(home.appendingPathComponent("Library/Logs/DiagnosticReports/App-2026.ips"))
        try write(home.appendingPathComponent("Library/Logs/DiagnosticReports/Retired/Old.crash"))
        try write(home.appendingPathComponent("Library/Logs/DiagnosticReports/Today.ips"), daysOld: 0)
        try write(home.appendingPathComponent("Library/Caches/Firefox/Profiles/x/cache2/blob"), bytes: 1_200_000)
        try write(home.appendingPathComponent("Library/Caches/com.example.app/blob"), bytes: 1_200_000)
        try write(home.appendingPathComponent("Library/Caches/pip/http/blob"), bytes: 1_200_000)
        try write(home.appendingPathComponent("Downloads/Installer.dmg"), daysOld: 45)
        try write(home.appendingPathComponent("Downloads/Recent.dmg"), daysOld: 20)
        let shaders = root.appendingPathComponent("C")
        try write(shaders.appendingPathComponent("com.apple.metal/com.example.game/libraries.data"), bytes: 1_200_000)
        let updates = root.appendingPathComponent("Updates")
        try write(updates.appendingPathComponent("042-12345/InstallAssistant.pkg"), bytes: 11_000_000)
        ageTree(root)

        let options = CleanerOptions(includeDeveloperCaches: false, userCacheDirectory: shaders, systemUpdatesFolder: updates)
        let report = CleanerScanner.scan(customFolders: [], preset: .quick, home: home, temporaryDirectory: root.appendingPathComponent("T"), options: options)
        func names(_ category: CleanupCategory) -> Set<String> { Set(report.items.filter { $0.category == category }.map(\.url.lastPathComponent)) }
        XCTAssertEqual(names(.crashReports), ["App-2026.ips", "Old.crash"], "Files from the last day are protected")
        XCTAssertEqual(names(.browserCaches), ["Firefox"])
        XCTAssertEqual(names(.caches), ["com.example.app"], "Browser and developer caches are not double counted")
        XCTAssertEqual(names(.developerCaches), [], "Developer caches are opt-in")
        XCTAssertEqual(names(.shaderCaches), ["com.example.game"])
        XCTAssertEqual(names(.oldInstallers), ["Installer.dmg"])
        XCTAssertTrue(names(.downloads).contains("Recent.dmg"))
        XCTAssertEqual(names(.systemUpdates), ["Updates"])
        XCTAssertTrue(report.items.filter { $0.category.isReviewOnly }.allSatisfy { !$0.isSelected })

        let optedIn = CleanerScanner.scan(customFolders: [], preset: .quick, home: home, temporaryDirectory: root.appendingPathComponent("T"),
                                          options: CleanerOptions(includeDeveloperCaches: true))
        XCTAssertEqual(Set(optedIn.items.filter { $0.category == .developerCaches }.map(\.url.lastPathComponent)), ["pip"])
    }

    func testLogsOnlyOlderThan30Days() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        try write(home.appendingPathComponent("Library/Logs/App/old.log"), bytes: 20_000, daysOld: 45)
        try write(home.appendingPathComponent("Library/Logs/App/new.log"), bytes: 20_000, daysOld: 5)
        try write(home.appendingPathComponent("Library/Logs/DiagnosticReports/x.ips"), bytes: 20_000, daysOld: 45)
        ageTree(root)
        let report = CleanerScanner.scan(customFolders: [], preset: .deep, home: home, temporaryDirectory: root.appendingPathComponent("T"))
        XCTAssertEqual(report.items.filter { $0.category == .logs }.map(\.url.lastPathComponent), ["old.log"])
    }

    // MARK: Review-only and files in use

    func testReviewOnlyItemsCannotBeSelectedOrMoved() throws {
        let root = try fixture()
        let file = try write(root.appendingPathComponent("Old.dmg"))
        var review = item(file, .oldInstallers)
        review.isSelected = true
        XCTAssertTrue(CleanupSafety.selection([review]).isEmpty)
        let ledger = ConfirmationLedger()
        let preview = try XCTUnwrap(ledger.issue(paths: [file.path]))
        let grant = try ledger.consume(token: preview.token).get()
        let result = CleanupSafety.trash(grant, allItems: [review])
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(result.messages.first?.contains(CleanupSafety.reviewOnlyReason) == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFilesInUseAreSkippedAndListed() throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("cache")
        let open = try write(folder.appendingPathComponent("open.db"))
        let index = OpenFileIndex(paths: [open.path, "/some/other/file"])
        XCTAssertTrue(index.isInUse(open))
        XCTAssertTrue(index.isInUse(folder), "A folder holding an open file is in use")
        XCTAssertFalse(index.isInUse(root.appendingPathComponent("cache-2")))
        XCTAssertFalse(index.isInUse(root.appendingPathComponent("other")))

        let ledger = ConfirmationLedger()
        let preview = try XCTUnwrap(ledger.issue(paths: [folder.path]))
        let grant = try ledger.consume(token: preview.token).get()
        let result = CleanupSafety.trash(grant, allItems: [], openFiles: index)
        XCTAssertTrue(result.moved.isEmpty)
        let report = TrashReport.summarize(movedCount: 0, messages: result.messages)
        XCTAssertEqual(report.groups.first?.reason, CleanupSafety.inUseReason)
        XCTAssertEqual(report.groups.first?.paths, [folder.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: open.path))
    }

    /// Reads real process tables (read-only): a child process holding a fixture file open is seen.
    func testOpenFileIndexSeesAFileHeldOpenByAnotherProcess() throws {
        let root = try fixture()
        let file = try write(root.appendingPathComponent("held.txt"))
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", file.path]
        tail.standardOutput = FileHandle.nullDevice
        try tail.run()
        defer { tail.terminate(); tail.waitUntilExit() }
        var seen = false
        for _ in 0..<20 where !seen {
            Thread.sleep(forTimeInterval: 0.1)
            seen = OpenFileIndex.capture().isInUse(file)
        }
        XCTAssertTrue(seen)
        XCTAssertFalse(OpenFileIndex.capture().isInUse(root.appendingPathComponent("nobody-has-this-open")))
    }

    // MARK: Duplicates: keep newest / keep oldest

    func testKeepNewestOrOldest() {
        let old = item(URL(fileURLWithPath: "/f/old.bin"), .duplicates, group: "g", modified: Date(timeIntervalSince1970: 10))
        let new = item(URL(fileURLWithPath: "/f/new.bin"), .duplicates, group: "g", modified: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(CleanupSafety.retainedCopies([old, new]).map(\.url.lastPathComponent), ["old.bin"])
        XCTAssertEqual(CleanupSafety.retainedCopies([old, new], keep: .newest).map(\.url.lastPathComponent), ["new.bin"])
        var both = [old, new]; both[0].isSelected = true; both[1].isSelected = true
        XCTAssertEqual(CleanupSafety.selection(both, keep: .newest).map(\.url.lastPathComponent), ["old.bin"])
        XCTAssertEqual(CleanupSafety.extraDuplicateCopies(both, keep: .oldest).map(\.url.lastPathComponent), ["new.bin"])
    }

    @MainActor
    func testSelectExtraCopiesFollowsTheKeepChoice() {
        let model = AppModel()
        model.items = [item(URL(fileURLWithPath: "/f/old.bin"), .duplicates, group: "g", modified: Date(timeIntervalSince1970: 10)),
                       item(URL(fileURLWithPath: "/f/new.bin"), .duplicates, group: "g", modified: Date(timeIntervalSince1970: 20))]
        model.selectExtraDuplicateCopies()
        XCTAssertEqual(model.selectedItems.map(\.url.lastPathComponent), ["new.bin"])
        model.duplicateKeep = .newest
        XCTAssertTrue(model.selectedItems.isEmpty, "Switching the kept copy unselects it")
        model.selectExtraDuplicateCopies()
        XCTAssertEqual(model.selectedItems.map(\.url.lastPathComponent), ["old.bin"])
    }

    // MARK: Broken startup items

    func testBrokenStartupDetection() throws {
        let root = try fixture()
        let present = try write(root.appendingPathComponent("helper"))
        XCTAssertNil(StartupScanner.brokenReason(program: present.path))
        XCTAssertNil(StartupScanner.brokenReason(program: "node"), "Bare command names are not judged")
        XCTAssertNil(StartupScanner.brokenReason(program: nil))
        XCTAssertTrue(StartupScanner.brokenReason(program: root.appendingPathComponent("gone").path)?.contains("missing") == true)
        let volume = "MacSweepTestVolume-\(UUID().uuidString.prefix(6))"
        XCTAssertTrue(StartupScanner.brokenReason(program: "/Volumes/\(volume)/bin/tool")?.contains("isn't connected") == true)
    }

    private func plist(_ url: URL, program: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": url.deletingPathExtension().lastPathComponent,
                                                                         "ProgramArguments": [program], "RunAtLoad": true], format: .xml, options: 0)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86_400)], ofItemAtPath: url.path)
    }

    func testSwitchOffMovesOnlyABrokenUserAgentThroughTheJournal() throws {
        let root = try fixture()
        let agents = root.appendingPathComponent("LaunchAgents")
        let brokenURL = agents.appendingPathComponent("com.example.gone.plist")
        try plist(brokenURL, program: root.appendingPathComponent("missing-binary").path)
        let fineURL = agents.appendingPathComponent("com.example.fine.plist")
        try plist(fineURL, program: try write(root.appendingPathComponent("present-binary")).path)
        let scan = try StartupScanner.scan(locations: [.init(url: agents, source: .userLaunchAgents)])
        let broken = try XCTUnwrap(scan.definitions.first { $0.label == "com.example.gone" })
        let fine = try XCTUnwrap(scan.definitions.first { $0.label == "com.example.fine" })
        XCTAssertTrue(broken.isBroken)
        XCTAssertFalse(fine.isBroken)

        let journal = CleanupJournal(directory: root.appendingPathComponent("history"))
        let trash = root.appendingPathComponent("fixture-trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let mover: (URL) throws -> URL? = { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        let (refusedFine, _) = StartupSwitch.switchOff(fine, launchAgents: agents, journal: journal, mover: mover)
        XCTAssertTrue(refusedFine.moved.isEmpty, "Working items are never switched off")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fineURL.path))

        let elsewhere = StartupDefinition(id: brokenURL.path, url: brokenURL, label: broken.label, displayName: broken.displayName,
                                          source: .localLaunchAgents, program: broken.program, runAtLoad: true, keepAlive: nil, brokenReason: "x")
        XCTAssertTrue(StartupSwitch.switchOff(elsewhere, launchAgents: agents, journal: journal, mover: mover).0.moved.isEmpty,
                      "Items in the Mac's Library are never moved")

        let (result, refused) = StartupSwitch.switchOff(broken, launchAgents: agents, journal: journal, mover: mover)
        XCTAssertEqual(result.moved, [brokenURL])
        XCTAssertFalse(refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: brokenURL.path))
        XCTAssertEqual(try journal.entries().first?.state, .moved, "Restorable from History")
    }

    // MARK: Space breakdown and results summary

    func testSpaceBreakdownGroupsAndCountsOnce() {
        let shared = URL(fileURLWithPath: "/f/Downloads/copy.zip")
        let items = [item(URL(fileURLWithPath: "/f/Caches/a"), .caches, size: 1_000),
                     item(URL(fileURLWithPath: "/f/Crash/a.ips"), .crashReports, size: 10),
                     item(shared, .downloads, size: 500),
                     item(URL(fileURLWithPath: "/f/Documents/copy.zip"), .duplicates, size: 500, group: "g", modified: Date(timeIntervalSince1970: 1)),
                     item(shared, .duplicates, size: 500, group: "g", modified: Date(timeIntervalSince1970: 2)),
                     item(URL(fileURLWithPath: "/f/Downloads/old.dmg"), .oldInstallers, size: 7_000)]
        let breakdown = SpaceBreakdown.compute(items)
        XCTAssertEqual(breakdown.readyToClean.map(\.category), [.caches, .crashReports])
        XCTAssertEqual(breakdown.readyBytes, 1_010)
        XCTAssertEqual(breakdown.reviewBytes, 500, "The download that is also an extra duplicate copy counts once")
        XCTAssertEqual(breakdown.reviewOnlyBytes, 7_000)
        XCTAssertEqual(breakdown.totalBytes, 1_510, "Review-only space is reported separately")
    }

    func testResultsSummaryShowsFreedSpace() {
        let report = TrashReport.summarize(movedCount: 2, messages: ["Moved: /a", "Moved: /b"], freedBytes: 5_000_000)
        XCTAssertTrue(report.summary.contains("Moved 2 items"))
        XCTAssertTrue(report.summary.contains("freed when you empty the Trash"))
    }
}
