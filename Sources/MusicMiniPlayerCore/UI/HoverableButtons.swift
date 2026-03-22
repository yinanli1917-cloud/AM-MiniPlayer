/**
 * [INPUT]: MusicController (播放状态), LyricsService (翻译状态)
 * [OUTPUT]: MusicButtonView, GlassButtonBackground, HideButtonView, ExpandButtonView, TranslationButtonView, PlaylistTabBarIntegrated
 * [POS]: UI/ 的可复用按钮组件，从 MiniPlayerView 拆分
 */

import SwiftUI
import AppKit

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - GlassButtonBackground
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 macOS 26+ Liquid Glass 按钮背景适配

struct GlassButtonBackground: ViewModifier {
    var fillOpacity: Double
    var shadowOpacity: Double
    var shadowRadius: CGFloat
    var isLightBackground: Bool = false  // 🔑 背景亮度信息，用于文字颜色适配

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // 🔑 Liquid Glass: 使用 .clear 材质，亮色背景用黑字
            content
                .foregroundStyle(isLightBackground ? Color.black : Color.white)
                .glassEffect(.clear.tint(Color.black.opacity(0.1)), in: .capsule)
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: 3)
        } else {
            content
                .foregroundStyle(isLightBackground ? Color.black : Color.white)
                .background(Color.white.opacity(fillOpacity))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: 3)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Hoverable Button Style Helpers
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 共享的亮度/透明度计算，消除 MusicButtonView/HideButtonView/ExpandButtonView 的重复代码

private func hoverableButtonFillOpacity(isLightBackground: Bool, isHovering: Bool) -> Double {
    isLightBackground
        ? (isHovering ? 0.55 : 0.45)
        : (isHovering ? 0.20 : 0.10)
}

private func hoverableButtonShadowOpacity(isLightBackground: Bool) -> Double {
    isLightBackground ? 0.5 : 0.0
}

private func hoverableButtonShadowRadius(isLightBackground: Bool) -> CGFloat {
    isLightBackground ? 10 : 0
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - HoverableActionButton（统一的 Glass 按钮）
// ═══════════════════════════════════════════════════════════════════════════════

struct HoverableActionButton: View {
    let action: () -> Void
    let label: AnyView
    var helpText: String = ""
    var accessibilityText: String = ""  // 🔑 无障碍标签，独立于 helpText
    var artworkBrightness: CGFloat = 0.5
    var isAlbumPage: Bool = false

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isLightBackground: Bool { isAlbumPage && artworkBrightness > 0.5 }

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .modifier(GlassButtonBackground(
                    fillOpacity: hoverableButtonFillOpacity(isLightBackground: isLightBackground, isHovering: isHovering),
                    shadowOpacity: hoverableButtonShadowOpacity(isLightBackground: isLightBackground),
                    shadowRadius: hoverableButtonShadowRadius(isLightBackground: isLightBackground),
                    isLightBackground: isLightBackground
                ))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHovering = hovering
                }
            }
        }
        .help(helpText)
        .accessibilityLabel(accessibilityText.isEmpty ? helpText : accessibilityText)
    }
}

// ── 便捷工厂（保持调用点不变） ──

struct MusicButtonView: View {
    var artworkBrightness: CGFloat = 0.5
    var isAlbumPage: Bool = false

    var body: some View {
        HoverableActionButton(
            action: {
                let url = URL(fileURLWithPath: "/System/Applications/Music.app")
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            },
            label: AnyView(HStack(spacing: 4) {
                Image(systemName: "arrow.up.left").font(.system(size: 10, weight: .semibold))
                Text("Music").font(.system(size: 11, weight: .medium))
            }),
            helpText: "打开 Apple Music",
            accessibilityText: "打开 Apple Music",
            artworkBrightness: artworkBrightness,
            isAlbumPage: isAlbumPage
        )
    }
}

struct HideButtonView: View {
    var onHide: () -> Void
    var artworkBrightness: CGFloat = 0.5
    var isAlbumPage: Bool = false

    var body: some View {
        HoverableActionButton(
            action: onHide,
            label: AnyView(Image(systemName: "chevron.up").font(.system(size: 13, weight: .medium))),
            helpText: "收起到菜单栏",
            accessibilityText: "隐藏播放器",
            artworkBrightness: artworkBrightness,
            isAlbumPage: isAlbumPage
        )
    }
}

struct ExpandButtonView: View {
    var onExpand: () -> Void
    var artworkBrightness: CGFloat = 0.5
    var isAlbumPage: Bool = false

    var body: some View {
        HoverableActionButton(
            action: onExpand,
            label: AnyView(Image(systemName: "pip.exit").font(.system(size: 12, weight: .medium))),
            helpText: "展开为浮窗",
            accessibilityText: "展开播放器",
            artworkBrightness: artworkBrightness,
            isAlbumPage: isAlbumPage
        )
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - TranslationButtonView
// ═══════════════════════════════════════════════════════════════════════════════
/// 翻译按钮 - 显示/隐藏歌词翻译（直接toggle，无二级菜单）

struct TranslationButtonView: View {
    @ObservedObject var lyricsService: LyricsService
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 🔑 记录是否已经尝试过强制重试（防止无限重试）
    @State private var hasTriedForceRetry = false

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                // 🔑 智能翻译逻辑：
                // 1. 如果翻译开关关闭 → 打开翻译
                // 2. 如果翻译开关已开启但没有翻译结果，且未尝试过强制重试 → 强制重试翻译
                // 3. 其他情况 → 关闭翻译

                if !lyricsService.showTranslation {
                    // 情况1：打开翻译
                    lyricsService.showTranslation = true
                    hasTriedForceRetry = false  // 重置重试标记
                    lyricsService.debugLogPublic("🔘 翻译按钮：打开翻译")
                } else if !lyricsService.hasTranslation && !lyricsService.isTranslating && !hasTriedForceRetry {
                    // 情况2：翻译开关已开启但没有翻译结果，强制重试一次
                    lyricsService.debugLogPublic("🔘 翻译按钮：强制重试翻译（当前无翻译结果）")
                    hasTriedForceRetry = true  // 标记已尝试过
                    lyricsService.forceRetryTranslation()
                } else {
                    // 情况3：关闭翻译
                    lyricsService.showTranslation = false
                    hasTriedForceRetry = false  // 重置重试标记
                    lyricsService.debugLogPublic("🔘 翻译按钮：关闭翻译")
                }
            }
        }) {
            Image(systemName: "translate")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)  // 🔑 icon 始终 100% opacity
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.white.opacity(lyricsService.showTranslation ? 0.3 : (isHovering ? 0.2 : 0.12)))  // 🔑 切换状态 0.3，hover 0.2，常驻 0.12
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHovering = hovering
                }
            }
        }
        // 🔑 歌曲切换时重置重试标记
        .onChange(of: lyricsService.lyrics.count) { _, _ in
            hasTriedForceRetry = false
        }
        .help("Toggle Translation")
        .accessibilityLabel(lyricsService.showTranslation ? "关闭翻译" : "开启翻译")
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PlaylistTabBarIntegrated
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 集成版 Tab Bar，带透明背景

struct PlaylistTabBarIntegrated: View {
    @Binding var selectedTab: Int

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                // Background Capsule - 恢复原来的透明设计（装饰性）
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 32)
                    .accessibilityHidden(true)

                // Selection Capsule（装饰性）
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: geo.size.width / 2 - 4, height: 28)
                        .offset(x: selectedTab == 0 ? 2 : geo.size.width / 2 + 2, y: 2)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedTab)
                }
                .accessibilityHidden(true)

                // Tab Labels
                HStack(spacing: 0) {
                    Button(action: { selectedTab = 0 }) {
                        Text("History")
                            .font(.system(size: 13, weight: selectedTab == 0 ? .semibold : .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("播放历史")
                    .accessibilityAddTraits(selectedTab == 0 ? .isSelected : [])

                    Button(action: { selectedTab = 1 }) {
                        Text("Up Next")
                            .font(.system(size: 13, weight: selectedTab == 1 ? .semibold : .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("待播清单")
                    .accessibilityAddTraits(selectedTab == 1 ? .isSelected : [])
                }
            }
            .frame(height: 32)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("播放列表标签栏")
        }
        .padding(.horizontal, 50)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - RoundedCorner Helpers
// ═══════════════════════════════════════════════════════════════════════════════

extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner

    func path(in rect: CGRect) -> Path {
        // 每个角独立控制圆角半径
        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 { path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false) }
        path.closeSubpath()
        return path
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Conditional View Modifier
// ═══════════════════════════════════════════════════════════════════════════════

extension View {
    /// Applies a modifier conditionally
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
