import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import MacSweepCore
@testable import MacSweep

/// Every test here uses the in-memory key store and a stub transport.
/// No test reads or writes the login Keychain, and none reaches the network.
final class AIKeyStoreTests: XCTestCase {
    private static let secret = "sk-or-v1-fedcba9876543210fedcba9876543210"

    private func settings(keyEnv: String = "") -> AISettings {
        AISettings(enabled: true, provider: .openai, baseURL: "https://openrouter.ai/api/v1", model: "m", keyEnv: keyEnv, timeoutSeconds: 10)
    }

    private let reply = #"{"model":"m","choices":[{"message":{"content":"{\"recommendations\":[]}"}}]}"#

    func testMemoryStoreCleansAndRejects() throws {
        let store = InMemoryAIKeyStore()
        XCTAssertFalse(store.hasKey())
        XCTAssertThrowsError(try store.save("   ")) { XCTAssertEqual($0 as? AIKeyStoreError, .empty) }
        XCTAssertThrowsError(try store.save("sk-abc def")) { XCTAssertEqual($0 as? AIKeyStoreError, .invalid) }
        XCTAssertThrowsError(try store.save(String(repeating: "a", count: 4097))) { XCTAssertEqual($0 as? AIKeyStoreError, .invalid) }
        try store.save("  \(Self.secret)\n")
        XCTAssertTrue(store.hasKey())
        XCTAssertEqual(store.read(), Self.secret)
        try store.remove()
        XCTAssertFalse(store.hasKey())
        XCTAssertNil(store.read())
        for error in [AIKeyStoreError.empty, .invalid, .keychain(-25300)] {
            XCTAssertFalse(error.localizedDescription.contains(Self.secret))
        }
    }

    func testSavedKeyIsSentAndWinsOverTheEnvironment() async throws {
        let stub = AIClientTests.StubTransport([(reply, 200)])
        let client = AIClient(settings: settings(keyEnv: "TEST_AI_KEY"), transport: stub,
                              environment: ["TEST_AI_KEY": "env-value-should-not-be-used"], keyStore: InMemoryAIKeyStore(Self.secret))
        XCTAssertTrue(client.keyFound)
        _ = try await client.suggestions(snapshot: Data("{}".utf8))
        XCTAssertEqual(stub.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.secret)")
        XCTAssertEqual(client.scrub("bad key \(Self.secret) here"), "bad key ••• here")
    }

    func testEnvironmentIsOnlyAFallback() async throws {
        let stub = AIClientTests.StubTransport([(reply, 200)])
        let client = AIClient(settings: settings(keyEnv: "TEST_AI_KEY"), transport: stub,
                              environment: ["TEST_AI_KEY": Self.secret], keyStore: InMemoryAIKeyStore())
        _ = try await client.suggestions(snapshot: Data("{}".utf8))
        XCTAssertEqual(stub.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.secret)")

        let none = AIClientTests.StubTransport([(reply, 200)])
        _ = try await AIClient(settings: settings(), transport: none, environment: [:], keyStore: InMemoryAIKeyStore()).suggestions(snapshot: Data("{}".utf8))
        XCTAssertNil(none.requests.first?.value(forHTTPHeaderField: "Authorization"), "No key, no header (local servers)")
    }

    func testConnectionReportSaysSavedNeverTheKey() async {
        let stub = AIClientTests.StubTransport([(#"{"data":[{"id":"m"}]}"#, 200)])
        let report = await AIClient(settings: settings(), transport: stub, environment: [:], keyStore: InMemoryAIKeyStore(Self.secret)).testConnection()
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.keyFound)
        XCTAssertTrue(report.message.contains("key saved in Keychain"), report.message)
        XCTAssertFalse(report.message.contains(Self.secret))
    }

    @MainActor
    func testTestsNeverGetTheRealKeychain() {
        XCTAssertTrue(AIKeyStores.live() is InMemoryAIKeyStore, "Outside the .app bundle the Keychain is never used")
        XCTAssertTrue(AppModel().aiKeyStore is InMemoryAIKeyStore)
    }

    @MainActor
    func testModelSavesReplacesAndRemovesWithoutLeaking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(settingsStore: try SettingsStore(root: root))
        let store = InMemoryAIKeyStore()
        model.aiKeyStore = store
        model.refreshAIKeyStatus()
        XCTAssertFalse(model.aiKeySaved)
        XCTAssertNotNil(model.saveAIKey(" "))
        XCTAssertFalse(model.aiKeySaved)

        XCTAssertNil(model.saveAIKey(Self.secret))
        XCTAssertTrue(model.aiKeySaved)
        XCTAssertEqual(store.read(), Self.secret)
        XCTAssertNil(model.saveAIKey(Self.secret + "2"))
        XCTAssertEqual(store.read(), Self.secret + "2")

        var draft = settings()
        XCTAssertNil(model.saveAISettings(draft))
        let encoded = String(decoding: try JSONEncoder().encode(model.aiSettings), as: UTF8.self)
        XCTAssertFalse(encoded.contains(Self.secret), "Settings never hold the key")
        draft.keyEnv = Self.secret
        XCTAssertNotNil(model.saveAISettings(draft), "A key pasted into the variable field is rejected")

        XCTAssertNil(model.removeAIKey())
        XCTAssertFalse(model.aiKeySaved)
        XCTAssertNil(store.read())
        XCTAssertFalse(model.logText.contains("fedcba9876543210"), "The key is never shown in the log")
        let actions = try String(contentsOf: root.appendingPathComponent("logs/actions.log"), encoding: .utf8)
        XCTAssertTrue(actions.contains("AI key replaced in the Keychain."), actions)
        XCTAssertTrue(actions.contains("AI key removed from the Keychain."))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fedcba9876543210"), "\(file.lastPathComponent) must never hold the key")
        }
    }

    /// Keychain calls live in exactly one file, so they are easy to audit.
    func testKeychainCodeOnlyInAIKeyStore() throws {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 20)
        for file in files where file.lastPathComponent != "AIKeyStore.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in ["SecItem", "kSecClass", "kSecValueData"] {
                XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) must not contain \(word)")
            }
        }
    }
}
