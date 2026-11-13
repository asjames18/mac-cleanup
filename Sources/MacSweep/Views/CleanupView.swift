import AppKit
import SwiftUI

struct CleanupView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    private var filteredItems: [CleanupItem] {
        model.visibleItems.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let retained = CleanupSafety.retainedCopies(model.items)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Less clutter. More room.").font(.title2.weight(.semibold))
                    Text("Scan, take a closer look, then choose what to remove.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Scan preset", selection: $model.selectedPreset) {
                    ForEach(ScanPreset.allCases) { preset in Text(preset.title).tag(preset) }
                }.frame(width: 155).disabled(model.isBusy || model.waitingForFilesystem)
                Button { model.scan() } label: {
                    Label(model.lastScanDate == nil ? "Scan" : "Scan Again", systemImage: "magnifyingglass")
                }.buttonStyle(.borderedProminent).disabled(model.isBusy || model.waitingForFilesystem)
            }.padding(24)
            if !model.customFolders.isEmpty { customFolders }
            Divider()
            HStack(spacing: 16) {
                Picker("Category", selection: $model.selectedCategory) {
                    Text("All candidates").tag(nil as CleanupCategory?)
                    ForEach(model.summaries) { summary in
                        Text("\(summary.category.title) · \(summary.count)").tag(Optional(summary.category))
                    }
                }.frame(width: 205)
                Text("\(model.totalSize.formattedFileSize) to review")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                TextField("Search files", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            if model.selectedCategory == .duplicates || model.selectedPreset == .duplicatesOnly {
                Text("Duplicate scans compare files of at least 1 MB. Hidden files, package contents and protected locations are excluded. Check Activity for read errors and coverage limits.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                Divider()
            }
            HSplitView {
                Group {
                    if model.items.isEmpty {
                        SuiteEmptyState(icon: "sparkle.magnifyingglass",
                            title: model.isBusy ? "Taking a closer look…" : model.lastScanDate == nil ? "Your next bit of breathing room." : "No candidates found.",
                            detail: model.isBusy ? "You can continue exploring the app while the scan runs."
                                : "Choose a scan preset above. Results depend on folder access; check Activity for details.")
                    } else if filteredItems.isEmpty {
                        SuiteEmptyState(icon: "line.3.horizontal.decrease.circle", title: "No matching files.", detail: "Try a different category or search term.")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredItems) { item in
                                    CleanupFileRow(item: item,
                                        protectsRetainedCopy: retained.contains { ProtectionRules.contains(item.url, $0.url) },
                                        isFocused: model.focusedItemID == item.id,
                                        onFocus: { model.focusItem(item) }, onToggle: { model.toggleItem(item) })
                                        .disabled(model.isBusy || model.waitingForFilesystem)
                                    Divider().padding(.leading, 48)
                                }
                            }
                        }
                    }
                }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                if let item = model.focusedItem, !model.items.isEmpty {
                    CleanupDetailView(item: item,
                        copies: item.duplicateGroupID.map { group in model.items.filter { $0.duplicateGroupID == group }.sorted { $0.id < $1.id } } ?? [],
                        busy: model.isBusy || model.waitingForFilesystem,
                        onToggle: { model.toggleItem($0) })
                        .id(item.duplicateGroupID ?? item.id)
                        .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
                }
            }
            Divider()
            HStack(spacing: 14) {
                Button("Select Category") { model.setVisibleSelection(true) }
                    .disabled(model.visibleItems.isEmpty || model.isBusy || model.waitingForFilesystem)
                    .help("Select candidates in the current category, retaining a copy of each duplicate group")
                Button("Clear") { model.setVisibleSelection(false) }
                    .disabled(model.visibleItems.isEmpty || model.isBusy || model.waitingForFilesystem)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(model.selectedSize.formattedFileSize) selected").font(.headline).monospacedDigit()
                    Text("Review before removing").font(.caption).foregroundStyle(.secondary)
                }
                Button { model.cleanSelectedItems() } label: {
                    Label("Move to Trash", systemImage: "trash")
                }.buttonStyle(.borderedProminent)
                    .disabled(model.selectedItems.isEmpty || model.isBusy || model.waitingForFilesystem)
            }.padding(20)
        }
    }

    private var customFolders: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.customFolders, id: \.self) { folder in
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(folder.lastPathComponent).lineLimit(1)
                        Button { model.removeCustomFolder(folder) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.plain).help("Remove \(folder.lastPathComponent) from scan")
                            .disabled(model.isBusy || model.waitingForFilesystem)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.quaternary, in: Capsule()).help(folder.path)
                }
            }.padding(.horizontal, 24)
        }.padding(.bottom, 14)
    }
}

private struct CleanupFileRow: View {
    let item: CleanupItem
    let protectsRetainedCopy: Bool
    let isFocused: Bool
    let onFocus: () -> Void
    let onToggle: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Toggle("Select \(item.name)", isOn: Binding(get: { item.isSelected }, set: { _ in onToggle() }))
                .labelsHidden().toggleStyle(.checkbox)
                .disabled(protectsRetainedCopy)
                .help(protectsRetainedCopy ? "This item is a required retained duplicate or contains one." : "Select this candidate for review before removal")
            Button(action: onFocus) {
                HStack(spacing: 12) {
                    Image(systemName: item.category.systemImage).foregroundStyle(Theme.accent2).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                        if protectsRetainedCopy {
                            Label("Protected: retains a duplicate copy", systemImage: "checkmark.shield")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(item.size.formattedFileSize).monospacedDigit().font(.callout.weight(.medium))
                        Text(item.category.title).font(.caption).foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background(isFocused ? Color.teal.opacity(0.09) : .clear)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }
}

private struct CleanupDetailView: View {
    let item: CleanupItem
    let copies: [CleanupItem]
    let busy: Bool
    let onToggle: (CleanupItem) -> Void
    @State private var shownCopies = 20
    var body: some View {
        let retainedID = CleanupSafety.retainedCopies(copies).first?.id
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: item.category.systemImage).font(.largeTitle).foregroundStyle(Theme.accent2)
                Text(item.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                DetailField(title: "Location", value: item.path)
                DetailField(title: "Why it was found", value: item.reason)
                DetailField(title: "Before you remove it", value: item.safetyNote)
                DetailField(title: "Size", value: item.size.formattedFileSize)
                DetailField(title: "Modified", value: item.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                if item.duplicateGroupID != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Matching copies").font(.headline)
                        Text("\(copies.count) copies · \(copies.filter { !$0.isSelected }.count) keeping · \(copies.filter(\.isSelected).count) selected")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Includes copies outside the current filter. These matched at scan time; MacSweep checks them again before removal. One copy is protected from selection; you can keep additional copies.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(copies.prefix(shownCopies))) { copy in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(copy.id == retainedID ? "Required retained copy" : copy.isSelected ? "Selected for Trash" : "Keeping", systemImage: copy.isSelected ? "trash" : "checkmark.shield")
                                    .font(.caption.weight(.semibold))
                                Text(copy.path).font(.caption).textSelection(.enabled)
                                    .lineLimit(3).truncationMode(.middle).help(copy.path)
                                HStack {
                                    Button(copy.id == retainedID ? "Protected Copy" : copy.isSelected ? "Keep This Copy" : "Select for Trash") { onToggle(copy) }
                                        .disabled(busy || copy.id == retainedID)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([copy.url]) } label: {
                                        Image(systemName: "finder")
                                    }.help("Reveal this copy in Finder").accessibilityLabel("Reveal \(copy.name) in Finder")
                                }
                            }.padding(.vertical, 6)
                            Divider()
                        }
                        if copies.count > shownCopies {
                            Button("Show More Copies") { shownCopies += 20 }
                        }
                    }
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                    Label("Reveal in Finder", systemImage: "finder")
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.background(.primary.opacity(0.025))
    }
}
