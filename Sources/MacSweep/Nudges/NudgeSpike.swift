import Foundation
import Security

/// Phase 0 check, run with `--nudge-spike`: can an ad-hoc signed MacSweep post local
/// notifications and register itself with SMAppService? Writes logs/nudge-spike.json.
struct NudgeSpikeReport: Codable, Equatable, Sendable {
    var bundlePath = ""
    var bundleIdentifier = ""
    var signature = ""
    var notificationsBefore = NotificationService.Authorization.unknown
    var requestGranted: Bool?
    var requestError: String?
    var requestTimedOut = false
    var notificationsAfter = NotificationService.Authorization.unknown
    var postError: String?
    var loginItemBefore = LoginItemService.Status.unknown
    var registerError: String?
    var loginItemAfterRegister = LoginItemService.Status.unknown
    var unregisterError: String?
    var loginItemFinal = LoginItemService.Status.unknown
    var finishedAt = Date()
}

@MainActor
private final class SpikeBox {
    var result: (granted: Bool, error: String?)?
}

@MainActor
enum NudgeSpike {
    static func run(requestTimeout: Duration = .seconds(20), keepLoginItem: Bool = false) async -> NudgeSpikeReport {
        var report = NudgeSpikeReport()
        report.bundlePath = Bundle.main.bundlePath
        report.bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        report.signature = signatureKind()
        let notes = NotificationService.shared
        notes.configure()
        report.notificationsBefore = await notes.authorization()
        if report.notificationsBefore == .notDetermined {
            var outcome: (granted: Bool, error: String?)?
            let box = SpikeBox()
            Task { @MainActor in box.result = await notes.requestAuthorization() }
            let deadline = ContinuousClock.now.advanced(by: requestTimeout)
            while ContinuousClock.now < deadline {
                if let result = box.result { outcome = result; break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let outcome { report.requestGranted = outcome.granted; report.requestError = outcome.error }
            else { report.requestTimedOut = true }
        }
        report.notificationsAfter = await notes.authorization()
        if report.notificationsAfter == .authorized || report.notificationsAfter == .provisional {
            report.postError = await notes.post(id: "macsweep.spike", title: "MacSweep can notify you",
                                                body: "This is a one-time test from MacSweep's setup check.")
        }
        report.loginItemBefore = LoginItemService.status
        do { try LoginItemService.register() } catch { report.registerError = error.localizedDescription }
        report.loginItemAfterRegister = LoginItemService.status
        if !keepLoginItem && report.loginItemBefore != .enabled {
            do { try LoginItemService.unregister() } catch { report.unregisterError = error.localizedDescription }
        }
        report.loginItemFinal = LoginItemService.status
        report.finishedAt = Date()
        return report
    }

    static func write(_ report: NudgeSpikeReport, to directory: URL = SettingsStore.defaultRoot.appendingPathComponent("logs", isDirectory: true)) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("nudge-spike.json")
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    /// "adhoc", "developer-id", "unsigned" or "unknown", read from this process's own code signature.
    static func signatureKind() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unknown" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "unknown" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "unsigned" }
        if let flags = dict[kSecCodeInfoFlags as String] as? UInt32, flags & 0x0002 != 0 { return "adhoc" }
        return dict[kSecCodeInfoTeamIdentifier as String] != nil ? "team-signed" : "unknown"
    }
}
