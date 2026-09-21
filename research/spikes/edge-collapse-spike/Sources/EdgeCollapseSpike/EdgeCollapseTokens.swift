/**
 * [INPUT]: None — pure constants + Animation factories.
 * [OUTPUT]: EdgeCollapseTokens (frame geometry, corner radii, tint/hover
 *           constants, the single-`withAnimation`-per-transition Animation
 *           table) + EdgeCollapseTempo/EdgeCollapseBounce/EdgeCollapseVariant/
 *           EdgeCollapseTint enums.
 * [POS]: Standalone spike, rewritten for the AUDIT-2026-09-20.md "correct
 *        approach": one `GlassEffectContainer` + stable `glassEffectID`s +
 *        ONE `withAnimation` per transition, so the token table now holds
 *        exactly five `Animation` values (collapse×2 bounce arms, floating
 *        out, floating retract, expand) instead of the old per-channel
 *        spring relay. App-portable: no spike-only dependencies, safe to
 *        lift into Sources/MusicMiniPlayerCore/UI/ verbatim.
 * [PROTOCOL]: Every number here must match top-level task instruction #2's
 *             animation table exactly. Tempo multiplies DURATIONS only —
 *             never bounce fractions or distances.
 */

import SwiftUI

/// Tempo multiplier applied uniformly to every animation duration (top-level
/// task instruction #6 control-window switch "Tempo 1.0,1.5").
public enum EdgeCollapseTempo: Double, CaseIterable, Identifiable, Sendable {
    case normal = 1.0
    case slow = 1.5
    public var id: Double { rawValue }
}

/// Collapse-only "feel" arm (top-level task instruction #6: "Bounce
/// settle,bouncy"). Only the collapse transition switches between these two
/// springs — floating out/retract/expand each have one fixed spring
/// (instruction #2).
public enum EdgeCollapseBounce: String, CaseIterable, Identifiable, Sendable {
    case settle = "Settle"
    case bouncy = "Bouncy"
    public var id: String { rawValue }
}

/// H = horizontal floating layout (info bar above, control below); V =
/// vertical (artwork drop above, control below), design §6.
public enum EdgeCollapseVariant: String, CaseIterable, Identifiable, Sendable {
    case h = "Horizontal (H)"
    case v = "Vertical (V)"
    public var id: String { rawValue }
}

/// Top-level task instruction #1 "Tint": gradient (black→clear, black end at
/// the screen-edge side) / black (flat 0.85) / none (raw glass, no overlay).
public enum EdgeCollapseTint: String, CaseIterable, Identifiable, Sendable {
    case gradient = "Gradient"
    case black = "Black"
    case none = "None"
    public var id: String { rawValue }
}

public enum EdgeCollapseTokens {

    // MARK: - Window / container (top-level task instruction #3)

    /// The ONE fixed panel content size — the window never resizes, ever.
    /// Right edge pinned to the screen's right edge, vertically centered.
    public static let containerSize = CGSize(width: 320, height: 360)

    /// `GlassEffectContainer(spacing:)` — governs how close two glass shapes
    /// must be before the system blends/unions them (instruction #1,
    /// default 24; glass-morph-spike's own scenario 2 measured a real,
    /// continuously-changing blend at this kind of spacing with NO identity
    /// change at all — see research/spikes/glass-morph-spike/results/summary.md).
    public static let containerSpacing: CGFloat = 20

    // MARK: - Card (body id "body" in `.card`)

    public static let cardSize = CGSize(width: 250, height: 316)
    public static let cardCornerRadius: CGFloat = 22
    public static let cardArtworkInset: CGFloat = 16
    /// Artwork-colour tint strength on the card glass.
    public static let cardTintOpacity: Double = 0.35

    // MARK: - Tucked (body id "body" in `.tucked`)

    /// Visible capsule size, flush to the right edge. Drawn as
    /// `RoundedRectangle(cornerRadius: height/2)` — mathematically identical
    /// to `Capsule()` (Apple's own `DefaultGlassEffectShape` docs: "the
    /// default shape applied by glass effects, a capsule" = a rounded rect
    /// whose corner radius is half the short side) — see README "shape
    /// identity" note for why this spike never switches the `body` view's
    /// concrete `Shape` TYPE across states.
    public static let tuckedSize = CGSize(width: 8, height: 96)
    /// v5: the tucked state is an island grown out of the screen edge
    /// (flat side on the edge, round side inward), not a stalk.
    public static let islandSize = CGSize(width: 32, height: 112)
    public static let islandCornerRadius: CGFloat = 16
    public static let islandArtwork: CGFloat = 24
    public static let floatingBarArtwork: CGFloat = 52
    public static let floatingDropArtwork: CGFloat = 56
    /// Hover/click hit-region padding beyond the visible 8pt sliver — an 8pt
    /// target is not landable with a cursor (design §6).
    public static let tuckedHoverExpand: CGFloat = 16

    // MARK: - Floating (body id "body" + control id "control" in `.floating`)

    /// "floating bodies 12pt in from the right edge" — instruction #1.
    public static let floatingEdgeGap: CGFloat = 12
    /// Visual gap between the body and control shapes (VStack spacing) —
    /// distinct from `containerSpacing` (the glass BLEND threshold).
    public static let floatingBodyControlGap: CGFloat = 24
    public static let floatingHoverExitExpand: CGFloat = 12

    public static let floatingBarHeight: CGFloat = 72
    public static let floatingBarMinWidth: CGFloat = 220
    public static let floatingBarMaxWidth: CGFloat = 280
    /// Budget added to the measured title text width to get the bar's
    /// content width (artwork dot + spacing + horizontal padding).
    public static let floatingBarHorizontalPadding: CGFloat = 84

    public static let floatingControlSizeH = CGSize(width: 116, height: 40)
    public static let floatingControlCornerRadius: CGFloat = 20

    /// V variant's artwork drop: task instruction #1 explicitly overrides
    /// the old Circle/32×32-capsule-ish shape with a RoundedRectangle
    /// corner 16 "to keep the explicit-shape rule" (aspect ≥3:1 OR corner
    /// ≤ half short side — 16 = 32/2, satisfies the corner clause exactly).
    public static let floatingDropSizeV = CGSize(width: 64, height: 64)
    public static let floatingDropCornerRadiusV: CGFloat = 16
    public static let floatingControlSizeV = CGSize(width: 40, height: 116)

    // MARK: - Tint overlay (top-level task instruction #1)

    public static let tintOpacity: Double = 0.45
    /// Base darkening under the gradient arm (native Glass.tint, keeps rim).
    public static let tintBaseOpacity: Double = 0.45
    /// Edge-side dimming layer (HIG: dark dimming layer ~35%) strength and width fraction.
    public static let edgeDimOpacity: Double = 0.62
    public static let edgeDimInnerOpacity: Double = 0.18
    public static let edgeDimFraction: CGFloat = 1.0
    /// Inset so the tint overlay never paints over the glass rim highlight
    /// (instruction #1: "Overlay must not cover the glass rim... inset by
    /// 1.5pt" — the alternative offered, blendMode .multiply, is NOT used
    /// here because .multiply would darken the rim too, just less abruptly;
    /// an inset overlay leaves the outermost ~1.5pt of rim fully exposed).
    public static let tintInset: CGFloat = 1.5

    // MARK: - Drag-away-from-edge expand threshold (design §4 table)

    public static let dragAwayFromEdgeExpandThreshold: CGFloat = 40

    // MARK: - Reduce Motion (top-level task instruction #5)

    public static let reduceMotionCrossfadeDuration: TimeInterval = 0.18

    // MARK: - Animation table (top-level task instruction #2)

    public static let collapseSettleDuration: TimeInterval = 0.32
    public static let collapseSettleBounce: Double = 0.0
    public static let collapseBouncyDuration: TimeInterval = 0.36
    public static let collapseBouncyBounce: Double = 0.28

    public static let floatingOutDuration: TimeInterval = 0.24
    public static let floatingOutBounce: Double = 0.15

    public static let floatingRetractDuration: TimeInterval = 0.20
    public static let floatingRetractBounce: Double = 0.0

    public static let expandDuration: TimeInterval = 0.36
    public static let expandBounce: Double = 0.12

    /// card→tucked (or tucked→expanding-straight-to-card's reverse case is
    /// `expandAnimation`, not this). Bounce arm selects one of two springs
    /// — the ONLY transition the Bounce control affects (instruction #2).
    public static func collapseAnimation(bounce: EdgeCollapseBounce, tempo: EdgeCollapseTempo) -> Animation {
        switch bounce {
        case .settle:
            return .spring(duration: scaled(collapseSettleDuration, tempo: tempo), bounce: collapseSettleBounce)
        case .bouncy:
            return .spring(duration: scaled(collapseBouncyDuration, tempo: tempo), bounce: collapseBouncyBounce)
        }
    }

    /// tucked→floating (hover in).
    public static func floatingOutAnimation(tempo: EdgeCollapseTempo) -> Animation {
        .spring(duration: scaled(floatingOutDuration, tempo: tempo), bounce: floatingOutBounce)
    }

    /// floating→tucked (hover out).
    public static func floatingRetractAnimation(tempo: EdgeCollapseTempo) -> Animation {
        .spring(duration: scaled(floatingRetractDuration, tempo: tempo), bounce: floatingRetractBounce)
    }

    /// tucked→card or floating→card (click / expand).
    public static func expandAnimation(tempo: EdgeCollapseTempo) -> Animation {
        .spring(duration: scaled(expandDuration, tempo: tempo), bounce: expandBounce)
    }

    /// Reduce Motion's opacity-only crossfade (linear, no geometry spring).
    public static func reduceMotionAnimation(tempo: EdgeCollapseTempo) -> Animation {
        .linear(duration: scaled(reduceMotionCrossfadeDuration, tempo: tempo))
    }

    /// Scales any duration by the tempo multiplier. Never apply this to a
    /// bounce fraction or a distance — top-level task instruction #2:
    /// "Tempo multiplies durations."
    public static func scaled(_ duration: TimeInterval, tempo: EdgeCollapseTempo) -> TimeInterval {
        duration * tempo.rawValue
    }
}
