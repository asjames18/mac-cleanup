import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

final class ConfirmFlowTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func item(_ url: URL, group: String? = nil, selected: Bool = true) -> CleanupItem {
        CleanupItem(id: url.path, url: url, category: group == nil ? .custom : .duplicates, size: 10,
                    modifiedAt: .distantPast, kind: "File", reason: "Fixture", safetyNote: "", duplicateGroupID: group, isSelected: selected)
    }

    private func grant(_ urls: [URL]) throws -> ConfirmationGrant {
        let ledger = ConfirmationLedger()
        let preview = try XCTUnwrap(ledger.issue(paths: urls.map(\.path)))
        return try ledger.consume(token: preview.token).get()
    }

    func testLastCopyGuardFindsTargetsCoveringWholeGroup() throws {
        let root = try fixture()
        let a = root.appendingPathComponent("a/copy.bin"), b = root.appendingPathComponent("b/copy.bin"), c = root.appendingPathComponent("c/other.bin")
        let items = [item(a, group: "g1"), item(b, group: "g1"), item(c)]
        XCTAssertTrue(CleanupSafety.lastCopyTargets([a], allItems: items).isEmpty)
        XCTAssertEqual(CleanupSafety.lastCopyTargets([a, b, c], allItems: items).count, 2)
        // A parent folder that holds both copies is blocked too.
        XCTAssertEqual(CleanupSafety.lastCopyTargets([root], allItems: items), [ProtectionRules.normalizedPath(root).lowercased()])
    }

    func testTrashRefusesRemovingEveryCopyBeforeAnyMove() throws {
        let root = try fixture()
        let a = root.appendingPathComponent("a.bin"), b = root.appendingPathComponent("b.bin")
        for url in [a, b] {
            try Data(repeating: 7, count: 64).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: url.path)
        }
        let items = [item(a, group: "g1"), item(b, group: "g1")]
        // The sandbox points at an empty folder, so nothing could move even if the guard failed.
        let result = try TestSandbox.$policy.withValue(SandboxPolicy(enabled: true, root: root.appendingPathComponent("empty-sandbox"))) {
            CleanupSafety.trash(try grant([a, b]), allItems: items)
        }
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.messages.filter { $0.contains(CleanupSafety.lastCopyMessage) }.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    @MainActor
    func testDeclinedConfirmationMovesNothing() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("old.zip")
        try Data("x".utf8).write(to: file)
        var titles: [String] = []
        let model = AppModel(confirmation: { title, _ in titles.append(title); return false })
        model.items = [item(file)]
        model.cleanSelectedItems()
        XCTAssertEqual(titles, ["Do you really want to do this action?"])
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    func testSheetTokenIsSingleUseAndExpires() throws {
        let model = AppModel()
        var approvals = 0, cancels = 0
        let start = Date()
        model.now = { start }
        model.requestConfirmation(summary: "Test", detail: "", urls: [URL(fileURLWithPath: "/fixture/a")],
                                  onCancel: { cancels += 1 }) { _ in approvals += 1 }
        let first = try XCTUnwrap(model.pendingConfirmation)
        XCTAssertEqual(first.rows.map(\.path), ["/fixture/a"])
        XCTAssertTrue(first.sandboxOn)
        model.approvePendingConfirmation()
        model.approvePendingConfirmation()
        XCTAssertEqual(approvals, 1, "A confirmation is used once")
        XCTAssertEqual(model.confirmationLedger.consume(token: first.preview.token), .failure(.alreadyUsed))

        model.requestConfirmation(summary: "Later", detail: "", urls: [URL(fileURLWithPath: "/fixture/b")],
                                  onCancel: { cancels += 1 }) { _ in approvals += 1 }
        model.now = { start.addingTimeInterval(301) }
        model.approvePendingConfirmation()
        XCTAssertEqual(approvals, 1, "An expired confirmation never runs the action")
        XCTAssertEqual(cancels, 1)
        XCTAssertNil(model.pendingConfirmation)
    }

    @MainActor
    func testApprovedCleanupStillPassesSandboxAndSafetyChecks() async throws {
        let root = try fixture()
        let file = root.appendingPathComponent("old.zip")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: file.path)
        let model = AppModel(confirmation: { _, _ in true })
        var reviewed = item(file)
        reviewed.snapshot = try FileSnapshotReader.capture(file)
        model.items = [reviewed]
        model.cleanSelectedItems()
        for _ in 0..<300 where model.status != .complete { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.logText.contains("Test sandbox is on"), model.logText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The sandbox refuses a temp file outside it")
    }
}
