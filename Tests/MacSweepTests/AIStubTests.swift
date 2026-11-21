import Foundation
import XCTest
import MacSweepCore
@testable import MacSweep

/// Suggestions: built-in rules, AI merge, list behavior and the confirm step. No test reaches the network.
final class AIStubTests: XCTestCase {
    private func item(_ url: URL, category: CleanupCategory, size: Int64 = 2_048, group: String? = nil,
                      modified: Date = .distantPast) -> CleanupItem {
        CleanupItem(id: category.rawValue + url.path, url: url, category: category, size: size, modifiedAt: modified,
                    kind: "File", reason: "Fixture", safetyNote: "", duplicateGroupID: group, isSelected: false)
    }

    private func fixtureItems() -> [CleanupItem] {
        [item(URL(fileURLWithPath: "/fixture/Library/Caches/com.example.app"), category: .caches, size: 80_000_000),
         item(URL(fileURLWithPath: "/fixture/Library/Logs/DiagnosticReports/a.ips"), category: .crashReports, size: 6_000_000),
         item(URL(fileURLWithPath: "/fixture/Downloads/secret-plan.zip"), category: .downloads, size: 3_000),
         item(URL(fileURLWithPath: "/fixture/Documents/a.bin"), category: .duplicates, size: 5_000, group: "g", modified: Date(timeIntervalSince1970: 1)),
         item(URL(fileURLWithPath: "/fixture/Documents/b.bin"), category: .duplicates, size: 5_000, group: "g", modified: Date(timeIntervalSince1970: 2)),
         item(URL(fileURLWithPath: "/fixture/Downloads/Old.dmg"), category: .oldInstallers, size: 90_000_000)]
    }

    private func store() throws -> SettingsStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try MainActor.assumeIsolated { try SettingsStore(root: root) }
    }

    func testRulesCoverCategoriesDuplicatesAndReviewLinks() {
        let context = SuggestionContext(items: fixtureItems())
        let ids = SuggestionEngine.cards(context).map(\.id)
        XCTAssertEqual(Set(ids), ["trash:caches", "trash:crashReports", "trash:downloads", "duplicates", "review:old-installers"])
        XCTAssertEqual(ids.first, "trash:caches", "Largest first")
        XCTAssertEqual(ids.last, "review:old-installers", "Review links come after actions")
        XCTAssertEqual(SuggestionEngine.targets(.trashDuplicateCopies, context).map(\.lastPathComponent), ["b.bin"], "Keeps the oldest copy")
        var newest = context; newest.keep = .newest
        XCTAssertEqual(SuggestionEngine.targets(.trashDuplicateCopies, newest).map(\.lastPathComponent), ["a.bin"], "Keeps the newest copy")
        XCTAssertTrue(SuggestionEngine.targets(.trashCategory("oldInstallers"), context).isEmpty, "Review-only categories are never bulk targets")
        XCTAssertTrue(SuggestionEngine.targets(.trashCategory("largeFiles"), context).isEmpty)
    }

    func testSnapshotHasNoPathsOrFileNames() throws {
        let broken = StartupDefinition(id: "/fixture/Library/LaunchAgents/com.example.gone.plist",
                                       url: URL(fileURLWithPath: "/fixture/Library/LaunchAgents/com.example.gone.plist"),
                                       label: "com.example.gone", displayName: "gone-helper", source: .userLaunchAgents,
                                       program: "/Volumes/External/gone-helper", runAtLoad: true, keepAlive: nil,
                                       brokenReason: "The drive “External” it starts from isn't connected.")
        let data = SuggestionEngine.snapshot(SuggestionContext(items: fixtureItems(), startup: [broken]))
        let text = String(decoding: data, as: UTF8.self)
        for leak in ["/fixture", "secret-plan", "a.bin", "Old.dmg", "External", "/Volumes", "LaunchAgents/"] {
            XCTAssertFalse(text.contains(leak), "Snapshot must not contain \(leak)")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["allowed_actions"])
        XCTAssertTrue(text.contains("user:com.example.gone"))
        XCTAssertTrue(text.contains("drive not connected"))
    }

    @MainActor
    func testNothingShowsOrAppliesWhileOff() {
        let model = AppModel()
        model.items = fixtureItems()
        model.rebuildSuggestions()
        XCTAssertTrue(model.suggestionCards.isEmpty)
        let card = SuggestionEngine.cards(SuggestionContext(items: fixtureItems()))[0]
        XCTAssertFalse(model.applySuggestion(card), "Suggestions are off by default")
    }

    @MainActor
    func testApplyRemovesOnlyThatCardUntilNextScanAndRefusedHideFor14Days() async throws {
        let settings = try store()
        let model = AppModel(cleanerScan: { _, _ in ScanReport(items: [], storageItems: [], messages: []) }, settingsStore: settings)
        var on = AISettings.dormant; on.enabled = true
        XCTAssertNil(model.saveAISettings(on))
        model.items = fixtureItems()
        model.rebuildSuggestions()
        let before = model.suggestionCards.map(\.id)
        XCTAssertEqual(before.count, 5)

        model.recordSuggestionOutcome(model.suggestionCards[0], applied: true, refused: false)
        XCTAssertEqual(model.suggestionCards.map(\.id), Array(before.dropFirst()), "Only the applied card goes; the order stays")
        XCTAssertEqual(model.hiddenSuggestionCount, 1)

        let refusedCard = model.suggestionCards[0]
        model.recordSuggestionOutcome(refusedCard, applied: false, refused: true)
        XCTAssertEqual(model.hiddenSuggestionCount, 2)
        let skip = SuggestionSkipList.load(from: settings.store.root)
        XCTAssertNotNil(skip.refused[refusedCard.id], "Refused suggestions are remembered in rec-skip.json")

        model.recordSuggestionOutcome(model.suggestionCards[0], applied: false, refused: false)
        XCTAssertEqual(model.hiddenSuggestionCount, 2, "A cancelled or empty apply keeps the card")

        model.scan()
        for _ in 0..<300 where model.status != .complete { try await Task.sleep(for: .milliseconds(10)) }
        model.items = fixtureItems()
        model.rebuildSuggestions()
        XCTAssertEqual(model.hiddenSuggestionCount, 1, "A new Smart Scan brings applied cards back; refused stay hidden")
        XCTAssertFalse(model.suggestionCards.contains { $0.id == refusedCard.id })
    }

    @MainActor
    func testApplyAlwaysAsksAndStillPassesTheSandbox() async throws {
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
        var on = AISettings.dormant; on.enabled = true
        XCTAssertNil(model.saveAISettings(on))
        let card = try XCTUnwrap(model.suggestionCards.first { $0.id == "trash:downloads" })

        XCTAssertTrue(model.applySuggestion(card))
        XCTAssertEqual(answers.asked, ["Do you really want to do this action?"])
        XCTAssertFalse(model.isBusy, "Declining runs nothing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(model.suggestionCards.map(\.id), [card.id], "Declining keeps the card")

        answers.answer = true
        XCTAssertTrue(model.applySuggestion(card))
        for _ in 0..<300 where model.status != .complete { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.logText.contains("Test sandbox is on"), "An approved suggestion still passes the sandbox and safety checks")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(model.suggestionCards.map(\.id), [card.id], "Nothing moved, so the card stays")
    }

    @MainActor
    func testAskAIMergesValidatedPicksAndFallsBackOnError() async throws {
        let model = AppModel()
        model.aiEnvironment = [:]
        let reply = #"{"model":"m","choices":[{"message":{"content":"{\"recommendations\":[{\"title\":\"Clear crash reports now\",\"reason\":\"old\",\"action\":{\"type\":\"trash_category\",\"category\":\"crashReports\"}},{\"title\":\"Delete Documents\",\"action\":{\"type\":\"trash_category\",\"category\":\"largeFiles\"}},{\"title\":\"Empty Trash\",\"action\":{\"type\":\"empty_trash\"}}]}"}}]}"#
        let stub = AIClientTests.StubTransport([(reply, 200)])
        model.aiTransport = stub
        let settings = AISettings(enabled: true, provider: .openai, baseURL: "http://127.0.0.1:1234/v1", model: "m", keyEnv: "")
        XCTAssertNil(model.saveAISettings(settings))
        XCTAssertTrue(stub.requests.isEmpty, "Saving settings never contacts the AI")
        model.items = fixtureItems()
        model.rebuildSuggestions()
        XCTAssertTrue(stub.requests.isEmpty, "Building cards never contacts the AI")

        await model.askAI()
        XCTAssertEqual(stub.requests.count, 1)
        let crash = try XCTUnwrap(model.suggestionCards.first { $0.id == "trash:crashReports" })
        XCTAssertEqual(crash.source, .both)
        XCTAssertEqual(crash.title, "Clear crash reports now")
        XCTAssertEqual(crash.facts.bytes, 6_000_000)
        XCTAssertFalse(model.suggestionCards.contains { $0.id == "trash:largeFiles" })
        XCTAssertTrue(model.aiStatus?.contains("1 of 2 picks passed") == true, model.aiStatus ?? "")

        model.aiTransport = AIClientTests.StubTransport([("oops", 500)])
        await model.askAI()
        XCTAssertTrue(model.aiStatus?.contains("Showing the built-in rules") == true)
        XCTAssertFalse(model.suggestionCards.isEmpty)
    }

    @MainActor
    func testSaveRejectsKeyValues() {
        let model = AppModel()
        var draft = AISettings.dormant
        draft.keyEnv = "sk-or-v1-0123456789abcdef0123456789abcdef"
        XCTAssertNotNil(model.saveAISettings(draft))
        XCTAssertEqual(model.aiSettings, .dormant)
    }

    /// Network code lives in exactly one file, so it is easy to audit.
    func testNetworkCodeOnlyInAIClient() throws {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 20)
        for file in files where file.lastPathComponent != "AIClient.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in ["URLSession", "URLRequest", "NWConnection", "CFNetwork", "dataTask"] {
                XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) must not contain \(word)")
            }
        }
    }
}
