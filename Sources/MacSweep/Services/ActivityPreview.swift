import Foundation

/// Bound layout work without truncating the underlying diagnostic report.
struct ActivityPreview {
    let text: String
    let truncated: Bool

    init(_ source: String) {
        let limit = 16_384
        // Inspect only the bounded tail, not the length of the whole report.
        // Scalar boundaries avoid cutting UTF-8 code units in paths/messages.
        let tail = source.unicodeScalars.suffix(limit + 1)
        truncated = tail.count > limit
        text = String(String.UnicodeScalarView(tail.suffix(limit)))
    }
}
