/**
 * [INPUT]: EdgePresentationModel (environment), MusicController (environment,
 *          artwork + play/pause), MicroInteractionFeel.edgeMorph arm
 * [OUTPUT]: EdgeMorphHost — the card↔pill Liquid Glass morph view; pure helpers
 *           `showsPill`/`baseBackdropHidden` consumed by PanelBackdrop
 * [POS]: C1 贴边形变设计 §2/§3/§7 commit 2 — 挂在 MiniPlayerView 的根 ZStack
 * [PROTOCOL]: 变更时更新此头部，然后检查 research/c1-edge-morph-design-2026-09-12.md §2/§3/§7
 */

import SwiftUI
import QuartzCore

public struct EdgeMorphHost: View {
    @EnvironmentObject var edgePresentation: EdgePresentationModel
    @EnvironmentObject var musicController: MusicController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var morphNS

    // Three-clock scheduler state (design §4/§9 commit 3). `pillMounted` is
    // the pre-seed step — the pill container exists at opacity 0 immediately,
    // before geometry has visibly moved. `pillIdentitySwitched` is the
    // content clock (card↔pill identity swap). `materialOpacity` is the
    // pill's own glass-material fade, settling on its own clock independent
    // of the identity switch. `generation` guards the deferred steps so a
    // rapid reverse (hide→restore before contentLagMin elapses) cancels the
    // stale scheduled step rather than letting it stomp a newer one.
    @State private var pillMounted = false
    @State private var pillIdentitySwitched = false
    @State private var materialOpacity: Double = 0
    @State private var generation = 0

    public init() {}

    public var body: some View {
        let arm = MicroInteractionFeel.edgeMorph
        let presentation = edgePresentation.presentation

        Group {
            if arm == .morph {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 40) {
                    // Card-side identity carrier. §2 裁定 card 本体保持不透明
                    // fluid、不套玻璃材质；但 `glassEffectID(_:in:)` 只在「与
                    // glassEffect 一起使用」时才驱动身份延续动画——official.md
                    // §1 抓取的文档原文：「Use `.glassEffectID` modifier on
                    // child views for transitions or morphing of glass
                    // views」，且 `Glass` 结构公开 `.clear` 变体（同文件：
                    // 「Glass 结构：.regular、.clear、.identity」，两者都在
                    // 已验证清单里，非 [未验证] 标注）。于是 card 侧用
                    // `.glassEffect(.clear, in:)` 作为零材质占位——`.clear`
                    // 不带自适应/模糊，视觉上不给 card 叠加任何材质，只satisfy
                    // glassEffectID 的「必须搭配 glassEffect」这条文档约束，
                    // 让 card→pill 的身份延续动画有源头可插值。
                    //
                    // 占位改成与 pill 同宽(20pt)、贴 snapped edge 的窄条，而非
                    // 铺满整卡——铺满整卡会让这块 `.glassEffect` 常驻为一个
                    // 全卡 CABackdropLayer，compositor 在下方 fluid 渐变每帧
                    // 动画时都要重求值它，正是 CLAUDE.md「Blur economy」条目
                    // 警告的 resident-filter 合成器代价（12-25 行静态模糊行
                    // 曾把 WindowServer 打到 +38 点）。窄条把常驻面积从整卡
                    // 缩到 20pt 宽，且用 Capsule 而非 RoundedRectangle，让
                    // card→pill 形变在形状上连续。
                    if presentation == .card {
                        let edge = edgePresentation.snappedEdge
                        Color.clear
                            .glassEffect(.clear, in: Capsule(style: .continuous))
                            .glassEffectID("panelBody", in: morphNS)
                            .frame(width: 20)
                            .frame(maxHeight: .infinity)
                            .frame(maxWidth: .infinity, alignment: edge == .left ? .leading : .trailing)
                            .allowsHitTesting(false)
                    }

                    if pillMounted {
                        pillContent(presentation: presentation)
                            .glassEffect(.regular, in: Capsule(style: .continuous))
                            .glassEffectID("panelBody", in: morphNS)
                            .opacity(pillIdentitySwitched ? 1 : 0)
                            .overlay(
                                Capsule(style: .continuous)
                                    .fill(Color.clear)
                                    // materialOpacity drives the glass's own
                                    // fade-in on its own clock, independent
                                    // of the identity opacity above — see
                                    // design §4/§9 commit 3.
                                    .opacity(materialOpacity)
                            )
                    }
                }
                .onChange(of: EdgeMorphHost.showsPill(presentation: presentation, arm: arm)) { _, showing in
                    scheduleMorph(showing: showing, presentation: presentation, arm: arm)
                }
            } else {
                // macOS < 26: GlassEffectContainer/glassEffect are unavailable —
                // fall back to nothing, same as `.v0` (design §7 clause: "or
                // when #available fails, EdgeMorphHost renders EmptyView()").
                EmptyView()
            }
            } else {
                // `.v0`: EdgeMorphHost renders nothing — byte-identical to
                // today's behaviour (design §7).
                EmptyView()
            }
        }
    }

    /// Drives the three clocks off `EdgeMorphClockScheduler.plan(t0:reduceMotion:)`.
    /// `t0` is "now" here (`CACurrentMediaTime()`) because this is fired from
    /// the SwiftUI `onChange`, which is the closest available proxy to the
    /// AppKit `onGeometryMorphWillStart` intent point for this view's own
    /// clock scheduling — the plan's pre-seed/content/material offsets are
    /// unaffected by which side observes `t0` first.
    private func scheduleMorph(showing: Bool, presentation: EdgePresentation, arm: MicroInteractionFeel.EdgeMorphMode) {
        generation += 1
        let myGeneration = generation
        let t0 = CACurrentMediaTime()
        let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: reduceMotion)
        let anims = EdgeMorphClockScheduler.animations(reduceMotion: reduceMotion)

        if showing {
            // Pre-seed: mount the pill container immediately at opacity 0 —
            // "target pre-seeded ~20ms before geometry" (design §4).
            pillMounted = true
            pillIdentitySwitched = false
            DebugLogger.log(
                "EdgeMorph",
                "t=\(plan.preSeedStart) clock=preSeed state=\(presentation) arm=\(arm) token=edgeMorphPreSeedLead=\(MicroInteractionFeel.Tokens.edgeMorphPreSeedLead)"
            )
        }

        let contentDelay = plan.contentStart - t0
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, contentDelay)) {
            guard EdgeMorphClockScheduler.shouldApply(generation: myGeneration, current: self.generation) else { return }
            DebugLogger.log(
                "EdgeMorph",
                "t=\(CACurrentMediaTime()) clock=content state=\(presentation) arm=\(arm) pill=\(showing ? "mount" : "unmount") token=edgeMorphContentDuration=\(plan.contentDuration)"
            )
            withAnimation(anims.content) {
                self.pillIdentitySwitched = showing
                if !showing {
                    self.pillMounted = false
                }
            }
        }

        let materialDelay = plan.materialStart - t0
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, materialDelay)) {
            guard EdgeMorphClockScheduler.shouldApply(generation: myGeneration, current: self.generation) else { return }
            DebugLogger.log(
                "EdgeMorph",
                "t=\(CACurrentMediaTime()) clock=material state=\(presentation) arm=\(arm) token=edgeMorphMaterialSettle=\(plan.materialDuration)"
            )
            withAnimation(anims.material) {
                self.materialOpacity = showing ? 1 : 0
            }
        }
    }

    @ViewBuilder
    private func pillContent(presentation: EdgePresentation) -> some View {
        let edge = edgePresentation.snappedEdge
        VStack(spacing: 6) {
            if let artwork = musicController.currentArtwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.5))
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            if presentation == .peeking {
                Button(action: { musicController.togglePlayPause() }) {
                    Image(systemName: musicController.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .frame(width: presentation == .peeking ? 44 : 20)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity, alignment: edge == .left ? .leading : .trailing)
    }

    /// Pure table: `.v0` never shows the pill; `.morph` shows it for every
    /// non-card presentation state. Mirrors the design §7 A/B contract.
    public static func showsPill(presentation: EdgePresentation, arm: MicroInteractionFeel.EdgeMorphMode) -> Bool {
        guard arm == .morph else { return false }
        switch presentation {
        case .card:
            return false
        case .hidingToPill, .pill, .peeking, .restoringToCard:
            return true
        }
    }

    /// Pure table consumed by `PanelBackdrop`: the `.base` role must render
    /// `Color.clear` (let the pill carry the only glass) exactly when the
    /// pill is showing under the morph arm. `.v0` never hides the base.
    public static func baseBackdropHidden(presentation: EdgePresentation, arm: MicroInteractionFeel.EdgeMorphMode) -> Bool {
        showsPill(presentation: presentation, arm: arm)
    }
}
