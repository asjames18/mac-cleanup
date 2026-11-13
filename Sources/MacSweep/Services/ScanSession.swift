import Foundation

struct ScanLimit: Sendable {
    let seconds: TimeInterval
    let entries: Int
    static let quick = ScanLimit(seconds: 20, entries: 25_000)
    static let extended = ScanLimit(seconds: 300, entries: 1_000_000)
}

struct ScanUpdate: Sendable {
    let stage: String
    let path: String
    let examined: Int
    let elapsed: TimeInterval
    let items: [CleanupItem]
    let storage: [StorageItem]
}

/// Confined to one synchronous scan worker. TaskLocal passes this context down
/// traversal helpers; the only cross-thread output is an immutable update.
final class ScanSession: @unchecked Sendable {
    private let started = ProcessInfo.processInfo.systemUptime
    private let limit: ScanLimit
    private let progress: @Sendable (ScanUpdate) -> Void
    private var lastEmission: TimeInterval = 0
    private var examined = 0
    private(set) var errors = 0
    private var lastError = ""
    private var stage = "Starting scan"
    private var path = ""
    private var items: [CleanupItem] = []
    private var storage: [StorageItem] = []

    init(limit: ScanLimit, progress: @escaping @Sendable (ScanUpdate) -> Void) {
        self.limit = limit
        self.progress = progress
    }

    var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - started }
    var stopped: Bool { elapsed >= limit.seconds || examined >= limit.entries }
    var summary: String {
        let coverage = Task.isCancelled ? "Cancelled; partial coverage." : stopped
            ? "Scan limit reached; partial coverage. Unfinished cleanup folders were excluded. Some locations remain unscanned."
            : errors > 0 ? "Finished with partial coverage; some locations or files were unreadable. Hidden files, packages and protected paths are excluded."
            : "Finished accessible locations; hidden files, packages and protected paths are excluded."
        return "\(coverage) \(errors) read errors. \(lastError) Examined \(examined) entries in \(String(format: "%.1f", elapsed)) seconds."
    }

    func recordError(_ url: URL, error: Error) {
        errors += 1
        lastError = "Last inaccessible path: \(url.path) (\(error.localizedDescription))."
    }

    func found(_ item: CleanupItem) {
        items.append(item)
        emit(force: items.count == 1)
    }

    func visit(_ url: URL) {
        examined += 1
        path = url.path
        emit(force: false)
    }

    func publish(items: [CleanupItem]? = nil, storage: [StorageItem]? = nil, stage: String) {
        if let items { self.items = items }
        if let storage { self.storage = storage }
        self.stage = stage
        emit(force: true)
    }

    private func emit(force: Bool) {
        let now = elapsed
        guard force || now - lastEmission >= 0.25 else { return }
        lastEmission = now
        progress(ScanUpdate(stage: stage, path: path, examined: examined, elapsed: now, items: items, storage: storage))
    }
}
