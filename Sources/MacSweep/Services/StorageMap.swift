import Foundation

/// Relative recorded sizes, not unique volume allocation or reclaimable bytes.
struct StorageMap: Sendable {
    struct Item: Identifiable, Sendable {
        let id: String
        let entry: StorageEntry?
        let label: String
        let bytes: Double
        let partial: Bool
        let count: Int
    }
    let items: [Item]
    let unknown: Int
    let zero: Int
    static let empty = StorageMap(items: [], unknown: 0, zero: 0)

    static func prepare(_ entries: [StorageEntry], measurements: [String: StorageMeasurement]) -> StorageMap {
        var sized: [Item] = []
        var unknown = 0, zero = 0
        for entry in entries {
            guard !Task.isCancelled else { return .empty }
            let bytes: Int64
            let partial: Bool
            switch entry.kind {
            case .file: bytes = entry.allocatedBytes; partial = false
            case .folder:
                guard let measurement = measurements[entry.url.path] else { unknown += 1; continue }
                bytes = measurement.allocatedBytes; partial = measurement.partial
            case .link, .other: unknown += 1; continue
            }
            guard bytes > 0 else {
                if partial { unknown += 1 } else { zero += 1 }
                continue
            }
            sized.append(Item(id: entry.id, entry: entry, label: entry.url.lastPathComponent,
                              bytes: Double(bytes), partial: partial, count: 1))
        }
        sized.sort { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        let visible = Array(sized.prefix(12))
        let rest = sized.dropFirst(12)
        guard !rest.isEmpty else { return StorageMap(items: visible, unknown: unknown, zero: zero) }
        let grouped = Item(id: "remaining-items", entry: nil, label: "\(rest.count) more items",
                           bytes: rest.reduce(0) { $0 + $1.bytes }, partial: rest.contains(where: \.partial), count: rest.count)
        return StorageMap(items: visible + [grouped], unknown: unknown, zero: zero)
    }
}

/// Balanced binary partition keeps layout work bounded by the displayed tile count.
enum StorageMapLayout {
    struct Tile {
        let index: Int
        let rect: CGRect
    }
    static func tiles(weights: [Double], in bounds: CGRect) -> [Tile] {
        let valid = weights.indices.filter { weights[$0].isFinite && weights[$0] > 0 }
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite,
              let maximum = valid.map({ weights[$0] }).max() else { return [] }
        // Normalize before summing so even extreme finite weights cannot overflow.
        let scaled = weights.map { $0 / maximum }
        var result: [Tile] = []
        func partition(_ indices: ArraySlice<Int>, _ rect: CGRect) {
            guard let first = indices.first else { return }
            if indices.count == 1 { result.append(Tile(index: first, rect: rect)); return }
            let total = indices.reduce(0) { $0 + scaled[$1] }
            var leftWeight = scaled[first]
            var split = indices.startIndex + 1
            while split < indices.endIndex - 1 && leftWeight + scaled[indices[split]] <= total / 2 {
                leftWeight += scaled[indices[split]]; split += 1
            }
            let fraction = total > 0 ? leftWeight / total : 0.5
            let horizontal = rect.width >= rect.height
            let extent = (horizontal ? rect.width : rect.height) * fraction
            let pieces = rect.divided(atDistance: extent, from: horizontal ? .minXEdge : .minYEdge)
            partition(indices[..<split], pieces.slice)
            partition(indices[split...], pieces.remainder)
        }
        partition(valid[...], bounds)
        return result
    }
}
