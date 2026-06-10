import SwiftUI
import AppKit

// MARK: - Fluid Gradient Background (Apple Music Style)
// 基于 Apple Music 逆向工程：直接用封面图片 + twist扭曲 + 模糊
// 参考: https://www.aadishv.dev/music

/// 流体渐变背景视图 - 使用封面图片 + 模糊效果
/// 🔑 优化：静态多层 + 更大偏移/旋转差异 = 流体扭曲感（无动画，CPU 友好）
/// 🔑 换曲交叉淡入：封面到达/更换/消失都经过 0.6s crossfade —— 背景永不硬切
///    （旧实现直接 swap `if let artwork` 分支，黑↔金一帧跳变，录屏可见闪烁）
public struct FluidGradientBackground: View {
    let artwork: NSImage?
    @State private var displayedArtwork: NSImage?
    @State private var tone = ArtworkBackgroundToneMap.neutral

    private static let crossfade = Animation.easeInOut(duration: 0.6)

    public init(artwork: NSImage?) {
        self.artwork = artwork
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let diagonal = sqrt(size.width * size.width + size.height * size.height)

            ZStack {
                Color.black

                if let artwork = displayedArtwork {
                    ZStack {
                        ZStack {
                            fluidLayer(artwork: artwork, containerSize: size,
                                       size: diagonal * 1.5,
                                       offsetX: size.width * 0.05, offsetY: -size.height * 0.03,
                                       rotation: 0.12)

                            fluidLayer(artwork: artwork, containerSize: size,
                                       size: diagonal * 0.95,
                                       offsetX: -size.width * 0.22, offsetY: -size.height * 0.15,
                                       rotation: 0.45)

                            fluidLayer(artwork: artwork, containerSize: size,
                                       size: diagonal * 0.8,
                                       offsetX: size.width * 0.25, offsetY: size.height * 0.2,
                                       rotation: -0.35)
                        }
                        .blur(radius: 58)
                        .saturation(tone.textureSaturation)
                        .contrast(tone.textureContrast)
                        .brightness(tone.textureBrightness)

                        Color.white
                            .opacity(tone.liftOpacity)
                            .blendMode(.screen)

                        Color.black
                            .opacity(tone.shadeOpacity)
                    }
                    // Distinct identity per artwork: a change crossfades old → new instead of
                    // mutating one subtree in place (which applies as an instant cut).
                    .id(ObjectIdentifier(artwork))
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            displayedArtwork = artwork
            updateTone()
        }
        .onChange(of: artwork) {
            withAnimation(Self.crossfade) {
                displayedArtwork = artwork
                updateTone()
            }
        }
    }

    @ViewBuilder
    private func fluidLayer(
        artwork: NSImage,
        containerSize: CGSize,
        size: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat,
        rotation: CGFloat
    ) -> some View {
        Image(nsImage: artwork)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipped()
            .rotationEffect(.radians(rotation))
            .position(x: containerSize.width / 2 + offsetX, y: containerSize.height / 2 + offsetY)
    }

    private func updateTone() {
        guard let artwork else {
            tone = .neutral
            return
        }
        tone = ArtworkBackgroundToneMap.forMetrics(artwork.artworkVisualMetrics())
    }
}

struct ArtworkVisualMetrics: Equatable {
    let averageLuminance: Double
    let shadowLuminance: Double
    let highlightLuminance: Double
    let luminanceSpread: Double
    let averageSaturation: Double

    static let neutral = ArtworkVisualMetrics(
        averageLuminance: 0.5,
        shadowLuminance: 0.25,
        highlightLuminance: 0.75,
        luminanceSpread: 0.5,
        averageSaturation: 0.35
    )
}

struct ArtworkBackgroundToneMap {
    static let neutral = ArtworkBackgroundToneMap(
        shadeOpacity: 0.18,
        liftOpacity: 0.0,
        textureBrightness: -0.16,
        textureSaturation: 1.14,
        textureContrast: 1.08,
        textureDimmingOpacity: 0.06
    )

    let shadeOpacity: Double
    let liftOpacity: Double
    let textureBrightness: Double
    let textureSaturation: Double
    let textureContrast: Double
    let textureDimmingOpacity: Double

    static func forLuminance(_ luminance: CGFloat) -> ArtworkBackgroundToneMap {
        forMetrics(ArtworkVisualMetrics(
            averageLuminance: Double(luminance),
            shadowLuminance: max(0, Double(luminance) - 0.25),
            highlightLuminance: min(1, Double(luminance) + 0.25),
            luminanceSpread: 0.5,
            averageSaturation: 0.35
        ))
    }

    static func forMetrics(_ metrics: ArtworkVisualMetrics) -> ArtworkBackgroundToneMap {
        let average = clamp(metrics.averageLuminance)
        let highlight = clamp(metrics.highlightLuminance)
        let spread = clamp(metrics.luminanceSpread)
        let saturation = clamp(metrics.averageSaturation)
        let highlightPressure = max(0.0, (highlight - 0.62) / 0.38)
        let whiteoutPressure = max(0.0, (average - 0.56) / 0.44)
        let flatness = max(0.0, (0.22 - spread) / 0.22)
        let lowChroma = max(0.0, (0.18 - saturation) / 0.18)
        let highChroma = max(0.0, (saturation - 0.58) / 0.42)
        let darkPressure = max(0.0, (0.24 - average) / 0.24)
        let shadowPressure = max(0.0, (0.18 - metrics.shadowLuminance) / 0.18)

        return ArtworkBackgroundToneMap(
            shadeOpacity: min(0.34, 0.12 + highlightPressure * 0.11 + whiteoutPressure * 0.08 + flatness * 0.03 + highChroma * 0.04 - darkPressure * 0.05),
            liftOpacity: min(0.075, shadowPressure * 0.035 + darkPressure * 0.055),
            textureBrightness: -0.13 - highlightPressure * 0.12 - whiteoutPressure * 0.10 + darkPressure * 0.10,
            textureSaturation: min(1.26, max(0.82, 1.08 + lowChroma * 0.10 - highChroma * 0.24)),
            textureContrast: min(1.24, max(1.02, 1.06 + flatness * 0.12 + highlightPressure * 0.08 - highChroma * 0.10 - darkPressure * 0.04)),
            textureDimmingOpacity: min(0.13, highlightPressure * 0.07 + whiteoutPressure * 0.06 + highChroma * 0.025)
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

// MARK: - macOS 15+ MeshGradient 版本（备选方案）

@available(macOS 15.0, *)
public struct MeshGradientBackground: View {
    let artwork: NSImage?

    @State private var phase: CGFloat = 0

    public init(artwork: NSImage?) {
        self.artwork = artwork
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let baseSize = min(size.width, size.height)

            ZStack {
                Color.black

                if let artwork = artwork {
                    // 使用与 FluidGradientBackground 相同的多层封面方案
                    // Layer 1: 125%
                    artworkLayer(artwork: artwork, size: baseSize * 1.25, containerSize: size,
                                 rotation: phase * 0.3, offsetRadius: 0, offsetAngle: 0)
                    // Layer 2: 80%
                    artworkLayer(artwork: artwork, size: baseSize * 0.8, containerSize: size,
                                 rotation: -phase * 0.4, offsetRadius: 0, offsetAngle: 0)
                    // Layer 3: 50%
                    artworkLayer(artwork: artwork, size: baseSize * 0.5, containerSize: size,
                                 rotation: phase * 0.6, offsetRadius: baseSize * 0.15, offsetAngle: phase)
                    // Layer 4: 25%
                    artworkLayer(artwork: artwork, size: baseSize * 0.25, containerSize: size,
                                 rotation: -phase * 0.8, offsetRadius: baseSize * 0.2, offsetAngle: -phase * 1.2 + .pi)
                }
            }
            .blur(radius: 60)
            .saturation(1.4)
            .brightness(-0.05)
        }
        .onAppear {
            startAnimation()
        }
    }

    @ViewBuilder
    private func artworkLayer(
        artwork: NSImage,
        size: CGFloat,
        containerSize: CGSize,
        rotation: CGFloat,
        offsetRadius: CGFloat,
        offsetAngle: CGFloat
    ) -> some View {
        let centerX = containerSize.width / 2
        let centerY = containerSize.height / 2
        let offsetX = offsetRadius > 0 ? cos(offsetAngle) * offsetRadius : 0
        let offsetY = offsetRadius > 0 ? sin(offsetAngle) * offsetRadius : 0

        Image(nsImage: artwork)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipped()
            .rotationEffect(.radians(rotation))
            .position(x: centerX + offsetX, y: centerY + offsetY)
    }

    private func startAnimation() {
        withAnimation(.linear(duration: 40).repeatForever(autoreverses: false)) {
            phase = .pi * 2
        }
    }
}

// MARK: - 统一入口

public struct AdaptiveFluidBackground: View {
    let artwork: NSImage?

    public init(artwork: NSImage?) {
        self.artwork = artwork
    }

    public var body: some View {
        // 两个实现现在相同，直接用 FluidGradientBackground
        FluidGradientBackground(artwork: artwork)
    }
}
