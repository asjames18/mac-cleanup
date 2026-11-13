import Foundation
import SwiftUI

@MainActor
final class FolderAccessStore: ObservableObject {
    @Published private(set) var results: [FolderAccessResult] = []
    @Published private(set) var checking = false
    @Published private(set) var waiting = false
    @Published private(set) var message = "Not checked."
    @Published private(set) var checkedAt: Date?
    private var token: UUID?
    private var worker: Task<Void, Never>?
    private let timeout: Duration
    private let probe: @Sendable (URL) -> FolderAccessResult
    var busy: Bool { checking || waiting }

    init(timeout: Duration = .seconds(20), probe: @escaping @Sendable (URL) -> FolderAccessResult = FolderAccessChecker.check) {
        self.timeout = timeout; self.probe = probe
    }

    func check(_ urls: [URL]) {
        guard !busy else { return }
        let roots = ScanPreferences.normalized(urls)
        let page = Array(roots.prefix(200))
        let id = UUID()
        token = id; checking = true; results = []; checkedAt = nil
        message = "Checking folder listing access…"
        let probe = probe
        let worker = Task.detached(priority: .utility) { [weak self] in
            for url in page {
                guard !Task.isCancelled else { break }
                let result = probe(url)
                guard !Task.isCancelled else { break }
                await self?.receive(result, token: id)
            }
        }
        self.worker = worker
        let watchdog = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard self?.token == id else { return }
            self?.cancel(message: "Access check timed out. Waiting for the filesystem to return.")
        }
        Task { [weak self] in
            await worker.value
            watchdog.cancel()
            guard let self else { return }
            let completed = self.token == id
            self.token = nil; self.worker = nil; self.checking = false; self.waiting = false
            if completed {
                self.checkedAt = Date()
                self.message = roots.count > page.count ? "Checked the first 200 locations; more folders remain unchecked." : "Folder checks finished. Results describe access at the time checked."
            } else {
                self.message = "Check stopped. Displayed results are partial; you can check again."
            }
        }
    }

    private func receive(_ result: FolderAccessResult, token: UUID) {
        guard self.token == token else { return }
        results.append(result)
    }

    func cancel(message: String = "Check canceled. Waiting for the filesystem to return.") {
        guard checking else { return }
        token = nil; checking = false; waiting = true; worker?.cancel()
        self.message = message
    }
}
