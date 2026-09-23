import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder real-device report (stage bundle 3q item 3, screenshot of 《啟程》
// "只有你能带我走向 / 未来的旅程"): while line 1 was mid-sweep through "带" (x≈115), the entire
// NOT-YET-SUNG second visual line ("未来的旅") showed a uniform half-bright highlight, with only
// its last character ("程") staying dark.
//
// Root cause (`NativeLyricsTextSweepLayout.buildLayout`): a word RUN's glyph range can span the
// wrap boundary between two visual lines — the lyric source's "word" segmentation for CJK text
// doesn't always land on the same boundary NSLayoutManager wraps at. The old loop added a FULL
// COPY of such a run — same `startTime`/`endTime` — into EVERY fragment its glyphs touched, with
// no `break`. While line 1 was genuinely sweeping through that run, line 2's duplicate copy
// (identical time window, just a narrower `rect` clipped to line 2's portion of the glyphs)
// independently evaluated the SAME [startTime, endTime] against `currentTime` and computed its
// own nonzero progress — revealing line 2's copy in lockstep with line 1, even though line 2
// hadn't been reached at all.
//
// Fix: a run that spans N fragments now has its time window split PROPORTIONALLY by glyph count
// across those fragments in reading order, so only the fragment currently under the wavefront can
// have `currentTime > startTime`; every later fragment's slice starts strictly after the earlier
// ones end.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsWrapRunSplitTests: XCTestCase {
    private let fontSize: CGFloat = 24
    private let width: CGFloat = 150
    private let fadeHalfPoint: CGFloat = 10

    /// A single word run whose 11 CJK characters are wide enough, at this width/font, to wrap
    /// across two visual lines by themselves — the exact shape of the founder's report (one sung
    /// "word" straddling the wrap point).
    private let longRunText = "只有你能带我走向未来的旅程"

    private func wrappedLinePlan(currentTime: TimeInterval) -> [NativeLyricsTextSweepVisualLinePlan] {
        let runs = [
            NativeLyricsWordRunPlan(
                text: longRunText,
                startTime: 0,
                endTime: 10,
                progress: 0,
                isCJK: true,
                isEmphasis: false,
                baseFloatY: 0,
                opacity: 1,
                sweep: NativeLyricsSweepPlan(progress: 0, brightAlpha: 1, fadeHalfPoint: fadeHalfPoint, postLineFade: 1),
                emphasis: .inactive
            )
        ]
        return NativeLyricsTextSweepLayout.makePlan(
            displayText: longRunText,
            wordRuns: runs,
            width: width,
            fontSize: fontSize,
            fadeHalfPoint: fadeHalfPoint
        )
    }

    /// Sanity precondition: this fixture must actually wrap into 2+ visual lines, or the rest of
    /// this test proves nothing.
    func test_fixtureWrapsAcrossTwoVisualLines() {
        let linePlan = wrappedLinePlan(currentTime: 0.01)
        XCTAssertGreaterThanOrEqual(linePlan.count, 2,
            "fixture must wrap for this test to exercise the cross-line run-split path; got \(linePlan.count) line(s)")
    }

    /// Every visual line AFTER the first must carry the run's split slice STRICTLY later than the
    /// previous line's slice — this is what stops a not-yet-reached line from ever satisfying
    /// `currentTime > startTime` while an earlier line is still sweeping through the shared run.
    func test_runSpanningWrap_splitsTimeStrictlyAscendingAcrossLines() throws {
        let linePlan = wrappedLinePlan(currentTime: 0.01)
        try skipIfNotWrapped(linePlan)

        var previousEnd: TimeInterval?
        for (index, line) in linePlan.enumerated() {
            guard let run = line.runs.first else {
                XCTFail("line \(index) has no runs")
                continue
            }
            if let previousEnd {
                XCTAssertGreaterThanOrEqual(run.startTime, previousEnd,
                    "line \(index)'s slice of the shared run must start no earlier than the previous line's slice ended")
            }
            XCTAssertLessThan(run.startTime, run.endTime, "line \(index)'s slice must have positive duration")
            previousEnd = run.endTime
        }
    }

    /// The core regression: while `currentTime` sits inside line 0's time slice (line 0 is
    /// genuinely sweeping), every LATER visual line's wavefront must read as "not yet reached" —
    /// i.e. at or before that line's own sweep start, never a partial reveal.
    func test_earlierLineSweeping_laterLineShowsNoReveal() throws {
        let linePlan = wrappedLinePlan(currentTime: 0.01)
        try skipIfNotWrapped(linePlan)

        guard let firstRun = linePlan[0].runs.first else {
            XCTFail("line 0 has no runs")
            return
        }
        // Pick a moment strictly inside line 0's own slice of the run (not at its very start, so
        // this is a genuine "mid-sweep" sample, matching the founder's screenshot).
        let midLine0 = firstRun.startTime + (firstRun.endTime - firstRun.startTime) * 0.5
        XCTAssertLessThan(midLine0, linePlan[1].runs.first?.startTime ?? .infinity,
            "test setup: the sampled time must fall before line 1's slice even starts, or this isn't testing the 'line 1 not reached yet' case")

        let maskLines = NativeLyricsTextSweepLayout.maskLines(
            from: linePlan,
            fadeHalfPoint: fadeHalfPoint,
            currentTime: midLine0
        )
        XCTAssertEqual(maskLines.count, linePlan.count)

        // Line 0 (the sweeping line) should show a real, in-progress wavefront strictly after its
        // own line start — sanity check that the fixture is actually exercising a live sweep.
        let line0Start = linePlan[0].runs.first!.rect.minX - fadeHalfPoint
        XCTAssertGreaterThan(maskLines[0].wavefrontX, line0Start,
            "line 0 should be visibly mid-sweep at this sampled time")

        // Line 1 (and any further wrapped line) must NOT reveal anything yet: its wavefront must
        // sit at or before ITS OWN sweep start (first glyph minX - fadeHalfPoint) — this is what
        // "wholly dark, not half-bright" means for the mask. Before the 3q fix this failed because
        // line 1 inherited a live, partially-advanced copy of the same run.
        for index in 1..<linePlan.count {
            guard let firstGlyphRect = linePlan[index].runs.first?.rect else { continue }
            let ownSweepStart = firstGlyphRect.minX - fadeHalfPoint
            XCTAssertLessThanOrEqual(maskLines[index].wavefrontX, ownSweepStart + 0.01,
                "line \(index) must show zero reveal while an earlier line is still sweeping through the shared run — got wavefrontX=\(maskLines[index].wavefrontX), ownSweepStart=\(ownSweepStart)")
        }
    }

    private func skipIfNotWrapped(_ linePlan: [NativeLyricsTextSweepVisualLinePlan]) throws {
        guard linePlan.count >= 2 else {
            throw XCTSkip("fixture did not wrap into 2+ visual lines at width=\(width)/fontSize=\(fontSize) on this platform — see test_fixtureWrapsAcrossTwoVisualLines")
        }
    }
}
