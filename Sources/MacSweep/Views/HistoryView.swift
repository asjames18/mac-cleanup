import AppKit
import SwiftUI
import MacSweepCore

struct HistoryView: View {
    @StateObject private var store: HistoryStore

    init(store: HistoryStore? = nil) {
        _store = StateObject(wrappedValue: store ?? HistoryStore(journal: CleanupSafety.defaultJournal))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Cleanup History").font(.title2.bold())
                Spacer()
                if store.canCancel { Button("Cancel") { store.cancelRead() } }
                Button("Refresh") { Task { await store.refresh() } }.disabled(store.busy)
            }
            Text("Restore verified items from Trash after reviewing the exact destination. Existing files are never overwritten. Pending operations have an unknown outcome; inspect both locations in Finder before taking further action.")
                .foregroundStyle(.secondary)
            if store.loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(store.canCancel ? "Checking history and file locations…" : store.mutationMessage)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = store.error { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
            if store.totalCount > store.rows.count {
                HStack {
                    Text("Showing the newest \(store.rows.count) of \(store.totalCount) records.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Load Older") { Task { await store.loadOlder() } }.disabled(store.busy)
                }
            }
            if store.rows.isEmpty {
                Text(store.busy ? "Waiting for history…" : store.error != nil ? "History could not be loaded. Try Refresh." : "No cleanup operations recorded yet.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary)
            } else {
                List(store.rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(row.entry.source.lastPathComponent).font(.headline)
                            Spacer()
                            Text(stateLabel(row.entry)).font(.caption.bold())
                            Text(row.entry.date, style: .date).font(.caption)
                        }
                        Text("Original: \(row.entry.source.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let failure = row.entry.error { Text(failure).font(.caption).foregroundStyle(Theme.danger) }
                        if let destination = row.entry.destination {
                            Text("Trash location: \(destination.path)").font(.caption).textSelection(.enabled)
                        }
                        if let restore = row.entry.restore {
                            Text("Restore destination: \(restore.destination.path)").font(.caption).textSelection(.enabled)
                            if let date = restore.reconciledAt {
                                Text("Restore verified on " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let failure = restore.error {
                                Text("Restore attempt failed without moving the item: " + failure).font(.caption).foregroundStyle(Theme.danger)
                            }
                        }
                        if row.entry.restore?.state != .restored, let reason = row.unavailable {
                            Text(reason.localizedDescription).font(.caption).foregroundStyle(.secondary)
                            if reason == .accessDenied {
                                Link("About macOS file access", destination: URL(string: "https://support.apple.com/guide/mac-help/mchl211c911f/mac")!).font(.caption)
                            }
                        }
                        HStack {
                            Button("Reveal Original Location") { reveal(row.entry.source) }
                            if row.entry.restore?.state == .pending {
                                Button("Verify Restore Outcome…") { Task { await store.reviewRestoreOutcome(id: row.id) } }
                            }
                            if row.canRestore {
                                Button("Restore…") { Task { await store.review(id: row.id) } }
                            }
                            if row.canChooseFolder {
                                Button("Choose Another Folder…") { chooseFolder(for: row) }
                            }
                            if let destination = row.entry.destination {
                                Button("Reveal Trash Location") { reveal(destination) }
                            }
                            if let restore = row.entry.restore {
                                Button("Reveal Restore Location") { reveal(restore.destination) }
                            }
                        }.disabled(store.busy)
                    }.padding(.vertical, 8)
                }
            }
        }
        .padding(24)
        .task { await store.refresh() }
        .onDisappear { store.cancelReview() }
        .sheet(item: Binding(get: { store.reviewedPlan }, set: { if $0 == nil { store.cancelReview() } })) { plan in
            VStack(alignment: .leading, spacing: 16) {
                Text("Restore this item?").font(.title2.bold())
                Text("From Trash").font(.headline)
                Text(plan.source.path).textSelection(.enabled)
                Text("To this exact destination").font(.headline)
                Text(plan.destination.path).textSelection(.enabled)
                Text("The item will be moved to this existing folder on the same volume. If the item or destination changes, recovery stops. Nothing will be overwritten.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { store.cancelReview() }
                    Button("Restore") { Task { await store.confirmRestore() } }
                }
            }.padding(24).frame(width: 580)
        }
        .sheet(item: Binding(get: { store.reviewedReconciliation }, set: { if $0 == nil { store.cancelReview() } })) { plan in
            VStack(alignment: .leading, spacing: 16) {
                Text("Record this restore as completed?").font(.title2.bold())
                Text("The recorded file identity and content metadata match at:")
                Text(plan.restoredLocation.path).textSelection(.enabled)
                Text("The former Trash location is empty:")
                Text(plan.formerTrashLocation.path).textSelection(.enabled)
                Text("Confirming checks these locations again and updates History only. No files are moved or deleted. This verifies the current endpoints, not every change that may have occurred inside a folder.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { store.cancelReview() }
                    Button("Record Verified Restore") { Task { await store.confirmRestoreOutcome() } }
                }
            }.padding(24).frame(width: 580)
        }
    }

    private func stateLabel(_ entry: CleanupJournalEntry) -> String {
        if let restore = entry.restore {
            switch restore.state {
            case .restored: return "Restored"
            case .pending: return "Restore outcome unknown"
            case .failed: return "Restore failed · not moved"
            }
        }
        return entry.state == .pending ? "Cleanup outcome unknown" : entry.state.rawValue.capitalized
    }

    @MainActor
    private func reveal(_ url: URL) {
        Task {
            guard let location = await store.finderLocation(for: url) else { return }
            if location.openFolder { NSWorkspace.shared.open(location.url) }
            else { NSWorkspace.shared.activateFileViewerSelecting([location.url]) }
        }
    }

    @MainActor
    private func chooseFolder(for row: HistoryRow) {
        let panel = NSOpenPanel()
        panel.title = "Choose an existing restore folder"
        panel.prompt = "Review Destination"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            Task { await store.review(id: row.id, destination: folder.appendingPathComponent(row.entry.source.lastPathComponent)) }
        }
    }
}
