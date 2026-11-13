import SwiftUI

struct SuiteCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line) }
    }
}

struct SuiteEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent2).padding(24)
                .background(Theme.accent2.opacity(0.08), in: Circle())
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 430)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct UsageMeter: View, Equatable {
    let fraction: Double?
    var color: Color = Theme.accent2

    nonisolated static func == (lhs: UsageMeter, rhs: UsageMeter) -> Bool { lhs.fraction == rhs.fraction && lhs.color == rhs.color }

    var body: some View {
        // Drawn in a Canvas: a new value is a cheap redraw with no layout pass (no GeometryReader).
        Canvas { context, size in
            let radius = size.height / 2
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius),
                         with: .color(.primary.opacity(0.06)))
            if let fraction {
                let width = size.width * min(1, max(0, fraction))
                context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height), cornerRadius: radius),
                             with: .style(color.gradient))
            }
        }
        .frame(height: 7)
        .accessibilityElement()
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "Unavailable")
    }
}

/// Shown above cleanup views while the test sandbox is on.
struct SandboxBanner: View {
    var onTurnOff: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "testtube.2").foregroundStyle(Theme.warn)
            Text(SandboxText.banner).font(.callout).foregroundStyle(Theme.text)
            Spacer()
            Button("Turn Off Sandbox…", action: onTurnOff)
                .help("Asks “Do you really want to do this action?” first")
        }
        .padding(.horizontal, 24).padding(.vertical, 9)
        .background(Theme.warn.opacity(0.10))
        .accessibilityElement(children: .combine)
    }
}
