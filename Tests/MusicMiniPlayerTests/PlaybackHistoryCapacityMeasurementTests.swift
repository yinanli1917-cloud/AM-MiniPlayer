/**
 * [INPUT]: MusicController (preview + DEBUG seed), PlaylistView, SwiftUI/AppKit hosting
 * [OUTPUT]: NOT assertions about a "correct" number — real wall-clock
 *           measurements of PlaylistView body-eval+layout cost at History
 *           row counts 50/100/200/300, printed via XCTContext for the
 *           2026-09-25 capacity decision (research/diagnosis-2026-09-25-history.md §3).
 *           Every row's artwork is PRE-CACHED (musicController.artworkCache)
 *           so `.task`'s free memory-only tier always hits — zero network,
 *           zero ScriptingBridge calls, regardless of row count (see the
 *           09-15 SB-scan-storm and iTunes-rate-limit postmortems this file
 *           deliberately stays clear of).
 * [POS]: Test module (2026-09-25 diagnosis phase-2 capacity step). Uses the
 *        SAME NSWindow-hosting idiom as PlaylistViewRenderChurnTests — a
 *        detached NSHostingView never reproduces real SwiftUI/AppKit
 *        invalidation+layout behavior (banned-patterns.md).
 * [PROTOCOL]: Changes here → update this header, then check root CLAUDE.md
 */

import XCTest
import SwiftUI
@testable import MusicMiniPlayerCore

#if DEBUG
@MainActor
final class PlaybackHistoryCapacityMeasurementTests: XCTestCase {

    private var hostWindow: NSWindow?

    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

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

    private func makeController(historyCount: Int) -> MusicController {
        let controller = MusicController(preview: true)
        var entries: [PlaybackHistoryEntry] = []
        entries.reserveCapacity(historyCount)
        let tinyImage = NSImage(size: NSSize(width: 4, height: 4))
        for i in 0..<historyCount {
            let pid = "CAPACITY-TEST-\(i)"
            entries.append(PlaybackHistoryEntry(
                persistentID: pid, title: "Song \(i)", artist: "Artist \(i % 37)", album: "Album \(i % 11)",
                duration: 180 + Double(i % 60), sourceKind: .library,
                startedAt: Date(timeIntervalSince1970: Double(1_000_000 - i))
            ))
            // Pre-cache every row's artwork on the FREE memory-only tier
            // (`loadArtwork()`'s first check) so its `.task` never reaches
            // the ScriptingBridge or network tiers — zero I/O regardless of
            // row count, exactly what "first display" looks like for a
            // founder whose library artwork is already warm (real Application
            // Support ArtworkCache had ~98 entries as of the phase-1 diagnosis).
            controller.artworkCache.setObject(tinyImage, forKey: pid as NSString, cost: 64)
        }
        controller.debugSeedPlaybackHistoryForTesting(entries)
        controller.upNextTracks = []
        controller.recentTracks = []
        controller.queueProvenance = .playlistContextOnly(playlistName: "Test Playlist")
        return controller
    }

    /// Average wall-clock cost of one forced PlaylistView.body re-evaluation
    /// (triggered by an unrelated @Published write, same technique
    /// PlaylistViewRenderChurnTests already established) + whatever layout
    /// pass follows it, with the Playlist page VISIBLE (so History actually
    /// renders its rows, not the empty-state text) at `historyCount` rows.
    private func measureAverageBodyEvalCost(historyCount: Int, writes: Int = 40) -> TimeInterval {
        let controller = makeController(historyCount: historyCount)
        let hosting = NSHostingView(rootView: CapacityProbeHost(controller: controller))
        hostInWindow(hosting)
        pump(0.3) // let the initial mount + layout fully settle before timing

        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<writes {
            controller.audioQuality = (i % 2 == 0) ? "Lossless" : "Hi-Res Lossless"
            pump(0.01)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return elapsed / Double(writes)
    }

    /// Not a pass/fail assertion on a specific number — this IS the
    /// measurement the capacity decision is based on. Prints each row
    /// count's average cost so the numbers land in the swift test log
    /// verbatim (see the phase-2 report for the actual figures + the
    /// capacity chosen from them). Still asserts the qualitative claim any
    /// capacity decision needs to be safe: cost must not blow up
    /// super-linearly between 50 and 300 rows.
    func test_measureAndReport_bodyEvalCost_at50_100_200_300Rows() {
        let counts = [50, 100, 200, 300]
        var costs: [Int: TimeInterval] = [:]
        for count in counts {
            costs[count] = measureAverageBodyEvalCost(historyCount: count)
        }

        for count in counts {
            let ms = (costs[count] ?? 0) * 1000
            // Deliberately printed (not just asserted) — this is the number
            // research/diagnosis-2026-09-25-history.md §3 and the phase-2
            // report quote for the capacity decision.
            print("CAPACITY_MEASUREMENT rows=\(count) avgBodyEvalCostMs=\(String(format: "%.3f", ms))")
        }

        guard let cost50 = costs[50], let cost300 = costs[300], cost50 > 0 else {
            return XCTFail("measurement produced a zero or missing baseline — cannot judge scaling")
        }
        let ratio = cost300 / cost50
        XCTAssertLessThan(
            ratio, 20,
            "300 rows costs \(String(format: "%.1f", ratio))x what 50 rows costs per re-render — a 6x row-count increase producing a 20x+ cost increase would mean something is scaling worse than linearly and capacity must NOT simply be raised without also addressing that"
        )
    }
}

private struct CapacityProbeHost: View {
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
