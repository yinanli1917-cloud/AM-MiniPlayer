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
    @State private var lastArtworkHash: Int = 0  // 🔑 缓存上次的 artwork hash
    private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "LiquidBackground")

    // 🔑 静态颜色缓存，避免重复计算
    private static var colorCache: NSCache<NSNumber, NSColor> = {
        let cache = NSCache<NSNumber, NSColor>()
        cache.countLimit = 50  // 最多缓存 50 个颜色
        return cache
    }()

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
        }
        .allowsHitTesting(false)  // 🔑 整个背景不拦截点击，让点击穿透到前景内容
        .onAppear {
            updateColor()
        }
        .onChange(of: artwork) {
            updateColor()
        }
    }

    private func updateColor() {
        if let artwork = artwork {
            // 🔑 使用 hash 检测是否是同一张图片
            let artworkHash = artwork.hashValue
            if artworkHash == lastArtworkHash && dominantColor != .clear {
                // 相同的 artwork，跳过计算
                return
            }

            // 🔑 检查缓存
            if let cachedColor = Self.colorCache.object(forKey: NSNumber(value: artworkHash)) {
                DispatchQueue.main.async {
                    self.lastArtworkHash = artworkHash
                    withAnimation(.easeInOut(duration: 0.5)) {
                        self.dominantColor = Color(nsColor: cachedColor)
                    }
                }
                return
            }

            // 计算颜色
            DispatchQueue.global(qos: .userInitiated).async {
                if let nsColor = artwork.dominantColor() {
                    // 缓存结果
                    Self.colorCache.setObject(nsColor, forKey: NSNumber(value: artworkHash))

                    DispatchQueue.main.async {
                        self.lastArtworkHash = artworkHash
                        withAnimation(.easeInOut(duration: 0.5)) {
                            self.dominantColor = Color(nsColor: nsColor)
                        }
                    }
                }
            }
        } else {
            lastArtworkHash = 0
            withAnimation(.easeInOut(duration: 0.4)) {
                dominantColor = .clear
            }
        }
    }
}
