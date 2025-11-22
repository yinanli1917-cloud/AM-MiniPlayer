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

            // 2. Liquid Glass Effect with dynamic tint
            if let color = dominantColor {
                Rectangle()
                    .fill(Color(nsColor: color))
                    .glassEffect(.regular.tint(Color(nsColor: color)))
                    .ignoresSafeArea()
            } else {
                // Fallback: regular glass without tint
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.regular)
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
