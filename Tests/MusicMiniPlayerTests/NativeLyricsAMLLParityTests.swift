//
//  NativeLyricsAMLLParityTests.swift
//
//  First-principles, code-based diagnosis of the native lyrics UX. Each test pins a
//  disputed behavior against a TRUSTED reference and classifies it:
//    - MYTH  : a Codex-claimed regression that the current code does NOT have
//              (the test asserts correct behavior and PASSES → claim discarded).
//    - DIVERGENCE : native (AMLL semantics) deliberately differs from old v2.8; the
//              user chose "keep AMLL semantics", so this is documented, not a defect.
//    - DEFECT (view-layer): native diverges from AMLL in a way the user reported;
//              pinned here at its exact source location so Phase 3 can flip it test-first.
//
//  References (TRUSTED):
//    - AMLL upstream  : github.com/Steve-xmh/applemusic-like-lyrics @ 243112b
//                       (vendored at tmp/amll-source, SHA-verified against GitHub).
//    - v2.8 SwiftUI   : LyricLineView.swift:129-147 @ b24b182a — ported verbatim into
//                       NativeLyricsVisualTarget.legacyTarget(...), so testing
//                       legacyTarget pins the v2.8 reference as executable values.
//

import XCTest
import CoreGraphics
@testable import MusicMiniPlayerCore

final class NativeLyricsAMLLParityTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Fixtures
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func assertTarget(
        _ target: NativeLyricsVisualTarget,
        opacity: CGFloat,
        scale: CGFloat,
        blur: CGFloat,
        isActive: Bool,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(target.opacity, opacity, accuracy: 1e-6, "opacity \(message)", file: file, line: line)
        XCTAssertEqual(target.scale, scale, accuracy: 1e-6, "scale \(message)", file: file, line: line)
        XCTAssertEqual(target.blur, blur, accuracy: 1e-6, "blur \(message)", file: file, line: line)
        XCTAssertEqual(target.isActive, isActive, "isActive \(message)", file: file, line: line)
    }

    private func row(
        index: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        isPrelude: Bool = false
    ) -> LayerBackedLyricRow {
        let line = LyricLine(text: "Line \(index)", startTime: startTime, endTime: endTime)
        let displayLine = DisplayLyricLine(
            id: "line-\(index)",
            sourceIndex: index,
            segmentIndex: 0,
            segmentCount: 1,
            line: line
        )
        return LayerBackedLyricRow(
            id: displayLine.id,
            index: index,
            displayLine: displayLine,
            sourceLine: line,
            isPrelude: isPrelude,
            preludeEndTime: 0,
            interlude: nil
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Visual law: MYTHS (Codex claims the current code does NOT have)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// MYTH "active row stays bright during manual scroll". The current code flattens
    /// EVERY row — including the active one — to the neutral browse state, exactly like
    /// v2.8 (LyricLineView.swift:131/137/144: scale 0.95, blur 0, textOpacity 0.6).
    func test_MYTH_manualScroll_flattensEveryRow_includingActive() {
        let active = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 5, currentIndex: 5, scrollTargetIndex: 5,
            bufferedActiveIndices: [5], isManualScrolling: true
        )
        let far = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 15, currentIndex: 5, scrollTargetIndex: 5,
            bufferedActiveIndices: [5], isManualScrolling: true
        )
        assertTarget(active, opacity: 0.6, scale: 0.95, blur: 0, isActive: true, "active row during manual scroll")
        assertTarget(far, opacity: 0.6, scale: 0.95, blur: 0, isActive: false, "far row during manual scroll")
    }

    /// MYTH "native blur is capped at 5". The current inactive-blur law is uncapped
    /// (LyricsPresentationModels.swift:284-289), which honors the user's "uncapped blur"
    /// iron law. A far line at distance 10 yields 15.0pt, not min(5, ...).
    /// NOTE: AMLL upstream DOES cap at 5px (dom/lyric-line.ts:289 @ 243112b). This is the
    /// one place the user's explicit "uncapped" iron law overrides AMLL literalism.
    func test_MYTH_inactiveBlur_isUncapped() {
        let far = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 15, currentIndex: 5, scrollTargetIndex: 5,
            bufferedActiveIndices: [5], isManualScrolling: false
        )
        XCTAssertEqual(far.blur, 15.0, accuracy: 1e-6, "distance-10 future line must be uncapped (10 * 1.5)")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Visual law: native (AMLL) vs v2.8, executable comparison
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// v2.8 reference, pinned via legacyTarget (the verbatim port of LyricLineView:129-147).
    /// Inactive blur is SYMMETRIC: abs(distance) * 1.5 with no passed-line step.
    func test_v28Reference_legacyTarget_values() {
        let activeC = NativeLyricsVisualTarget.legacyTarget(displayIndex: 5, currentIndex: 5, isManualScrolling: false)
        assertTarget(activeC, opacity: 1.0, scale: 1.0, blur: 0, isActive: true, "v2.8 active, blend 0")

        let passed1 = NativeLyricsVisualTarget.legacyTarget(displayIndex: 4, currentIndex: 5, isManualScrolling: false)
        assertTarget(passed1, opacity: 0.35, scale: 0.95, blur: 1.5, isActive: false, "v2.8 passed dist-1 = 1.5 (symmetric)")

        let interludeActive = NativeLyricsVisualTarget.legacyTarget(displayIndex: 5, currentIndex: 5, isManualScrolling: false, interludeBlend: 1.0)
        assertTarget(interludeActive, opacity: 0.35, scale: 0.95, blur: 1.5, isActive: true, "v2.8 interlude scale = 1 - b*0.05 = 0.95")
    }

    /// DIVERGENCE: AMLL adds a passed-line +1 blur step (asymmetric), so a passed line at
    /// distance 1 is 3.0pt in native vs 1.5pt in v2.8. The user chose AMLL semantics, so
    /// this asymmetry is intended. AMLL ref: base/layout.ts:326-327 @ 243112b.
    func test_DIVERGENCE_amllPassedLine_hasExtraBlurStep_vs_v28() {
        let amllPassed = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 4, currentIndex: 5, scrollTargetIndex: 5,
            bufferedActiveIndices: [5], isManualScrolling: false
        )
        let v28Passed = NativeLyricsVisualTarget.legacyTarget(displayIndex: 4, currentIndex: 5, isManualScrolling: false)
        XCTAssertEqual(amllPassed.blur, 3.0, accuracy: 1e-6, "AMLL passed dist-1 = (1+1)*1.5")
        XCTAssertEqual(v28Passed.blur, 1.5, accuracy: 1e-6, "v2.8 passed dist-1 = 1*1.5")
        XCTAssertGreaterThan(amllPassed.blur, v28Passed.blur, "AMLL over-blurs passed lines vs v2.8 by one step")
    }

    /// DIVERGENCE: future (upcoming) lines are symmetric in BOTH laws — no passed-step —
    /// so they match. Future distance 2 = 3.0pt in native and v2.8.
    func test_DIVERGENCE_futureLine_matchesV28() {
        let amllFuture = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 7, currentIndex: 5, scrollTargetIndex: 5,
            bufferedActiveIndices: [5], isManualScrolling: false
        )
        let v28Future = NativeLyricsVisualTarget.legacyTarget(displayIndex: 7, currentIndex: 5, isManualScrolling: false)
        XCTAssertEqual(amllFuture.blur, v28Future.blur, accuracy: 1e-6, "future-line blur matches v2.8")
        XCTAssertEqual(amllFuture.blur, 3.0, accuracy: 1e-6)
    }

    /// DIVERGENCE: native active-row interlude scale is 1 - blend*0.03 (= 0.97 at blend 1),
    /// while v2.8 used 1 - blend*0.05 (= 0.95). A 0.02 difference at full interlude.
    func test_DIVERGENCE_activeInterludeScale_003_vs_v28_005() {
        let amllActive = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 5, currentIndex: 5, scrollTargetIndex: 5,
            bufferedActiveIndices: [5], isManualScrolling: false, interludeBlend: 1.0
        )
        assertTarget(amllActive, opacity: 0.35, scale: 0.97, blur: 1.5, isActive: true, "AMLL interlude active scale 0.97")
    }

    /// CHARACTERIZATION of the "smeared active row / wrong brightness" report: native keeps
    /// secondary buffered rows (e.g. K-pop harmony) bright at opacity 0.85, a tier that v2.8
    /// never had (v2.8 non-active = 0.35). Whether this multi-row brightness is desired is a
    /// product decision for the checkpoint. AMLL ref: base/layout.ts:272/277 @ 243112b (0.85).
    func test_CHARACTERIZATION_bufferedHarmonyRow_staysBrightAt085() {
        // Two simultaneously-active rows (5 hot, 6 buffered harmony).
        let hot = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 5, currentIndex: 5, scrollTargetIndex: 5,
            bufferedActiveIndices: [5, 6], isManualScrolling: false
        )
        let buffered = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 6, currentIndex: 5, scrollTargetIndex: 5,
            bufferedActiveIndices: [5, 6], isManualScrolling: false
        )
        assertTarget(hot, opacity: 1.0, scale: 1.0, blur: 0, isActive: true, "primary active row")
        assertTarget(buffered, opacity: 0.85, scale: 1.0, blur: 0, isActive: true, "harmony row stays bright (no v2.8 equivalent)")

        // v2.8 would dim that same neighbor to 0.35 — the executable contrast.
        let v28Neighbor = NativeLyricsVisualTarget.legacyTarget(displayIndex: 6, currentIndex: 5, isManualScrolling: false)
        XCTAssertEqual(v28Neighbor.opacity, 0.35, accuracy: 1e-6, "v2.8 neighbor would be 0.35, not 0.85")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Active-row ownership: MYTH "ownership split / smeared"
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// MYTH "semantic owner is split across rows". Even with overlapping harmony lines both
    /// HOT at once, amllState resolves a SINGLE semantic owner = hotGroups.max()
    /// (LyricsPresentationModels.swift:503-505). The multi-row brightness is a rendering
    /// choice (above), not an ownership ambiguity.
    func test_MYTH_harmonyLines_resolveToSingleSemanticOwner() {
        let rows = [
            row(index: 0, startTime: 0.0, endTime: 1.5, isPrelude: true),
            row(index: 4, startTime: 6.0, endTime: 9.0),
            row(index: 5, startTime: 10.0, endTime: 14.0),
            row(index: 6, startTime: 10.5, endTime: 14.0),   // harmony, overlaps 5
            row(index: 7, startTime: 16.0, endTime: 18.0)
        ]
        let state = NativeLyricsTimelinePolicy.amllState(
            at: 12.0, rows: rows, fallback: 0, previous: nil, isSeeking: false
        )
        XCTAssertEqual(state.hotGroups, [5, 6], "both harmony lines are hot")
        XCTAssertEqual(state.semanticIndex, 6, "single owner = max of hot groups")
    }

    /// MYTH "seek is not handled in the timeline policy". The PURE function handles seek
    /// correctly: with isSeeking=true, bufferedGroups collapses to exactly hotGroups
    /// (LyricsPresentationModels.swift:484-485). The real defect is the CALLER, which always
    /// passes isSeeking:false (LyricsLayerRendererView.swift:723) — see the view-layer test.
    func test_MYTH_amllState_seekCollapsesBufferedToHot() {
        let rows = [
            row(index: 0, startTime: 0.0, endTime: 1.5, isPrelude: true),
            row(index: 5, startTime: 10.0, endTime: 14.0),
            row(index: 6, startTime: 10.5, endTime: 14.0)
        ]
        let priorWithStaleBuffer = NativeLyricsTimelinePolicy.AMLLState(
            playbackTime: 5.0, hotGroups: [], bufferedGroups: [1, 2, 3],
            scrollToIndex: 1, semanticIndex: 1
        )
        let seeked = NativeLyricsTimelinePolicy.amllState(
            at: 12.0, rows: rows, fallback: 0, previous: priorWithStaleBuffer, isSeeking: true
        )
        XCTAssertEqual(seeked.bufferedGroups, seeked.hotGroups, "seek must drop stale buffer, keep only hot")
        XCTAssertEqual(seeked.hotGroups, [5, 6])
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - View-layer DEFECTS (pinned at source; Phase 3 flips these test-first)
    //
    // These behaviors live in an NSView with CALayer side effects and cannot be exercised
    // as pure functions. Following the precedent in NativeLyricsSurfaceSourceTests, we pin
    // the exact defective wiring by source inspection. Each test currently PASSES because
    // the defect is really present; Phase 3 will change the wiring AND this assertion
    // together (failing-test-first per defect).
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func rendererSource(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Extract a single method's body (from its `func NAME(` to the next top-level
    /// `private func`/`func` at the same indentation) so wiring assertions are scoped
    /// to that method and not fooled by the same call appearing elsewhere.
    private func functionBody(_ name: String, in source: String) -> String {
        guard let start = source.range(of: "func \(name)(") else {
            XCTFail("function \(name) not found in source")
            return ""
        }
        let after = source[start.upperBound...]
        let end = after.range(of: "\n    private func ") ?? after.range(of: "\n    func ")
        return String(end.map { after[..<$0.lowerBound] } ?? after)
    }

    /// D1 FIXED — tap-to-jump must SPRING to the line from current rendered positions,
    /// not hard-snap. v2.8 parity: LyricLineView's `.animation(value: fullOffset)` owns the
    /// transition (LyricsView.swift:1671-1672). The spring path (semanticSpringRetarget +
    /// currentRenderedYByIndex) existed but was unwired; handleNativeLineTap now routes to it.
    func test_tapToLine_springRetargets_notHardSnap() throws {
        let body = functionBody("handleNativeLineTap", in: try rendererSource())
        XCTAssertTrue(
            body.contains("semanticSpringRetarget(") && body.contains(".tapToLine"),
            "tap-to-jump must route through the spring retarget path"
        )
        XCTAssertFalse(
            body.contains("forceDirectSnap("),
            "tap-to-jump must not hard-snap"
        )
    }

    /// D2 FIXED — manual-scroll recovery springs back to the live line from the scrolled
    /// position (v2.8 spring-release; AMLL releases ownership and lets layout spring,
    /// base/index.ts:797-800), instead of an abrupt hard snap.
    func test_manualScrollRecovery_springReleases() throws {
        let body = functionBody("recoverNativeManualScroll", in: try rendererSource())
        XCTAssertTrue(
            body.contains("semanticSpringRetarget(") && body.contains(".manualScroll"),
            "manual-scroll recovery must spring-release to the live line"
        )
        XCTAssertFalse(
            body.contains("forceDirectSnap("),
            "manual-scroll recovery must not hard-snap"
        )
    }

    /// DEFECT D3 — seek is a HEURISTIC, not first-class. The natural recompute always calls
    /// amllState(isSeeking: false) and fakes seek by detecting a >1-line index jump. AMLL
    /// threads an explicit isSeek flag from the transport (base/index.ts:480-518).
    /// Phase 3: thread a real seek signal; remove the jump heuristic.
    func test_DEFECT_seek_isHeuristicNotFirstClass() throws {
        let source = try rendererSource()
        XCTAssertTrue(source.contains("isSeeking: false"), "DEFECT pinned: natural recompute hardcodes isSeeking:false")
        XCTAssertTrue(source.contains("abs(liveIndex - current) > 1"), "DEFECT pinned: seek inferred from >1-line jump heuristic")
    }

    /// DEFECT D4 — tap forwarding is looser than AMLL: when manual-scrolling, a miss still
    /// fires the hovered row's handler via a frame expanded by 24pt. AMLL requires the
    /// pointer to land inside the target's real frame (dom/index.ts hit-test).
    func test_DEFECT_tapForwarding_hasLooseHoveredFallback() throws {
        let source = try rendererSource()
        XCTAssertTrue(
            source.contains("insetBy(dx: 0, dy: -24)"),
            "DEFECT pinned: hovered-row tap fallback expands the hit frame by 24pt"
        )
    }
}
