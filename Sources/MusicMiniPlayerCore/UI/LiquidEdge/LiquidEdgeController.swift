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
 *     back in at alpha 0 so a click to expand finds it ready.
 */

import AppKit
import SwiftUI
import Combine
import QuartzCore

@MainActor
public final class LiquidEdgeController {
    public static let autoPeekDefaultsKey = "liquidEdgeShowSongOnTrackChange"

    public private(set) var state: LiquidEdgeState = .card
    public var isActive: Bool { state != .card }
    var isAnimating: Bool { motion != nil }

    private weak var card: SnappablePanel?
    private(set) var stageWindow: LiquidEdgeStageWindow?
    private var stage: LiquidEdgeStageView?
    private var side: LiquidEdgeSide = .right
    private(set) var geometry = LiquidEdgeGeometry.reference
    /// The card's rect in stage coordinates as it is on screen (not mirrored).
    private var cardInStage = CGRect.zero
    /// The panel window's whole frame in stage coordinates (its content
    /// view, which the mask lives on, spans all of it).
    private var windowInStage = CGRect.zero

    private var pose = LiquidEdgePoses(.reference).pose(.card)
    private var motion: LiquidEdgeMotion?
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

    private var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var poses: LiquidEdgePoses { LiquidEdgePoses(geometry) }

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
        motion = nil
        pendingSettle = nil
        dwellWork?.cancel(); peekWork?.cancel()
        state = .card
        restorePanel()
        stageWindow?.orderOut(nil)
    }

    // MARK: - Stage

    /// The panel as drawn, in screen coordinates. The panel window is
    /// titled with full-size content, and the panel draws only inside its
    /// content view's safe area (below the 32pt title bar; MiniPlayerView
    /// clips to that rect), so the window frame is taller than the panel
    /// (founder recording 2026-09-23: the liquid expanded 32pt too tall).
    static func drawnPanelFrame(_ card: NSWindow) -> CGRect {
        guard let content = card.contentView else { return card.frame }
        let rect = card.convertToScreen(content.convert(content.safeAreaRect, to: nil))
        return rect.width > 0 && rect.height > 0 ? rect : card.frame
    }

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

        // The panel window: on-window whenever it may be shown next.
        switch next {
        case .expanding: prewarmPanel()
        case .tucked where from == .floating: parkPanel()
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
        stage?.apply(p)
        applyPanel(p)
    }

    /// At rest: park or restore the panel window to match the state.
    private func finishIfResting() {
        switch state {
        case .card:
            restorePanel()
            stageWindow?.orderOut(nil)
        case .tucked: parkPanel()
        case .floating: prewarmPanel()
        default: break
        }
    }

    // MARK: - Frame loop

    private func startLink() {
        guard drivesFrames else { return }
        if let link { link.isPaused = false; return }
        guard let screen = card?.screen ?? NSScreen.main else { return }
        let l = screen.displayLink(target: self, selector: #selector(frame(_:)))
        let maxRate = Float(screen.maximumFramesPerSecond)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maxRate), maximum: maxRate, preferred: maxRate)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() { link?.isPaused = true }

    @objc private func frame(_ l: CADisplayLink) { tick(at: l.targetTimestamp) }

    func tick(at when: CFTimeInterval) {
        guard let motion else { stopLink(); return }
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
        }
    }
}
