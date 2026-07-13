import SwiftUI

enum ThemePreference: String, CaseIterable {
    case light
    case dark

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var label: String { self == .dark ? "Dark" : "Light" }
}

struct FluentPalette {
    let background: Color
    let surface: Color
    let field: Color
    let text: Color
    let secondaryText: Color
    let border: Color
    let accent: Color
    let hover: Color

    static func resolve(_ scheme: ColorScheme) -> FluentPalette {
        if scheme == .dark {
            return FluentPalette(
                background: Color(red: 0.07, green: 0.09, blue: 0.12),
                surface: Color.white.opacity(0.075),
                field: Color.white.opacity(0.09),
                text: .white,
                secondaryText: Color.white.opacity(0.66),
                border: Color.white.opacity(0.28),
                accent: Color(red: 0.00, green: 0.47, blue: 0.84),
                hover: Color.white.opacity(0.11)
            )
        }
        return FluentPalette(
            background: Color(red: 0.91, green: 0.94, blue: 0.97),
            surface: Color.white.opacity(0.58),
            field: Color.white.opacity(0.72),
            text: Color(red: 0.08, green: 0.10, blue: 0.13),
            secondaryText: Color.black.opacity(0.58),
            border: Color.black.opacity(0.22),
            accent: Color(red: 0.00, green: 0.38, blue: 0.72),
            hover: Color.white.opacity(0.64)
        )
    }
}
