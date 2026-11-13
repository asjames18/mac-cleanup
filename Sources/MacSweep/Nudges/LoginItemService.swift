import Foundation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`. MacSweep starts with `--background`
/// (menu bar only) when macOS opens it at login.
@MainActor
enum LoginItemService {
    enum Status: String, Codable, Sendable {
        case notRegistered, enabled, requiresApproval, notFound, unknown
    }

    static var status: Status { map(SMAppService.mainApp.status) }

    static func register() throws { try SMAppService.mainApp.register() }
    static func unregister() throws { try SMAppService.mainApp.unregister() }

    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    nonisolated static func map(_ status: SMAppService.Status) -> Status {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }
}
