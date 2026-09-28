/**
 * [INPUT]: Foundation only.
 * [OUTPUT]: Exports TourMotionPolicy (Tokens + `resolve(reduceMotion:)`).
 * [POS]: MusicMiniPlayerCore/Onboarding. Pure timing/values table (proposal
 *        §8.5's `MicroInteractionFeel.Tokens` additions + §8.4's Reduce
 *        Motion total rules), consumed by the AppKit-side card/ring/halo/
 *        celebration views. No view code, no clock — just numbers, so it is
 *        exhaustively testable (§11.1 TourMotionPolicyTests).
 */

import Foundation

public enum TourMotionPolicy {

    /// §8.5 — raw values as proposed for `MicroInteractionFeel.Tokens`.
    public enum Tokens {
        public static let cardPresentResponse = 0.36
        public static let cardPresentDamping = 0.86
        public static let cardTravelResponse = 0.50
        public static let cardTravelDamping = 0.86
        public static let cardDismissDuration = 0.16
        public static let contentStagger = 0.04

        public static let ringOuterDiameter: CGFloat = 28
        public static let ringLineWidth: CGFloat = 5.5
        public static let ringFillDuration = 0.60
        public static let ringPulseResponse = 0.50
        public static let ringPulseDamping = 0.62

        public static let beatCheckResponse = 0.28
        public static let beatCheckDamping = 0.60

        public static let haloSettleDuration = 0.90

        public static let sparkCount = 16
        public static let sparkLifetime = 0.55

        public static let confettiCount = 72
        public static let confettiLifetime = 1.8
        public static let confettiGravity: CGFloat = 360

        public static let finaleAutoDismiss = 8.0

        /// §8.1: step completion → next card, from "beat 打勾" to "新内容淡入".
        public static let stepCompletionFeedback = 1.0
        /// §3.3 S4′: the deferral note stays up before moving to S5.
        public static let deferralNoteHold = 1.1
    }

    /// A resolved bundle of "should this animate at all" decisions — §8.4's
    /// "一切位移与缩放 → 淡化；粒子不放；触觉保留；环填充线性；手势示意静止在起点态".
    public struct Spec: Equatable {
        public let reduceMotion: Bool
        public var cardMovesAlongPath: Bool { !reduceMotion }
        public var particlesEnabled: Bool { !reduceMotion }
        public var hapticsEnabled: Bool { true }
        public var ringFillLinear: Bool { reduceMotion }
        public var haloPulses: Bool { !reduceMotion }
        public var gestureGlyphAnimates: Bool { !reduceMotion }
        public var ringPulseOnFinale: Bool { !reduceMotion }

        public var cardPresentDuration: Double { reduceMotion ? 0.16 : Tokens.cardPresentResponse }
        public var cardTravelDuration: Double { reduceMotion ? 0.16 : Tokens.cardTravelResponse }
        public var cardDismissDuration: Double { Tokens.cardDismissDuration }
    }

    public static func resolve(reduceMotion: Bool) -> Spec { Spec(reduceMotion: reduceMotion) }
}
