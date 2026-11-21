import Foundation
import XCTest
@testable import MacSweepCore

final class SuggestionModelTests: XCTestCase {
    private let caps = SuggestionCapabilities(trashableCategories: ["caches", "logs"], duplicateCopies: true,
                                              brokenStartupIDs: ["user:com.example.gone"], reviewTabs: ["maintenance"])

    private func facts(_ action: SuggestionAction) -> SuggestionFacts? {
        switch action {
        case .trashCategory("caches"): SuggestionFacts(bytes: 500, risk: .low, reversible: true, itemCount: 3)
        case .trashCategory("logs"): SuggestionFacts(bytes: 0, risk: .low, reversible: true, itemCount: 0)
        case .trashDuplicateCopies: SuggestionFacts(bytes: 9_000, risk: .medium, reversible: true, itemCount: 2)
        case .disableStartupItem: SuggestionFacts(bytes: 0, risk: .low, reversible: true, itemCount: 1)
        case .review: SuggestionFacts(bytes: 0, risk: .none, reversible: true, itemCount: 0)
        default: nil
        }
    }

    func testParserReadsJSONModeFencesAndProse() {
        let json = #"{"recommendations":[{"title":"Clear caches","reason":"Apps rebuild them","action":{"type":"trash_category","category":"caches"}}]}"#
        XCTAssertEqual(SuggestionResponseParser.parse(json).map(\.action), [.trashCategory("caches")])
        XCTAssertEqual(SuggestionResponseParser.parse("```json\n\(json)\n```").count, 1)
        XCTAssertEqual(SuggestionResponseParser.parse("Sure! Here you go: \(json) Hope that helps.").count, 1)
        let list = #"[{"title":"Look","action":{"type":"review","tab":"maintenance"}}]"#
        XCTAssertEqual(SuggestionResponseParser.parse(list).map(\.action), [.review("maintenance")])
        XCTAssertTrue(SuggestionResponseParser.parse("not json at all").isEmpty)
    }

    func testParserDropsAnythingOutsideTheFourActionShapes() {
        let json = #"""
        {"recommendations":[
          {"title":"Empty the Trash","action":{"type":"empty_trash"}},
          {"title":"Delete these","action":{"type":"recycle","paths":["/Users/x/Documents/a.pdf"]}},
          {"title":"Run this","action":{"type":"shell","command":"rm -rf ~"}},
          {"title":"No action"},
          {"action":{"type":"trash_category","category":"caches"}},
          {"title":"Extra copies","action":{"type":"trash_duplicate_copies"}}
        ]}
        """#
        XCTAssertEqual(SuggestionResponseParser.parse(json).map(\.action), [.trashDuplicateCopies])
    }

    func testParserCapsItemsAndText() {
        let one = #"{"title":"\#(String(repeating: "t", count: 500))","reason":"\#(String(repeating: "r", count: 900))","action":{"type":"review","tab":"maintenance"}}"#
        let json = "{\"recommendations\":[" + Array(repeating: one, count: 40).joined(separator: ",") + "]}"
        let parsed = SuggestionResponseParser.parse(json)
        XCTAssertEqual(parsed.count, SuggestionResponseParser.maximumItems)
        XCTAssertEqual(parsed[0].title.count, 120)
        XCTAssertEqual(parsed[0].reason.count, 300)
    }

    func testCapabilitiesRevalidateEveryAction() {
        XCTAssertNotNil(caps.validate(.trashCategory("caches")))
        XCTAssertNil(caps.validate(.trashCategory("largeFiles")), "Only allowlisted categories")
        XCTAssertNil(caps.validate(.trashCategory("../Documents")))
        XCTAssertNil(caps.validate(.disableStartupItem("user:com.example.fine")), "Only items the app found broken")
        XCTAssertNil(caps.validate(.review("settings")))
        XCTAssertNil(SuggestionCapabilities().validate(.trashDuplicateCopies))
        XCTAssertEqual(caps.allowlist.count, 5)
    }

    func testMergeUsesAppFactsDedupesAndSortsBySize() {
        let rules = [SuggestionProposal(title: "Clear app caches", reason: "rules", action: .trashCategory("caches")),
                     SuggestionProposal(title: "Review", reason: "", action: .review("maintenance"))]
        let ai = [SuggestionProposal(title: "Free 50 GB of caches!", reason: "AI says so", action: .trashCategory("caches")),
                  SuggestionProposal(title: "Remove copies", reason: "dupes", action: .trashDuplicateCopies),
                  SuggestionProposal(title: "Logs", reason: "", action: .trashCategory("logs")),
                  SuggestionProposal(title: "Not allowed", reason: "", action: .trashCategory("largeFiles")),
                  SuggestionProposal(title: "Startup", reason: "", action: .disableStartupItem("user:com.example.gone"))]
        let cards = SuggestionMerger.merge(rules: rules, ai: ai, capabilities: caps, facts: facts)
        XCTAssertEqual(cards.map(\.id), ["duplicates", "trash:caches", "startup:user:com.example.gone", "review:maintenance"])
        let caches = cards[1]
        XCTAssertEqual(caches.source, .both)
        XCTAssertEqual(caches.title, "Free 50 GB of caches!")
        XCTAssertEqual(caches.facts.bytes, 500, "The app's own size, never the model's number")
        XCTAssertEqual(cards[0].source, .ai)
        XCTAssertEqual(cards.last?.source, .rules)
        XCTAssertFalse(cards.contains { $0.id == "trash:logs" }, "An action with nothing to move is dropped")
    }

    func testSkipListHidesRefusedForFourteenDaysAndPersists() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var skip = SuggestionSkipList()
        skip.refuse("startup:user:a", now: now)
        XCTAssertTrue(skip.isHidden("startup:user:a", now: now.addingTimeInterval(13 * 86_400)))
        XCTAssertFalse(skip.isHidden("startup:user:a", now: now.addingTimeInterval(15 * 86_400)))
        XCTAssertFalse(skip.isHidden("other", now: now))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try skip.save(to: root)
        XCTAssertEqual(SuggestionSkipList.load(from: root).refused.keys.sorted(), ["startup:user:a"])
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(SuggestionSkipList.fileName).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        skip.prune(now: now.addingTimeInterval(20 * 86_400))
        XCTAssertTrue(skip.refused.isEmpty)
        try Data("{ broken".utf8).write(to: root.appendingPathComponent(SuggestionSkipList.fileName))
        XCTAssertEqual(SuggestionSkipList.load(from: root), SuggestionSkipList(), "A bad file means nothing is hidden")
    }

    func testFilterCountsHidden() {
        let now = Date()
        let cards = SuggestionMerger.merge(rules: [SuggestionProposal(title: "A", reason: "", action: .trashCategory("caches")),
                                                   SuggestionProposal(title: "B", reason: "", action: .trashDuplicateCopies),
                                                   SuggestionProposal(title: "C", reason: "", action: .disableStartupItem("user:com.example.gone"))],
                                           ai: [], capabilities: caps, facts: facts)
        var skip = SuggestionSkipList(); skip.refuse("startup:user:com.example.gone", now: now)
        let visible = SuggestionFilter.visible(cards, applied: ["duplicates"], skip: skip, now: now)
        XCTAssertEqual(visible.cards.map(\.id), ["trash:caches"])
        XCTAssertEqual(visible.hidden, 2)
    }

    func testTimeoutDefaultsAndClamps() throws {
        XCTAssertEqual(AISettings.dormant.timeoutSeconds, 45)
        var ai = AISettings.dormant; ai.timeoutSeconds = 3
        XCTAssertEqual(try ai.validated().timeoutSeconds, 10)
        ai.timeoutSeconds = 9_999
        XCTAssertEqual(try ai.validated().timeoutSeconds, 120)
        let old = try JSONCoding.decoder().decode(AISettings.self, from: Data(#"{"enabled":false}"#.utf8))
        XCTAssertEqual(old.timeoutSeconds, 45, "Settings saved by older versions get the default")
    }
}
