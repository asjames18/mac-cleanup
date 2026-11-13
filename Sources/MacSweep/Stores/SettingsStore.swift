import Foundation
import MacSweepCore

/// settings.json, backups/ and logs/actions.log under ~/Library/Application Support/MacSweep.
@MainActor
final class SettingsStore {
    static let fileName = "settings.json"
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacSweep", isDirectory: true)
    }

    let store: AtomicJSONStore
    let log: ActionLog
    private(set) var settings: MacSweepSettings
    /// A message to show once when a corrupt settings file was moved aside.
    private(set) var recoveryNote: String?

    init(root: URL = SettingsStore.defaultRoot, legacyDefaults: UserDefaults? = nil) throws {
        let store = try AtomicJSONStore(root: root)
        let log = try ActionLog(directory: root.appendingPathComponent("logs", isDirectory: true))
        let fileExists = FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.fileName).path)
        let loaded = store.load(Self.fileName, as: MacSweepSettings.self, default: MacSweepSettings())
        self.store = store
        self.log = log
        settings = loaded.value
        if let bak = loaded.recoveredBackup {
            recoveryNote = "Settings were unreadable and were reset to safe defaults. The old file is at \(bak.path)."
            log.append(kind: "settings", message: "Recovered from unreadable settings.json; moved to \(bak.lastPathComponent).")
        }
        // One-time migration of the sandbox switch from UserDefaults.
        if !fileExists, let legacyDefaults, let legacy = legacyDefaults.object(forKey: SandboxPreferences.key) as? Bool {
            settings.sandboxEnabled = legacy
            try? store.save(Self.fileName, value: settings, backupReason: "migrate")
            log.append(kind: "settings", message: "Migrated test sandbox setting (\(legacy ? "on" : "off")) from preferences.")
        }
    }

    func update(reason: String, _ change: (inout MacSweepSettings) -> Void) throws {
        var next = settings
        change(&next)
        guard next != settings else { return }
        try store.save(Self.fileName, value: next, backupReason: reason)
        settings = next
    }
}
