/**
 * [INPUT]: The panel window (SnappablePanel), its screen, the user's input
 *          (swipe, hover, click, shortcut), MusicController.shared.
 * [OUTPUT]: LiquidEdgeController — tucks the real panel into a screen edge as
 *           one liquid object and brings it back: state machine, per-frame
 *           spring motion, the stage window under the panel, and the panel
 *           window's alpha + content mask.
 * [POS]: Liquid edge (ported from research/spikes/edge-collapse-spike,
 *        founder-approved 2026-09-22). Replaces the window-sliding edge hide
 *        when installed as SnappablePanel.liquidEdgeHandler.
 * [PROTOCOL]:
 *   - The panel stays in its own window, never moved or scaled; per frame
 *     only the window's alpha and a CAShapeLayer mask on its content change,
 *     so the liquid growing IS the panel appearing (no migration, no
 *     snapshot).
 *   - Motion is sampled at the display link's targetTimestamp (the frame's
 *     display time): sampling at callback time hid missed deadlines in the
 *     prototype.
 *   - While tucked the panel window is ordered out and the panel is marked
 *     occluded (its per-frame work stops: the prototype measured 4-6ms per
 *     frame for a hidden live panel); while the capsule rests it is ordered
 *     back in at alpha 0 so a click to expand finds it ready (in the turn
 *     after the last frame, not inside it).
 *   - A motion holds EdgeMotionGate from its first frame to its settle:
 *     main-thread work nobody can see meanwhile defers through it. Every
 *     frame's deadline is accounted by EdgeHitchTrace (zero cost at rest).
 *   - Per frame the stage's layers and the panel's mask commit together,
 *     once.
 */

import AppKit
import SwiftUI
import Combine
import QuartzCore

@MainActor
public final class LiquidEdgeController {
    public static let autoPeekDefaultsKey = "liquidEdgeShowSongOnTrackChange"

    public private(set) var state: LiquidEdgeState = .card {
        didSet {
            guard oldValue != state else { return }
            stateSubject.send(state)
        }
    }
    public var isActive: Bool { state != .card }
    /// Onboarding tour hook (§6 "贴边状态"): every `state` change, current
    /// value first (`CurrentValueSubject`) so a subscriber that attaches
    /// mid-collapse still sees where things stand.
    private let stateSubject = CurrentValueSubject<LiquidEdgeState, Never>(.card)
    public var statePublisher: AnyPublisher<LiquidEdgeState, Never> { stateSubject.eraseToAnyPublisher() }
    var isAnimating: Bool { motion != nil }

    private weak var card: SnappablePanel?
    private(set) var stageWindow: LiquidEdgeStageWindow?
    private var stage: LiquidEdgeStageView?
    /// Onboarding tour hook: which screen edge the sliver/capsule is
    /// currently on — read alongside `tuckedRegionInScreen`/
    /// `floatingHitRegionInScreen` to mirror the S6 card/halo correctly.
    public private(set) var side: LiquidEdgeSide = .right
    private(set) var geometry = LiquidEdgeGeometry.reference
    /// The card's rect in stage coordinates as it is on screen (not mirrored).
    private var cardInStage = CGRect.zero
    /// The panel window's whole frame in stage coordinates (its content
    /// view, which the mask lives on, spans all of it).
    private var windowInStage = CGRect.zero

    private var pose = LiquidEdgePoses(.reference).pose(.card)
    private var motion: LiquidEdgeMotion? {
        didSet {
            // One gate hold per motion, however many retargets it takes.
            switch (oldValue == nil, motion == nil) {
            case (true, false): gate.begin(); holdsGate = true
            case (false, true): gate.end(); holdsGate = false
            default: break
            }
        }
    }
    private var holdsGate = false
    private var motionKind = "edge"
    private var motionStart: CFTimeInterval = 0
    private var pendingSettle: LiquidEdgeEvent?
    private var link: CADisplayLink?

    private var swipe: LiquidEdgeSwipe?
    private var hovering = false
    private var dwellWork: DispatchWorkItem?
    private var peeking = false
    private var peekWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    let panelMask = CAShapeLayer()

    /// Tells the app whether the panel is visible (its per-frame work pauses when not).
    public var onPanelOccluded: ((Bool) -> Void)?

    // Test seams: a controllable clock and no display link, so a test steps
    // frames itself (`tick(at:)`).
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    var drivesFrames = true
    var reduceMotionOverride: Bool?
    /// While a motion runs, non-urgent main-thread work waits (EdgeMotionGate)
    /// and every frame's deadline is accounted (EdgeHitchTrace).
    var gate = EdgeMotionGate.shared
    var hitchTrace = EdgeHitchTrace.shared

    public init(card: SnappablePanel) {
        self.card = card
        MusicController.shared.$currentTrackTitle
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.trackChanged() }
            .store(in: &cancellables)
        // A display change moves the edge: put the panel back instead of
        // leaving a sliver where the edge used to be.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reset() }
            .store(in: &cancellables)
    }

    deinit { if holdsGate { EdgeMotionGate.shared.end() } }

    private var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var poses: LiquidEdgePoses { LiquidEdgePoses(geometry) }

    // MARK: - Onboarding tour hooks (§6 "贴边小条"/"面板边")

    /// The tucked sliver's screen rect — `.zero` before the first
    /// `collapse(to:)` has ever run (no stage exists yet to be screen-relative to).
    public var tuckedRegionInScreen: CGRect { toScreen(poses.tuckedRect) }
    /// The floating capsule's padded hit region, screen space — matches
    /// exactly what the stage view itself hit-tests against while `.floating`.
    public var floatingHitRegionInScreen: CGRect { toScreen(poses.hitRegion(for: .floating)) }

    /// Canonical-local (edge always conceptually "right") → screen: un-mirror
    /// for the left edge, then offset by the stage window's own origin (the
    /// stage's canonical space and `card.frame` share the same reference —
    /// see `prepareStage`).
    private func toScreen(_ r: CGRect) -> CGRect {
        guard let stageWindow else { return .zero }
        var out = r
        if side == .left, let w = stage?.bounds.width { out.origin.x = w - out.maxX }
        return out.offsetBy(dx: stageWindow.frame.origin.x, dy: stageWindow.frame.origin.y)
    }

    // MARK: - Entry points

    /// Tuck the panel into `edge`. Returns false if it cannot (then the
    /// caller falls back to its old behaviour).
    @discardableResult
    public func collapse(to edge: SnappablePanel.Edge) -> Bool {
        guard state == .card, let card, card.isVisible, edge != .none,
              let screen = card.screen ?? NSScreen.main else { return false }
        side = edge == .left ? .left : .right
        prepareStage(card: card, screen: screen)
        card.hasShadow = false
        installPanelMask(on: card)
        pose = poses.pose(.card)
        transition(.collapseRequested, settle: .settled, kind: .collapse)
        return true
    }

    public func expand() {
        guard state == .tucked || state == .floating else { return }
        transition(.expandRequested, settle: .settled, kind: .expand)
    }

    /// Put everything back to a normal visible panel at once (the app is
    /// hiding or showing the window some other way).
    public func reset() {
        guard state != .card else { return }
        stopLink()
        hitchTrace.end()
        motion = nil
        pendingSettle = nil
        dwellWork?.cancel(); peekWork?.cancel()
        state = .card
        restorePanel()
        stageWindow?.orderOut(nil)
    }

    // MARK: - Stage

    /// The panel as drawn, in screen coordinates: the window itself. The
    /// panel window is exactly the panel (PanelWindowMetrics, founder
    /// 2026-09-23). Not the content view's safe area: the hidden title bar
    /// still reports a 32pt AppKit safe area that the panel draws under, so
    /// deriving from it landed the liquid 32pt short.
    static func drawnPanelFrame(_ card: NSWindow) -> CGRect { card.frame }

    private func prepareStage(card: SnappablePanel, screen: NSScreen) {
        let visible = screen.visibleFrame
        let f = Self.drawnPanelFrame(card)
        let m = LiquidEdgeTokens.stageMargin
        // The screen edge the liquid joins.
        let edgeScreenX = side == .right ? max(visible.maxX, f.maxX) : min(visible.minX, f.minX)
        var s = CGRect(x: 0, y: f.minY - m, width: 0, height: f.height + 2 * m)
        if side == .right {
            s.origin.x = f.minX - m
            s.size.width = edgeScreenX - s.minX
        } else {
            s.origin.x = edgeScreenX
            s.size.width = f.maxX + m - s.minX
        }

        let window = stageWindow ?? LiquidEdgeStageWindow()
        let view = stage ?? LiquidEdgeStageView(frame: .zero)
        if stage == nil {
            view.onHoverChange = { [weak self] in $0 ? self?.hoverEntered() : self?.hoverExited() }
            view.onTap = { [weak self] in self?.expand() }
            view.onSwipe = { [weak self] in self?.handleSwipe($0) }
            view.activeHitRegionProvider = { [weak self] in
                guard let self else { return .zero }
                return self.state == .card ? .zero : self.poses.hitRegion(for: self.state)
            }
        }
        window.setFrame(s, display: false)
        window.contentView = view
        window.level = card.level
        window.orderFront(nil)
        window.order(.below, relativeTo: card.windowNumber)
        stageWindow = window
        stage = view

        // Geometry from where the stage actually is, so the liquid's card
        // sits exactly on the panel whatever the window server did.
        let a = window.frame
        cardInStage = CGRect(x: f.minX - a.minX, y: a.maxY - f.maxY, width: f.width, height: f.height)
        let w = card.frame
        windowInStage = CGRect(x: w.minX - a.minX, y: a.maxY - w.maxY, width: w.width, height: w.height)
        let canonicalCard = side == .right ? cardInStage
            : CGRect(x: a.width - cardInStage.maxX, y: cardInStage.minY, width: f.width, height: f.height)
        let edgeInStage = edgeScreenX - a.minX
        geometry = LiquidEdgeGeometry(card: canonicalCard, edgeX: side == .right ? edgeInStage : a.width - edgeInStage)
        view.frame = CGRect(origin: .zero, size: a.size)
        view.side = side
        view.geometry = geometry
    }

    // MARK: - Panel window

    private func installPanelMask(on card: SnappablePanel) {
        guard let content = card.contentView else { return }
        content.wantsLayer = true
        panelMask.frame = content.bounds
        content.layer?.mask = panelMask
    }

    private func applyPanel(_ p: LiquidEdgePose) {
        guard let card, let content = card.contentView else { return }
        let panel = CGFloat(min(max(p.panelOpacity, 0), 1))
        card.alphaValue = panel
        // The liquid's visible part, from canonical to stage to the panel's own
        // coordinates.
        let clip = LiquidEdgeStageView.largerPart(p)
        var r = clip.rect
        if side == .left, let w = stage?.bounds.width { r.origin.x = w - r.maxX }
        r = r.offsetBy(dx: -windowInStage.minX, dy: -windowInStage.minY)
        if !content.isFlipped { r.origin.y = content.bounds.height - r.maxY }
        let corner = min(max(clip.corner, 0), min(r.width, r.height) / 2)
        panelMask.frame = content.bounds
        panelMask.path = CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    private func restorePanel() {
        prewarmPending = false
        guard let card else { return }
        card.contentView?.layer?.mask = nil
        card.alphaValue = 1
        card.ignoresMouseEvents = false
        if !card.isVisible { card.orderFront(nil) }
        card.hasShadow = true
        card.invalidateShadow()
        onPanelOccluded?(false)
    }

    /// Ordered out while tucked (its per-frame work stops).
    private func parkPanel() {
        prewarmPending = false
        guard let card else { return }
        card.orderOut(nil)
        onPanelOccluded?(true)
    }

    /// Back in, invisible and click-through, ready to be revealed.
    private func prewarmPanel() {
        guard let card else { return }
        card.alphaValue = 0
        card.ignoresMouseEvents = true
        if !card.isVisible {
            card.orderFront(nil)
            onPanelOccluded?(false)
        }
    }

    // MARK: - Input

    func hoverEntered() {
        hovering = true
        peeking = false
        peekWork?.cancel()
        guard state == .tucked else { return }
        stage?.setHoverBoost(true)
        dwellWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .tucked, self.hovering else { return }
            self.transition(.hoverEntered, settle: nil, kind: .floatOut)
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LiquidEdgeTokens.hoverDwell, execute: work)
    }

    func hoverExited() {
        hovering = false
        dwellWork?.cancel(); dwellWork = nil
        stage?.setHoverBoost(false)
        guard state == .floating else { return }
        transition(.hoverExited, settle: nil, kind: .retract)
    }

    private func handleSwipe(_ phase: LiquidEdgeStageView.SwipePhase) {
        switch phase {
        case .began: swipe = LiquidEdgeSwipe()
        case .changed(let dx, let dy):
            if swipe == nil { swipe = LiquidEdgeSwipe() }
            if swipe?.add(dx: dx, dy: dy, presentation: state) == .expand { expand() }
        case .ended: swipe = nil
        }
    }

    func trackChanged() {
        let enabled = UserDefaults.standard.object(forKey: Self.autoPeekDefaultsKey) as? Bool ?? true
        guard LiquidEdgeAutoPeek.shouldPeek(presentation: state, enabled: enabled,
                                            playerAlreadyNotifies: false, hovering: hovering) else { return }
        peeking = true
        transition(.hoverEntered, settle: nil, kind: .floatOut)
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.peeking, !self.hovering, self.state == .floating else { return }
            self.peeking = false
            self.transition(.hoverExited, settle: nil, kind: .retract)
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LiquidEdgeAutoPeek.holdSeconds, execute: work)
    }

    // MARK: - Transitions

    private func transition(_ event: LiquidEdgeEvent, settle: LiquidEdgeEvent?, kind: LiquidEdgeTransition) {
        let from = state
        let next = LiquidEdgeReducer.reduce(from, event)
        guard next != from else { return }
        let now = clock()
        motionKind = "\(kind)"
        if drivesFrames, !reduceMotion { beginHitchTrace() }

        // The panel window: on-window whenever it may be shown next.
        switch next {
        case .expanding: EdgeHitchTrace.measure("prewarmPanel") { prewarmPanel() }
        case .tucked where from == .floating: EdgeHitchTrace.measure("parkPanel") { parkPanel() }
        default: break
        }

        if reduceMotion {
            stopLink(); motion = nil
            state = next
            if let settle { state = LiquidEdgeReducer.reduce(state, settle) }
            apply(poses.pose(state.layout))
            finishIfResting()
            stage?.refreshHitRegion()
            return
        }

        let interrupted = motion.map { now - motionStart < $0.nominalDuration } ?? false
        let start: (value: [Double], velocity: [Double])
        if let motion { start = motion.sample(at: now - motionStart) }
        else { start = (pose.vector(), Array(repeating: 0, count: LiquidEdgePose.channelCount)) }
        let stages: [LiquidEdgeMotion.Stage] = interrupted
            ? LiquidEdgeChoreography.direct(to: poses.pose(next.layout).vector())
            : LiquidEdgeChoreography.stages(kind: kind, fromTucked: from == .tucked, geometry: geometry, bouncy: true)
        motion = LiquidEdgeMotion(from: start.value, velocity: start.velocity, stages: stages)
        motionStart = now
        pendingSettle = settle
        state = next
        stage?.refreshHitRegion()
        startLink()
        tick(at: now)
    }

    private func apply(_ p: LiquidEdgePose) {
        pose = p
        // One commit per frame for the stage's layers and the panel's mask together
        // (each used to flush on its own: two render-server round trips a frame, and
        // the liquid and the mask could land a frame apart).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        EdgeHitchTrace.measure("stage.apply") { stage?.apply(p) }
        EdgeHitchTrace.measure("panel.apply") { applyPanel(p) }
        CATransaction.commit()
    }

    /// At rest: park or restore the panel window to match the state.
    private func finishIfResting() {
        switch state {
        case .card:
            EdgeHitchTrace.measure("restorePanel") { restorePanel() }
            stageWindow?.orderOut(nil)
        case .tucked: EdgeHitchTrace.measure("parkPanel") { parkPanel() }
        case .floating:
            if drivesFrames {
                // Ordering the panel in is 8-16ms (its SwiftUI catches up): do it in the turn
                // after the last frame has been committed, not inside it.
                prewarmPending = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.prewarmPending, self.state == .floating, self.motion == nil else { return }
                    self.prewarmPending = false
                    EdgeHitchTrace.measure("prewarmPanel") { self.prewarmPanel() }
                }
            } else {
                EdgeHitchTrace.measure("prewarmPanel") { prewarmPanel() }
            }
        default: break
        }
    }

    /// A deferred `prewarmPanel` is waiting for the turn after the last frame.
    private var prewarmPending = false

    // MARK: - Frame loop

    private func startLink() {
        guard drivesFrames else { return }
        beginHitchTrace()
        if let link { link.isPaused = false; return }
        guard let screen = card?.screen ?? NSScreen.main else { return }
        let l = screen.displayLink(target: self, selector: #selector(frame(_:)))
        let maxRate = Float(screen.maximumFramesPerSecond)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maxRate), maximum: maxRate, preferred: maxRate)
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// Accounts the frames of this motion (a no-op when already tracing).
    private func beginHitchTrace() {
        let screen = card?.screen ?? NSScreen.main
        hitchTrace.begin(motion: motionKind, nominalInterval: 1.0 / Double(max(screen?.maximumFramesPerSecond ?? 60, 1)))
    }

    private func stopLink() { link?.isPaused = true }

    @objc private func frame(_ l: CADisplayLink) {
        hitchTrace.frameBegan(target: l.targetTimestamp, timestamp: l.timestamp)
        let t0 = CACurrentMediaTime()
        tick(at: l.targetTimestamp)
        hitchTrace.frameTicked(cost: CACurrentMediaTime() - t0)
    }

    func tick(at when: CFTimeInterval) {
        guard let motion else { stopLink(); hitchTrace.end(); return }
        let t = when - motionStart
        apply(LiquidEdgePose(vector: motion.sample(at: t).value))
        if let settle = pendingSettle, t >= motion.nominalDuration {
            pendingSettle = nil
            state = LiquidEdgeReducer.reduce(state, settle)
            stage?.refreshHitRegion()
        }
        if t >= motion.settledDuration {
            apply(LiquidEdgePose(vector: motion.to))
            if state == .card { apply(poses.pose(.card)) }
            self.motion = nil
            stopLink()
            finishIfResting()
            // After the resting work, so its cost is accounted to this motion.
            hitchTrace.end()
        }
    }
}
