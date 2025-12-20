//
//  ProgressiveBlurView.swift
//  MusicMiniPlayer
//
//  使用 Metal Shader 实现的真正渐进模糊
//  纯模糊效果，无任何颜色叠加
//

import SwiftUI

// MARK: - 渐进模糊方向

enum BlurDirection {
    case topToBottom  // 顶部模糊，底部清晰
    case bottomToTop  // 底部模糊，顶部清晰
}

// MARK: - Metal Shader 渐进模糊

/// 使用 Metal Shader 实现的渐进模糊 View Modifier
@available(macOS 14.0, *)
struct ProgressiveBlurModifier: ViewModifier {
    let direction: BlurDirection
    let maxRadius: CGFloat
    let blurHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .visualEffect { content, proxy in
                content.layerEffect(
                    ShaderLibrary.bundle(Bundle.module).progressiveBlurFromBottom(
                        .float2(proxy.size),
                        .float(maxRadius),
                        .float(blurHeight)
                    ),
                    maxSampleOffset: CGSize(width: maxRadius, height: maxRadius)
                )
            }
    }
}

// MARK: - 兼容性封装（fallback 到 NSVisualEffectView）

/// 渐进模糊视图
/// - macOS 14+：使用 Metal Shader
/// - macOS 14 以下：fallback 到 VisualEffectView + mask
struct ProgressiveBlurView: View {
    let direction: BlurDirection
    let maxBlur: CGFloat
    let height: CGFloat

    init(direction: BlurDirection = .bottomToTop, maxBlur: CGFloat = 20, height: CGFloat = 100) {
        self.direction = direction
        self.maxBlur = maxBlur
        self.height = height
    }

    var body: some View {
        // 使用 VisualEffectView + mask 作为 fallback
        // Metal shader 版本需要应用到内容上，这里是 overlay 用法
        VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
            .mask(gradientMask)
    }

    @ViewBuilder
    private var gradientMask: some View {
        switch direction {
        case .topToBottom:
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.8), location: 0.3),
                    .init(color: .black.opacity(0.5), location: 0.5),
                    .init(color: .black.opacity(0.2), location: 0.7),
                    .init(color: .clear, location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        case .bottomToTop:
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.2), location: 0.3),
                    .init(color: .black.opacity(0.5), location: 0.5),
                    .init(color: .black.opacity(0.8), location: 0.7),
                    .init(color: .black, location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - 条件渐进模糊 ViewModifier

/// 条件渐进模糊 - 避免 @ViewBuilder 中 if/else 导致视图重建
@available(macOS 14.0, *)
struct ConditionalProgressiveBlur: ViewModifier {
    let isEnabled: Bool
    let maxRadius: CGFloat
    let blurHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .visualEffect { view, geometryProxy in
                // 使用 0 半径来"禁用"模糊效果
                let effectiveRadius = isEnabled ? maxRadius : 0.0
                let effectiveHeight = isEnabled ? blurHeight : 0.0

                return view.layerEffect(
                    ShaderLibrary.bundle(Bundle.module).progressiveBlurFromBottom(
                        .float2(geometryProxy.size),
                        .float(effectiveRadius),
                        .float(effectiveHeight)
                    ),
                    maxSampleOffset: CGSize(width: maxRadius, height: maxRadius)
                )
            }
    }
}

// MARK: - View Extension

extension View {
    /// 应用渐进模糊效果（Metal Shader 版本）
    /// 需要 macOS 14+
    @available(macOS 14.0, *)
    @ViewBuilder
    func progressiveBlur(
        direction: BlurDirection = .bottomToTop,
        maxRadius: CGFloat = 20,
        blurHeight: CGFloat = 100
    ) -> some View {
        // 🔑 直接使用 visualEffect，不用 GeometryReader 避免破坏布局
        self.visualEffect { content, geometryProxy in
            switch direction {
            case .bottomToTop:
                content.layerEffect(
                    ShaderLibrary.bundle(Bundle.module).progressiveBlurFromBottom(
                        .float2(geometryProxy.size),
                        .float(maxRadius),
                        .float(blurHeight)
                    ),
                    maxSampleOffset: CGSize(width: maxRadius, height: maxRadius)
                )
            case .topToBottom:
                content.layerEffect(
                    ShaderLibrary.bundle(Bundle.module).progressiveBlurFromTop(
                        .float2(geometryProxy.size),
                        .float(maxRadius),
                        .float(blurHeight)
                    ),
                    maxSampleOffset: CGSize(width: maxRadius, height: maxRadius)
                )
            }
        }
    }

    /// 添加底部渐进模糊 overlay
    func progressiveBlurBottom(height: CGFloat = 100, blur: CGFloat = 20) -> some View {
        self.overlay(alignment: .bottom) {
            ProgressiveBlurView(direction: .bottomToTop, maxBlur: blur, height: height)
                .frame(height: height)
                .allowsHitTesting(false)
        }
    }

    /// 添加顶部渐进模糊 overlay
    func progressiveBlurTop(height: CGFloat = 100, blur: CGFloat = 20) -> some View {
        self.overlay(alignment: .top) {
            ProgressiveBlurView(direction: .topToBottom, maxBlur: blur, height: height)
                .frame(height: height)
                .allowsHitTesting(false)
        }
    }
}
