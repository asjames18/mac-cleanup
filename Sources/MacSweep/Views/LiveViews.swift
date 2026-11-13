import AppKit
import Combine
import SwiftUI

/// Live text and meters that bypass SwiftUI's update and layout passes. Each one subscribes to a
/// `ReadingStore` and, when its own displayed value changes, marks only itself for redraw. A new sample
/// therefore never re-evaluates the dashboard's views or re-lays out the window.

/// How a live label looks. Fonts are resolved once.
enum LiveTextStyle {
    case metric, caption, captionMono

    var font: NSFont {
        switch self {
        case .metric:
            let base = NSFont.monospacedDigitSystemFont(ofSize: 27, weight: .semibold)
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 27) } ?? base
        case .caption: return NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        case .captionMono: return NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        }
    }

    var color: NSColor {
        switch self {
        case .metric: .labelColor
        case .caption, .captionMono: .secondaryLabelColor
        }
    }
}

/// Draws one string. Changing `text` only asks for a redraw of this view; its size never changes.
final class LiveLabelView: NSView {
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(text)
            redraws += 1
        }
    }
    var style: LiveTextStyle = .caption { didSet { attributes = Self.attributes(style, alignment: alignment) } }
    var alignment: NSTextAlignment = .left { didSet { attributes = Self.attributes(style, alignment: alignment) } }
    private(set) var redraws = 0
    private var attributes: [NSAttributedString.Key: Any] = LiveLabelView.attributes(.caption, alignment: .left)

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func attributes(_ style: LiveTextStyle, alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: style.font, .foregroundColor: style.color, .paragraphStyle: paragraph]
    }

    override func draw(_ dirtyRect: NSRect) {
        (text as NSString).draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}

/// A rounded usage bar drawn directly; a new fraction is a redraw of this view only.
final class LiveMeterView: NSView {
    var fraction: Double? {
        didSet { if fraction != oldValue { needsDisplay = true; redraws += 1 } }
    }
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    private(set) var redraws = 0

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard let fraction else { return }
        let width = bounds.width * min(1, max(0, fraction))
        guard width > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: radius, yRadius: radius).fill()
    }
}

/// A label bound to a reading store.
struct LiveText<Value: Equatable>: NSViewRepresentable {
    let store: ReadingStore<Value>
    var style: LiveTextStyle = .caption
    var alignment: NSTextAlignment = .left
    let text: (Value) -> String

    final class Coordinator { var subscription: AnyCancellable? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LiveLabelView {
        let view = LiveLabelView(frame: .zero)
        view.style = style
        view.alignment = alignment
        view.text = text(store.value)
        let transform = text
        context.coordinator.subscription = store.$value.map(transform).removeDuplicates()
            .sink { [weak view] newText in MainActor.assumeIsolated { view?.text = newText } }
        return view
    }

    func updateNSView(_ view: LiveLabelView, context: Context) {}
}

/// A usage bar bound to a reading store.
struct LiveMeter<Value: Equatable>: NSViewRepresentable {
    let store: ReadingStore<Value>
    let color: Color
    let fraction: (Value) -> Double?

    final class Coordinator { var subscription: AnyCancellable? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LiveMeterView {
        let view = LiveMeterView(frame: .zero)
        view.color = NSColor(color)
        view.fraction = fraction(store.value)
        let transform = fraction
        context.coordinator.subscription = store.$value.map(transform).removeDuplicates()
            .sink { [weak view] newFraction in MainActor.assumeIsolated { view?.fraction = newFraction } }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.levelIndicator)
        return view
    }

    func updateNSView(_ view: LiveMeterView, context: Context) {}
}
