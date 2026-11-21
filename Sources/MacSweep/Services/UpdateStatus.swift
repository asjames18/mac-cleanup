import Foundation
import MacSweepCore

/// Read-only protection and update status for the Maintenance view. Nothing here changes a setting.
struct ProtectionStatus: Equatable, Sendable {
    var gatekeeperOn: Bool?
    var xprotectVersion: String?
    var xprotectAgeDays: Int?
    var pendingMacOSUpdates: [String]?

    /// Built-in tools only (spctl and two plists). No network, no admin rights.
    static func read(now: Date = Date()) -> ProtectionStatus {
        let gatekeeper = SystemSignals.run("/usr/sbin/spctl", ["--status"]).flatMap(HealthCheckParsers.gatekeeper)
        let (version, age) = HealthCheckRunner.xprotect(now: now)
        return ProtectionStatus(gatekeeperOn: gatekeeper, xprotectVersion: version,
                                xprotectAgeDays: age.map { Int($0 / 86_400) }, pendingMacOSUpdates: HealthCheckRunner.pendingUpdates())
    }
}

/// `brew outdated`, run only when you press Check. Auto-update, analytics and hints are switched off,
/// so it reads Homebrew's local data and installs nothing.
struct HomebrewStatus: Equatable, Sendable {
    var installed: Bool
    var outdated: [String]
    var error: String?

    static let candidatePaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    static func brewPath(fileManager: FileManager = .default) -> String? {
        candidatePaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    static func parse(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func check() -> HomebrewStatus {
        guard let brew = brewPath() else { return HomebrewStatus(installed: false, outdated: []) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:" + URL(fileURLWithPath: brew).deletingLastPathComponent().path,
                           "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1",
                           "HOMEBREW_NO_INSTALL_CLEANUP": "1"]
        guard let output = SystemSignals.run(brew, ["outdated", "--quiet"], timeout: 60, environment: environment) else {
            return HomebrewStatus(installed: true, outdated: [], error: "Homebrew did not answer within a minute.")
        }
        return HomebrewStatus(installed: true, outdated: parse(output))
    }
}
