import Foundation
import XCTest
@testable import MacSweepCore

final class AISettingsTests: XCTestCase {
    func testDormantDefaultsAreOffAndLocal() {
        let ai = AISettings.dormant
        XCTAssertFalse(ai.enabled)
        XCTAssertEqual(ai.provider, .rules)
        XCTAssertEqual(ai.baseURL, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(ai.keyEnv, "OPENROUTER_API_KEY")
        XCTAssertFalse(MacSweepSettings().ai.enabled)
    }

    func testEnvNamesAccepted() throws {
        for name in ["OPENROUTER_API_KEY", "OPENAI_API_KEY", "_LOCAL", "lmstudio_key2", ""] {
            XCTAssertTrue(AISettings.isEnvName(name), name)
            var ai = AISettings.dormant; ai.keyEnv = name
            XCTAssertNoThrow(try ai.validated(), name)
        }
        for bad in ["1KEY", "MY-KEY", "KEY NAME", "KÉY", String(repeating: "A", count: 65)] {
            XCTAssertFalse(AISettings.isEnvName(bad), bad)
        }
    }

    func testKeyValuesAreRejected() {
        for secret in ["sk-proj-abcdefghijklmnop1234", "sk-or-v1-0123456789abcdef0123456789abcdef", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456",
                       "AKIAIOSFODNN7EXAMPLE", "AIzaSyD-1234567890abcdefghijklmnop", "Bearer abcdefghijklmnop", "a1b2c3d4e5f6g7h8i9j0k1l2"] {
            var ai = AISettings.dormant; ai.keyEnv = secret
            XCTAssertThrowsError(try ai.validated(), secret) { error in
                XCTAssertEqual(error as? AISettings.ValidationError, .looksLikeKeyValue, secret)
            }
        }
        var model = AISettings.dormant; model.model = "sk-proj-abcdefghijklmnop1234"
        XCTAssertThrowsError(try model.validated(), "A key pasted into the model field is rejected too")
    }

    func testEndpoints() {
        for ok in ["http://127.0.0.1:1234/v1", "http://localhost:11434/v1", "https://openrouter.ai/api/v1", ""] { XCTAssertTrue(AISettings.isEndpoint(ok), ok) }
        for bad in ["ftp://host", "file:///etc/passwd", "https://user:pass@host/v1", "https://host/v1?key=abc", "http://", "not a url", "javascript:alert(1)"] {
            XCTAssertFalse(AISettings.isEndpoint(bad), bad)
        }
    }

    func testStoredKeyValueIsDroppedOnLoadAndAITurnedOff() throws {
        let json = #"{"version":1,"sandboxEnabled":true,"ai":{"enabled":true,"provider":"openai","baseURL":"https://openrouter.ai/api/v1","model":"x","keyEnv":"sk-or-v1-0123456789abcdef0123456789abcdef"}}"#
        let settings = try JSONCoding.decoder().decode(MacSweepSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.ai.enabled)
        XCTAssertEqual(settings.ai.keyEnv, "OPENROUTER_API_KEY")
        let encoded = String(decoding: try JSONCoding.encoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(encoded.contains("sk-or"))
    }

    func testUnknownProviderFallsBackToRules() throws {
        let json = #"{"ai":{"enabled":false,"provider":"cloud-magic"}}"#
        let settings = try JSONCoding.decoder().decode(MacSweepSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.ai.provider, .rules)
        XCTAssertTrue(settings.sandboxEnabled)
    }
}
