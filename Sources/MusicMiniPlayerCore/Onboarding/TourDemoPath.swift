/**
 * [INPUT]: CoreGraphics (CGPoint/CGRect/CGFloat) only.
 * [OUTPUT]: Exports TourDemoPath — the fixed quadratic-Bézier arc used ONLY
 *           by the S5 in-card demo animation (proposal §3.3 S5, §8.8 v3.3).
 * [POS]: MusicMiniPlayerCore/Onboarding. Pure math, ported 1:1 from
 *        `docs/design/2026-09-25-onboarding/storyboard.html`'s
 *        `arcControl`/`arcPoint`/`easeOut` (720×440 stage, panel 250×284) so
 *        the storyboard and the shipped code agree on the same curve. The
 *        REAL panel's corner-snap spring (`SnappablePanel.startSpringAnimation`,
 *        `Spring(duration: 0.5, bounce: 0.15)`) is untouched — this path only
 *        drives the little illustrative panel-shadow inside the tour card.
 */

import CoreGraphics
import Foundation

public enum TourDemoPath {
    /// Max deviation from the chord, as a fraction of the chord length
    /// (proposal §8.8: "弧高 = 位移的 9%").
    public static let sagittaRatio: CGFloat = 0.09
    /// Where the curve's peak sits along the chord, 0...1 (§8.8: "行程 45% 处").
    public static let peak: CGFloat = 0.45
    /// §8.8: "0.6 s ease-out".
    public static let duration: TimeInterval = 0.6

    /// The quadratic Bézier's control point: on the chord at `peak`, offset
    /// toward `bulgeToward` by `2 * sagittaRatio * chordLength` (a quadratic
    /// Bézier's maximum deviation from the chord is half the control
    /// point's own offset from it — storyboard.html's `arcControl`).
    public static func control(from: CGPoint, to: CGPoint, bulgeToward center: CGPoint) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = max(hypot(dx, dy), 1)
        var nx = -dy / len, ny = dx / len

        let mid = CGPoint(x: from.x + dx * peak, y: from.y + dy * peak)
        let towardCenter = CGPoint(x: center.x - mid.x, y: center.y - mid.y)
        if nx * towardCenter.x + ny * towardCenter.y < 0 { nx = -nx; ny = -ny }

        let offset = 2 * sagittaRatio * len
        return CGPoint(x: mid.x + nx * offset, y: mid.y + ny * offset)
    }

    /// Point at parameter `t` (0...1, NOT yet eased) along the quadratic
    /// Bézier `from` → `control` → `to`.
    public static func point(from: CGPoint, control: CGPoint, to: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
            y: u * u * from.y + 2 * u * t * control.y + t * t * to.y
        )
    }

    /// `cubic-bezier(.2, .8, .2, 1)` approximated the way storyboard.html
    /// does it (`1 - (1-t)^2.6`) — close enough that a shared visual
    /// reference (the storyboard) and this code read the same curve; both
    /// start at 0, end at 1, monotonic, no overshoot.
    public static func easeOut(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return 1 - pow(1 - clamped, 2.6)
    }

    /// Convenience: the eased point at `progress` (0...1) along the arc from
    /// `from` to `to`, bulging toward `bulgeToward` (typically the demo
    /// stage's own center — the corner the card is nudging the panel-shadow
    /// TOWARD, on the side nearer the middle of the screen).
    public static func point(from: CGPoint, to: CGPoint, bulgeToward center: CGPoint, progress: CGFloat) -> CGPoint {
        let c = control(from: from, to: to, bulgeToward: center)
        return point(from: from, control: c, to: to, t: easeOut(progress))
    }

    /// Reduce Motion (§8.8 table): no arc, land directly on the target.
    public static func reducedMotionPoint(to: CGPoint) -> CGPoint { to }
}
