import SwiftUI

/// Antonio's dark palette (handoff §1). Use these instead of system accent colors.
enum Theme {
    static let bg = Color(hex: 0x0D1017)
    static let panel = Color(hex: 0x141822)
    static let panel2 = Color(hex: 0x1A1F2C)
    static let line = Color(hex: 0x262C3B)
    static let text = Color(hex: 0xE8EBF2)
    static let muted = Color(hex: 0x8A93A8)
    static let accent = Color(hex: 0x7C6CFF)
    static let accent2 = Color(hex: 0x2DD4BF)
    static let danger = Color(hex: 0xFF5D73)
    static let warn = Color(hex: 0xFFA94D)
    static let info = Color(hex: 0x6EA8FE)
    static let ok = Color(hex: 0x3DDC97)
    static let radius: CGFloat = 14
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A keycap label used by the shortcut overlay.
struct Kbd: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
    }
}

struct Chip: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}
