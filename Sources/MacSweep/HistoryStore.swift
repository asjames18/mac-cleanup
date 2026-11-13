import Foundation
import SwiftUI
import MacSweepCore

struct HistoryRow: Identifiable, Sendable {
    let entry: CleanupJournalEntry
    let unavailable: RestoreError?
    var id: UUID { entry.id }
    var canRestore: Bool { unavailable == nil }
    var canChooseFolder: Bool { unavailable == .conflict || unavailable == .crossVolume || unavailable == .unsafePath }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var rows: [HistoryRow] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var reviewedPlan: RestorePlan?
    @Published private(set) var reviewedReconciliation: RestoreReconciliationPlan?
    @Published private(set) var mutationMessage = "Restoring the reviewed item…"
    @Published private(set) var totalCount = 0
    @Published private(set) var waitingForFilesystem = false
    private var readToken: UUID?
    private var cancelledRead = false
    private var cancelWorker: (() -> Void)?
    private let reviewPlan: @Sendable (UUID, URL?) throws -> RestorePlan
    private let readTimeout: Duration
    var busy: Bool { loading || waitingForFilesystem }
    var canCancel: Bool { readToken != nil && !cancelledRead }
    private let journal: CleanupJournal
    private let loadEntries: @Sendable () throws -> [CleanupJournalEntry]
    private var cachedEntries: [CleanupJournalEntry] = []
    var hasOlderEntries: Bool { rows.count < cachedEntries.count }

    init(journal: CleanupJournal, loadEntries: (@Sendable () throws -> [CleanupJournalEntry])? = nil, readTimeout: Duration = .seconds(25),
         reviewPlan: (@Sendable (UUID, URL?) throws -> RestorePlan)? = nil) {
        self.reviewPlan = reviewPlan ?? { try RestoreEngine(journal: journal).review(id: $0, destination: $1) }
        self.readTimeout = readTimeout
        self.journal = journal
        self.loadEntries = loadEntries ?? { try journal.entries() }
    }

    /// Cancellation releases the UI but retains the worker gate until an in-flight
    /// filesystem call actually returns. Late results never replace current state.
    private func read<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async -> Result<T, Error>? {
        guard !busy, !Task.isCancelled else { return nil }
        let token = UUID()
        readToken = token; cancelledRead = false; loading = true; error = nil
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }
        cancelWorker = { worker.cancel() }
        let watchdog = Task { [weak self, readTimeout] in
            do { try await Task.sleep(for: readTimeout) } catch { return }
            guard let self, self.readToken == token else { return }
            self.cancelRead(message: "History timed out. Waiting for the filesystem before another operation can start.")
        }
        let result: Result<T, Error>
        do {
            let value = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
                Task { @MainActor [weak self] in
                    guard self?.readToken == token else { return }
                    self?.cancelRead()
                }
            }
            result = .success(value)
        } catch { result = .failure(error) }
        watchdog.cancel()
        let discard = cancelledRead || Task.isCancelled
        readToken = nil; cancelWorker = nil; loading = false; waitingForFilesystem = false
        if discard {
            error = "History operation stopped. You can refresh or review again."
            return nil
        }
        return result
    }

    func cancelRead(message: String = "History operation canceled. Waiting for the filesystem to finish.") {
        guard canCancel else { return }
        cancelledRead = true; cancelWorker?(); loading = false; waitingForFilesystem = true
        reviewedPlan = nil; reviewedReconciliation = nil; error = message
    }

    func refresh() async {
        let journal = journal
        let loadEntries = loadEntries
        guard let result = await read({
            let entries = try loadEntries()
            return (try Self.assess(Array(entries.prefix(200)), journal: journal), entries)
        }) else { return }
        switch result {
        case .success(let result):
            cachedEntries = result.1
            rows = result.0; totalCount = result.1.count; error = nil
        case .failure(let failure): error = "History unavailable: \(failure.localizedDescription)"
        }
    }

    func loadOlder() async {
        guard hasOlderEntries else { return }
        let page = Array(cachedEntries.dropFirst(rows.count).prefix(200))
        let journal = journal
        guard let result = await read({ try Self.assess(page, journal: journal) }) else { return }
        switch result {
        case .success(let page): rows.append(contentsOf: page)
        case .failure(let failure): error = "Older history unavailable: \(failure.localizedDescription)"
        }
    }

    nonisolated private static func assess(_ entries: [CleanupJournalEntry], journal: CleanupJournal) throws -> [HistoryRow] {
        let engine = RestoreEngine(journal: journal)
        return try entries.map { entry in
            try Task.checkCancellation()
            let unavailable: RestoreError?
            do { try engine.assess(entry); unavailable = nil }
            catch let reason as RestoreError { unavailable = reason }
            return HistoryRow(entry: entry, unavailable: unavailable)
        }
    }

    func review(id: UUID, destination: URL? = nil) async {
        guard !busy else { return }
        reviewedPlan = nil; reviewedReconciliation = nil
        let reviewPlan = reviewPlan
        guard let result = await read({
            try reviewPlan(id, destination)
        }) else { return }
        switch result {
        case .success(let plan): reviewedPlan = plan
        case .failure(let failure): error = failure.localizedDescription
        }
        loading = false
    }

    func cancelReview() {
        cancelRead()
        reviewedPlan = nil; reviewedReconciliation = nil
    }

    func finderLocation(for url: URL) async -> (url: URL, openFolder: Bool)? {
        guard let result = await read({ () -> (URL, Bool)? in
            if FileManager.default.fileExists(atPath: url.path) { return (url, false) }
            let parent = url.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return (parent, true)
            }
            return nil
        }) else { return nil }
        let location: (URL, Bool)?
        switch result {
        case .success(let value): location = value
        case .failure(let failure): error = failure.localizedDescription; return nil
        }
        if location == nil { error = "This item and its containing folder are no longer available in Finder." }
        return location
    }

    func reviewRestoreOutcome(id: UUID) async {
        guard !busy else { return }
        reviewedPlan = nil; reviewedReconciliation = nil
        let journal = journal
        guard let result = await read({ try RestoreEngine(journal: journal).reviewReconciliation(id: id) }) else { return }
        switch result {
        case .success(let plan): reviewedReconciliation = plan
        case .failure(let failure):
            error = "The restore outcome could not be confirmed. History remains unchanged. " + failure.localizedDescription
        }
    }

    func confirmRestoreOutcome() async {
        guard !busy, let plan = reviewedReconciliation else { return }
        reviewedReconciliation = nil; loading = true; error = nil
        mutationMessage = "Saving the verified restore outcome…"
        let journal = journal
        let result = await Task.detached(priority: .utility) {
            Result { try RestoreEngine(journal: journal).confirmReconciliation(plan) }
        }.value
        loading = false
        await refresh()
        if case .failure(let failure) = result { error = failure.localizedDescription }
    }

    /// Called only by the confirmation sheet's Restore button.
    func confirmRestore() async {
        guard !busy, let plan = reviewedPlan else { return }
        reviewedPlan = nil; loading = true; error = nil; mutationMessage = "Restoring the reviewed item…"
        let journal = journal
        let result = await Task.detached(priority: .utility) {
            Result { try RestoreEngine(journal: journal).restore(plan) }
        }.value
        loading = false
        await refresh()
        if case .failure(let failure) = result { error = failure.localizedDescription }
    }
}
