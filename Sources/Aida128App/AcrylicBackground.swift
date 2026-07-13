import AppKit
import SwiftUI

struct AcrylicBackground: NSViewRepresentable {
    let isDark: Bool
    let reduceTransparency: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .underWindowBackground
        view.isEmphasized = true
        view.state = reduceTransparency ? .inactive : .followsWindowActiveState
        view.wantsLayer = true
        let fallback = isDark ? NSColor.windowBackgroundColor : NSColor.controlBackgroundColor
        view.layer?.backgroundColor = reduceTransparency ? fallback.cgColor : NSColor.clear.cgColor
    }
}

struct AcrylicBackdrop: View {
    let isDark: Bool
    let reduceTransparency: Bool

    var body: some View {
        ZStack {
            AbstractColorField(isDark: isDark)
            AcrylicBackground(isDark: isDark, reduceTransparency: reduceTransparency)
            if !reduceTransparency {
                Image(nsImage: AcrylicNoise.image)
                    .resizable(resizingMode: .tile)
                    .interpolation(.none)
                    .opacity(isDark ? 0.055 : 0.035)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct AbstractColorField: View {
    let isDark: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LinearGradient(
                    colors: isDark
                        ? [Color(red: 0.025, green: 0.045, blue: 0.09), Color(red: 0.12, green: 0.035, blue: 0.16)]
                        : [Color(red: 0.72, green: 0.88, blue: 1.0), Color(red: 0.96, green: 0.78, blue: 0.92)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Ellipse()
                    .fill(Color(red: 0.0, green: 0.58, blue: 0.95).opacity(isDark ? 0.78 : 0.62))
                    .frame(width: size.width * 0.78, height: size.height * 0.42)
                    .blur(radius: 58)
                    .rotationEffect(.degrees(-18))
                    .offset(x: -size.width * 0.25, y: -size.height * 0.24)
                Ellipse()
                    .fill(Color(red: 0.83, green: 0.13, blue: 0.61).opacity(isDark ? 0.62 : 0.48))
                    .frame(width: size.width * 0.66, height: size.height * 0.48)
                    .blur(radius: 72)
                    .rotationEffect(.degrees(24))
                    .offset(x: size.width * 0.31, y: size.height * 0.02)
                Ellipse()
                    .fill(Color(red: 0.0, green: 0.78, blue: 0.61).opacity(isDark ? 0.42 : 0.36))
                    .frame(width: size.width * 0.62, height: size.height * 0.32)
                    .blur(radius: 64)
                    .rotationEffect(.degrees(-8))
                    .offset(x: -size.width * 0.05, y: size.height * 0.38)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.black.opacity(isDark ? 0.26 : 0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

@MainActor
private enum AcrylicNoise {
    static let image: NSImage = {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt64 = 0xA128_F10E_2019
        for pixel in 0..<(width * height) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let value = UInt8((state >> 56) & 0xff)
            pixels[pixel * 4] = value
            pixels[pixel * 4 + 1] = value
            pixels[pixel * 4 + 2] = value
            pixels[pixel * 4 + 3] = 82
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }()
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
    }
}
