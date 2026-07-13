import SwiftUI

struct RevealButton<Content: View>: View {
    let enabled: Bool
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var target = CGPoint.zero
    @State private var light = CGPoint.zero
    @State private var hovering = false

    var body: some View {
        let palette = FluentPalette.resolve(colorScheme)
        Button(action: action) {
            content()
                .contentShape(Rectangle())
                .background(selected ? palette.accent.opacity(0.22) : palette.field)
                .overlay {
                    GeometryReader { geometry in
                        if hovering {
                            revealFill(size: geometry.size)
                            revealBorder(size: geometry.size)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .overlay(
                    Rectangle().stroke(
                        selected ? palette.accent.opacity(0.92) : palette.border.opacity(0.62),
                        lineWidth: selected ? 1.4 : 0.7
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.62)
        .onContinuousHover { phase in
            guard enabled else { return }
            switch phase {
            case let .active(location):
                target = location
                if !hovering {
                    light = location
                    hovering = true
                } else if reduceMotion {
                    light = location
                } else {
                    withAnimation(.linear(duration: 0.075)) { light = location }
                }
            case .ended:
                if reduceMotion {
                    hovering = false
                } else {
                    withAnimation(.easeOut(duration: 0.14)) { hovering = false }
                }
            }
        }
    }

    private func revealFill(size: CGSize) -> some View {
        RadialGradient(
            colors: [Color.white.opacity(colorScheme == .dark ? 0.20 : 0.42), .clear],
            center: normalizedCenter(in: size),
            startRadius: 0,
            endRadius: max(56, min(120, size.width * 0.78))
        )
        .blendMode(colorScheme == .dark ? .screen : .plusLighter)
    }

    private func revealBorder(size: CGSize) -> some View {
        Rectangle()
            .stroke(Color.white.opacity(colorScheme == .dark ? 0.90 : 0.78), lineWidth: 1.25)
            .mask(
                RadialGradient(
                    colors: [.white, .clear],
                    center: normalizedCenter(in: size),
                    startRadius: 2,
                    endRadius: max(42, min(92, size.width * 0.62))
                )
            )
    }

    private func normalizedCenter(in size: CGSize) -> UnitPoint {
        UnitPoint(
            x: max(0, min(1, light.x / max(size.width, 1))),
            y: max(0, min(1, light.y / max(size.height, 1)))
        )
    }
}
