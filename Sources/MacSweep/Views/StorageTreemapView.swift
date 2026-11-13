import SwiftUI

struct StorageTreemapView: View {
    let map: StorageMap
    let canNavigate: Bool
    let onOpen: (StorageEntry) -> Void
    let onShowList: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relative recorded sizes").font(.headline)
            Text("Tiles compare allocated bytes for matching items. Shared blocks may be counted more than once; this is not reclaimable space. Partial folder totals omit skipped content.")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(map.unknown) unmeasured or unsupported · \(map.zero) items with zero recorded allocated bytes. Use the list to measure folders.")
                .font(.caption).foregroundStyle(.secondary)
            if map.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No positive measured sizes to map.")
                    Button("Show List", action: onShowList)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    let tiles = StorageMapLayout.tiles(weights: map.items.map(\.bytes), in: CGRect(origin: .zero, size: proxy.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(tiles, id: \.index) { tile in
                            let item = map.items[tile.index]
                            Button {
                                if let entry = item.entry { onOpen(entry) } else { onShowList() }
                            } label: {
                                ZStack(alignment: .topLeading) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.accentColor.opacity(item.entry?.kind == .folder ? 0.32 : 0.17))
                                    if tile.rect.width > 85 && tile.rect.height > 52 {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Label(item.label, systemImage: item.entry?.kind == .folder ? "folder" : item.entry == nil ? "ellipsis" : "doc")
                                                .font(.callout.weight(.medium)).lineLimit(2)
                                            Text(size(item)).font(.caption).lineLimit(1)
                                            if item.partial { Text("Partial total").font(.caption).foregroundStyle(.secondary) }
                                        }.padding(9)
                                    }
                                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(item.entry?.kind == .folder && !canNavigate)
                            .frame(width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3))
                            .clipped()
                            .position(x: tile.rect.midX, y: tile.rect.midY)
                            .help(description(item))
                            .accessibilityLabel(description(item))
                        }
                    }
                }.frame(minHeight: 200)
            }
        }
    }

    private func size(_ item: StorageMap.Item) -> String {
        item.bytes >= Double(Int64.max) ? "Over " + Int64.max.formattedFileSize : Int64(item.bytes).formattedFileSize
    }
    private func description(_ item: StorageMap.Item) -> String {
        item.label + ": " + size(item) + (item.partial ? ", partial total. " : ". ")
            + (item.entry == nil ? "Show remaining items in the list." : item.entry?.kind == .folder ? "Open folder." : "Reveal in Finder.")
    }
}
