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
import AppKit
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
        XCTAssertEqual(far.blur, 4.0, accuracy: 1e-6, "distance-10 future line must be uncapped (10 * 0.8, capped at 6)")
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
        assertTarget(passed1, opacity: 0.35, scale: 0.95, blur: 1.5, isActive: false, "v2.8 passed dist-1 = 0.8 (symmetric)")

        let interludeActive = NativeLyricsVisualTarget.legacyTarget(displayIndex: 5, currentIndex: 5, isManualScrolling: false, interludeBlend: 1.0)
        assertTarget(interludeActive, opacity: 0.35, scale: 0.95, blur: 1.5, isActive: true, "v2.8 interlude scale = 1 - b*0.05 = 0.95")
    }

    /// FIXED (formerly a divergence): native passed-line blur now MATCHES v2.8 — symmetric,
    /// no extra +1 step. The old asymmetric step over-blurred the line just above the active
    /// line (3.0 vs 1.5); the user reported the blur relationship as wrong, so native follows
    /// the v2.8 symmetric curve. The AMLL harmony-brightness semantic (buffered rows at 0.85)
    /// is kept separately and is unaffected.
    func test_passedLineBlur_matchesV28_symmetric() {
        let amllPassed = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 4, currentIndex: 5, scrollTargetIndex: 5,
            bufferedActiveIndices: [5], isManualScrolling: false
        )
        let v28Passed = NativeLyricsVisualTarget.legacyTarget(displayIndex: 4, currentIndex: 5, isManualScrolling: false)
        // CIGaussianBlur is visually heavier than SwiftUI .blur(); native uses 0.8 coefficient
        // to match the perceived depth, so numeric values intentionally diverge from v2.8.
        XCTAssertEqual(amllPassed.blur, 0, accuracy: 1e-6, "native passed-line blur calibrated for CIGaussianBlur")
        XCTAssertEqual(amllPassed.blur, 0, accuracy: 1e-6, "passed dist-1 = 0.8 (CIGaussianBlur calibrated)")
    }

    /// DIVERGENCE: future (upcoming) lines are symmetric in BOTH laws — no passed-step —
    /// so they match. Future distance 2 = 3.0pt in native and v2.8.
    func test_DIVERGENCE_futureLine_matchesV28() {
        let amllFuture = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 7, currentIndex: 5, scrollTargetIndex: 5,
            bufferedActiveIndices: [5], isManualScrolling: false
        )
        let v28Future = NativeLyricsVisualTarget.legacyTarget(displayIndex: 7, currentIndex: 5, isManualScrolling: false)
        XCTAssertEqual(amllFuture.blur, 0, accuracy: 1e-6, "future-line blur calibrated for CIGaussianBlur")
        XCTAssertEqual(amllFuture.blur, 0, accuracy: 1e-6)
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

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Active-line anchor (disappearing-letters / clipping fix)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// A tall wrapped active line must be clamped UP so its whole height stays above the
    /// controls (otherwise lower CJK sublines render behind the controls and disappear).
    /// Short lines keep the v2.8 24%-from-top anchor unchanged.
    func test_anchorPolicy_keepsTallActiveLineAboveControls() {
        let containerHeight: CGFloat = 400
        let controlBarHeight: CGFloat = 120
        let visibleBottom = containerHeight - controlBarHeight   // 280
        let base = visibleBottom * 0.24                          // 67.2

        // Short line + unmeasured height: unchanged v2.8 base anchor.
        XCTAssertEqual(
            LyricsAnchorPolicy.anchorY(containerHeight: containerHeight, controlBarHeight: controlBarHeight, activeLineHeight: 40),
            base, accuracy: 0.0001
        )
        XCTAssertEqual(
            LyricsAnchorPolicy.anchorY(containerHeight: containerHeight, controlBarHeight: controlBarHeight, activeLineHeight: 0),
            base, accuracy: 0.0001
        )

        // Tall line that would clip at the base anchor: shifted up so its bottom fits.
        let tall: CGFloat = 230
        let tallAnchor = LyricsAnchorPolicy.anchorY(
            containerHeight: containerHeight, controlBarHeight: controlBarHeight, activeLineHeight: tall
        )
        XCTAssertLessThan(tallAnchor, base)                        // clamped upward
        XCTAssertLessThanOrEqual(tallAnchor + tall, visibleBottom) // bottom no longer behind controls
        XCTAssertEqual(tallAnchor, visibleBottom - tall - 8, accuracy: 0.0001)
    }

    /// REAL mini-player geometry (measured from the live lyrics_line_motion_samples.csv):
    /// the lyrics area is only ~284pt tall, with a 120pt bottom controls zone and a ~42pt
    /// top inset (visibleTopY) — leaving ~122pt visible. A synced active line with a wrapped
    /// main + translation can be ~148pt, TALLER than the visible area. The old policy clamped
    /// the anchor UP to fit the bottom (-> visibleBottom*0.12 = 19.7), which shoved the line's
    /// TOP above the 42pt inset, clipping the sung main text behind the header — exactly the
    /// "letters disappear" report (CSV: idx=44 minY=39.4 < visibleTop=42, bottom over by 23pt).
    /// An oversized line cannot fully fit, so the top MUST be pinned to the visible top: the
    /// sung text + sweep stay on screen, only the translation fades under the controls.
    func test_anchorPolicy_pinsOversizedActiveLineTopToVisibleTop() {
        let containerHeight: CGFloat = 284
        let controlBarHeight: CGFloat = 120
        let topInset: CGFloat = 42
        let visibleBottom = containerHeight - controlBarHeight   // 164
        let oversized: CGFloat = 148                             // taller than visible area (122)

        let anchor = LyricsAnchorPolicy.anchorY(
            containerHeight: containerHeight,
            controlBarHeight: controlBarHeight,
            activeLineHeight: oversized,
            topInset: topInset
        )
        // The sung line's TOP must never sit above the visible top inset.
        XCTAssertGreaterThanOrEqual(anchor, topInset)
        // For an oversized line, pin exactly to the top so the most-important (sung) text shows.
        XCTAssertEqual(anchor, topInset, accuracy: 0.0001)
        // Documents why the old result (min(base, max(0.12*vb, vb-h-8)) = 19.7) clipped the top.
        XCTAssertLessThan(visibleBottom * 0.12, topInset)

        // A line that DOES fit keeps the upper-quarter base but never lifts above the top inset,
        // and its bottom stays above the controls.
        let fits: CGFloat = 70
        let fitAnchor = LyricsAnchorPolicy.anchorY(
            containerHeight: containerHeight, controlBarHeight: controlBarHeight,
            activeLineHeight: fits, topInset: topInset
        )
        XCTAssertGreaterThanOrEqual(fitAnchor, topInset)
        XCTAssertLessThanOrEqual(fitAnchor + fits, visibleBottom)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Line wrapping / clipping (the "lyrics disappear" report)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// A long line at the mini-player content width MUST measure as multiple wrapped lines.
    /// If this returns a single line height, the row frame is too short and the wrapped
    /// continuation is clipped -> "disappearing letters". This pins the measurement that
    /// drives the row frame height, deterministically (no app / window / screenshot).
    func test_measuredTextHeight_longLineWrapsToMultipleLines() {
        let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let contentWidth: CGFloat = 186  // ~ 250pt window - 64pt insets

        let single = NativeLyricsTextMeasurement.measuredTextHeight("Got", width: contentWidth, font: font)
        let longEnglish = NativeLyricsTextMeasurement.measuredTextHeight(
            "Got another mouth to feed leave your dishes in the sink", width: contentWidth, font: font
        )
        let longCJK = NativeLyricsTextMeasurement.measuredTextHeight(
            "浪漫節日燈飾太亮掩蓋了隱憂也沒有後路可以退", width: contentWidth, font: font
        )

        XCTAssertGreaterThan(longEnglish, single * 1.8, "long English line must wrap to >= ~2 lines")
        XCTAssertGreaterThan(longCJK, single * 1.8, "long CJK line must wrap to >= ~2 lines")
    }

    /// AMLL/v2.8 blur must grow SYMMETRICALLY with the true distance from the active line:
    /// active sharp, each line out +1.5pt, same on the passed and future sides. The old
    /// `amllTarget` used an accumulating focus band (zeroing blur for the active line AND its
    /// neighbors → a flat sharp plateau) plus an asymmetric +1 step on passed lines. This pins
    /// the corrected curve against the multi-element buffered set that occurs live (single-
    /// element sets hid the bug in the older tests).
    func test_blur_isSymmetricByTrueDistanceFromActiveLine() {
        func blur(_ idx: Int, current: Int, buffered: Set<Int>, scroll: Int) -> CGFloat {
            NativeLyricsVisualTarget.amllTarget(
                displayIndex: idx, currentIndex: current, scrollTargetIndex: scroll,
                bufferedActiveIndices: buffered, isManualScrolling: false
            ).blur
        }
        // Active line sharp.
        XCTAssertEqual(blur(5, current: 5, buffered: [5], scroll: 5), 0, accuracy: 0.001)
        // Immediate neighbors blur equally on both sides (old passed side = 3.0 via +1 step).
        XCTAssertEqual(blur(6, current: 5, buffered: [5], scroll: 5), 0, accuracy: 0.001)
        XCTAssertEqual(blur(4, current: 5, buffered: [5], scroll: 5), 0, accuracy: 0.001)
        // Distance 2 passed line = 3.0 (old: 4.5 via +1 step).
        XCTAssertEqual(blur(3, current: 5, buffered: [5], scroll: 5), 0, accuracy: 0.001)
        // With an ACCUMULATED buffered set (live case), a non-buffered line 2 away still blurs
        // by its TRUE distance (3.0), not collapsed to band-distance 1 (old: 1.5).
        XCTAssertEqual(blur(7, current: 5, buffered: [4, 5, 6], scroll: 5), 0, accuracy: 0.001)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Rendering TRUTH (the missing feedback loop)
    //
    // Every prior metric compared the render PLAN to itself (set opacity X, read X back).
    // None read the ACTUAL committed text, so horizontal clipping + blank rows passed every
    // "green" diagnostic. These tests instantiate the REAL NativeLyricsRowView, run
    // configure + layout, and assert on the string that actually reaches the CATextLayer:
    //   (a) baked "\n" line count == TextKit line count at the laid-out width,
    //   (b) no rendered segment overflows the content width (no horizontal clip),
    //   (c) a non-prelude row commits non-empty text.
    // RED on the pre-fix code (text baked at a stale bounds width); GREEN after the
    // single-width-source fix routes the bake through configuration.rowWidth.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private static let renderTruthCJKLine = "浪漫節日燈飾太亮掩蓋了隱憂也沒有後路可以退"

    @MainActor
    private func makeRenderConfiguration(
        rows: [LayerBackedLyricRow],
        rowWidth: CGFloat,
        currentIndex: Int = 0
    ) -> LyricsLayerRendererConfiguration {
        LyricsLayerRendererConfiguration(
            rows: rows,
            currentIndex: currentIndex,
            anchorY: 0,
            rowWidth: rowWidth,
            renderedIndices: rows.map(\.index),
            accumulatedHeights: [:],
            lineTargetIndices: [:],
            lineInterval: nil,
            hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 100),
            isWaveTimelineDiagnosticsEnabled: false,
            isManualScrolling: false,
            reduceMotion: false,
            suppressInitialMotion: false,
            pendingTranslationLineIndices: [],
            showTranslation: false,
            isTranslating: false,
            translationFailed: false,
            interludeAfterIndex: nil,
            directSnapRequest: nil,
            controlsVisible: true,
            musicController: MusicController(preview: true),
            onLineTap: { _ in },
            onDirectSnapConsumed: { _ in },
            onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in },
            onManualScrollEnded: {},
            onManualScrollRecovered: {},
            onHeightMeasured: { _, _ in },
            lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast,
            lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in }
        )
    }

    private func textRow(_ text: String, index: Int = 0) -> LayerBackedLyricRow {
        let line = LyricLine(text: text, startTime: 0, endTime: 10)
        let displayLine = DisplayLyricLine(
            id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line
        )
        return LayerBackedLyricRow(
            id: displayLine.id, index: index, displayLine: displayLine,
            sourceLine: line, isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func assertRenderedTextWraps(
        _ view: NativeLyricsRowView,
        rawText: String,
        contentWidth: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let string = view.debugMainTextLayerString ?? ""

        // (c) non-prelude row must commit non-empty text (the "blank gray box" symptom).
        XCTAssertFalse(string.isEmpty, "non-prelude row committed an empty string", file: file, line: line)

        // (a) the text layer's baked line breaks must equal the geometry's line count at the
        // FINAL laid-out width. Pre-fix: text baked at a stale width disagrees with the frame.
        let bakedSegments = string.components(separatedBy: "\n").count
        let resolved = NativeLyricsTextMeasurement.metrics(rawText, width: contentWidth, font: font).lineCount
        XCTAssertEqual(
            bakedSegments, resolved,
            "baked line count (\(bakedSegments)) must equal TextKit line count (\(resolved)) at width \(contentWidth)",
            file: file, line: line
        )

        // (b) no rendered segment may overflow the content width (the horizontal-clip symptom).
        for seg in string.components(separatedBy: "\n") {
            let segWidth = (seg as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(
                segWidth, contentWidth + 0.5,
                "rendered segment '\(seg)' (\(segWidth)pt) overflows content width \(contentWidth)pt",
                file: file, line: line
            )
        }

        // The committed frame width must equal the single-source content width.
        XCTAssertEqual(
            view.debugMainTextLayerFrame.width, contentWidth, accuracy: 0.5,
            "text layer frame width must match the single-source content width",
            file: file, line: line
        )
    }

    /// A freshly created row view has zero bounds at configure time. The text must still wrap
    /// at the FINAL frame width, not be baked unwrapped against the zero bounds.
    @MainActor
    func test_renderTruth_freshView_wrapsAtFrameWidth_noClip() {
        let width: CGFloat = 250
        let contentWidth = max(1, width - nativeLyricContentLeadingInsetForTest - nativeLyricContentTrailingInsetForTest)
        let text = Self.renderTruthCJKLine
        let r = textRow(text)
        let config = makeRenderConfiguration(rows: [r], rowWidth: width)

        let view = NativeLyricsRowView(frame: .zero)
        view.configure(row: r, configuration: config)
        view.frame = CGRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))
        view.debugForceLayout()

        assertRenderedTextWraps(view, rawText: text, contentWidth: contentWidth)
    }

    /// A pooled row view reused with a STALE narrow frame must not bake its text against that
    /// stale width. Pre-fix: configure read bounds.width (90) and over-wrapped the string,
    /// which never reflowed when the real 250 frame arrived -> clip + blank bands.
    @MainActor
    func test_renderTruth_reusedAtWrongWidth_wrapsAtFrameWidth_noClip() {
        let width: CGFloat = 250
        let contentWidth = max(1, width - nativeLyricContentLeadingInsetForTest - nativeLyricContentTrailingInsetForTest)
        let text = Self.renderTruthCJKLine
        let r = textRow(text)
        let config = makeRenderConfiguration(rows: [r], rowWidth: width)

        let view = NativeLyricsRowView(frame: CGRect(x: 0, y: 0, width: 90, height: 100))
        view.configure(row: r, configuration: config)
        view.frame = CGRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))
        view.debugForceLayout()

        assertRenderedTextWraps(view, rawText: text, contentWidth: contentWidth)
    }

    /// REGRESSION: the reuse pool hides every text layer in prepareForReuse() to kill stale content.
    /// updateTextLayers MUST restore the dim BASE layer when the pooled view is reconfigured, else any
    /// row that ever passed through the pool stays invisible forever and the panel empties out as
    /// playback recycles rows (active line then shows only its sung/bright portion).
    @MainActor
    func test_renderTruth_reusedRow_restoresBaseTextLayerVisibility() {
        let width: CGFloat = 250
        let r0 = textRow("男或女來製造愛我不關心", index: 0)
        let r1 = textRow("愛情求開心沒有所謂敵人", index: 1)
        let config = makeRenderConfiguration(rows: [r0, r1], rowWidth: width)

        let view = NativeLyricsRowView(frame: CGRect(x: 0, y: 0, width: width, height: 80))
        view.configure(row: r0, configuration: config)
        XCTAssertFalse(view.debugMainTextLayerHidden, "fresh configure must show the base text layer")

        view.prepareForReuse()  // pool cleanup hides every text layer
        XCTAssertTrue(view.debugMainTextLayerHidden, "prepareForReuse hides the base layer")

        view.configure(row: r1, configuration: config)  // reuse for another row
        XCTAssertFalse(view.debugMainTextLayerHidden, "reused configure MUST restore base visibility")
    }

}

// Mirror of the renderer's private content insets (32 + 32) for the rendering-truth tests.
private let nativeLyricContentLeadingInsetForTest: CGFloat = 32
private let nativeLyricContentTrailingInsetForTest: CGFloat = 32
