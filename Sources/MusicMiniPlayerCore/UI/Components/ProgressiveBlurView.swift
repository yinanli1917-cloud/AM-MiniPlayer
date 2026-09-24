//
//  ProgressiveBlurView.swift
//  MusicMiniPlayer
//
//  VisualEffectView + 渐变 mask 的渐进模糊 overlay
//

import SwiftUI

// MARK: - 渐进模糊方向

enum BlurDirection {
    case topToBottom  // 顶部模糊，底部清晰
    case bottomToTop  // 底部模糊，顶部清晰
}

// MARK: - VisualEffectView 渐进模糊

/// 渐进模糊视图：VisualEffectView + 渐变 mask
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
        VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
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

// MARK: - View Extension

extension View {
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
