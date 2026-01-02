import SwiftUI
import AppKit

// MARK: - Fluid Gradient Background (Apple Music Style)
// 基于 Apple Music 逆向工程：直接用封面图片 + twist扭曲 + 模糊
// 参考: https://www.aadishv.dev/music

/// 流体渐变背景视图 - 使用封面图片本身而非提取颜色
/// 使用 TimelineView 实现真正的持续流体动画
public struct FluidGradientBackground: View {
    let artwork: NSImage?

    public init(artwork: NSImage?) {
        self.artwork = artwork
    }

    public var body: some View {
        // 🔑 使用 TimelineView 实现真正的持续动画
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            GeometryReader { geometry in
                let size = geometry.size
                let diagonal = sqrt(size.width * size.width + size.height * size.height)

                ZStack {
                    if let artwork = artwork {
                        // 🎨 5 层封面副本，持续不规则运动

                        // Layer 0: 超大底层，确保填满所有角落，缓慢旋转
                        artworkLayer(
                            artwork: artwork,
                            size: diagonal * 1.4,
                            containerSize: size,
                            rotation: time * 0.02,
                            offsetX: sin(time * 0.03) * size.width * 0.05,
                            offsetY: cos(time * 0.025) * size.height * 0.05
                        )

                        // Layer 1: 偏左上，独立运动轨迹
                        artworkLayer(
                            artwork: artwork,
                            size: diagonal * 0.85,
                            containerSize: size,
                            rotation: -time * 0.035 + 0.5,
                            offsetX: sin(time * 0.05 + 1.0) * size.width * 0.2 - size.width * 0.1,
                            offsetY: cos(time * 0.04 + 0.5) * size.height * 0.15 - size.height * 0.1
                        )

                        // Layer 2: 偏右下，反向运动
                        artworkLayer(
                            artwork: artwork,
                            size: diagonal * 0.7,
                            containerSize: size,
                            rotation: time * 0.045 - 0.8,
                            offsetX: cos(time * 0.055 + 2.0) * size.width * 0.2 + size.width * 0.1,
                            offsetY: sin(time * 0.045 + 1.5) * size.height * 0.2 + size.height * 0.1
                        )

                        // Layer 3: 偏左下，8 字形轨迹
                        artworkLayer(
                            artwork: artwork,
                            size: diagonal * 0.55,
                            containerSize: size,
                            rotation: -time * 0.06 + 1.5,
                            offsetX: sin(time * 0.07) * size.width * 0.25 - size.width * 0.05,
                            offsetY: sin(time * 0.07 * 2) * size.height * 0.15 + size.height * 0.15
                        )

                        // Layer 4: 偏右上，椭圆轨迹
                        artworkLayer(
                            artwork: artwork,
                            size: diagonal * 0.4,
                            containerSize: size,
                            rotation: time * 0.08 - 2.0,
                            offsetX: cos(time * 0.08 + 3.0) * size.width * 0.3 + size.width * 0.1,
                            offsetY: sin(time * 0.06 + 2.0) * size.height * 0.2 - size.height * 0.1
                        )
                    }
                }
                // 🔑 模糊
                .blur(radius: 55)
                // 🔑 饱和度 - 稍微增强
                .saturation(1.2)
                // 🔑 轻微降低亮度
                .brightness(-0.08)
            }
        }
    }

    /// 单个封面图层
    @ViewBuilder
    private func artworkLayer(
        artwork: NSImage,
        size: CGFloat,
        containerSize: CGSize,
        rotation: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat
    ) -> some View {
        let centerX = containerSize.width / 2
        let centerY = containerSize.height / 2

        Image(nsImage: artwork)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipped()
            .rotationEffect(.radians(rotation))
            .position(x: centerX + offsetX, y: centerY + offsetY)
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
