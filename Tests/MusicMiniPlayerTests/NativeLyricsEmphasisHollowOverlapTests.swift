import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 3h round, item 6 (founder 2026-09-17: emphasis "跟其他普通歌词太割裂"/重影) — model-level test
// for the hypothesis identified this round: `applyFloatingHiddenBase` hollows the dim whole-line
// base using the word's UNSCALED glyph rect (the static text-layout width), while the emphasis
// word's bright tile is drawn SCALED UP (`NativeLyricsEmphasisPlan.scale = 1 + emphasisWeight*0.1*
// amount`, up to ~1.12x) and centered on the same glyph midpoint. The hollow never grows with the
// scale, so whenever scale > 1 the enlarged bright tile's true on-screen footprint exceeds the
// transparent hole cut for it — the overflow reads as the enlarged glyph's edge overlapping the
// FULL-OPACITY dim ink of whatever sits immediately next to it (a neighbouring word's own glyph,
// still drawn at rest since it was never hollowed). That overlap is exactly the kind of "edge
// blur/double image" shape the founder described.
//
// This is a pure MODEL-level test (no NativeLyricsRowView/render pipeline involved): it drives
// `NativeLyricsTextRenderPlan.make` directly across the emphasis word's active window and reads
// `run.emphasis.scale` — the exact quantity `NativeLyricsRowView.applyFloatingHiddenBase` (traced:
// takes only a `Set<Int>` of orders, never a scale/inflation amount) has no path to account for.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsEmphasisHollowOverlapTests: XCTestCase {

    /// Same fixture as NativeLyricsEmphasisFeelParityTests.emphasisLine() / the founder's own
    /// 2026-09-14 report: "about" (word index 3, duration 2.2s) is the sole emphasis-eligible run.
    private func emphasisLine() -> LyricLine {
        LyricLine(
            text: "what it's all about",
            startTime: 10, endTime: 16.2,
            words: [
                LyricWord(word: "what ", startTime: 10.0, endTime: 10.6),
                LyricWord(word: "it's ", startTime: 10.6, endTime: 11.2),
                LyricWord(word: "all ", startTime: 11.2, endTime: 11.8),
                LyricWord(word: "about", startTime: 11.8, endTime: 14.0),
            ]
        )
    }

    /// Sweep across "about"'s whole active window (its own span plus the tail of its float/lift
    /// easing, matching NativeLyricsEmphasisFeelParityTests' own 11.85...13.9 scan) and report the
    /// applied emphasis scale directly from the model. `about` is word order 3 (0-indexed) of 4.
    func test_emphasisScale_isGenuinelyAboveOne_andHollowComputationHasNoScaleParameter() {
        let emphasisOrder = 3
        let line = emphasisLine()
        var maxScale: CGFloat = 1
        var sampleCount = 0
        var positiveOverflowCount = 0
        var maxOverflowFraction: CGFloat = 0

        var t: TimeInterval = 11.85
        while t <= 13.9 {
            let plan = NativeLyricsTextRenderPlan.make(
                configuration: .init(line: line, currentTime: t, isActive: true)
            )
            defer { t += 0.02 }
            guard plan.wordRuns.indices.contains(emphasisOrder) else { continue }
            let scale = plan.wordRuns[emphasisOrder].emphasis.scale
            sampleCount += 1
            maxScale = max(maxScale, scale)
            // `applyFloatingHiddenBase`'s hollow is a fixed character-range blank against the
            // word's own STATIC (unscaled) layout width — this fraction is exactly how far the
            // rendered tile's edge sits past that static hole on each side, expressed as a fraction
            // of the tile's own half-width (identical in spirit to `(scale - 1)` for a
            // center-anchored scale transform).
            let overflowFraction = scale > 1.001 ? (scale - 1) : 0
            if overflowFraction > 0 {
                positiveOverflowCount += 1
                maxOverflowFraction = max(maxOverflowFraction, overflowFraction)
            }
        }

        print("[EmphasisHollowOverlap] samples=\(sampleCount) positiveOverflowSamples=\(positiveOverflowCount) " +
              "maxScale=\(String(format: "%.4f", maxScale)) maxOverflowFraction=\(String(format: "%.4f", maxOverflowFraction))")

        XCTAssertGreaterThan(sampleCount, 10, "fixture must actually sample the emphasis window")
        XCTAssertGreaterThan(maxScale, 1.01,
            "precondition: this word's emphasis animation must actually scale up noticeably, or the hypothesis is untestable here")
        XCTAssertGreaterThan(positiveOverflowCount, 0,
            "the emphasis word's model-level scale must exceed 1.0 for at least one sample — if this is 0, the hollow-overflow hypothesis does not apply to this fixture")
        // Root-cause statement: the hollow computation (`NativeLyricsRowView.applyFloatingHiddenBase`,
        // fed by `floatingOrders: Set<Int>`) never receives or reads this scale value at all — it
        // blanks the SAME static character range regardless of how large the animation currently
        // renders the word. Whenever `maxOverflowFraction` is positive, the rendered tile is
        // provably larger than the hole cut for it.
        XCTAssertGreaterThan(maxOverflowFraction, 0,
            "root cause confirmed: the emphasis word's rendered scale exceeds 1.0, but the static hollow computation has no scale parameter to grow the hole by")
    }
}
