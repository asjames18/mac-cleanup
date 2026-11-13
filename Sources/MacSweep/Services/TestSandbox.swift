import Foundation

/// While the test sandbox is on, MacSweep may only move items that live inside
/// its sandbox folder. The check runs in `CleanupSafety.moveWithJournal`, the
/// single path every Trash move takes, so the UI cannot bypass it.
struct SandboxPolicy: Equatable, Sendable {
    var enabled: Bool
    var root: URL

    static var standard: SandboxPolicy { SandboxPolicy(enabled: true, root: TestSandbox.defaultRoot) }
    static var off: SandboxPolicy { SandboxPolicy(enabled: false, root: TestSandbox.defaultRoot) }
}

enum TestSandbox {
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacSweep/test-sandbox", isDirectory: true)
    }

    /// Safe by default: a job that never binds a policy runs with the sandbox on.
    @TaskLocal static var policy: SandboxPolicy = .standard

    /// Returns a refusal message, or nil when the move is allowed by the policy.
    static func refusal(for url: URL, policy: SandboxPolicy = TestSandbox.policy) -> String? {
        guard policy.enabled else { return nil }
        let root = policy.root
        let inside = ProtectionRules.contains(root, url)
            && ProtectionRules.normalizedPath(root).lowercased() != ProtectionRules.normalizedPath(url).lowercased()
        guard inside, !ProtectionRules.hasSymlinkComponent(url) else {
            return "Test sandbox is on. Only items inside \(root.path) can be moved to Trash. Turn the sandbox off in Settings to clean elsewhere."
        }
        return nil
    }

    static func allows(_ url: URL, policy: SandboxPolicy = TestSandbox.policy) -> Bool {
        refusal(for: url, policy: policy) == nil
    }

    /// Creates the sandbox folder with private permissions.
    @discardableResult
    static func prepare(_ root: URL = defaultRoot) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }
}

/// Persists the sandbox switch. A missing value means on.
@MainActor
struct SandboxPreferences {
    static let key = "testSandbox.enabled.v1"
    let defaults: UserDefaults

    func load() -> Bool {
        defaults.object(forKey: Self.key) as? Bool ?? true
    }

    func save(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }
}
