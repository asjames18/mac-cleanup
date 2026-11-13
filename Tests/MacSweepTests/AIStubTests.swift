import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

final class AIStubTests: XCTestCase {
    private func item(_ url: URL, category: CleanupCategory, group: String? = nil) -> CleanupItem {
        CleanupItem(id: category.rawValue + url.path, url: url, category: category, size: 2_048, modifiedAt: .distantPast,
                    kind: "File", reason: "Fixture", safetyNote: "", duplicateGroupID: group, isSelected: false)
    }

    func testNoRecommendationsWhileOffOrWithRemoteProvider() {
        let items = [item(URL(fileURLWithPath: "/fixture/Downloads/a.dmg"), category: .downloads)]
        XCTAssertTrue(AIRecommender.recommendations(settings: .dormant, items: items).isEmpty)
        var remote = AISettings.dormant; remote.enabled = true; remote.provider = .openai
        XCTAssertTrue(AIRecommender.recommendations(settings: remote, items: items).isEmpty, "Remote providers are not connected")
    }

    func testRulesKeepOldestDuplicateCopy() {
        var on = AISettings.dormant; on.enabled = true
        let a = item(URL(fileURLWithPath: "/fixture/a.bin"), category: .duplicates, group: "g")
        let b = item(URL(fileURLWithPath: "/fixture/b.bin"), category: .duplicates, group: "g")
        let recs = AIRecommender.recommendations(settings: on, items: [a, b])
        XCTAssertEqual(recs.map(\.id), ["duplicate-copies"])
        guard case .moveToTrash(let urls) = recs[0].action else { return XCTFail() }
        XCTAssertEqual(urls.count, 1, "One copy of each group is always kept")
    }

    @MainActor
    func testApplyNeedsAIOnAndAlwaysAsksFirst() async throws {
        let root = ProtectionRules.canonicalTrustedRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("old.dmg")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: file.path)
        let answers = Answers()
        let model = AppModel(confirmation: { title, _ in answers.asked.append(title); return answers.answer })
        var download = item(file, category: .downloads)
        download.snapshot = try FileSnapshotReader.capture(file)
        model.items = [download]
        let rec = AIRecommendation(id: "t", title: "Move 1 old downloads to Trash", detail: "", action: .moveToTrash([file]), reversible: true)

        XCTAssertFalse(model.applyAIRecommendation(rec), "AI is off by default")
        XCTAssertTrue(answers.asked.isEmpty)

        var on = AISettings.dormant; on.enabled = true
        XCTAssertNil(model.saveAISettings(on))
        XCTAssertTrue(model.applyAIRecommendation(rec))
        XCTAssertEqual(answers.asked, ["Do you really want to do this action?"])
        XCTAssertFalse(model.isBusy, "Declining runs nothing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        answers.answer = true
        XCTAssertTrue(model.applyAIRecommendation(rec))
        for _ in 0..<300 where model.status != .complete { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.logText.contains("Test sandbox is on"), "An approved AI action still passes the sandbox and safety checks")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    func testSaveRejectsKeyValues() {
        let model = AppModel()
        var draft = AISettings.dormant
        draft.keyEnv = "sk-or-v1-0123456789abcdef0123456789abcdef"
        XCTAssertNotNil(model.saveAISettings(draft))
        XCTAssertEqual(model.aiSettings, .dormant)
    }

    func testAISourcesContainNoNetworkClient() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/MacSweep/Services/AIRecommendations.swift", "Sources/MacSweepCore/AISettings.swift"] {
            let text = try String(contentsOf: tests.appendingPathComponent(path), encoding: .utf8)
            for word in ["URLSession", "URLRequest", "NWConnection", "CFNetwork", "dataTask"] {
                XCTAssertFalse(text.contains(word), "\(path) must not contain \(word)")
            }
        }
    }
}
