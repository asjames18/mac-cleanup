import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ActivityReportView: View {
    @ObservedObject var model: AppModel
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scan Activity").font(.caption.weight(.semibold))
                Text("Reports include file paths.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Copy Report") {
                    let text = report()
                    NSPasteboard.general.clearContents()
                    message = NSPasteboard.general.setString(text, forType: .string) ? "Report copied." : "The clipboard could not accept the report."
                }
                Button("Save Report…", action: save).disabled(saving)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if model.activityPreview.truncated {
                Text("Showing the end of a long report. Copy or save to read it all.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(model.activityPreview.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 90)
        }.padding(16).frame(height: 200).accessibilityLabel("Scan activity")
    }

    private func report() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let state: String
        switch model.status {
        case .idle: state = "Idle"
        case .scanning(let stage): state = stage
        case .cleaning: state = "Moving reviewed items to Trash"
        case .complete: state = "Operation finished; see coverage and errors below"
        }
        return """
        MacSweep diagnostic report
        Captured: \(Date().formatted(.iso8601))
        App version: \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        View: \(model.mainViewMode.title)
        Scan preset currently selected: \(model.selectedPreset.title)
        Status: \(state)
        Waiting for filesystem: \(model.waitingForFilesystem ? "Yes" : "No")

        Current progress
        \(model.scanDetail)

        Coverage summary
        \(model.scanSummary)

        Activity
        \(model.logText)

        This report captures current in-memory activity, including file paths. It is not a complete operation history or a guarantee of scan coverage.
        """
    }

    private func save() {
        guard !saving else { return }
        let text = report()
        let panel = NSSavePanel()
        panel.title = "Save MacSweep diagnostic report"
        panel.nameFieldStringValue = "MacSweep-report.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        saving = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { saving = false; return }
            Task {
                let result = await Task.detached(priority: .utility) {
                    Result { try Data(text.utf8).write(to: url, options: .atomic) }
                }.value
                saving = false
                switch result {
                case .success: message = "Report saved to \(url.path)."
                case .failure(let error): message = "Report could not be saved: \(error.localizedDescription)"
                }
            }
        }
    }
}
