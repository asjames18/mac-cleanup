import SwiftUI

struct FolderAccessView: View {
    @ObservedObject var model: AppModel
    @StateObject private var store = FolderAccessStore()

    var body: some View {
        Section("Folder access") {
            Text("Check whether MacSweep can list common scan folders and Trash. macOS may ask permission. A successful check does not prove access to every file or permission to remove it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Check Access") {
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    store.check(["Downloads", "Desktop", "Documents", ".Trash"].map { home.appendingPathComponent($0) } + model.customFolders)
                }.disabled(store.busy || model.isBusy || model.waitingForFilesystem)
                if store.checking {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { store.cancel() }
                }
            }
            Text(store.message).font(.caption).foregroundStyle(.secondary)
            if let date = store.checkedAt { Text("Last checked: \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
            ForEach(store.results) { result in
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.url.path).font(.caption).textSelection(.enabled)
                    Text(result.status.label).font(.caption.bold())
                        .foregroundStyle(result.status == .readable ? Color.secondary : Color.orange)
                }
            }
            Text("For denied locations, review MacSweep under System Settings → Privacy & Security → Files and Folders or Full Disk Access, then check again. Managed restrictions may still apply. Adding an exclusion does not grant access.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Apple’s guide to file access", destination: URL(string: "https://support.apple.com/guide/mac-help/mchl211c911f/mac")!)
        }
        .onDisappear { store.cancel() }
    }
}
