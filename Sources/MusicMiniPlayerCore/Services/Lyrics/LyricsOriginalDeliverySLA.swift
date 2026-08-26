import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Original-lyrics 3s SLA (founder A-rule, 2026-08-26).
//
// Original lyrics from play/trigger to on-screen text must be ≤ 3s on every
// path. Translation is a sidecar: if it lands inside the 3s window it ships
// with the original; if not, original publishes first and translation hot-
// inserts onto the existing word axis. Translation never gates original.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Real trigger→display paths for original lyrics. Exhaustive for the A-rule
/// tests: each case has a ceiling, and 2.9s/3.1s boundary behavior is pinned.
enum LyricsOriginalDeliveryPath: String, CaseIterable, Sendable {
    case memoryCacheHit
    case diskPreflightHit
    case missMemoReplay
    case provisionalCache
    case sameTrackSeek
    case networkForegroundHit
    case networkForegroundMiss
    case trackChange
    case forceRefresh
    case coldStart
}

enum LyricsOriginalDeliverySLA {
    /// User-visible original-lyrics contract.
    static let userVisibleCeiling: TimeInterval = 3.0
    /// Test boundary: by this elapsed time original MUST already be published
    /// (content or a terminal miss). Foreground budget is 2.70s plus scheduler
    /// headroom; 2.9s is the last instant that still sits inside 3s.
    static let originalMustPublishBy: TimeInterval = 2.9
    /// Test boundary: a translation arriving at 3.1s is a legal sidecar
    /// hot-insert, not an SLA miss and not a view rebuild.
    static let translationLateArrival: TimeInterval = 3.1

    static var foregroundBudget: TimeInterval { LyricsFetcher.foregroundHardDeadline }

    /// Accuracy-first degradation for the foreground race when the wall
    /// deadline fires. Higher index = drop first. Translation is not a rung.
    static let accuracyDegradationOrder: [LyricsSource] = [
        .appleMusic, .amll, .netEase, .qq, .lrclib, .lrclibSearch, .genius, .lyricsOvh
    ]

    static func originalCeiling(for path: LyricsOriginalDeliveryPath) -> TimeInterval {
        switch path {
        case .memoryCacheHit, .diskPreflightHit, .missMemoReplay, .provisionalCache, .sameTrackSeek:
            return 0
        case .networkForegroundHit, .networkForegroundMiss, .trackChange, .forceRefresh, .coldStart:
            return foregroundBudget
        }
    }

    /// Original text is publishable the moment it exists. Translation readiness
    /// is recorded, never a gate.
    static func shouldPublishOriginal(
        elapsed: TimeInterval,
        hasOriginal: Bool,
        translationReady: Bool
    ) -> Bool {
        _ = elapsed
        _ = translationReady
        return hasOriginal
    }

    static func shouldWaitForTranslation(elapsed: TimeInterval, hasOriginal: Bool) -> Bool {
        _ = elapsed
        return !hasOriginal
    }

    /// At/after `originalMustPublishBy`, searching for original is a contract miss.
    static func originalMustHavePublished(elapsed: TimeInterval) -> Bool {
        elapsed >= originalMustPublishBy
    }

    static func originalBudgetViolated(elapsed: TimeInterval, hasPublishedOriginal: Bool) -> Bool {
        elapsed > userVisibleCeiling && !hasPublishedOriginal
    }

    /// Late translation may land on the existing axis whenever original is up.
    /// 3.1s is the explicit late-arrival fixture, not a cutoff.
    static func translationHotInsertAllowed(
        elapsed: TimeInterval,
        originalAlreadyPublished: Bool
    ) -> Bool {
        originalAlreadyPublished && elapsed >= 0
    }
}
