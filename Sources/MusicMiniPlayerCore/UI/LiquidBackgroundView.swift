import SwiftUI

public struct LiquidBackgroundView: View {
    var artwork: NSImage?
    @State private var dominantColor: NSColor?
    
    public init(artwork: NSImage? = nil) {
        self.artwork = artwork
    }
    
    public var body: some View {
        ZStack {
            // 1. Native Glass Material
            // .underWindowBackground allows the desktop wallpaper to show through with a blur.
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            // 2. Dynamic Theme Tint (Liquid Effect)
            if let color = dominantColor {
                ZStack {
                    // Translucent tint to colorize the glass
                    // Increased opacity to 0.4 to make the color (e.g. red sofa) more visible
                    Color(nsColor: color)
                        .opacity(0.4) 
                    
                    // Subtle gradient to add depth without blocking the background
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(nsColor: color).opacity(0.5),
                            Color(nsColor: color).opacity(0.1)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
            }
            
            // 3. Noise Texture (Optional, keeps it subtle)
            Rectangle()
                .fill(Color.white.opacity(0.02))
                .blendMode(.overlay)
                .ignoresSafeArea()
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
