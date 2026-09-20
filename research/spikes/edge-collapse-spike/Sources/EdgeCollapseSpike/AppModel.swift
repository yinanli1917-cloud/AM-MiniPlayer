/**
 * [INPUT]: EdgeCollapseEvent (from gesture/hover/click handlers) + control
 *          window switches (variant/tint/tempo/reduceMotion override/track).
 * [OUTPUT]: EdgeCollapseAppModel — drives EdgePresentation via
 *           EdgeCollapseReducer, runs the four transition choreographies
 *           (collapsing/floatingOut/floatingRetract/expanding) off
 *           EdgeCollapseClockScheduler + EdgeCollapseTokens, and publishes
 *           every value the views read.
 * [POS]: Standalone spike app layer (NOT app-portable — this is the demo
 *        harness wiring the portable pieces together for one screen).
 * [PROTOCOL]: Every transition's timing MUST come from EdgeCollapseTokens/
 *             EdgeCollapseClockScheduler, never a hand-typed number here.
 */

import AppKit
import SwiftUI
import QuartzCore

public enum SpikeVariant: String, CaseIterable, Identifiable {
    case h = "Horizontal (H)"
    case v = "Vertical (V)"
    public var id: String { rawValue }
}

public enum SpikeTint: String, CaseIterable, Identifiable {
    case gradient = "Gradient"
    case black = "Black"
    public var id: String { rawValue }
}

/// Where the shared hero artwork currently lives — drives which of
/// CardView/pill-overlay/FloatingBodiesView mounts the matchedGeometryEffect
/// source (design §5/§8: "matchedGeometryEffect 单一 Namespace").
public enum HeroLocation: Equatable {
    case page
    case pill
    case floatingBody
}

@MainActor
public final class EdgeCollapseAppModel: ObservableObject {

    // MARK: - State machine

    @Published public private(set) var presentation: EdgePresentation = .card

    // MARK: - Shape (CollapseShape.animatableData channels)

    @Published var shape = CollapseShapeTrajectory.collapsing[0].geometry

    // MARK: - Hero

    @Published var heroLocation: HeroLocation = .page

    // MARK: - Material

    @Published var blackOverlayOpacity: Double = 0

    // MARK: - Page content (fade + 8pt shift toward the edge, design §7.1 t=0)

    @Published var pageContentOpacity: Double = 1
    @Published var pageContentShift: CGFloat = 0

    // MARK: - Goo canvas (metaball bridge — mounted only in the documented windows)

    @Published var gooMounted = false

    // MARK: - Floating two-body choreography (design §6/§7.2)

    /// 0 = merged with the info body (no visible neck), grows toward
    /// `EdgeCollapseTokens.floatingBodyEdgeGap`-scaled separation as the
    /// control body pinches off.
    @Published var floatingSeparation: CGFloat = 0
    /// Distance of the floating bodies from the edge; animates in from 0.
    @Published var floatingBodyOffset: CGFloat = 0
    @Published var artworkDotOpacity: Double = 0
    @Published var floatingControlsOpacity: Double = 0
    @Published var floatingOvershootScale: CGFloat = 1

    // MARK: - Control-window switches (design §10 items 4/6, top-level task §3)

    @Published public var variant: SpikeVariant = .h
    @Published public var tint: SpikeTint = .gradient
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

    /// Fake progress fill for the tucked stalk (design §5: "窄杆 = 进度填充").
    /// No real player is wired into this spike — just a slow sawtooth so the
    /// tucked/floating views have something to show.
    @Published var fakeProgress: Double = 0.35

    // MARK: - Window wiring

    weak var panel: EdgeCollapsePanel?

    private var generation = 0
    private let t0Ref = CACurrentMediaTime()
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

    // MARK: - Event entry point

    public func send(_ event: EdgeCollapseEvent) {
        let previous = presentation
        let next = EdgeCollapseReducer.reduce(state: previous, event: event)
        guard next != previous else { return }
        presentation = next
        handleEnter(next, previous: previous)
    }

    /// External convenience so the control window's buttons and the panel's
    /// gesture/hover/click handlers share one call path.
    public func requestCollapse(edge: EdgeCollapseEdge = .right) { send(.collapseRequested(edge)) }
    public func requestHoverEnter() { send(.hoverEntered) }
    public func requestHoverExit() { send(.hoverExited) }
    public func requestExpand() { send(.expandRequested) }

    public func toggleIsPlaying() { isPlaying.toggle() }

    public func nextTrack() { trackIndex = (trackIndex + 1) % tracks.count }

    private func handleEnter(_ state: EdgePresentation, previous: EdgePresentation) {
        switch state {
        case .collapsing:
            runCollapsing()
        case .expanding:
            runExpanding()
        case .floating:
            if previous == .tucked { runFloatingOut() }
        case .tucked:
            if previous == .floating { runFloatingRetract() }
            // previous == .collapsing already finished its own frame snap.
        case .card:
            break
        }
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    private func schedule(after delay: TimeInterval, generation myGeneration: Int, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self else { return }
            guard EdgeCollapseClockScheduler.shouldApply(generation: myGeneration, current: self.generation) else { return }
            work()
        }
    }

    private func dampingFraction(bounce: Double) -> Double {
        // SwiftUI's `.spring(response:dampingFraction:)` and the design doc's
        // "bounce" both describe the same spring family; dampingFraction =
        // 1 - bounce is the standard SwiftUI-documented conversion.
        max(0.05, 1 - bounce)
    }

    // MARK: - Collapsing (design §7.1)

    private func runCollapsing() {
        let myGen = nextGeneration()
        let t0 = CACurrentMediaTime()
        let plan = EdgeCollapseClockScheduler.plan(kind: .collapsing, reduceMotion: reduceMotion, tempo: tempo)

        // Keep the larger (card) frame for the whole transition; shrink only
        // at the very end (design §3 "Frame changes ONLY at settled boundaries").
        if let panel {
            panel.setPresentationFrame(panel.frame(forContentSize: EdgeCollapseTokens.cardSize), animated: false)
            EdgeCollapseLog.frame(panel.frame, state: .collapsing)
        }

        if reduceMotion {
            withAnimation(.linear(duration: plan.material.duration)) {
                blackOverlayOpacity = 1
                pageContentOpacity = 0
                heroLocation = .pill
            }
            schedule(after: plan.totalDuration, generation: myGen) { [weak self] in self?.finishCollapsing() }
            return
        }

        let t = EdgeCollapseTokens.self
        func s(_ d: TimeInterval) -> TimeInterval { t.scaled(d, tempo: tempo) }

        EdgeCollapseLog.clock(t0: t0, state: .collapsing, clock: "geometry", event: "start")
        withAnimation(.easeOut(duration: s(t.collapseContentFadeShiftDuration))) {
            pageContentOpacity = 0
            pageContentShift = t.collapseContentShiftDistance
        }
        withAnimation(.easeIn(duration: plan.material.duration)) {
            blackOverlayOpacity = 1
        }
        EdgeCollapseLog.clock(t0: t0, state: .collapsing, clock: "material", event: "start")

        // 0–80ms: height collapses first.
        withAnimation(.spring(response: s(t.collapseHeightSpringResponse), dampingFraction: dampingFraction(bounce: t.collapseHeightSpringBounce))) {
            shape = CollapseShapeGeometry(width: t.cardSize.width, height: 60, cornerRadius: t.cardCornerRadius, neckWidth: 0)
        }

        // 80ms: hero detaches and flies to the pill slot (spring 0.32/0.35, LAST to settle).
        schedule(after: s(t.collapseHeroStart), generation: myGen) { [weak self] in
            guard let self else { return }
            EdgeCollapseLog.clock(t0: t0, state: .collapsing, clock: "hero", event: "start")
            withAnimation(.spring(response: s(t.heroSpringResponse), dampingFraction: self.dampingFraction(bounce: t.heroSpringBounce))) {
                self.heroLocation = .pill
            }
        }

        // 80–160ms: width snaps into a tall thin stalk.
        schedule(after: s(t.collapseWidthPhaseStart), generation: myGen) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: s(t.collapseWidthSpringResponse), dampingFraction: self.dampingFraction(bounce: t.collapseWidthSpringBounce))) {
                self.shape = CollapseShapeGeometry(width: 20, height: 180, cornerRadius: 10, neckWidth: 0)
            }
        }

        // 160–200ms: stalk shortens onto the pill, brief neck, overshoot 6%.
        schedule(after: s(t.collapseStalkPhaseStart), generation: myGen) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: s(t.collapseNeckSpringResponse), dampingFraction: self.dampingFraction(bounce: t.collapseNeckSpringBounce))) {
                self.shape = CollapseShapeGeometry(width: 26 * (1 + t.collapsePillOvershoot), height: 124, cornerRadius: 13, neckWidth: 10)
            }
        }
        schedule(after: s(t.collapseStalkPhaseEnd), generation: myGen) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: s(t.collapseNeckSpringResponse), dampingFraction: 1.0)) {
                self.shape = CollapseShapeGeometry(width: 28, height: 120, cornerRadius: 14, neckWidth: 0)
            }
        }

        // 200–320ms: pill hugs the edge (trailing alignment does the "translate"
        // for us — see CollapseShapeOverlay), metaball bridge mounted for continuity.
        schedule(after: plan.goo!.start, generation: myGen) { [weak self] in
            guard let self else { return }
            EdgeCollapseLog.clock(t0: t0, state: .collapsing, clock: "goo", event: "start")
            self.gooMounted = true
        }
        schedule(after: plan.goo!.settle, generation: myGen) {
            EdgeCollapseLog.clock(t0: t0, state: .collapsing, clock: "goo", event: "settle")
        }

        schedule(after: plan.hero!.settle, generation: myGen) {
            EdgeCollapseLog.clock(t0: t0, state: .collapsing, clock: "hero", event: "settle")
        }
        schedule(after: plan.geometry.settle, generation: myGen) {
            EdgeCollapseLog.clock(t0: t0, state: .collapsing, clock: "geometry", event: "settle")
        }

        schedule(after: plan.totalDuration, generation: myGen) { [weak self] in self?.finishCollapsing() }
    }

    private func finishCollapsing() {
        gooMounted = false
        if let panel {
            panel.setPresentationFrame(panel.frame(forContentSize: EdgeCollapseTokens.tuckedWindowSize), animated: false)
            EdgeCollapseLog.frame(panel.frame, state: .tucked)
        }
        send(.settled)
    }

    // MARK: - Floating out (design §7.2)

    private func runFloatingOut() {
        let myGen = nextGeneration()
        let t0 = CACurrentMediaTime()
        let plan = EdgeCollapseClockScheduler.plan(kind: .floatingOut, reduceMotion: reduceMotion, tempo: tempo)

        // Floating window is larger than tucked — expand FIRST (design §7.2 t=0).
        if let panel {
            let size = variant == .h ? EdgeCollapseTokens.floatingWindowSizeH : EdgeCollapseTokens.floatingWindowSizeV
            panel.setPresentationFrame(panel.frame(forContentSize: size), animated: false)
            EdgeCollapseLog.frame(panel.frame, state: .floating)
        }

        if reduceMotion {
            withAnimation(.linear(duration: plan.material.duration)) {
                floatingBodyOffset = EdgeCollapseTokens.floatingBodyEdgeGap
                floatingSeparation = 8
                artworkDotOpacity = 1
                floatingControlsOpacity = 1
            }
            return
        }

        let t = EdgeCollapseTokens.self
        func s(_ d: TimeInterval) -> TimeInterval { t.scaled(d, tempo: tempo) }

        gooMounted = true
        EdgeCollapseLog.clock(t0: t0, state: .floating, clock: "goo", event: "start")

        // 0–120ms: pill floats out with a neck, thinnest at 90ms, breaks at 120ms.
        withAnimation(.easeOut(duration: s(t.floatingNeckBreak))) {
            floatingBodyOffset = EdgeCollapseTokens.floatingBodyEdgeGap * 0.7
            floatingSeparation = 2
        }
        schedule(after: s(t.floatingArtworkFadeStart), generation: myGen) { [weak self] in
            withAnimation(.easeIn(duration: 0.08)) { self?.artworkDotOpacity = 1 }
        }
        schedule(after: s(t.floatingNeckBreak), generation: myGen) { [weak self] in
            guard let self else { return }
            EdgeCollapseLog.clock(t0: t0, state: .floating, clock: "goo", event: "settle")
            self.gooMounted = false
        }

        // 120–180ms: settle to 12pt from the edge with 4% overshoot.
        schedule(after: s(t.floatingNeckBreak), generation: myGen) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: s(0.06), dampingFraction: self.dampingFraction(bounce: t.floatingOvershoot))) {
                self.floatingBodyOffset = EdgeCollapseTokens.floatingBodyEdgeGap
                self.floatingSeparation = 8
                self.floatingOvershootScale = 1 + t.floatingOvershoot
            }
            withAnimation(.spring(response: s(0.06), dampingFraction: 1.0).delay(s(0.02))) {
                self.floatingOvershootScale = 1
            }
        }
        schedule(after: s(t.floatingControlsFadeStart), generation: myGen) { [weak self] in
            withAnimation(.easeIn(duration: 0.08)) { self?.floatingControlsOpacity = 1 }
        }
        schedule(after: plan.geometry.settle, generation: myGen) {
            EdgeCollapseLog.clock(t0: t0, state: .floating, clock: "geometry", event: "settle")
        }
    }

    // MARK: - Floating retract (design §7.2, symmetric ~160ms)

    private func runFloatingRetract() {
        let myGen = nextGeneration()
        let t0 = CACurrentMediaTime()
        let plan = EdgeCollapseClockScheduler.plan(kind: .floatingRetract, reduceMotion: reduceMotion, tempo: tempo)

        if reduceMotion {
            withAnimation(.linear(duration: plan.material.duration)) {
                floatingBodyOffset = 0
                floatingSeparation = 0
                artworkDotOpacity = 0
                floatingControlsOpacity = 0
            }
            schedule(after: plan.totalDuration, generation: myGen) { [weak self] in self?.finishFloatingRetract() }
            return
        }

        EdgeCollapseLog.clock(t0: t0, state: .tucked, clock: "goo", event: "start")
        gooMounted = true

        // Control body merges back into the info body first.
        withAnimation(.easeInOut(duration: plan.geometry.duration * 0.4)) {
            floatingSeparation = 0
            floatingControlsOpacity = 0
        }
        // Then the drop retracts into the edge with the neck.
        let t = EdgeCollapseTokens.self
        schedule(after: plan.geometry.duration * 0.4, generation: myGen) { [weak self] in
            guard let self else { return }
            withAnimation(.easeIn(duration: plan.geometry.duration * 0.6)) {
                self.floatingBodyOffset = 0
                self.artworkDotOpacity = 0
            }
        }
        _ = t
        schedule(after: plan.totalDuration, generation: myGen) { [weak self] in self?.finishFloatingRetract() }
    }

    private func finishFloatingRetract() {
        gooMounted = false
        if let panel {
            panel.setPresentationFrame(panel.frame(forContentSize: EdgeCollapseTokens.tuckedWindowSize), animated: false)
            EdgeCollapseLog.frame(panel.frame, state: .tucked)
        }
        // Already `.tucked` (the reducer moved us there on hoverExited) — no `.settled` needed.
    }

    // MARK: - Expanding (design §7.3)

    private func runExpanding() {
        let myGen = nextGeneration()
        let t0 = CACurrentMediaTime()
        let plan = EdgeCollapseClockScheduler.plan(kind: .expanding, reduceMotion: reduceMotion, tempo: tempo)

        // Card frame is larger than both tucked/floating — expand FIRST.
        if let panel {
            panel.setPresentationFrame(panel.frame(forContentSize: EdgeCollapseTokens.cardSize), animated: false)
            EdgeCollapseLog.frame(panel.frame, state: .expanding)
        }
        floatingBodyOffset = 0
        floatingSeparation = 0
        artworkDotOpacity = 0
        floatingControlsOpacity = 0

        if reduceMotion {
            withAnimation(.linear(duration: plan.material.duration)) {
                blackOverlayOpacity = 0
                pageContentOpacity = 1
                pageContentShift = 0
                heroLocation = .page
            }
            schedule(after: plan.totalDuration, generation: myGen) { [weak self] in self?.finishExpanding() }
            return
        }

        let t = EdgeCollapseTokens.self
        func s(_ d: TimeInterval) -> TimeInterval { t.scaled(d, tempo: tempo) }

        EdgeCollapseLog.clock(t0: t0, state: .expanding, clock: "geometry", event: "start")
        EdgeCollapseLog.clock(t0: t0, state: .expanding, clock: "hero", event: "start")
        withAnimation(.spring(response: s(t.heroSpringResponse), dampingFraction: dampingFraction(bounce: t.heroSpringBounce))) {
            heroLocation = .page
        }

        // 0–30ms: bulge into a rounder blob (width overshoot).
        withAnimation(.spring(response: s(0.03), dampingFraction: 0.6)) {
            shape = CollapseShapeGeometry(width: 42, height: 52, cornerRadius: 26, neckWidth: 0)
        }

        // 30–170ms: stretch toward the card rect.
        schedule(after: s(t.expandBulgePhaseEnd), generation: myGen) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: s(t.collapseWidthSpringResponse * 1.3), dampingFraction: 0.85)) {
                self.shape = CollapseShapeGeometry(width: t.cardSize.width, height: t.cardSize.height, cornerRadius: t.cardCornerRadius, neckWidth: 0)
            }
        }

        // Black overlay 1→0 from 90ms.
        schedule(after: plan.material.start, generation: myGen) { [weak self] in
            guard let self else { return }
            EdgeCollapseLog.clock(t0: t0, state: .expanding, clock: "material", event: "start")
            withAnimation(.easeOut(duration: plan.material.duration)) {
                self.blackOverlayOpacity = 0
            }
        }

        // 170–260ms: card settles (3% overshoot folded into the spring above);
        // page content fades in from 200ms; hero lands ~300ms.
        schedule(after: s(t.expandContentFadeStart), generation: myGen) { [weak self] in
            guard let self else { return }
            withAnimation(.easeIn(duration: s(0.1))) {
                self.pageContentOpacity = 1
                self.pageContentShift = 0
            }
        }
        schedule(after: plan.hero!.settle, generation: myGen) {
            EdgeCollapseLog.clock(t0: t0, state: .expanding, clock: "hero", event: "settle")
        }
        schedule(after: plan.geometry.settle, generation: myGen) {
            EdgeCollapseLog.clock(t0: t0, state: .expanding, clock: "geometry", event: "settle")
        }

        schedule(after: plan.totalDuration, generation: myGen) { [weak self] in self?.finishExpanding() }
    }

    private func finishExpanding() {
        if let panel {
            EdgeCollapseLog.frame(panel.frame, state: .card)
        }
        send(.settled)
    }
}
