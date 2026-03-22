import SwiftUI
import AppKit

// MARK: - Fluid Gradient Background (Apple Music Style)
// 基于 Apple Music 逆向工程：直接用封面图片 + twist扭曲 + 模糊
// 参考: https://www.aadishv.dev/music

/// 流体渐变背景视图 - 使用封面图片 + 模糊效果
/// 🔑 优化：静态多层 + 更大偏移/旋转差异 = 流体扭曲感（无动画，CPU 友好）
public struct FluidGradientBackground: View {
    let artwork: NSImage?

    public init(artwork: NSImage?) {
        self.artwork = artwork
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let diagonal = sqrt(size.width * size.width + size.height * size.height)

            ZStack {
                if let artwork = artwork {
                    // 🎨 5 层封面副本，模拟动画的"某一帧"静止状态
                    // 通过更大的偏移和旋转差异，创造流体扭曲感

                    // Layer 0: 超大底层，轻微偏移，确保填满角落
                    fluidLayer(artwork: artwork, containerSize: size,
                               size: diagonal * 1.5,
                               offsetX: size.width * 0.05, offsetY: -size.height * 0.03,
                               rotation: 0.12)

                    // Layer 1: 偏左上，较大旋转
                    fluidLayer(artwork: artwork, containerSize: size,
                               size: diagonal * 0.95,
                               offsetX: -size.width * 0.22, offsetY: -size.height * 0.15,
                               rotation: 0.45)

                    // Layer 2: 偏右下，反向旋转
                    fluidLayer(artwork: artwork, containerSize: size,
                               size: diagonal * 0.8,
                               offsetX: size.width * 0.25, offsetY: size.height * 0.2,
                               rotation: -0.35)

                    // Layer 3: 偏左下，更大旋转
                    fluidLayer(artwork: artwork, containerSize: size,
                               size: diagonal * 0.65,
                               offsetX: -size.width * 0.18, offsetY: size.height * 0.22,
                               rotation: 0.7)

                    // Layer 4: 偏右上，极端旋转
                    fluidLayer(artwork: artwork, containerSize: size,
                               size: diagonal * 0.5,
                               offsetX: size.width * 0.2, offsetY: -size.height * 0.18,
                               rotation: -0.55)
                }
            }
            .blur(radius: 55)
            .saturation(1.2)
            .brightness(-0.08)
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
