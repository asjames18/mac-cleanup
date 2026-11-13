import Foundation
import SwiftUI

@MainActor
final class StorageBrowserStore: ObservableObject {
    @Published private(set) var listingIndex = StorageListingIndex.empty
    @Published private(set) var entries: [StorageEntry] = []
    @Published private(set) var trail: [URL] = []
    @Published private(set) var busy = false
    @Published private(set) var waiting = false
    @Published private(set) var summary = ""
    @Published private(set) var error: String?
    @Published private(set) var matches: [StorageEntry] = []
    @Published private(set) var searching = false
    @Published private(set) var sizeMap = StorageMap.empty
    private var searchToken: UUID?
    private var searchWorker: Task<Void, Never>?
    private var query = ""
    private var largestFirst = true
    private var token: UUID?
    @Published private(set) var measurements: [String: StorageMeasurement] = [:]
    private var cancelWorker: (() -> Void)?
    private let read: @Sendable (URL, [URL]) throws -> StorageDirectoryReport
    private let match: @Sendable (StorageListingIndex, String, Bool) -> [StorageEntry]
    private let timeout: Duration
    var current: URL? { trail.last }
    var canNavigate: Bool { !busy && !waiting }

    init(timeout: Duration = .seconds(25), match: @escaping @Sendable (StorageListingIndex, String, Bool) -> [StorageEntry] = { $0.matching($1, largestFirst: $2) }, read: @escaping @Sendable (URL, [URL]) throws -> StorageDirectoryReport = { try StorageDirectoryReader.read($0, exclusions: $1) }) {
        self.timeout = timeout; self.read = read; self.match = match
    }
    func open(_ url: URL, exclusions: [URL], back: Bool = false) {
        guard canNavigate else { return }
        if back { trail.removeLast() }
        else if trail.last != url { trail.append(url) }
        cancelSearch()
        entries = []; listingIndex = .empty; measurements = [:]; error = nil; summary = "Reading folder contents…"
        let read = read
        perform({
            let report = try read(url, exclusions)
            return (report, StorageListingIndex(entries: report.entries))
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let report = value.0
                self.listingIndex = value.1
                self.entries = report.entries
                self.search(self.query, largestFirst: self.largestFirst, debounce: false)
                self.summary = "\(report.entries.count) items listed · \(report.skipped) excluded or unreadable. " + (report.partial ? "Partial listing: a limit, read error or folder change affected this check." : "Listing finished.")
            case .failure(let failure):
                self.error = failure.localizedDescription
                self.summary = "Folder unavailable. Check its path and access permissions."
            }
        }
    }

    func measure(_ url: URL, exclusions: [URL]) {
        guard canNavigate else { return }
        measurements[url.path] = nil
        search(query, largestFirst: largestFirst, debounce: false)
        summary = "Measuring \(url.lastPathComponent)…"; error = nil
        perform({ try StorageFolderMeasurer.measure(url, exclusions: exclusions) }) { [weak self] result in
            switch result {
            case .success(let value):
                self?.measurements[url.path] = value
                if let self { self.search(self.query, largestFirst: self.largestFirst, debounce: false) }
                self?.summary = "\(url.lastPathComponent): Unique files: \(value.files) · Folders encountered: \(value.folders) · Skipped: \(value.skipped). " + (value.partial ? "Partial measured total." : "Measurement finished.")
            case .failure(let failure):
                if failure is StorageReadError { self?.cancelSearch(); self?.entries = []; self?.listingIndex = .empty; self?.measurements = [:] }
                self?.error = failure.localizedDescription; self?.summary = "Measurement unavailable. Refresh to review current contents."
            }
        }
    }

    /// A canceled query never publishes into a newer query or folder listing.
    func search(_ query: String, largestFirst: Bool, debounce: Bool = true) {
        cancelSearch()
        self.query = query; self.largestFirst = largestFirst
        let id = UUID(); searchToken = id; searching = true
        let index = listingIndex
        let measurements = measurements
        let match = match
        searchWorker = Task.detached(priority: .userInitiated) { [weak self] in
            if debounce {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let result = match(index, query, largestFirst)
            guard !Task.isCancelled else { return }
            let map = StorageMap.prepare(result, measurements: measurements)
            guard !Task.isCancelled else { return }
            await self?.acceptSearch(result, map: map, token: id)
        }
    }

    private func acceptSearch(_ result: [StorageEntry], map: StorageMap, token: UUID) {
        guard searchToken == token else { return }
        matches = result; sizeMap = map; searching = false; searchWorker = nil; searchToken = nil
    }

    private func cancelSearch(clearResults: Bool = true) {
        searchWorker?.cancel(); searchWorker = nil; searchToken = nil
        if clearResults { matches = []; sizeMap = .empty }
        searching = false
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T,
                                      completion: @escaping @MainActor (Result<T, Error>) -> Void) {
        busy = true
        let id = UUID(); token = id
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let report = try work()
            try Task.checkCancellation()
            return report
        }
        cancelWorker = { worker.cancel() }
        let watchdog = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard self?.token == id else { return }
            self?.cancel("Folder read timed out. Waiting for the filesystem to return.")
        }
        Task { [weak self] in
            let result = await worker.result
            watchdog.cancel()
            guard let self else { return }
            let accepted = self.token == id
            self.cancelWorker = nil; self.token = nil; self.busy = false; self.waiting = false
            guard accepted else { self.summary = "Read stopped. Refresh to try again."; return }
            completion(result)
        }
    }
    func back(exclusions: [URL]) {
        guard canNavigate, trail.count > 1 else { return }
        open(trail[trail.count - 2], exclusions: exclusions, back: true)
    }
    func exclusionsChanged() {
        cancel()
        cancelSearch()
        entries = []; listingIndex = .empty; measurements = [:]; error = nil
        if !waiting { summary = "Exclusions changed. Refresh to list this folder again." }
    }

    func cancel(_ message: String = "Canceled. Waiting for the filesystem to return.") {
        cancelSearch(clearResults: false)
        guard busy else { return }
        token = nil; busy = false; waiting = true; cancelWorker?(); summary = message
    }
}
