/**
 * [INPUT]: None — pure constants.
 * [OUTPUT]: EdgeCollapseTokens (frame geometry + all §7 timing/spring numbers)
 *           + EdgeCollapseTempo (1.0 / 1.5 multiplier) + EdgeCollapseTokens.scaled(_:tempo:)
 * [POS]: Standalone spike for research/edge-collapse-redesign-2026-09-19.md §3/§7.
 *        App-portable: no spike-only dependencies, safe to lift into
 *        Sources/MusicMiniPlayerCore/UI/ verbatim (mirrors MicroInteractionFeel.Tokens
 *        style in Sources/MusicMiniPlayerCore/UI/MicroInteractionFeel.swift).
 * [PROTOCOL]: Changing a number here must match the §7 table in the design doc,
 *             or update the design doc first.
 */

import Foundation
import CoreGraphics

/// Tempo multiplier applied uniformly to every duration (never to overshoot
/// magnitudes or distances) — design §10 open item 4, both arms kept live.
public enum EdgeCollapseTempo: Double, CaseIterable {
    case normal = 1.0
    case slow = 1.5
}

public enum EdgeCollapseTokens {

    // MARK: - Frame geometry (design §3)

    public static let cardSize = CGSize(width: 250, height: 316)
    public static let tuckedSize = CGSize(width: 8, height: 96)
    /// Hit region for hover-over-stalk is the tucked window's own content
    /// area, already expanded 16pt beyond the visible 8pt sliver (design §6:
    /// "expand hit region by 16pt via a slightly larger transparent window
    /// frame is acceptable").
    public static let tuckedHitRegionExpand: CGFloat = 16
    /// Actual NSWindow content size while tucked: the visible capsule stays
    /// `tuckedSize` (8×96, drawn trailing-aligned so it stays flush with the
    /// screen edge), but the WINDOW is padded so there's a real hoverable
    /// target — an 8pt-wide window is nearly impossible to land a cursor on.
    public static var tuckedWindowSize: CGSize {
        CGSize(
            width: tuckedSize.width + 2 * tuckedHitRegionExpand,
            height: tuckedSize.height + 2 * tuckedHitRegionExpand
        )
    }

    /// Floating window covers the neck region (§3: "窗口扩到 40×120 覆盖颈的区域").
    /// Variant H needs extra width for the leftward info bar; kept as one
    /// constant per variant.
    public static let floatingWindowSizeV = CGSize(width: 40, height: 120)
    public static let floatingWindowSizeH = CGSize(width: 220, height: 132)
    public static let floatingBodyEdgeGap: CGFloat = 12
    /// Hover-exit hit region is the UNION of the floating bodies expanded by
    /// 12pt (design §6) — approximated here, per the same §6 permission, as
    /// the floating window's own (already-padded) content area.
    public static let floatingHoverExitExpand: CGFloat = 12

    public static let dragAwayFromEdgeExpandThreshold: CGFloat = 40

    // MARK: - Shared shape/card constants

    public static let cardCornerRadius: Double = 18
    public static let pillCornerRadius: Double = 14

    // MARK: - 7.1 collapsing (two-finger scroll, total ~460ms baseline)

    public static let collapseContentFadeShiftDuration: TimeInterval = 0.08
    public static let collapseContentShiftDistance: CGFloat = 8
    public static let collapseBlackOverlayDuration: TimeInterval = 0.10

    public static let collapseHeightPhaseStart: TimeInterval = 0.0
    public static let collapseHeightPhaseEnd: TimeInterval = 0.08

    public static let collapseHeroStart: TimeInterval = 0.08

    public static let collapseWidthPhaseStart: TimeInterval = 0.08
    public static let collapseWidthPhaseEnd: TimeInterval = 0.16

    public static let collapseStalkPhaseStart: TimeInterval = 0.16
    public static let collapseStalkPhaseEnd: TimeInterval = 0.20
    public static let collapsePillOvershoot: Double = 0.06

    public static let collapseGooPhaseStart: TimeInterval = 0.20
    public static let collapseGooPhaseEnd: TimeInterval = 0.32

    public static let collapseHeroSettle: TimeInterval = 0.34

    public static let collapseFrameSnapStart: TimeInterval = 0.32
    public static let collapseFrameSnapEnd: TimeInterval = 0.46
    public static let collapseTotalDuration: TimeInterval = 0.46

    public static let collapseWidthSpringResponse: Double = 0.22
    public static let collapseWidthSpringBounce: Double = 0.45
    public static let collapseHeightSpringResponse: Double = 0.18
    public static let collapseHeightSpringBounce: Double = 0.10
    public static let collapseNeckSpringResponse: Double = 0.14
    public static let collapseNeckSpringBounce: Double = 0.0

    public static let heroSpringResponse: Double = 0.32
    public static let heroSpringBounce: Double = 0.35

    // MARK: - 7.2 floating (hover out ~180ms, retract ~160ms)

    public static let floatingNeckThinnest: TimeInterval = 0.09
    public static let floatingNeckBreak: TimeInterval = 0.12
    public static let floatingArtworkFadeStart: TimeInterval = 0.04
    public static let floatingSettlePhaseEnd: TimeInterval = 0.18
    public static let floatingOvershoot: Double = 0.04
    public static let floatingControlsFadeStart: TimeInterval = 0.10
    public static let floatingOutDuration: TimeInterval = 0.18
    public static let floatingRetractDuration: TimeInterval = 0.16

    // MARK: - 7.3 expanding (click, ~360ms)

    public static let expandBulgePhaseEnd: TimeInterval = 0.03
    public static let expandStretchPhaseEnd: TimeInterval = 0.17
    public static let expandBlackOverlayStart: TimeInterval = 0.09
    public static let expandCardSettlePhaseEnd: TimeInterval = 0.26
    public static let expandOvershoot: Double = 0.03
    public static let expandContentFadeStart: TimeInterval = 0.20
    public static let expandHeroSettle: TimeInterval = 0.30
    public static let expandControlAbsorbDuration: TimeInterval = 0.12
    public static let expandTotalDuration: TimeInterval = 0.36

    // MARK: - Reduce Motion (design §8)

    public static let reduceMotionCrossfadeDuration: TimeInterval = 0.18

    // MARK: - Tempo scaling

    /// Scales any duration/timestamp by the tempo multiplier. Never apply
    /// this to overshoot fractions (`collapsePillOvershoot`, `floatingOvershoot`,
    /// `expandOvershoot`) or distances (`collapseContentShiftDistance`) —
    /// design §10 item 4 is about total *time*, not magnitude.
    public static func scaled(_ duration: TimeInterval, tempo: EdgeCollapseTempo) -> TimeInterval {
        duration * tempo.rawValue
    }
}
