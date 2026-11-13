import Foundation

struct StorageMeasurement: Sendable {
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let files: Int
    let folders: Int
    let skipped: Int
    let partial: Bool
}

enum StorageFolderMeasurer {
    /// Live metadata totals, not a filesystem snapshot or a reclaimable-space estimate.
    /// Count hard-linked files once, stay on the root volume and never follow links.
    static func measure(_ root: URL, exclusions: [URL] = [], limit: ScanLimit = .quick) throws -> StorageMeasurement {
        let started = ProcessInfo.processInfo.systemUptime
        var pending: [(URL, Int, StorageObjectID?)] = [(root, 0, nil)]
        var rootStamp: StorageDirectoryStamp?
        var seen = Set<StorageObjectID>()
        var volume: Int32?
        var examined = 0
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var files = 0
        var folders = 0
        var skipped = 0
        var partial = false
        func add(_ value: Int64, to total: inout Int64) {
            let result = total.addingReportingOverflow(value)
            total = result.overflow ? Int64.max : result.partialValue
            if result.overflow { partial = true }
        }
        while let (url, depth, expectedIdentity) = pending.popLast() {
            try Task.checkCancellation()
            let remaining = limit.seconds - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 0, examined < limit.entries else { partial = true; break }
            let report: StorageDirectoryReport
            do { report = try StorageDirectoryReader.read(url, exclusions: exclusions, limit: ScanLimit(seconds: remaining, entries: limit.entries - examined), expectedIdentity: expectedIdentity) }
            catch {
                if url == root { throw error }
                try Task.checkCancellation()
                skipped += 1; partial = true; continue
            }
            if url == root { rootStamp = report.stamp }
            if volume == nil { volume = report.device }
            guard report.device == volume else { skipped += 1; partial = true; continue }
            examined += report.examined
            skipped += report.skipped
            partial = partial || report.partial || report.skipped > 0
            for entry in report.entries {
                try Task.checkCancellation()
                guard let identity = entry.identity, identity.device == volume else { skipped += 1; partial = true; continue }
                switch entry.kind {
                case .file:
                    guard seen.insert(identity).inserted else { continue }
                    files += 1
                    add(entry.logicalBytes, to: &logical); add(entry.allocatedBytes, to: &allocated)
                case .folder:
                    guard seen.insert(identity).inserted else { continue }
                    guard depth < 64 else { skipped += 1; partial = true; continue }
                    folders += 1; pending.append((entry.url, depth + 1, identity))
                case .link, .other:
                    skipped += 1; partial = true
                }
            }
        }
        if let rootStamp, try !StorageDirectoryReader.verify(root, expected: rootStamp) { partial = true }
        return StorageMeasurement(logicalBytes: logical, allocatedBytes: allocated, files: files, folders: folders,
                                  skipped: skipped, partial: partial)
    }
}
