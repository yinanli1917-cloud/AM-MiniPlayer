/**
 * [INPUT]: EdgeCollapseEvent (from gesture/hover/click handlers) + control
 *          window switches (variant/tint/bounce/tempo/reduceMotion override/
 *          track/isPlaying).
 * [OUTPUT]: EdgeCollapseAppModel — drives EdgePresentation via
 *           EdgeCollapseReducer; every transition is exactly ONE
 *           `withAnimation` (top-level task instruction #2), settle detected
 *           via `.animation(_:completionCriteria:)`; publishes the values
 *           RootContentView reads (variant/tint/bounce/tempo/track/
 *           isPlaying/reduceMotionFlashOpacity/fakeProgress).
 * [POS]: Standalone spike app layer (NOT app-portable — this is the demo
 *        harness wiring the portable pieces together for one screen).
 * [PROTOCOL]: `performTransition` is the ONLY place that calls `withAnimation`
 *             for a presentation change — never add a second staggered
 *             `withAnimation`/`asyncAfter` relay elsewhere (that's exactly
 *             what AUDIT-2026-09-20.md §3 flagged in v1).
 */

import AppKit
import SwiftUI
import QuartzCore

@MainActor
public final class EdgeCollapseAppModel: ObservableObject {

    // MARK: - State machine (single source of truth for layout)

    @Published public private(set) var presentation: EdgePresentation = .card

    // MARK: - Reduce Motion crossfade overlay (top-level task instruction #5)

    @Published var reduceMotionFlashOpacity: Double = 0

    // MARK: - Fake progress fill for the tucked stalk (design §5)

    @Published var fakeProgress: Double = 0.35

    // MARK: - Control-window switches (top-level task instructions #1/#2/#6)

    @Published public var variant: EdgeCollapseVariant = .h
    @Published public var tint: EdgeCollapseTint = .gradient
    @Published public var bounce: EdgeCollapseBounce = .settle
    @Published public var tempo: EdgeCollapseTempo = .normal
    @Published public var reduceMotionOverride: Bool?
    @Published public var isPlaying = true
    @Published public var trackIndex = 0

    public let tracks = [
        "Blinding Lights",
        "三個人的晚餐",
        "Everything Everywhere All at Once (Original Motion Picture Soundtrack)",
    ]

    public var trackTitle: String { tracks[trackIndex % tracks.count] }

    var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Wiring back to the hosting view (hover hit-region refresh)

    weak var hostingView: EdgeGestureHostingView<RootContentView>?

    private var progressTimer: Timer?

    public init() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isPlaying else { return }
                self.fakeProgress = (self.fakeProgress + 0.01).truncatingRemainder(dividingBy: 1.0)
            }
        }
    }

    // MARK: - Public entry points (panel gesture/hover/click + control window buttons)

    public func requestCollapse(edge: EdgeCollapseEdge = .right) {
        guard presentation == .card else { return }
        performTransition(
            event: .collapseRequested(edge),
            settleEvent: .settled,
            animation: EdgeCollapseTokens.collapseAnimation(bounce: bounce, tempo: tempo),
            label: "collapse"
        )
    }

    public func requestHoverEnter() {
        guard presentation == .tucked else { return }
        performTransition(
            event: .hoverEntered,
            settleEvent: nil,
            animation: EdgeCollapseTokens.floatingOutAnimation(tempo: tempo),
            label: "floatingOut"
        )
    }

    public func requestHoverExit() {
        guard presentation == .floating else { return }
        performTransition(
            event: .hoverExited,
            settleEvent: nil,
            animation: EdgeCollapseTokens.floatingRetractAnimation(tempo: tempo),
            label: "floatingRetract"
        )
    }

    public func requestExpand() {
        guard presentation == .tucked || presentation == .floating else { return }
        performTransition(
            event: .expandRequested,
            settleEvent: .settled,
            animation: EdgeCollapseTokens.expandAnimation(tempo: tempo),
            label: "expand"
        )
    }

    public func toggleIsPlaying() { isPlaying.toggle() }

    public func nextTrack() {
        trackIndex = (trackIndex + 1) % tracks.count
        hostingView?.refreshHitRegion()
    }

    /// The active hover/click hit-region in the panel's fixed 320×360 local
    /// coordinate space, for `EdgeGestureHostingView`'s `NSTrackingArea` +
    /// `hitTest` (top-level task instruction #3). `.card` uses the card's
    /// own rect (no extra padding — the card fills most of the window
    /// already); `.tucked`/`.floating` use `EdgeCollapseLayout.hoverRegion`
    /// with their documented expand paddings. `EdgeCollapseLayout.rects`
    /// already normalizes `collapsing`→tucked / `expanding`→card, so this
    /// needs no extra switch over the 5-case state machine.
    func activeHitRegion() -> CGRect {
        let titleWidth = EdgeCollapseLayout.estimatedTitleWidth(trackTitle)
        switch EdgeCollapseLayout.visualLayout(for: presentation) {
        case .card:
            return EdgeCollapseLayout.rects(for: presentation, variant: variant, titleWidth: titleWidth).body
        case .tucked:
            return EdgeCollapseLayout.hoverRegion(for: presentation, variant: variant, titleWidth: titleWidth, expand: EdgeCollapseTokens.tuckedHoverExpand)
        case .floating:
            return EdgeCollapseLayout.hoverRegion(for: presentation, variant: variant, titleWidth: titleWidth, expand: EdgeCollapseTokens.floatingHoverExitExpand)
        }
    }

    // MARK: - Event entry point (reducer only — no animation here)

    private func send(_ event: EdgeCollapseEvent) {
        let previous = presentation
        let next = EdgeCollapseReducer.reduce(state: previous, event: event)
        guard next != previous else { return }
        presentation = next
    }

    // MARK: - The ONE transition driver (top-level task instruction #2)

    /// Every transition is exactly one `withAnimation(animation) { presentation
    /// = next }`. Settling is detected via `.logicallyComplete` completion
    /// criteria (macOS 14+), which then fires `settleEvent` (if any) to move
    /// the reducer's `collapsing`/`expanding` bookkeeping state to its
    /// resting `tucked`/`card` state — this second `send` is NOT itself
    /// wrapped in a new `withAnimation` and produces no visible change,
    /// because `EdgeCollapseLayout.visualLayout(for:)` already maps
    /// `collapsing`→`tucked` and `expanding`→`card`, so the single animated
    /// move already reached the correct visual target.
    private func performTransition(
        event: EdgeCollapseEvent,
        settleEvent: EdgeCollapseEvent?,
        animation: Animation,
        label: String
    ) {
        let from = presentation
        guard EdgeCollapseReducer.reduce(state: from, event: event) != from else { return }
        let t0 = CACurrentMediaTime()

        if reduceMotion {
            // Instant geometry snap under a Transaction with animations
            // disabled, cross-faded by a 180ms linear opacity flash — top-
            // level task instruction #5's "simplest correct thing".
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                send(event)
                if let settleEvent { send(settleEvent) }
            }
            hostingView?.refreshHitRegion()
            EdgeCollapseLog.event(t0: t0, from: from, to: presentation, anim: "\(label)-reduceMotion", event: "start")
            reduceMotionFlashOpacity = 1
            withAnimation(EdgeCollapseTokens.reduceMotionAnimation(tempo: tempo)) {
                reduceMotionFlashOpacity = 0
            }
            EdgeCollapseLog.event(t0: t0, from: from, to: presentation, anim: "\(label)-reduceMotion", event: "settle")
            return
        }

        let target = EdgeCollapseReducer.reduce(state: from, event: event)
        EdgeCollapseLog.event(t0: t0, from: from, to: target, anim: label, event: "start")
        if let hostingView {
            EdgeCollapseProbe.record(view: hostingView, label: label)
        }

        withAnimation(animation, completionCriteria: .logicallyComplete) {
            send(event)
        } completion: { [weak self] in
            guard let self else { return }
            let mid = self.presentation
            if let settleEvent { self.send(settleEvent) }
            EdgeCollapseLog.event(t0: t0, from: mid, to: self.presentation, anim: label, event: "settle")
        }
        hostingView?.refreshHitRegion()
    }
}
