import AppKit
import SwiftUI

struct StorageView: View {
    @ObservedObject var model: AppModel
    @State private var browseURL: URL?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Explore a Folder…") { chooseFolder() }
                Spacer()
            }.padding(16)
            if model.storageItems.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text(model.isBusy ? "Scan in progress" : "Analyze folders to map storage usage.")
                        .font(.title3.weight(.semibold))
                    Text(model.isBusy ? "Progress appears above. Storage analysis is separate from Quick Scan; folder totals appear as they finish." : "See readable space used by common folders and folders you add.")
                        .foregroundStyle(.secondary)
                    Button("Analyze Storage") { model.analyzeStorage() }
                        .buttonStyle(.borderedProminent).disabled(model.isBusy || model.waitingForFilesystem)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Folder Usage")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.top, 16)

                        Text("Readable file contents only. Hard-linked files count once per folder total. Folder totals can overlap; shared blocks are not guaranteed reclaimable space. Protected paths and package contents may be excluded.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                    let maxSize = max(model.storageItems.map(\.size).max() ?? 1, 1)
                        ForEach(model.storageItems) { item in
                            StorageUsageRow(
                                item: item,
                                fraction: Double(item.size) / Double(maxSize),
                                onExplore: { browseURL = item.url },
                                onReveal: {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                }
                            )
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: Binding(get: { browseURL != nil }, set: { if !$0 { browseURL = nil } })) {
            if let url = browseURL { StorageBrowserView(root: url, model: model) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Explore"
        if panel.runModal() == .OK { browseURL = panel.url }
    }
}

struct StorageUsageRow: View {
    let item: StorageItem
    let fraction: Double
    let onExplore: () -> Void
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(item.size.formattedFileSize + " readable")
                        .font(.headline)
                        .monospacedDigit()
                    Text("\(item.fileCount) unique files, \(item.folderCount) folders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Explore", action: onExplore)
                Button {
                    onReveal()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor)
                        .frame(width: max(0, min(proxy.size.width, proxy.size.width * fraction)))
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
