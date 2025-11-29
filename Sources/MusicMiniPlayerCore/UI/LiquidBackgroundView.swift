import SwiftUI
import AppKit
import os

// MARK: - NSVisualEffectView Wrapper for macOS Liquid Glass
struct LiquidGlassEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

public struct LiquidBackgroundView: View {
    var artwork: NSImage?
    @State private var dominantColor: Color = .clear
    private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "LiquidBackground")

    public init(artwork: NSImage? = nil) {
        self.artwork = artwork
    }

    public var body: some View {
        ZStack {
            // 第一层：macOS Liquid Glass - NSVisualEffectView with behindWindow blending
            LiquidGlassEffectView(
                material: .hudWindow,
                blendingMode: .behindWindow
            )
            .ignoresSafeArea()

            // 第二层：专辑主色调 - 使用更高的不透明度和正常混合
            if dominantColor != .clear {
                dominantColor
                    .opacity(0.6)  // 从0.35提高到0.6
                    .ignoresSafeArea()
                    .blendMode(.normal)  // 使用normal而不是overlay
            }

            // 第三层：额外的半透明材质层增强玻璃效果
            LiquidGlassEffectView(
                material: .hudWindow,
                blendingMode: .withinWindow
            )
            .ignoresSafeArea()
            .opacity(0.5)

            // 第四层：高光渐变层
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.white.opacity(0.25),
                    Color.clear,
                    Color.clear
                ]),
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()
            .blendMode(.overlay)

            // 第五层：深度渐变
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.white.opacity(0.04),
                    Color.clear,
                    Color.black.opacity(0.08)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .onAppear {
            updateColor()
        }
        .onChange(of: artwork) {
            updateColor()
        }
    }

    private func updateColor() {
        print("🎨 updateColor called, artwork available: \(artwork != nil)")

        if let artwork = artwork {
            DispatchQueue.global(qos: .userInitiated).async {
                if let nsColor = artwork.dominantColor() {
                    // Log the extracted color for debugging
                    var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                    nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

                    // Also log RGB values
                    let red = nsColor.redComponent
                    let green = nsColor.greenComponent
                    let blue = nsColor.blueComponent

                    print("🎨 Extracted dominant color - RGB: R=\(String(format: "%.2f", red)) G=\(String(format: "%.2f", green)) B=\(String(format: "%.2f", blue)) HSB: H=\(String(format: "%.2f", hue)) S=\(String(format: "%.2f", saturation)) B=\(String(format: "%.2f", brightness))")

                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.8)) {
                            self.dominantColor = Color(nsColor: nsColor)
                        }
                        print("🎨 Color applied to background")
                    }
                } else {
                    print("⚠️ Failed to extract dominant color")
                }
            }
        } else {
            print("🔄 No artwork - clearing color")
            withAnimation(.easeInOut(duration: 0.6)) {
                dominantColor = .clear
            }
        }
    }
}
