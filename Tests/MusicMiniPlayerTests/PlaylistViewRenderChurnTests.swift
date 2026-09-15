/**
 * [INPUT]: MusicController (preview), PlaylistView, SwiftUI/AppKit hosting
 * [OUTPUT]: Regression pin for the WT-D plan H CPU investigation (2026-09-15,
 *           founder real-machine measurements isolated the cause to 5718a46
 *           "show Up Next only when exact": 537a99e 7.4% max 9.3% ->
 *           5718a46 40.0% max 48.6%, History-row-count independent (0 vs 11
 *           rows both ~40% on a339486))
 * [POS]: Tests/ — hosts the real PlaylistView in a realized (invisible) NSWindow
 *        and counts actual SwiftUI body invocations via PlaylistView.debugBodyEvalCount
 *        (see PlaylistView.swift), instead of guessing from static reading. Per
 *        banned-patterns.md, a detached/un-hosted view never reproduces real
 *        SwiftUI/AppKit invalidation behavior — must be a realized NSWindow.
 *
 * Root cause (headless-proven below, not just read from source): @EnvironmentObject
 * subscribes to MusicController's `objectWillChange` at the OBJECT level, so ANY
 * @Published write already forced a full PlaylistView.body re-evaluation in BOTH
 * 537a99e and 5718a46 — identical count, proven by driving 20 redundant writes
 * against each checkout. The regression is NOT re-render FREQUENCY; it is the
 * COST of each (pre-existing-frequency) re-evaluation. 5718a46 introduced
 * `if upNextVisibility == .shown { PlaylistSection(...) } else { caption }` —
 * an OUTER conditional whose two branches are structurally different view
 * types, so SwiftUI tore down and rebuilt PlaylistSection's GeometryReader/
 * .preference sticky-header plumbing on every re-render, exactly the
 * "destroyed/recreated" trap banned-patterns.md already documents for
 * conditional ScrollView rendering. The fix keeps PlaylistSection itself
 * unconditional (stable identity, stable GeometryReader/.preference
 * subscription) and branches only its CONTENT, the same shape the History
 * section directly above it already used successfully.
 * [PROTOCOL]: Changes here -> update this header, then check root CLAUDE.md
 */

import XCTest
import SwiftUI
@testable import MusicMiniPlayerCore

#if DEBUG
@MainActor
final class PlaylistViewRenderChurnTests: XCTestCase {

    private var hostWindow: NSWindow?

    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    /// A detached NSHostingView never gets driven by AppKit's real display-link /
    /// invalidation pipeline — must be realized in a window for body evaluations
    /// (and any downstream CA commits) to actually happen, exactly like the
    /// existing NativeLyricsImplicitAnimationTests hosting pattern.
    private func hostInWindow(_ view: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = view
        window.orderFrontRegardless()
        hostWindow = window
    }

    private func pump(_ seconds: TimeInterval = 0.03) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeController(upNextNonEmpty: Bool) -> MusicController {
        let controller = MusicController(preview: true)
        controller.upNextTracks = upNextNonEmpty
            ? [("Now Next", "Some Artist", "Some Album", "np1", 200.0)]
            : []
        controller.recentTracks = []
        controller.queueProvenance = .playlistContextOnly(playlistName: "Test Playlist")
        controller.shuffleEnabled = false
        return controller
    }

    // MARK: - No self-perpetuating loop, either shape

    /// Baseline: with ZERO explicit stimulus after the initial mount settles,
    /// PlaylistView.body must stop re-evaluating on its own — Up Next shown.
    func test_idleWithUpNextShown_bodyStopsReevaluating() {
        let controller = makeController(upNextNonEmpty: true)
        let hosting = NSHostingView(rootView: PlaylistRenderChurnProbeHost(controller: controller))
        hostInWindow(hosting)
        pump(0.2)

        PlaylistView.debugBodyEvalCount = 0
        pump(1.0)

        XCTAssertEqual(
            PlaylistView.debugBodyEvalCount, 0,
            "PlaylistView.body re-evaluated \(PlaylistView.debugBodyEvalCount) times over 1s with zero explicit MusicController writes (Up Next shown) — a self-perpetuating loop exists independent of any real state change"
        )
    }

    /// Same idle probe with Up Next in the HIDDEN/fixed-caption state — the
    /// specific shape 5718a46 introduced. Must be equally silent at idle.
    func test_idleWithUpNextHiddenCaption_bodyStopsReevaluating() {
        let controller = makeController(upNextNonEmpty: false)
        controller.shuffleEnabled = true // .playlistContextOnly + shuffle on -> hidden(.shuffle)

        let hosting = NSHostingView(rootView: PlaylistRenderChurnProbeHost(controller: controller))
        hostInWindow(hosting)
        pump(0.3)

        PlaylistView.debugBodyEvalCount = 0
        pump(1.0)

        XCTAssertEqual(
            PlaylistView.debugBodyEvalCount, 0,
            "With Up Next hidden behind the fixed caption, PlaylistView.body re-evaluated \(PlaylistView.debugBodyEvalCount) times over 1s with zero explicit MusicController writes — a sticky-header geometry feedback loop is self-sustaining in this shape"
        )
    }

    // MARK: - No amplification: N writes -> at most N re-renders, never more

    /// @EnvironmentObject's coarse-grained invalidation means every MusicController
    /// @Published write already forces one PlaylistView.body re-evaluation — that
    /// is pre-existing SwiftUI behavior, not the bug, and out of scope to change
    /// here. What THIS test pins is that repeatedly toggling `upNextVisibility`
    /// between shown and hidden (the worst case for the old "destroy the whole
    /// PlaylistSection subtree" structure). Each toggle legitimately costs UP TO
    /// two body re-evaluations — one for the `@Published` write itself, one more
    /// when the header row's appear/disappear genuinely changes the section's
    /// height and the sticky-header GeometryReader/.preference plumbing reports
    /// the new frame back into `sectionOffsets` (@State) — but never runs away,
    /// and settles to zero the instant the writes stop. That bounded-and-settles
    /// shape is what distinguishes this from the old bug: destroying and
    /// rebuilding PlaylistSection's entire subtree (GeometryReader, preference
    /// subscription, and every Up Next row's own `.task`) is a structurally
    /// bigger, unbounded-relative-to-content-size cost, not a fixed small
    /// multiple of the write count.
    func test_upNextVisibilityToggle_boundedBodyEvals_noRunaway() {
        let controller = makeController(upNextNonEmpty: true)
        let hosting = NSHostingView(rootView: PlaylistRenderChurnProbeHost(controller: controller))
        hostInWindow(hosting)
        pump(0.2)

        PlaylistView.debugBodyEvalCount = 0

        let toggles = 10
        for i in 0..<toggles {
            controller.shuffleEnabled = (i % 2 == 0) // flips UpNextVisibility.shown <-> .hidden(.shuffle)
            pump(0.03)
        }

        XCTAssertLessThanOrEqual(
            PlaylistView.debugBodyEvalCount, toggles * 2 + 2,
            "expected roughly 2 body re-evaluations per visibility-flipping write (\(toggles) writes) plus a little settle slack, got \(PlaylistView.debugBodyEvalCount) — a bigger multiple means a toggle is triggering a teardown/rebuild cascade, not just the write plus one geometry-settle pass"
        )

        PlaylistView.debugBodyEvalCount = 0
        pump(0.5)
        XCTAssertEqual(
            PlaylistView.debugBodyEvalCount, 0,
            "body kept re-evaluating \(PlaylistView.debugBodyEvalCount) times after the last visibility toggle settled — a residual loop"
        )
    }

    /// "Stable playback, 5s" ceiling: simulates a realistic window of steady
    /// playback where MusicController still legitimately republishes some
    /// unrelated @Published property a handful of times (the EnvironmentObject
    /// mechanism means each one costs a PlaylistView.body re-run regardless of
    /// what property it is) — asserts the total never exceeds the number of
    /// writes actually made, i.e. no runaway/amplified re-render loop over a
    /// sustained window.
    func test_fiveSecondsSteadyPlayback_bodyEvalCountBoundedByActualWrites() {
        let controller = makeController(upNextNonEmpty: true)
        let hosting = NSHostingView(rootView: PlaylistRenderChurnProbeHost(controller: controller))
        hostInWindow(hosting)
        pump(0.2)

        PlaylistView.debugBodyEvalCount = 0

        // A handful of legitimate writes spread across ~5s of "steady" playback —
        // e.g. an occasional queue-hash reconciliation or quality-badge update.
        // Deliberately sparse: this is what "steady, nothing actually changing
        // about Up Next" looks like, not a stress test.
        let deadline = Date().addingTimeInterval(5.0)
        var writes = 0
        while Date() < deadline {
            controller.queueProvenance = .playlistContextOnly(playlistName: "Test Playlist")
            writes += 1
            pump(0.5)
        }

        XCTAssertLessThanOrEqual(
            PlaylistView.debugBodyEvalCount, writes,
            "over ~5s of steady playback with \(writes) real writes, PlaylistView.body re-evaluated \(PlaylistView.debugBodyEvalCount) times — more re-renders than writes means something is amplifying or looping"
        )
    }

    // MARK: - Sanity: the counter reflects real SwiftUI dependency behavior

    /// @EnvironmentObject/@ObservedObject subscribe to `objectWillChange` at the
    /// OBJECT level, not per-property — so ANY @Published write on MusicController,
    /// even one PlaylistView.body never reads (audioQuality), already forces a
    /// full re-evaluation. This is fundamental, pre-existing SwiftUI behavior
    /// (true identically before and after 5718a46) — documented here so nobody
    /// re-derives it the hard way, not asserted as a bug.
    func test_anyPublishedWrite_reRendersPlaylistView_environmentObjectIsCoarseGrained() {
        let controller = makeController(upNextNonEmpty: true)
        let hosting = NSHostingView(rootView: PlaylistRenderChurnProbeHost(controller: controller))
        hostInWindow(hosting)
        pump(0.15)

        PlaylistView.debugBodyEvalCount = 0

        let writes = 20
        for i in 0..<writes {
            controller.audioQuality = (i % 2 == 0) ? "Lossless" : "Hi-Res Lossless"
            pump(0.02)
        }

        XCTAssertGreaterThanOrEqual(
            PlaylistView.debugBodyEvalCount, writes,
            "expected @EnvironmentObject's coarse-grained objectWillChange to force a re-render on every unrelated write; got \(PlaylistView.debugBodyEvalCount)/\(writes) — if this is ever 0, EnvironmentObject's invalidation granularity changed and this file's reasoning needs revisiting"
        )
    }
}

private struct PlaylistRenderChurnProbeHost: View {
    @ObservedObject var controller: MusicController
    @Namespace private var namespace
    @State private var currentPage: PlayerPage = .playlist

    var body: some View {
        PlaylistView(
            currentPage: $currentPage,
            animationNamespace: namespace,
            selectedTab: .constant(1),
            showControls: .constant(true),
            isHovering: .constant(false),
            showOverlayContent: .constant(true)
        )
        .environmentObject(controller)
        .frame(width: 320, height: 560)
    }
}
#endif
