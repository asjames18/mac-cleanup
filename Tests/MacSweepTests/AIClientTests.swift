import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import MacSweepCore
@testable import MacSweep

/// Every test uses a stub transport. No test reaches the network.
final class AIClientTests: XCTestCase {
    final class StubTransport: AITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [(Data, Int)]
        private(set) var requests: [URLRequest] = []
        var delay: UInt64 = 0

        init(_ replies: [(String, Int)]) { self.replies = replies.map { (Data($0.0.utf8), $0.1) } }

        func send(_ request: URLRequest) async throws -> (Data, Int) {
            let reply: (Data, Int) = lock.withLock {
                requests.append(request)
                return replies.isEmpty ? (Data(), 500) : replies.removeFirst()
            }
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            return reply
        }

        var bodies: [[String: Any]] {
            requests.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        }
    }

    private static let secret = "sk-or-v1-0123456789abcdef0123456789abcdef"

    private func settings(model: String = "test/model") -> AISettings {
        AISettings(enabled: true, provider: .openai, baseURL: "https://openrouter.ai/api/v1/", model: model, keyEnv: "TEST_AI_KEY", timeoutSeconds: 10)
    }

    private func chat(_ content: String) -> String {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [content], options: [.fragmentsAllowed]), encoding: .utf8)!
        return #"{"model":"test/model","choices":[{"finish_reason":"stop","message":{"content":"# + escaped.dropFirst().dropLast() + "}}]}"
    }

    func testJSONModeRequestUsesKeyFromEnvironmentAndParses() async throws {
        let answer = #"{"recommendations":[{"title":"Clear caches","reason":"r","action":{"type":"trash_category","category":"caches"}}]}"#
        let stub = StubTransport([(chat(answer), 200)])
        let client = AIClient(settings: settings(), transport: stub, environment: ["TEST_AI_KEY": Self.secret])
        let result = try await client.suggestions(snapshot: Data(#"{"categories":[]}"#.utf8))
        XCTAssertEqual(result.proposals.map(\.action), [.trashCategory("caches")])
        XCTAssertTrue(result.jsonMode)
        XCTAssertEqual(stub.requests.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.secret)")
        XCTAssertNotNil(stub.bodies.first?["response_format"])
        XCTAssertEqual(request.timeoutInterval, 10, accuracy: 1)
    }

    func testFallsBackWithoutJSONModeOn400() async throws {
        let answer = #"Here: {"recommendations":[{"title":"Look","action":{"type":"review","tab":"maintenance"}}]}"#
        let stub = StubTransport([(#"{"error":{"message":"response_format not supported"}}"#, 400), (chat(answer), 200)])
        let client = AIClient(settings: settings(), transport: stub, environment: [:])
        let result = try await client.suggestions(snapshot: Data("{}".utf8))
        XCTAssertFalse(result.jsonMode)
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertNil(stub.bodies.last?["response_format"])
        XCTAssertNil(stub.requests.last?.value(forHTTPHeaderField: "Authorization"), "No key variable set means no header")
        XCTAssertEqual(result.proposals.count, 1)
    }

    func testHardDeadline() async {
        let stub = StubTransport([(chat("{}"), 200)])
        stub.delay = 5_000_000_000
        let client = AIClient(settings: settings(), transport: stub, environment: [:])
        let started = Date()
        do {
            _ = try await client.withDeadline(1) { try await client.suggestions(snapshot: Data("{}".utf8)) }
            XCTFail("Should time out")
        } catch {
            XCTAssertEqual(error as? AIError, .timedOut(1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testErrorsNeverShowTheKey() async {
        let stub = StubTransport([(#"{"error":{"message":"bad key \#(Self.secret)"}}"#, 401)])
        let client = AIClient(settings: settings(), transport: stub, environment: ["TEST_AI_KEY": Self.secret])
        do {
            _ = try await client.suggestions(snapshot: Data("{}".utf8))
            XCTFail("Should fail")
        } catch {
            let text = client.scrub(error.localizedDescription)
            XCTAssertFalse(text.contains(Self.secret))
            XCTAssertTrue(text.contains("401"))
        }
        let report = await AIClient(settings: settings(), transport: StubTransport([(#"{"error":"nope \#(Self.secret)"}"#, 403)]),
                                    environment: ["TEST_AI_KEY": Self.secret]).testConnection()
        XCTAssertFalse(report.ok)
        XCTAssertFalse(report.message.contains(Self.secret))
    }

    func testConnectionTestAndModelListUseGETModels() async throws {
        let list = #"{"data":[{"id":"b/model"},{"id":"test/model"},{"id":"a/model"}]}"#
        let stub = StubTransport([(list, 200), (list, 200)])
        let client = AIClient(settings: settings(), transport: stub, environment: [:])
        let report = await client.testConnection()
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.modelCount, 3)
        XCTAssertEqual(report.modelFound, true)
        XCTAssertFalse(report.keyFound)
        XCTAssertTrue(report.message.contains("no key saved"), report.message)
        let ids = try await client.models()
        XCTAssertEqual(ids, ["a/model", "b/model", "test/model"])
        XCTAssertEqual(stub.requests.map(\.httpMethod), ["GET", "GET"])
        XCTAssertEqual(stub.requests.first?.url?.path, "/api/v1/models")
    }

    func testNotConfiguredNeverSends() async {
        let stub = StubTransport([])
        var rules = settings(); rules.provider = .rules
        for candidate in [rules, settings(model: "")] {
            do { _ = try await AIClient(settings: candidate, transport: stub, environment: [:]).suggestions(snapshot: Data()); XCTFail() }
            catch { XCTAssertNotNil(error as? AIError) }
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }
}
