import SwiftUI
import os

public struct LiquidBackgroundView: View {
    var artwork: NSImage?
    @State private var dominantColor: Color = .clear
    private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "LiquidBackground")

    public init(artwork: NSImage? = nil) {
        self.artwork = artwork
    }

    public var body: some View {
        ZStack {
            // 底层：艳丽的颜色背景（clear需要colorful背景）
            // 注意：dominantColor已经在提取时增强过了，这里不再处理
            if dominantColor != .clear {
                dominantColor
                    .opacity(0.3)  // 提高opacity让颜色更明显
            } else {
                Color(red: 0.99, green: 0.24, blue: 0.27)  // 使用鲜艳的红色作为fallback
                    .opacity(0.3)
            }

            // 顶层：clear glass效果（最大透明度）
            Rectangle()
                .fill(.clear)
                .glassEffect(
                    {
                        if dominantColor != .clear {
                            return .clear.tint(dominantColor)
                        } else {
                            return .clear.tint(Color(red: 0.35, green: 0.15, blue: 0.25))
                        }
                    }(),
                    in: .rect(cornerRadius: 16)
                )
        }
        .ignoresSafeArea()
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
