/**
 * [INPUT]: None — pure constants.
 * [OUTPUT]: EdgeCollapseTokens (geometry, radii, dimming) + the Tempo /
 *           Bounce / Tint / TuckStyle switches the control window exposes.
 * [POS]: Standalone spike, v9 (2026-09-22).
 *   - Card = the real app window: 250×316, corner 16, 16pt off the screen
 *     edge (SnappablePanel.cornerMargin). Not flush.
 *   - Tucked = a short edge handle (founder: the full-height strip was ugly).
 *   - One object: at rest only one glass shape is visible.
 */

import SwiftUI

public enum EdgeCollapseTempo: Double, CaseIterable, Identifiable, Sendable {
    case normal = 1.0
    case slow = 1.5
    public var id: Double { rawValue }
}

/// Collapse only: whether the handle overshoots into the edge and settles back.
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

/// What stays at the screen edge when tucked.
public enum EdgeCollapseTuckStyle: String, CaseIterable, Identifiable, Sendable {
    /// 6×56 handle, progress fills from the bottom.
    case handle = "Handle"
    /// 26×68 tab with a tiny cover and a progress line.
    case coverTab = "Cover tab"
    public var id: String { rawValue }
}

public enum EdgeCollapseTokens {

    /// The fixed window; it never resizes. Right edge = screen edge.
    public static let containerSize = CGSize(width: 320, height: 360)

    /// GlassEffectContainer spacing: shapes closer than this blend (neck);
    /// every resting gap is larger, so nothing blends at rest.
    public static let containerSpacing: CGFloat = 10

    // Card = real app window (MusicMiniPlayerApp.createFloatingWindow,
    // MiniPlayerView clip radius 16, SnappablePanel.cornerMargin 16).
    public static let cardSize = CGSize(width: 250, height: 316)
    public static let cardCornerRadius: CGFloat = 16
    public static let cardEdgeMargin: CGFloat = 16

    // Tucked
    public static let handleSize = CGSize(width: 6, height: 56)
    public static let tabSize = CGSize(width: 26, height: 68)
    public static let tabArtwork: CGFloat = 18
    public static let tuckedHoverExpand: CGFloat = 10

    // Droplet on hover
    public static let dropDiameter: CGFloat = 22
    public static let dropNeckGap: CGFloat = 5     // < containerSpacing → neck
    public static let blobDiameter: CGFloat = 76

    // Hover capsule
    public static let capsuleArtwork: CGFloat = 96
    public static let capsuleArtworkCorner: CGFloat = 14
    public static let capsulePadding: CGFloat = 12
    public static let capsuleTextHeight: CGFloat = 34
    public static let capsuleControlsHeight: CGFloat = 40
    public static let capsuleCornerRadius: CGFloat = 26
    public static let capsuleEdgeGap: CGFloat = 14
    public static var capsuleSize: CGSize {
        let w = capsuleArtwork + capsulePadding * 2
        let h = capsulePadding + capsuleArtwork + 8 + capsuleTextHeight + 4 + capsuleControlsHeight + 10
        return CGSize(width: w, height: h)
    }
    public static let floatingHoverExitExpand: CGFloat = 14

    // Blur
    public static let contentBlur: CGFloat = 6
    /// Lyrics page has no cover: the cover becomes its blurred background.
    public static let lyricsBackdropBlur: CGFloat = 26

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
