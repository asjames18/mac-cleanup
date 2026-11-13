import Foundation

/// Dormant AI settings. Only the *name* of an environment variable is ever stored, never a key.
/// This build has no network client: nothing is sent anywhere, whatever these values are.
public struct AISettings: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable {
        case rules   // local rules only
        case openai  // OpenAI-compatible endpoint (LM Studio, Ollama, OpenRouter); not connected in this build
    }

    public var enabled: Bool
    public var provider: Provider
    public var baseURL: String
    public var model: String
    public var keyEnv: String

    public init(enabled: Bool = false, provider: Provider = .rules, baseURL: String = "http://127.0.0.1:1234/v1",
                model: String = "", keyEnv: String = "OPENROUTER_API_KEY") {
        self.enabled = enabled
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.keyEnv = keyEnv
    }

    public static let dormant = AISettings()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AISettings.dormant
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        provider = (try? c.decodeIfPresent(Provider.self, forKey: .provider)) ?? fallback.provider
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? fallback.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? fallback.model
        keyEnv = try c.decodeIfPresent(String.self, forKey: .keyEnv) ?? fallback.keyEnv
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case invalidEnvName, looksLikeKeyValue, invalidEndpoint, modelTooLong

        public var errorDescription: String? {
            switch self {
            case .invalidEnvName: "Enter the name of an environment variable, such as OPENROUTER_API_KEY (letters, digits and _)."
            case .looksLikeKeyValue: "That looks like an API key. MacSweep stores only the variable name, never the key itself."
            case .invalidEndpoint: "The base URL must be http or https, with a host and no user name, password or query."
            case .modelTooLong: "The model name is too long (120 characters at most)."
            }
        }
    }

    /// Environment variable names: a letter or _, then letters, digits or _, at most 64 characters. Empty is allowed.
    public static func isEnvName(_ value: String) -> Bool {
        if value.isEmpty { return true }
        guard value.count <= 64, let first = value.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first), first.isASCII else { return false }
        return value.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) }
    }

    /// Heuristic: known key prefixes, or a long mixed string with no underscore (variable names use _).
    public static func looksLikeSecret(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let prefixes = ["sk-", "sk_", "pk-", "rk-", "ghp_", "gho_", "ghs_", "github_pat_", "xox", "akia", "asia", "aiza", "bearer ", "eyj", "glpat-", "hf_"]
        if prefixes.contains(where: { lower.hasPrefix($0) }) && trimmed.count >= 12 { return true }
        let hasDigit = trimmed.contains(where: \.isNumber)
        let hasLetter = trimmed.contains(where: \.isLetter)
        return trimmed.count >= 20 && !trimmed.contains("_") && hasDigit && hasLetter
    }

    public static func isEndpoint(_ value: String) -> Bool {
        if value.isEmpty { return true }
        guard !value.contains(where: \.isWhitespace), let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return false }
        return true
    }

    /// Returns a cleaned copy or throws; never stores a key value.
    public func validated() throws -> AISettings {
        var copy = self
        copy.keyEnv = keyEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.looksLikeSecret(copy.keyEnv) || Self.looksLikeSecret(copy.model) { throw ValidationError.looksLikeKeyValue }
        guard Self.isEnvName(copy.keyEnv) else { throw ValidationError.invalidEnvName }
        guard Self.isEndpoint(copy.baseURL) else { throw ValidationError.invalidEndpoint }
        guard copy.model.count <= 120 else { throw ValidationError.modelTooLong }
        return copy
    }

    /// Used on load: anything invalid falls back to the dormant value and turns AI off.
    public func sanitized() -> AISettings {
        if let valid = try? validated() { return valid }
        var copy = AISettings.dormant
        copy.provider = provider
        return copy
    }
}
