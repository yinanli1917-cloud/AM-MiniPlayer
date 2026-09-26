import AppKit
import Foundation

/**
 * [INPUT]: Depends on ButtonIconLegibility.swift's existing sampling primitives
 *          (`ButtonIconID`, `ButtonIconRects`, `ButtonIconCompositeSampler`,
 *          `ButtonIconCompositeBitmap.dominantColor`, `ButtonIconBackdropColor`,
 *          `APCAContrast`, `ButtonIconDecision.grayThreshold`) and
 *          `BackdropLegibilityBand.RGBColor` for the shared 0...1 sRGB-gamma colour
 *          model. Does NOT depend on `ButtonIconTone`/`ButtonIconDecision.resolve`/
 *          `ButtonIconGraySolve` — those stay the `.legacy` arm's own path, untouched.
 * [OUTPUT]: Exports `ButtonFillTint` (the pure "sampled backdrop colour -> button fill
 *           colour" function), `ButtonFillLegibility.resolveAll` (the async-pipeline
 *           entry point, mirrors `ButtonIconLegibility.resolveAll`'s fullscreen/
 *           non-fullscreen branching but resolves fill colours instead of icon tones),
 *           and `ButtonFillRefreshCoordinator` (off-main-thread, last-request-wins,
 *           mirrors `ButtonIconRefreshCoordinator`).
 * [POS]: UI/ 的 shuffle/repeat 按钮"填充色"机制 — founder 2026-09-26: 专辑页 shuffle/
 *        repeat 圆按钮在亮封面上很难看；对照苹果 Music 迷你播放器的星形/"…"圆按钮，问题根源
 *        不是图标颜色该多灰（那是 ButtonIconLegibility.swift 现有机制在做的事），而是圆的填充
 *        从来不会主动变暗——图标只能被迫调灰调黑去将就一个本来就很亮的填充。这里反过来：图标
 *        永远纯白，填充自己负责暗到能撑住白图标。数字依据见
 *        research/album-buttons-2026-09-26.md（对苹果截图和我方截图的像素实测）。
 *
 *        `MicroInteractionFeel.ButtonFillMode.tinted`（默认）走这条路径；`.legacy`
 *        （今天的行为，字节级不变）继续走 ButtonIconLegibility.swift 原有的
 *        `resolveAll`/`ButtonIconDecision`/`ButtonIconRefreshCoordinator`，完全不受
 *        本文件影响——两条路径除了共享的取样原语（同一份"这个按钮正下方是什么颜色"）之外
 *        彼此独立，任何一条出问题都不会牵连另一条，也不会把现有的
 *        `ButtonIconLegibilityTests`/`ButtonIconLegibilityEvalTests`（516+328 行，覆盖
 *        `.legacy` 臂的全部行为）置于风险中。
 */

// MARK: - Pure fill-colour function

/// Given the raw colour sampled from directly behind one shuffle/repeat button
/// (the SAME sample `ButtonIconLegibility`'s `.legacy` arm already computes —
/// `ButtonIconCompositeBitmap.dominantColor` for the fullscreen hero composite,
/// `ButtonIconBackdropColor.predictedFluidBackdropColor` otherwise), resolves the
/// button's own fill colour. The icon drawn on top of this fill is ALWAYS pure
/// white — this function's only job is guaranteeing that white reads clearly.
enum ButtonFillTint {
    /// Shared with `ButtonIconDecision.grayThreshold` (`ButtonIconLegibility.swift`)
    /// on purpose — this file answers a different question ("how dark should the
    /// FILL be") but "is white legible here" should not have two different answers
    /// in the same feature.
    static let apcaFloor: Double = ButtonIconDecision.grayThreshold

    /// Apple's measured glass-vibrancy lift (research/album-buttons-2026-09-26.md):
    /// the star button's local background (lum 157/255) vs its fill (lum 182/255) is
    /// +25/255 (0.098); the "..." button's background (213/255) vs fill (235/255) is
    /// +22/255 (0.086). Both are near-uniform across R/G/B (hue-preserving, not a
    /// wash toward white) — this is the "glass" read: a small, constant brightening
    /// of whatever is directly behind the control, not a colour pick. Shipped value
    /// is the midpoint of the two measurements.
    static let glassLift: Double = 0.09

    /// Floor on how much of the sampled hue survives worst-case darkening, so a
    /// pathological input (e.g. pure white sampled colour) never collapses to
    /// literal (0,0,0) — mirrors `ButtonIconGraySolve.minimumLightness`'s "never
    /// pure black" rule, applied to a colour instead of a gray scalar.
    static let minimumRetainedFraction: Double = 0.02

    private static let white = BackdropLegibilityBand.RGBColor(r: 1, g: 1, b: 1)

    /// The resolved fill colour. Two regimes:
    ///   1. `sampled` lifted by `glassLift` already clears `apcaFloor` against a pure
    ///      white icon (the common case away from blown-out highlights, e.g. Apple's
    ///      own star button) -> return the lifted colour unchanged. This is the
    ///      "glass" look: a light, hue-preserving brightening of the real backdrop.
    ///   2. It does not (e.g. our own bright album-page fill measured at lum 228-241/255
    ///      — the actual bug) -> darken that lifted colour, hue-preserving (uniform
    ///      per-channel multiply toward black, the same technique
    ///      `BackdropLegibilityBand.resolveChannelCorrect`'s ceiling branch already
    ///      uses elsewhere in this codebase), solved by bisection so white-on-fill
    ///      lands EXACTLY on `apcaFloor` — never darker than that solve, never fully
    ///      black. This is the guarantee Apple's own fixed +lift does not give (its
    ///      "..." button is already a weak case at fill lum 235/255 — see the
    ///      research doc); this function trades a little of Apple's literal recipe
    ///      for an actual floor.
    static func resolve(sampled: BackdropLegibilityBand.RGBColor) -> BackdropLegibilityBand.RGBColor {
        let lifted = BackdropLegibilityBand.RGBColor(
            r: sampled.r + glassLift, g: sampled.g + glassLift, b: sampled.b + glassLift
        )
        guard abs(APCAContrast.lc(text: white, background: lifted)) < apcaFloor else {
            return lifted
        }
        return darkenToFloor(lifted)
    }

    /// Hue-preserving multiply-toward-black (`color * (1 - alpha)` on every
    /// channel), solved so `|APCA(white, result)| == apcaFloor` exactly. `alpha` is
    /// monotonically non-decreasing in contrast (darker backdrop -> more contrast
    /// against a fixed white foreground), so bisection always converges — same
    /// invariant `BackdropLegibilityBand.resolveChannelCorrect`'s darken branch and
    /// `ButtonIconGraySolve.lightness` both already rely on.
    private static func darkenToFloor(_ color: BackdropLegibilityBand.RGBColor) -> BackdropLegibilityBand.RGBColor {
        func contrast(atAlpha alpha: Double) -> Double {
            let darkened = BackdropLegibilityBand.RGBColor(
                r: color.r * (1 - alpha), g: color.g * (1 - alpha), b: color.b * (1 - alpha)
            )
            return abs(APCAContrast.lc(text: white, background: darkened))
        }

        // Defensive floor: full black (alpha=1) is APCA white-on-black, ~106 — far
        // above any realistic apcaFloor — so this branch is not expected to trigger
        // in practice. Kept anyway (mirrors ButtonIconGraySolve's own defensive
        // degenerate-end guard) so a future change to apcaFloor cannot silently spin
        // the bisection with no valid crossing.
        guard contrast(atAlpha: 1) >= apcaFloor else {
            return BackdropLegibilityBand.RGBColor(
                r: color.r * minimumRetainedFraction,
                g: color.g * minimumRetainedFraction,
                b: color.b * minimumRetainedFraction
            )
        }

        var lo = 0.0 // contrast(lo) < apcaFloor (guaranteed by resolve()'s guard before calling this)
        var hi = 1.0 // contrast(hi) >= apcaFloor
        for _ in 0..<48 {
            let mid = (lo + hi) / 2
            if contrast(atAlpha: mid) >= apcaFloor { hi = mid } else { lo = mid }
        }
        let alpha = min(hi, 1 - minimumRetainedFraction)
        return BackdropLegibilityBand.RGBColor(
            r: color.r * (1 - alpha), g: color.g * (1 - alpha), b: color.b * (1 - alpha)
        )
    }
}

// MARK: - Async pipeline entry point (mirrors ButtonIconLegibility.resolveAll)

enum ButtonFillLegibility {
    /// Resolves both shuffle/repeat buttons' FILL colours. Structurally mirrors
    /// `ButtonIconLegibility.resolveAll` (same fullscreen/non-fullscreen branching,
    /// same underlying samplers) on purpose — the two arms should agree on "what
    /// colour is actually behind this button", only the decision made from it
    /// differs — but is kept as an independent function (not a shared refactor of
    /// `resolveAll`) so `.legacy`'s existing behaviour/tests are provably untouched.
    ///
    /// THREADING: same contract as `ButtonIconLegibility.resolveAll` — does real
    /// CGContext/Core Image work in the fullscreen branch, must run off the main
    /// thread (`ButtonFillRefreshCoordinator` below does this via `Task.detached`).
    static func resolveAll(
        fullscreen: Bool,
        artwork: NSImage?,
        tone: ArtworkBackgroundToneMap,
        panelSize: CGSize,
        reduceTransparency: Bool,
        previous: [ButtonIconID: BackdropLegibilityBand.RGBColor]
    ) -> [ButtonIconID: BackdropLegibilityBand.RGBColor] {
        guard let artwork else {
            let neutralFill = ButtonFillTint.resolve(
                sampled: ButtonIconBackdropColor.predictedFluidBackdropColor(artwork: nil, reduceTransparency: reduceTransparency)
            )
            return Dictionary(uniqueKeysWithValues: ButtonIconID.allCases.map { ($0, neutralFill) })
        }

        if fullscreen {
            guard let bitmap = ButtonIconCompositeSampler.render(
                cover: artwork,
                tone: tone,
                totalFadeHeight: ButtonIconLegibility.fullscreenHeroFadeHeight,
                panelSize: panelSize,
                scale: ButtonIconLegibility.fullscreenCompositeScale
            ) else {
                return previous
            }
            var result: [ButtonIconID: BackdropLegibilityBand.RGBColor] = [:]
            for id in ButtonIconID.allCases {
                let rect = ButtonIconRects.rect(for: id, panelSize: panelSize)
                guard let sampled = bitmap.dominantColor(rect: rect) else {
                    if let priorFill = previous[id] {
                        result[id] = priorFill
                    }
                    continue
                }
                result[id] = ButtonFillTint.resolve(sampled: sampled)
            }
            return result
        }

        let sampled = ButtonIconBackdropColor.predictedFluidBackdropColor(artwork: artwork, reduceTransparency: reduceTransparency)
        let fill = ButtonFillTint.resolve(sampled: sampled)
        return Dictionary(uniqueKeysWithValues: ButtonIconID.allCases.map { ($0, fill) })
    }
}

// MARK: - Off-main-thread coordination (mirrors ButtonIconRefreshCoordinator)

/// Same last-request-wins contract as `ButtonIconRefreshCoordinator`: a `refresh`
/// call superseded by a newer one before its work completes resolves to `nil`,
/// never overwriting the newer result. Kept as its own actor (rather than
/// generalizing `ButtonIconRefreshCoordinator` over its result type) so the
/// `.legacy` arm's existing coordinator/tests are provably untouched.
actor ButtonFillRefreshCoordinator {
    private var generation: Int = 0
    private let compute: (
        _ fullscreen: Bool,
        _ artwork: NSImage?,
        _ tone: ArtworkBackgroundToneMap,
        _ panelSize: CGSize,
        _ reduceTransparency: Bool,
        _ previous: [ButtonIconID: BackdropLegibilityBand.RGBColor]
    ) async -> [ButtonIconID: BackdropLegibilityBand.RGBColor]

    init(
        compute: @escaping (
            _ fullscreen: Bool,
            _ artwork: NSImage?,
            _ tone: ArtworkBackgroundToneMap,
            _ panelSize: CGSize,
            _ reduceTransparency: Bool,
            _ previous: [ButtonIconID: BackdropLegibilityBand.RGBColor]
        ) async -> [ButtonIconID: BackdropLegibilityBand.RGBColor] = { fullscreen, artwork, tone, panelSize, reduceTransparency, previous in
            await Task.detached(priority: .userInitiated) {
                ButtonFillLegibility.resolveAll(
                    fullscreen: fullscreen,
                    artwork: artwork,
                    tone: tone,
                    panelSize: panelSize,
                    reduceTransparency: reduceTransparency,
                    previous: previous
                )
            }.value
        }
    ) {
        self.compute = compute
    }

    /// Returns the resolved fill colours, or `nil` if a NEWER `refresh` call was
    /// made before this one's `compute` finished (caller must drop this result).
    func refresh(
        fullscreen: Bool,
        artwork: NSImage?,
        tone: ArtworkBackgroundToneMap,
        panelSize: CGSize,
        reduceTransparency: Bool,
        previous: [ButtonIconID: BackdropLegibilityBand.RGBColor]
    ) async -> [ButtonIconID: BackdropLegibilityBand.RGBColor]? {
        generation += 1
        let myGeneration = generation
        let result = await compute(fullscreen, artwork, tone, panelSize, reduceTransparency, previous)
        guard myGeneration == generation else { return nil }
        return result
    }
}
