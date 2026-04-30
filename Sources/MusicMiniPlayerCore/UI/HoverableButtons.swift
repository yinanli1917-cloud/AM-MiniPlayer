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
    var luminance: CGFloat = 0.5

    func body(content: Content) -> some View {
        let adaptiveColor: Color = luminance > 0.55 ? .black : .white
        if #available(macOS 26.0, *) {
            content
                .foregroundStyle(adaptiveColor)
                .glassEffect(.clear, in: .capsule)
        } else {
            content
                .foregroundStyle(adaptiveColor)
                .background(Capsule().fill(.ultraThinMaterial))
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Conditional Glass Modifiers
// ═══════════════════════════════════════════════════════════════════════════════

struct ConditionalGlassContainer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

struct GlassCapsule: ViewModifier {
    var level: GlassCapsuleLevel = .regular
    var fallbackOpacity: Double = 0.1
    var isEnabled: Bool = true

    enum GlassCapsuleLevel {
        case clear, regular
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(isEnabled ? (level == .regular ? .regular : .clear) : .identity, in: .capsule)
        } else {
            content.background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .opacity(fallbackOpacity > 0 ? 1 : 0)
                    .overlay(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.2), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
            )
        }
    }
}

struct GlassCircle: ViewModifier {
    var isEnabled: Bool = true
    var tintColor: Color? = nil
    var fallbackFill: Color = .white
    var fallbackOpacity: Double = 0.2
    var fallbackShadowOpacity: Double = 0
    var fallbackShadowRadius: CGFloat = 0

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if let tint = tintColor, isEnabled {
                content.glassEffect(.regular.tint(tint), in: .circle)
            } else {
                content.glassEffect(isEnabled ? .regular : .identity, in: .circle)
            }
        } else {
            content.background(
                Circle()
                    .fill(fallbackFill.opacity(isEnabled ? fallbackOpacity : 0))
                    .shadow(color: .black.opacity(fallbackShadowOpacity), radius: fallbackShadowRadius, x: 0, y: 3)
            )
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Hoverable Button Style Helpers
// ═══════════════════════════════════════════════════════════════════════════════
// 🔑 共享的亮度/透明度计算，消除 MusicButtonView/HideButtonView/ExpandButtonView 的重复代码

// Helpers removed — GlassButtonBackground now only needs luminance

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
    private var effectiveLuminance: CGFloat { artworkBrightness }

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
                .modifier(GlassButtonBackground(luminance: effectiveLuminance))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.smooth(duration: 0.25)) {
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
    @State private var isPressed = false
    @State private var toggleBounce: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasTriedForceRetry = false

    var body: some View {
        Button {
            if !lyricsService.showTranslation {
                lyricsService.showTranslation = true
                hasTriedForceRetry = false
                lyricsService.debugLogPublic("🔘 翻译按钮：打开翻译")
            } else if !lyricsService.hasTranslation && !lyricsService.isTranslating && !hasTriedForceRetry {
                lyricsService.debugLogPublic("🔘 翻译按钮：强制重试翻译（当前无翻译结果）")
                hasTriedForceRetry = true
                lyricsService.forceRetryTranslation()
            } else {
                lyricsService.showTranslation = false
                hasTriedForceRetry = false
                lyricsService.debugLogPublic("🔘 翻译按钮：关闭翻译")
            }
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.12, dampingFraction: 0.9)) { isPressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { isPressed = false }
            }
        } label: {
            let isOn = lyricsService.showTranslation
            Image(systemName: "translate")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .scaleEffect(isPressed ? 0.82 : (isHovering ? 1.08 : 1.0))
                .scaleEffect(1 + toggleBounce * 0.15)
                .background(
                    Circle()
                        .fill(Color.white.opacity((isOn || isHovering) ? 0.25 : 0.12))
                        .scaleEffect(isPressed ? 0.82 : (isHovering ? 1.08 : 1.0))
                        .scaleEffect(1 + toggleBounce * 0.15)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .onChange(of: lyricsService.showTranslation) { _, newValue in
            guard !reduceMotion, newValue else { return }
            withAnimation(.spring(response: 0.12, dampingFraction: 0.9)) { toggleBounce = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.interpolatingSpring(stiffness: 300, damping: 8)) { toggleBounce = 0 }
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
                // Selection Capsule
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: geo.size.width / 2 - 4, height: 28)
                        .offset(x: selectedTab == 0 ? 2 : geo.size.width / 2 + 2, y: 2)
                        .animation(.bouncy(duration: 0.35), value: selectedTab)
                }
                .accessibilityHidden(true)

                // Tab Labels
                HStack(spacing: 0) {
                    Button(action: { selectedTab = 0 }) {
                        Text("History")
                            .font(.system(size: 13, weight: selectedTab == 0 ? .semibold : .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("播放历史")
                    .accessibilityAddTraits(selectedTab == 0 ? .isSelected : [])

                    Button(action: { selectedTab = 1 }) {
                        Text("Up Next")
                            .font(.system(size: 13, weight: selectedTab == 1 ? .semibold : .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("待播清单")
                    .accessibilityAddTraits(selectedTab == 1 ? .isSelected : [])
                }
            }
            .frame(height: 32)
            .modifier(GlassCapsule())
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
