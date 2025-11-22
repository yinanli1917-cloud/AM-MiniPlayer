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
        // Use glass effect with color tinting
        Rectangle()
            .fill(.clear)
            .glassEffect(
                dominantColor != .clear
                    ? .clear.tint(dominantColor.opacity(0.8)) // Increased from 0.6 to 0.8 for deeper color
                    : .clear.tint(Color(red: 0.35, green: 0.15, blue: 0.25).opacity(0.7)),
                in: .rect(cornerRadius: 16)
            )
            .ignoresSafeArea()
            .onAppear {
                updateColor()
            }
            .onChange(of: artwork) {
                updateColor()
            }
    }

    private func updateColor() {
        if let artwork = artwork {
            DispatchQueue.global(qos: .userInitiated).async {
                if let nsColor = artwork.dominantColor() {
                    // Log the extracted color for debugging
                    var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                    nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                    self.logger.info("🎨 Extracted dominant color - H:\(hue, format: .fixed(precision: 2)) S:\(saturation, format: .fixed(precision: 2)) B:\(brightness, format: .fixed(precision: 2))")

                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.8)) {
                            self.dominantColor = Color(nsColor: nsColor)
                        }
                    }
                } else {
                    self.logger.warning("⚠️ Failed to extract dominant color")
                }
            }
        } else {
            logger.info("🔄 No artwork - clearing color")
            withAnimation(.easeInOut(duration: 0.6)) {
                dominantColor = .clear
            }
        }
    }
}
