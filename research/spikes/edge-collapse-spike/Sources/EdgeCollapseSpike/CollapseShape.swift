/**
 * [INPUT]: width/height/cornerRadius/neckWidth (Double) — either driven live
 *          by SwiftUI's `animatableData` during a collapsing/expanding
 *          transition, or sampled offline via `CollapseShapeTrajectory`.
 * [OUTPUT]: CollapseShape (SwiftUI Shape) + CollapseShapeGeometry (pure value)
 *           + CollapseShapeTrajectory.sample(_:keyframes:) for card→stalk→pill
 *           and pill→blob→card keyframe interpolation.
 * [POS]: Standalone spike for research/edge-collapse-redesign-2026-09-19.md §8:
 *        "一个 CollapseShape 自定义 Shape，animatableData 含宽/高/圆角/颈宽四个
 *        通道". App-portable — only imports SwiftUI (public API), safe to lift
 *        into Sources/MusicMiniPlayerCore/UI verbatim.
 * [PROTOCOL]: `CollapseShapeGeometry.init` clamps cornerRadius to
 *             min(width, height) / 2 as a structural invariant — never loosen
 *             that clamp; it is the thing CollapseShapeTrajectoryTests pins.
 */

import SwiftUI

/// A single instant's shape parameters. Clamps `cornerRadius` to at most half
/// the short side at construction time — design §3's "禁止默认 Capsule 落在
/// 近方框上" rule, enforced structurally rather than only by convention.
public struct CollapseShapeGeometry: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let cornerRadius: Double
    public let neckWidth: Double

    public init(width: Double, height: Double, cornerRadius: Double, neckWidth: Double) {
        self.width = width
        self.height = height
        self.cornerRadius = min(cornerRadius, min(width, height) / 2)
        self.neckWidth = max(0, neckWidth)
    }
}

/// Custom `Shape` whose `animatableData` bundles all four channels so a
/// SINGLE `withAnimation` call interpolates whichever of them actually
/// changed under that call's Animation curve — callers get "separate
/// springs per channel" (design §8) by staggering WHEN each channel's
/// target changes (height 0–80ms, width 80–160ms, corner+neck 160–200ms;
/// see `EdgeCollapseHostView`'s phase scheduling), not by mixing curves
/// within one transaction.
public struct CollapseShape: Shape {
    public var width: Double
    public var height: Double
    public var cornerRadius: Double
    public var neckWidth: Double

    public init(_ geometry: CollapseShapeGeometry) {
        self.width = geometry.width
        self.height = geometry.height
        self.cornerRadius = geometry.cornerRadius
        self.neckWidth = geometry.neckWidth
    }

    public init(width: Double, height: Double, cornerRadius: Double, neckWidth: Double) {
        let g = CollapseShapeGeometry(width: width, height: height, cornerRadius: cornerRadius, neckWidth: neckWidth)
        self.width = g.width
        self.height = g.height
        self.cornerRadius = g.cornerRadius
        self.neckWidth = g.neckWidth
    }

    public var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(cornerRadius, neckWidth)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            // Re-clamp every frame: mid-interpolation, width/height pass
            // through the tall-thin-stalk phase where a stale un-clamped
            // cornerRadius could momentarily exceed the new short side.
            cornerRadius = min(newValue.second.first, min(width, height) / 2)
            neckWidth = max(0, newValue.second.second)
        }
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let bodyRect = CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
        path.addRoundedRect(in: bodyRect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))

        // The neck: a small bump on the leading (top) edge while the stalk
        // is handing off into the settled pill (design §7.1, 160–200ms:
        // "顶部留颈两帧后吸收"). Zero neckWidth draws nothing extra.
        if neckWidth > 0.5 {
            let neckHeight = min(20, height * 0.15)
            let neckRect = CGRect(
                x: rect.midX - neckWidth / 2,
                y: bodyRect.minY - neckHeight * 0.6,
                width: neckWidth,
                height: neckHeight
            )
            path.addRoundedRect(in: neckRect, cornerSize: CGSize(width: neckWidth / 2, height: neckWidth / 2))
        }

        return path
    }
}

/// Pure (no SwiftUI Animation involved) keyframe interpolation used by both
/// the offline sampling test and, optionally, scrubber-style debugging.
/// Two keyframe tables: `collapsing` (card → squashed → stalk → necked →
/// pill, feeding `CollapseShape` during design §7.1) and `expanding` (pill →
/// bulge → stretched → card, feeding §7.3). Numbers are the SAME shapes
/// `EdgeCollapseTokens`/the design doc describe in prose; kept here as
/// concrete geometry because the design doc doesn't pin exact intermediate
/// sizes.
public enum CollapseShapeTrajectory {
    public struct Keyframe: Equatable, Sendable {
        public let t: Double
        public let geometry: CollapseShapeGeometry

        public init(t: Double, geometry: CollapseShapeGeometry) {
            self.t = t
            self.geometry = geometry
        }
    }

    private static let cardGeometry = CollapseShapeGeometry(
        width: EdgeCollapseTokens.cardSize.width,
        height: EdgeCollapseTokens.cardSize.height,
        cornerRadius: EdgeCollapseTokens.cardCornerRadius,
        neckWidth: 0
    )

    private static let pillGeometry = CollapseShapeGeometry(width: 28, height: 120, cornerRadius: 14, neckWidth: 0)

    /// card (0–80ms) → height-collapsed (80ms) → thin stalk (160ms) →
    /// necked handoff (~180ms) → settled pill (200ms), design §7.1.
    public static let collapsing: [Keyframe] = [
        Keyframe(t: 0.00, geometry: cardGeometry),
        Keyframe(t: 0.40, geometry: CollapseShapeGeometry(width: 250, height: 60, cornerRadius: 18, neckWidth: 0)),
        Keyframe(t: 0.75, geometry: CollapseShapeGeometry(width: 20, height: 180, cornerRadius: 10, neckWidth: 0)),
        Keyframe(t: 0.90, geometry: CollapseShapeGeometry(width: 26, height: 124, cornerRadius: 13, neckWidth: 10)),
        Keyframe(t: 1.00, geometry: pillGeometry),
    ]

    /// pill (0ms) → rounder bulge/overshoot (30ms) → stretched toward card
    /// (170ms) → settled card (260ms), design §7.3.
    public static let expanding: [Keyframe] = [
        Keyframe(t: 0.00, geometry: pillGeometry),
        Keyframe(t: 0.12, geometry: CollapseShapeGeometry(width: 42, height: 52, cornerRadius: 26, neckWidth: 0)),
        Keyframe(t: 0.65, geometry: CollapseShapeGeometry(width: 220, height: 280, cornerRadius: 18, neckWidth: 0)),
        Keyframe(t: 1.00, geometry: cardGeometry),
    ]

    /// Piecewise-linear interpolation across `keyframes` at normalized
    /// progress `t` (values outside [0, 1] clamp to the nearest endpoint).
    public static func sample(_ t: Double, keyframes: [Keyframe]) -> CollapseShapeGeometry {
        precondition(!keyframes.isEmpty, "CollapseShapeTrajectory needs at least one keyframe")
        let clamped = min(max(t, 0), 1)
        guard let upperIndex = keyframes.firstIndex(where: { $0.t >= clamped }) else {
            return keyframes[keyframes.count - 1].geometry
        }
        if upperIndex == 0 { return keyframes[0].geometry }

        let lower = keyframes[upperIndex - 1]
        let upper = keyframes[upperIndex]
        let span = upper.t - lower.t
        let localT = span > 0 ? (clamped - lower.t) / span : 0

        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * localT }

        return CollapseShapeGeometry(
            width: lerp(lower.geometry.width, upper.geometry.width),
            height: lerp(lower.geometry.height, upper.geometry.height),
            cornerRadius: lerp(lower.geometry.cornerRadius, upper.geometry.cornerRadius),
            neckWidth: lerp(lower.geometry.neckWidth, upper.geometry.neckWidth)
        )
    }
}
