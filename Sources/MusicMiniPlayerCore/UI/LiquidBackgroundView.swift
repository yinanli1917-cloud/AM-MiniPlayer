import SwiftUI

public struct LiquidBackgroundView: View {
    var artwork: NSImage?
    @State private var dominantColor: NSColor?

    public init(artwork: NSImage? = nil) {
        self.artwork = artwork
    }

    public var body: some View {
        ZStack {
            // 1. Base layer with desktop wallpaper transparency
            Rectangle()
                .fill(.clear)
                .ignoresSafeArea()

            // 2. Liquid Glass Effect with dynamic tint (clear style for more transparency)
            if let color = dominantColor {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.clear.tint(Color(nsColor: color).opacity(0.3)))
                    .ignoresSafeArea()
            } else {
                // Fallback: clear glass without tint
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.clear)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            updateColor()
        }
        .onChange(of: artwork) { _ in
            updateColor()
        }
    }

    private func updateColor() {
        if let artwork = artwork {
            DispatchQueue.global(qos: .userInitiated).async {
                let color = artwork.dominantColor()
                DispatchQueue.main.async {
                    withAnimation(.linear(duration: 0.5)) {
                        self.dominantColor = color
                    }
                }
            }
        }
    }
}

#Preview {
    ZStack {
        // Simulate Desktop Wallpaper
        Color.purple
            .ignoresSafeArea()
        
        // The Player Window Background
        LiquidBackgroundView(artwork: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil))
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
