import AppKit
import Combine
import Foundation

@MainActor
final class MaintenanceStore: ObservableObject {
    @Published private(set) var definitions: [StartupDefinition] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var isLoading = false
    @Published var searchText = ""
    @Published var message: String?

    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()

    var filteredDefinitions: [StartupDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return definitions }
        return definitions.filter { item in
            [item.displayName, item.label, item.source.rawValue, item.program ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func refresh() {
        scanTask?.cancel()
        let currentID = UUID()
        scanID = currentID
        isLoading = true
        message = nil
        warnings = []

        scanTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try StartupScanner.scan()
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard scanID == currentID else { return }
                definitions = result.definitions
                warnings = result.warnings
                isLoading = false
            } catch is CancellationError {
                guard scanID == currentID else { return }
                isLoading = false
            } catch {
                guard scanID == currentID else { return }
                definitions = []
                isLoading = false
                message = error.localizedDescription
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        scanID = UUID()
        isLoading = false
    }

    func reveal(_ definition: StartupDefinition) {
        NSWorkspace.shared.activateFileViewerSelecting([definition.url])
    }

    func openLoginItems() {
        openSettings(
            URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
            name: "Login Items settings"
        )
    }

    func openStorageSettings() {
        openSettings(
            URL(string: "x-apple.systempreferences:com.apple.settings.Storage"),
            name: "Storage settings"
        )
    }

    func openSoftwareUpdate() {
        openSettings(
            URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"),
            name: "Software Update"
        )
    }

    func openActivityMonitor() {
        openApplication(at: "/System/Applications/Utilities/Activity Monitor.app", name: "Activity Monitor")
    }

    func openDiskUtility() {
        openApplication(at: "/System/Applications/Utilities/Disk Utility.app", name: "Disk Utility")
    }

    private func openSettings(_ url: URL?, name: String) {
        guard let url, NSWorkspace.shared.open(url) else {
            message = "MacSweep could not open \(name). You can open it manually from System Settings."
            return
        }
        message = nil
    }

    private func openApplication(at path: String, name: String) {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: path) else {
            message = "MacSweep could not find \(name) in the standard Utilities folder."
            return
        }

        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            Task { @MainActor in
                self?.message = error.map { "MacSweep could not open \(name): \($0.localizedDescription)" }
            }
        }
    }
}
