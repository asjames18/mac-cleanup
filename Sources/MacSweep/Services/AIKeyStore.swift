import Foundation
#if canImport(Security)
import Security
#endif

/// Where the optional AI key lives. The real app uses the macOS Keychain; tests use the in-memory store,
/// so no test ever reads or writes the login Keychain. The key is never logged, shown, or written to settings.
protocol AIKeyStore: Sendable {
    /// True when a key is saved. Checks attributes only, so it never reads the secret.
    func hasKey() -> Bool
    func read() -> String?
    func save(_ key: String) throws
    func remove() throws
}

enum AIKeyStoreError: Error, Equatable, LocalizedError {
    case empty
    case invalid
    case keychain(Int32)

    var errorDescription: String? {
        switch self {
        case .empty: "Paste the API key first."
        case .invalid: "That doesn't look like an API key (no spaces or line breaks, 4,096 characters at most)."
        case .keychain(let status): "The Keychain refused the change (error \(status))."
        }
    }

    /// Trims the pasted value and rejects anything that can't be a key. Never echoes the value.
    static func cleaned(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIKeyStoreError.empty }
        guard key.count <= 4096, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw AIKeyStoreError.invalid }
        return key
    }
}

/// Test and preview store. Lives only in memory.
final class InMemoryAIKeyStore: AIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) { self.value = value }

    func hasKey() -> Bool { lock.withLock { value != nil } }
    func read() -> String? { lock.withLock { value } }
    func save(_ key: String) throws {
        let cleaned = try AIKeyStoreError.cleaned(key)
        lock.withLock { value = cleaned }
    }
    func remove() throws { lock.withLock { value = nil } }
}

#if canImport(Security)
/// A generic password in the login Keychain, readable only while the Mac is unlocked and never synced to other devices.
struct KeychainAIKeyStore: AIKeyStore {
    static let account = "openai-compatible-api-key"
    static var defaultService: String { "\(Bundle.main.bundleIdentifier ?? "com.local.MacSweep").ai" }

    var service: String = KeychainAIKeyStore.defaultService

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    func hasKey() -> Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    func save(_ key: String) throws {
        let data = Data(try AIKeyStoreError.cleaned(key).utf8)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AIKeyStoreError.keychain(status) }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "MacSweep AI key"
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw AIKeyStoreError.keychain(added) }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIKeyStoreError.keychain(status) }
    }
}
#endif

enum AIKeyStores {
    /// The Keychain only inside the real app bundle; anything else (unit tests, swift run) gets a memory store.
    static func live() -> any AIKeyStore {
        #if canImport(Security)
        if Bundle.main.bundleURL.pathExtension == "app" { return KeychainAIKeyStore() }
        #endif
        return InMemoryAIKeyStore()
    }
}
