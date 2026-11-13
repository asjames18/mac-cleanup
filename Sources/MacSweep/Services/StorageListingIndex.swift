import Foundation

/// Prepared off the main actor once per listing, not on each SwiftUI redraw.
struct StorageListingIndex: Sendable {
    private struct Row: Sendable {
        let entry: StorageEntry
        let name: String
        let searchKey: String
    }
    private let byName: [Row]
    private let bySize: [Row]
    private let locale: Locale
    static let empty = StorageListingIndex(entries: [])

    init(entries: [StorageEntry]) {
        let locale = Locale.current
        self.locale = locale
        func rank(_ kind: StorageEntry.Kind) -> Int {
            switch kind { case .folder: 0; case .file: 1; case .link: 2; case .other: 3 }
        }
        let rows = entries.map { entry in
            let name = entry.url.lastPathComponent
            return Row(entry: entry, name: name, searchKey: name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale))
        }.sorted {
            if rank($0.entry.kind) != rank($1.entry.kind) { return rank($0.entry.kind) < rank($1.entry.kind) }
            let order = $0.name.localizedStandardCompare($1.name)
            if order == .orderedSame { return $0.entry.id < $1.entry.id }
            return order == .orderedAscending
        }
        byName = rows
        bySize = rows.enumerated().sorted {
            if rank($0.element.entry.kind) != rank($1.element.entry.kind) { return rank($0.element.entry.kind) < rank($1.element.entry.kind) }
            if $0.element.entry.kind == .file && $0.element.entry.allocatedBytes != $1.element.entry.allocatedBytes {
                return $0.element.entry.allocatedBytes > $1.element.entry.allocatedBytes
            }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    func matching(_ query: String, largestFirst: Bool) -> [StorageEntry] {
        let rows = largestFirst ? bySize : byName
        let key = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        var matches: [StorageEntry] = []
        for (offset, row) in rows.enumerated() {
            if offset % 128 == 0 && Task.isCancelled { return [] }
            if query.isEmpty || row.searchKey.contains(key) { matches.append(row.entry) }
        }
        return matches
    }
}
