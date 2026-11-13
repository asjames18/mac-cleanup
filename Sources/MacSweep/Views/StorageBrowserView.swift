import AppKit
import SwiftUI

struct StorageBrowserView: View {
    let root: URL
    @ObservedObject var model: AppModel
    @StateObject private var store: StorageBrowserStore

    init(root: URL, model: AppModel, store: StorageBrowserStore? = nil) {
        self.root = root; self.model = model
        _store = StateObject(wrappedValue: store ?? StorageBrowserStore())
    }
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var displayed = 200
    @State private var showMap = false
    @State private var largestFirst = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Explore Storage").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text(store.current?.path ?? root.path).font(.caption).textSelection(.enabled)
            HStack {
                Button("Back") { displayed = 200; search = ""; store.back(exclusions: model.excludedFolders) }
                    .disabled(store.trail.count < 2 || !store.canNavigate)
                Button("Refresh") { displayed = 200; store.open(store.current ?? root, exclusions: model.excludedFolders) }.disabled(!store.canNavigate)
                Button("Measure Folder") { store.measure(store.current ?? root, exclusions: model.excludedFolders) }.disabled(!store.canNavigate)
                if store.busy { ProgressView().controlSize(.small); Button("Cancel") { store.cancel() } }
                Spacer()
                Toggle("Largest files first", isOn: $largestFirst)
            }
            HStack {
                TextField("Search this folder", text: $search).textFieldStyle(.roundedBorder)
                Picker("Display", selection: $showMap) {
                    Text("List").tag(false)
                    Text("Size Map").tag(true)
                }.pickerStyle(.segmented).frame(width: 180)
            }
            Text("Totals cover file contents, excluding directory overhead. Logical bytes and allocated blocks are not guaranteed reclaimable space. Measure folders on demand; partial totals omit skipped content. Links are listed but never followed.")
                .font(.caption).foregroundStyle(.secondary)
            Text(store.summary).font(.caption).foregroundStyle(.secondary)
            if let total = store.measurements[(store.current ?? root).path] {
                Text(total.allocatedBytes.formattedFileSize + " allocated · " + total.logicalBytes.formattedFileSize + " logical" + (total.partial ? " · Partial measured total" : " · Measured total"))
                    .font(.headline)
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled) }
            if store.searching { Text("Searching…").font(.caption).foregroundStyle(.secondary) }
            let matches = store.matches
            if showMap {
                StorageTreemapView(map: store.sizeMap, canNavigate: store.canNavigate, onOpen: { entry in
                    if entry.kind == .folder {
                        displayed = 200; search = ""; store.open(entry.url, exclusions: model.excludedFolders)
                    } else { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                }, onShowList: { showMap = false })
            } else {
            List(Array(matches.prefix(displayed))) { entry in
                HStack {
                    Image(systemName: entry.kind == .folder ? "folder" : entry.kind == .link ? "link" : "doc")
                    VStack(alignment: .leading) {
                        Text(entry.url.lastPathComponent).lineLimit(1)
                        Text(entry.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.kind == .file {
                        VStack(alignment: .trailing) {
                            Text(entry.allocatedBytes.formattedFileSize + " on disk")
                            Text(entry.logicalBytes.formattedFileSize + " logical").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if entry.kind == .folder {
                        if let size = store.measurements[entry.url.path] {
                            VStack(alignment: .trailing) {
                                Text(size.allocatedBytes.formattedFileSize + (size.partial ? " measured · partial" : " allocated"))
                                Text(size.logicalBytes.formattedFileSize + " logical").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Measure") { store.measure(entry.url, exclusions: model.excludedFolders) }.disabled(!store.canNavigate)
                        Button("Open") { displayed = 200; search = ""; store.open(entry.url, exclusions: model.excludedFolders) }.disabled(!store.canNavigate)
                    }
                    Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                }
            }
            HStack {
                Text("Showing \(min(displayed, matches.count)) of \(matches.count) matching items").font(.caption)
                Spacer()
                if matches.count > displayed { Button("Show More") { displayed += 200 } }
            }
            }
        }.padding(20).frame(minWidth: 750, idealWidth: 850, minHeight: 540, idealHeight: 650)
        .onAppear {
            if store.current == nil { store.open(root, exclusions: model.excludedFolders) }
            else { store.search(search, largestFirst: largestFirst, debounce: false) }
        }
        .onDisappear { store.cancel() }
        .onChange(of: search) { value in displayed = 200; store.search(value, largestFirst: largestFirst) }
        .onChange(of: largestFirst) { value in displayed = 200; store.search(search, largestFirst: value) }
        .onChange(of: model.excludedFolders) { _ in store.exclusionsChanged() }
    }
}
