import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

@MainActor
final class Answers {
    var answer = false
    var asked: [String] = []
}

final class TestSandboxTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sandbox"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPolicyIsOnByDefaultAndRootedInApplicationSupport() {
        XCTAssertTrue(TestSandbox.policy.enabled)
        XCTAssertEqual(TestSandbox.policy, .standard)
        XCTAssertTrue(TestSandbox.defaultRoot.path.hasSuffix("Library/Application Support/MacSweep/test-sandbox"))
        XCTAssertNotNil(TestSandbox.refusal(for: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/file.zip")))
    }

    func testOnlyStrictDescendantsAreAllowed() throws {
        let root = try fixture()
        let policy = SandboxPolicy(enabled: true, root: root.appendingPathComponent("sandbox"))
        XCTAssertTrue(TestSandbox.allows(root.appendingPathComponent("sandbox/a.txt"), policy: policy))
        XCTAssertTrue(TestSandbox.allows(root.appendingPathComponent("SANDBOX/nested/b.txt"), policy: policy))
        XCTAssertFalse(TestSandbox.allows(root.appendingPathComponent("sandbox"), policy: policy), "The sandbox folder itself is never moved")
        XCTAssertFalse(TestSandbox.allows(root.appendingPathComponent("sandbox-other/a.txt"), policy: policy))
        XCTAssertFalse(TestSandbox.allows(root.appendingPathComponent("sandbox/../outside.txt"), policy: policy))
        XCTAssertFalse(TestSandbox.allows(root, policy: policy))
        XCTAssertTrue(TestSandbox.allows(root.appendingPathComponent("anywhere.txt"), policy: SandboxPolicy(enabled: false, root: policy.root)))
    }

    func testSymlinkInsideSandboxIsRefused() throws {
        let root = try fixture()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("sandbox/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let policy = SandboxPolicy(enabled: true, root: root.appendingPathComponent("sandbox"))
        XCTAssertFalse(TestSandbox.allows(link, policy: policy))
        XCTAssertFalse(TestSandbox.allows(link.appendingPathComponent("file"), policy: policy))
    }

    func testMoveOutsideSandboxNeverRecordsIntentOrCallsMover() throws {
        let root = try fixture()
        let outside = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: outside)
        let journal = CleanupJournal(directory: root.appendingPathComponent("journal"))
        var moverCalls = 0
        let result = TestSandbox.$policy.withValue(SandboxPolicy(enabled: true, root: root.appendingPathComponent("sandbox"))) {
            CleanupSafety.moveWithJournal(outside, journal: journal) { _ in moverCalls += 1; return nil }
        }
        XCTAssertEqual(moverCalls, 0)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(result.messages.joined().contains("Test sandbox is on"))
        XCTAssertTrue(try journal.entries().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testTrashOutsideSandboxIsRefusedEvenAfterValidation() throws {
        let root = try fixture()
        let outside = root.appendingPathComponent("old.zip")
        try Data(repeating: 1, count: 128).write(to: outside)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: outside.path)
        XCTAssertNoThrow(try CleanupSafety.validate(outside))
        let ledger = ConfirmationLedger()
        let preview = try XCTUnwrap(ledger.issue(paths: [outside.path]))
        let grant = try ledger.consume(token: preview.token).get()
        let result = TestSandbox.$policy.withValue(SandboxPolicy(enabled: true, root: root.appendingPathComponent("sandbox"))) {
            CleanupSafety.trash(grant)
        }
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testMoveInsideSandboxReachesMover() throws {
        let root = try fixture()
        let inside = root.appendingPathComponent("sandbox/sample.txt")
        try Data("sample".utf8).write(to: inside)
        let journal = CleanupJournal(directory: root.appendingPathComponent("journal"))
        var moverCalls = 0
        let result = TestSandbox.$policy.withValue(SandboxPolicy(enabled: true, root: root.appendingPathComponent("sandbox"))) {
            CleanupSafety.moveWithJournal(inside, journal: journal) { _ in moverCalls += 1; return nil }
        }
        XCTAssertEqual(moverCalls, 1)
        XCTAssertEqual(result.moved, [inside])
    }

    @MainActor
    func testPreferenceDefaultsOnAndTurningOffNeedsConfirmation() async throws {
        let suite = "MacSweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let answers = Answers()
        let scan: @Sendable ([URL], ScanPreset) -> ScanReport = { _, _ in
            ScanReport(items: [], storageItems: [], messages: [], coverageSummary: TestSandbox.policy.enabled ? "sandbox on" : "sandbox off")
        }
        let model = AppModel(cleanerScan: scan, sandboxPreferences: SandboxPreferences(defaults: defaults),
                             confirmation: { title, _ in answers.asked.append(title); return answers.answer })
        XCTAssertTrue(model.sandboxEnabled)

        XCTAssertFalse(model.setSandboxEnabled(false))
        XCTAssertTrue(model.sandboxEnabled)
        XCTAssertEqual(answers.asked, ["Do you really want to do this action?"])

        model.scan()
        for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.scanSummary.contains("sandbox on"), "Detached jobs carry the sandbox policy")

        answers.answer = true
        XCTAssertTrue(model.setSandboxEnabled(false))
        XCTAssertFalse(model.sandboxEnabled)
        XCTAssertFalse(AppModel(sandboxPreferences: SandboxPreferences(defaults: defaults)).sandboxEnabled)
        model.scan()
        for _ in 0..<200 where model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.scanSummary.contains("sandbox off"))

        XCTAssertTrue(model.setSandboxEnabled(true))
        XCTAssertEqual(answers.asked.count, 2, "Turning the sandbox on never asks")
        XCTAssertTrue(AppModel(sandboxPreferences: SandboxPreferences(defaults: defaults)).sandboxEnabled)
    }

    /// Opt-in: MACSWEEP_SANDBOX_SMOKE=1 moves one generated file from the real sandbox to the Trash.
    func testRealSandboxTrashMoveWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["MACSWEEP_SANDBOX_SMOKE"] == "1" else {
            throw XCTSkip("Set MACSWEEP_SANDBOX_SMOKE=1 to move a generated sandbox file to the Trash.")
        }
        let sandbox = try TestSandbox.prepare()
        let file = sandbox.appendingPathComponent("macsweep-smoke-\(UUID().uuidString).txt")
        try Data("MacSweep sandbox smoke test".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: file.path)
        let outside = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent("macsweep-outside-\(UUID().uuidString).txt")
        try Data("stay".utf8).write(to: outside)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: outside.path)
        defer { try? FileManager.default.removeItem(at: outside) }
        let journalRoot = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: journalRoot) }
        let journal = CleanupJournal(directory: journalRoot)

        try TestSandbox.$policy.withValue(.standard) {
            try CleanupSafety.validate(file)
            let moved = CleanupSafety.moveWithJournal(file, journal: journal)
            XCTAssertEqual(moved.moved, [file], moved.messages.joined(separator: "\n"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            let refused = CleanupSafety.moveWithJournal(outside, journal: journal)
            XCTAssertTrue(refused.moved.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
            print("SANDBOX SMOKE: moved \(file.lastPathComponent) to Trash; refused \(outside.path)")
        }
    }
}
