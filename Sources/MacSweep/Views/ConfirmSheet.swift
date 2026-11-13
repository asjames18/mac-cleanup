import MacSweepCore
import SwiftUI

struct ConfirmRow: Identifiable, Hashable, Sendable {
    let path: String
    let size: Int64?
    var id: String { path }
}

struct PendingConfirmation: Identifiable, Equatable {
    let preview: ConfirmationPreview
    let summary: String
    let detail: String
    let rows: [ConfirmRow]
    var actionTitle = "Move to Trash"
    var reversible = true
    var sandboxOn = true
    /// Items the sandbox will refuse; shown up front instead of after the move.
    var outsideSandbox = 0
    var id: String { preview.token }

    var totalSize: Int64? {
        let known = rows.compactMap(\.size)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}

/// "Do you really want to do this action?" Return confirms, Esc cancels.
struct ConfirmSheet: View {
    let pending: PendingConfirmation
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.title2)
                Text(ConfirmationLedger.title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
            }
            Text(pending.summary + (pending.totalSize.map { " · \($0.formattedFileSize)" } ?? ""))
                .font(.headline).foregroundStyle(Theme.text)
            Text(pending.detail).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(pending.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(row.path).font(.caption.monospaced()).foregroundStyle(Theme.text)
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(row.size?.formattedFileSize ?? "size not measured").font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                            Chip(text: pending.reversible ? "Reversible" : "Not reversible", color: pending.reversible ? Theme.ok : Theme.danger)
                        }
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        Divider().overlay(Theme.line)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 260)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
            Label(pending.reversible ? "Items go to the Trash. Restore them from Finder Trash or History." : "This action cannot be undone.",
                  systemImage: pending.reversible ? "arrow.uturn.backward.circle" : "xmark.octagon")
                .font(.caption).foregroundStyle(Theme.muted)
            if pending.sandboxOn {
                Label(pending.outsideSandbox > 0
                      ? "\(SandboxText.items(pending.outsideSandbox)) \(pending.outsideSandbox == 1 ? "is" : "are") outside the test sandbox and will be skipped."
                      : "Test sandbox is on: anything outside the sandbox folder will be refused.", systemImage: "testtube.2")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
            HStack {
                Text("Expires \(pending.preview.expiresAt.formatted(date: .omitted, time: .shortened)) · single use")
                    .font(.caption).foregroundStyle(Theme.muted)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(pending.actionTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction).tint(Theme.danger).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 620)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }
}
