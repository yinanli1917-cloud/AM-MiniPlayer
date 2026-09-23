/**
 * [INPUT]: None — pure constants.
 * [OUTPUT]: EdgeCollapseTokens (geometry, radii, dimming) + the Tempo /
 *           Bounce / Tint switches the control window exposes.
 * [POS]: Standalone spike, v8 (2026-09-22): tucked = the app's own 6pt
 *        edge strip at full panel height; hover = a vertical capsule that
 *        buds out of the strip. Springs live in EdgeCollapsePlan.
 */

import SwiftUI

public enum EdgeCollapseTempo: Double, CaseIterable, Identifiable, Sendable {
    case normal = 1.0
    case slow = 1.5
    public var id: Double { rawValue }
}

/// Collapse only: whether the strip tucks past the edge and pops back.
public enum EdgeCollapseBounce: String, CaseIterable, Identifiable, Sendable {
    case settle = "Settle"
    case bouncy = "Bouncy"
    public var id: String { rawValue }
}

public enum EdgeCollapseTint: String, CaseIterable, Identifiable, Sendable {
    case gradient = "Gradient"
    case black = "Black"
    case none = "None"
    public var id: String { rawValue }
}

public enum EdgeCollapseTokens {

    /// The fixed window; it never resizes. Right edge = screen edge.
    public static let containerSize = CGSize(width: 320, height: 360)

    /// GlassEffectContainer spacing. Smaller than `capsuleStripGap`, so the
    /// capsule and the strip are separate at rest and blend only while the
    /// capsule is budding out or merging back (Apple docs).
    public static let containerSpacing: CGFloat = 10

    // Card (the real panel, fullscreen-cover mode)
    public static let cardSize = CGSize(width: 250, height: 316)
    public static let cardCornerRadius: CGFloat = 22

    // Tucked strip = SnappablePanel.edgeHiddenVisibleWidth (6pt), full panel height.
    public static let stripWidth: CGFloat = 6
    public static let stripCornerRadius: CGFloat = 3
    /// Extra hover target to the left of the strip; 6pt alone is hard to land.
    public static let tuckedHoverExpand: CGFloat = 10

    // Hover capsule
    public static let capsuleArtwork: CGFloat = 96
    public static let capsuleArtworkCorner: CGFloat = 14
    public static let capsulePadding: CGFloat = 12
    public static let capsuleTextHeight: CGFloat = 34
    public static let capsuleControlsHeight: CGFloat = 40
    public static let capsuleCornerRadius: CGFloat = 26
    public static let capsuleStripGap: CGFloat = 12
    public static var capsuleSize: CGSize {
        let w = capsuleArtwork + capsulePadding * 2
        let h = capsulePadding + capsuleArtwork + 8 + capsuleTextHeight + 4 + capsuleControlsHeight + 10
        return CGSize(width: w, height: h)
    }
    /// Hover-exit margin around the capsule + strip union.
    public static let floatingHoverExitExpand: CGFloat = 14

    // Content blur while shapes morph (ref4) and the cover's blur as it tucks.
    public static let contentBlur: CGFloat = 6
    public static let heroTuckBlur: CGFloat = 8

    // Dimming layer: black at the screen edge, fading inward (Siri panel look).
    public static let edgeDimOpacity: Double = 0.92
    public static let edgeDimMidOpacity: Double = 0.40
    public static let edgeDimInnerOpacity: Double = 0.12
    public static let tintOpacity: Double = 0.45

    public static let reduceMotionCrossfadeDuration: TimeInterval = 0.18

    public static func reduceMotionAnimation(tempo: EdgeCollapseTempo) -> Animation {
        .linear(duration: reduceMotionCrossfadeDuration * tempo.rawValue)
    }
}
