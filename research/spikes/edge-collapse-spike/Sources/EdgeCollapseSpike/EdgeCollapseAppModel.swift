/**
 * [INPUT]: EdgeCollapseEvent (gesture / hover / click), control-window
 *          switches, MusicController.shared.
 * [OUTPUT]: EdgeCollapseAppModel — drives EdgePresentation via the reducer
 *           and moves `pose` once per display frame by sampling an
 *           EdgeCollapseMotion (pure function of time). No SwiftUI
 *           animations are involved in a transition.
 * [POS]: Standalone spike app layer.
 * [PROTOCOL]: `transition` is the only place a motion starts. A new motion
 *             starts from the current sampled value AND velocity, so hover
 *             in/out mid-flight never jumps. Per-frame samples are buffered
 *             in memory and printed once after the motion ends (no I/O on
 *             the frame path).
 */

import AppKit
import SwiftUI
import QuartzCore
import Combine
import MusicMiniPlayerCore

/// Per-frame pose, in its own observable so only the edge view re-renders
/// each frame (the control window observing the model re-laid-out its whole
/// Form every frame — sampled).
@MainActor
public final class EdgeCollapsePoseStore: ObservableObject {
    @Published public var pose: EdgeCollapsePose
    /// Immediate response when the cursor touches the edge light (before
    /// the dwell commits): 0...1, animated by SwiftUI (a tiny, local change).
    @Published public var hoverBoost: Double = 0
    /// Edge light colour, taken from the artwork.
    @Published public var glowColor: Color = .white
    init(_ pose: EdgeCollapsePose) { self.pose = pose }
}

@MainActor
public final class EdgeCollapseAppModel: ObservableObject {

    @Published public private(set) var presentation: EdgePresentation = .card
    public let poseStore = EdgeCollapsePoseStore(EdgeCollapsePoses.pose(.card, page: .album, style: .handle))
    private var pose: EdgeCollapsePose {
        get { poseStore.pose }
        set { poseStore.pose = newValue }
    }
    @Published var reduceMotionFlashOpacity: Double = 0

    @Published public var tint: EdgeCollapseTint = .gradient
    @Published public var bounce: EdgeCollapseBounce = .bouncy
    @Published public var tempo: EdgeCollapseTempo = .normal
    @Published public var reduceMotionOverride: Bool?
    @Published public var tuckStyle: EdgeCollapseTuckStyle = .handle {
        didSet {
            guard motion == nil, presentation == .tucked else { hostingView?.refreshHitRegion(); return }
            pose = EdgeCollapsePoses.pose(.tucked, page: page, style: tuckStyle)
            hostingView?.refreshHitRegion()
        }
    }
    private var page: PlayerPage { MusicController.shared.currentPage }
    private var dwellWork: DispatchWorkItem?

    /// Show the capsule for a moment on a track change (founder 2026-09-22),
    /// unless the player already posts its own song-change notification.
    /// No public API tells us whether Music/Spotify notifications are on, so
    /// the product needs a setting; the second switch simulates the answer.
    @Published public var autoPeekEnabled = true
    @Published public var playerAlreadyNotifies = false
    private var hovering = false
    private var peeking = false
    private var peekWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    // Two-finger swipe tracking (collapse follows the fingers).
    private var swipe: EdgeCollapseSwipe?
    private var trackMotion: EdgeCollapseMotion?

    weak var hostingView: EdgeGestureHostingView<RootContentView>?

    private var motion: EdgeCollapseMotion?
    private var motionKind: EdgeCollapseTransitionKind = .collapse
    private var motionStart: CFTimeInterval = 0
    private var pendingSettle: EdgeCollapseEvent?
    private var link: CADisplayLink?
    private var recorder = EdgeCollapseFrameRecorder()

    public var trackTitle: String { MusicController.shared.currentTrackTitle }

    var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public init() {
        let music = MusicController.shared
        music.$currentTrackTitle
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.trackChanged() }
            .store(in: &cancellables)
        music.$currentArtwork
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                guard let self else { return }
                let c = image.flatMap(edgeGlowColor) ?? NSColor.white
                withAnimation(.easeInOut(duration: 0.5)) { self.poseStore.glowColor = Color(nsColor: c) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Entry points

    public func requestCollapse(edge: EdgeCollapseEdge = .right) {
        guard presentation == .card else { return }
        transition(event: .collapseRequested(edge), settle: .settled, kind: .collapse)
    }

    /// The cursor has to rest on the tucked shape for `hoverDwell` before the
    /// capsule comes out; passing by the edge does nothing.
    public func requestHoverEnter(dwell: Bool = true) {
        hovering = true
        peeking = false          // the user takes over a peek
        peekWork?.cancel()
        guard presentation == .tucked else { return }
        // Respond on contact (Apple: feedback on pointer-down, not after a
        // wait): the light brightens now; the drop comes after the dwell.
        withAnimation(.easeOut(duration: 0.12)) { poseStore.hoverBoost = 1 }
        dwellWork?.cancel()
        guard dwell else { transition(event: .hoverEntered, settle: nil, kind: .floatOut); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.presentation == .tucked else { return }
            self.transition(event: .hoverEntered, settle: nil, kind: .floatOut)
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgeCollapseLayout.hoverDwell, execute: work)
    }

    public func requestHoverExit() {
        hovering = false
        dwellWork?.cancel(); dwellWork = nil
        withAnimation(.easeOut(duration: 0.2)) { poseStore.hoverBoost = 0 }
        guard presentation == .floating else { return }
        transition(event: .hoverExited, settle: nil, kind: .retract)
    }

    public func requestExpand() {
        guard presentation == .tucked || presentation == .floating else { return }
        transition(event: .expandRequested, settle: .settled, kind: .expand)
    }

    public func nextTrack() { MusicController.shared.nextTrack() }

    // MARK: - Track change peek

    private func trackChanged() {
        guard EdgeCollapseAutoPeek.shouldPeek(presentation: presentation, enabled: autoPeekEnabled,
                                              playerAlreadyNotifies: playerAlreadyNotifies, hovering: hovering) else { return }
        peeking = true
        transition(event: .hoverEntered, settle: nil, kind: .floatOut)
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.peeking, !self.hovering, self.presentation == .floating else { return }
            self.peeking = false
            self.transition(event: .hoverExited, settle: nil, kind: .retract)
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgeCollapseAutoPeek.holdSeconds, execute: work)
    }

    /// For the control window: behave as if the track just changed.
    public func simulateTrackChange() { trackChanged() }

    // MARK: - Two-finger swipe: the collapse follows the fingers

    private func restCardPose() -> EdgeCollapsePose {
        var rest = EdgeCollapsePoses.pose(.card, page: page, style: tuckStyle)
        let h = EdgeCollapsePoses.cardHero(page)
        rest.hero = h.rect; rest.heroCorner = h.corner; rest.heroBlur = h.blur
        return rest
    }

    public func swipeBegan() {
        guard presentation == .card, motion == nil, !reduceMotion else { swipe = nil; return }
        swipe = EdgeCollapseSwipe()
        trackMotion = EdgeCollapseMotion(
            from: restCardPose().vector(), velocity: Array(repeating: 0, count: EdgeCollapsePose.channelCount),
            stages: EdgeCollapseChoreography.stages(kind: .collapse, fromTucked: false, page: page, style: tuckStyle,
                                                    bounce: .settle, tempo: tempo))
    }

    public func swipeChanged(dx: Double, dy: Double) {
        if swipe == nil { swipeBegan() }
        guard var s = swipe, let tm = trackMotion else { return }
        let horizontal = s.add(dx: dx, dy: dy, at: CACurrentMediaTime())
        swipe = s
        guard horizontal else {
            // A vertical scroll (lyrics, playlist): let it be.
            swipe = nil; trackMotion = nil; pose = restCardPose(); return
        }
        pose = EdgeCollapsePose(vector: tm.sample(at: s.trackedMotionTime).value)
    }

    public func swipeEnded() {
        guard let s = swipe, let tm = trackMotion else { return }
        swipe = nil; trackMotion = nil
        let now = CACurrentMediaTime()
        let tau = s.trackedMotionTime
        if s.commits {
            // Carry on from where the fingers left it. The landing stage has
            // not started yet (tau <= 0.08s < 0.09s), so it can be rebuilt
            // with a bounce only when the release carried momentum.
            let stages = EdgeCollapseChoreography.stages(kind: .collapse, fromTucked: false, page: page, style: tuckStyle,
                                                         bounce: s.landingIsBouncy ? .bouncy : .settle, tempo: tempo)
            EdgeCollapseLog.event(t0: now, from: presentation, to: .collapsing, anim: "collapse-swipe", event: "start")
            flushRecorder()
            motion = EdgeCollapseMotion(from: tm.from, velocity: tm.velocity, stages: stages)
            motionKind = .collapse
            motionStart = now - tau
            pendingSettle = .settled
            recorder.begin(kind: "collapse-swipe", start: now)
            send(.collapseRequested(.right))
            hostingView?.refreshHitRegion()
            startLink()
            tick()
        } else if tau > 0 {
            // Not far or fast enough: spring back to the card, no bounce.
            flushRecorder()
            motion = EdgeCollapseMotion(from: pose.vector(), velocity: Array(repeating: 0, count: EdgeCollapsePose.channelCount),
                                        stages: EdgeCollapseChoreography.direct(to: restCardPose().vector(), tempo: tempo))
            motionKind = .expand
            motionStart = now
            pendingSettle = nil
            recorder.begin(kind: "swipe-cancel", start: now)
            startLink()
            tick()
        }
    }

    func activeHitRegion() -> CGRect {
        EdgeCollapseLayout.hitRegion(for: presentation, style: tuckStyle)
    }

    // MARK: - Transitions

    private func send(_ event: EdgeCollapseEvent) {
        let next = EdgeCollapseReducer.reduce(state: presentation, event: event)
        guard next != presentation else { return }
        presentation = next
    }

    private func transition(event: EdgeCollapseEvent, settle: EdgeCollapseEvent?, kind: EdgeCollapseTransitionKind) {
        let from = presentation
        let next = EdgeCollapseReducer.reduce(state: from, event: event)
        guard next != from else { return }
        let now = CACurrentMediaTime()
        let page = self.page
        let stages: [EdgeCollapseMotion.Stage]
        // Interrupted = the previous motion is still visibly under way. Its
        // settling tail (sub-point) does not count, so a hover right after a
        // collapse still gets the full drop choreography.
        let interrupted = motion.map { now - motionStart < $0.nominalDuration } ?? false
        if interrupted {
            let key: EdgeCollapseKeyPose
            switch EdgeCollapseLayout.visualLayout(for: next) {
            case .card: key = .card
            case .tucked: key = .tucked
            case .floating: key = .floating
            }
            stages = EdgeCollapseChoreography.direct(
                to: EdgeCollapsePoses.pose(key, page: page, style: tuckStyle).vector(), tempo: tempo)
        } else {
            stages = EdgeCollapseChoreography.stages(
                kind: kind, fromTucked: from == .tucked, page: page, style: tuckStyle, bounce: bounce, tempo: tempo)
        }
        let target = EdgeCollapsePose(vector: stages.last!.to)
        EdgeCollapseLog.event(t0: now, from: from, to: next, anim: kind.rawValue, event: "start")
        flushRecorder()

        if reduceMotion {
            stopLink()
            motion = nil
            send(event); pose = target
            if let settle { send(settle) }
            hostingView?.refreshHitRegion()
            reduceMotionFlashOpacity = 1
            withAnimation(EdgeCollapseTokens.reduceMotionAnimation(tempo: tempo)) { reduceMotionFlashOpacity = 0 }
            return
        }

        // Continue from wherever the previous motion is right now.
        let start: (value: [Double], velocity: [Double])
        if let motion {
            start = motion.sample(at: now - motionStart)
        } else {
            // At rest in the card the cover is hidden under the panel; take its
            // rect for the page showing now (album / lyrics / playlist).
            var rest = pose
            if from == .card {
                let h = EdgeCollapsePoses.cardHero(page)
                rest.hero = h.rect; rest.heroCorner = h.corner; rest.heroBlur = h.blur
            }
            start = (rest.vector(), Array(repeating: 0, count: EdgeCollapsePose.channelCount))
        }
        motion = EdgeCollapseMotion(from: start.value, velocity: start.velocity, stages: stages)
        motionKind = kind
        motionStart = now
        pendingSettle = settle
        recorder.begin(kind: kind.rawValue, start: now)

        send(event)
        hostingView?.refreshHitRegion()
        startLink()
        tick()
    }

    // MARK: - Frame loop

    private func startLink() {
        guard link == nil, let screen = NSScreen.main else { return }
        let l = screen.displayLink(target: self, selector: #selector(frame(_:)))
        // Without this the system picks a low adaptive rate (measured 25-40ms
        // gaps); SwiftUI's own animations request the display maximum.
        let maxRate = Float(screen.maximumFramesPerSecond)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maxRate), maximum: maxRate, preferred: maxRate)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ l: CADisplayLink) { tick() }

    private func tick() {
        guard let motion else { stopLink(); return }
        let now = CACurrentMediaTime()
        let t = now - motionStart
        let sample = motion.sample(at: t)
        pose = EdgeCollapsePose(vector: sample.value)
        recorder.record(now: now, pose: pose)

        if let settle = pendingSettle, t >= motion.nominalDuration {
            pendingSettle = nil
            let mid = presentation
            send(settle)
            EdgeCollapseLog.event(t0: motionStart, now: now, from: mid, to: presentation, anim: motionKind.rawValue, event: "settle")
            hostingView?.refreshHitRegion()
        }
        if t >= motion.settledDuration {
            pose = EdgeCollapsePose(vector: motion.to)
            // Expand ends with the capsule being the card; under the opaque
            // panel, swap to the resting card pose (same silhouette) so the
            // next collapse starts from the edge body.
            if presentation == .card {
                pose = EdgeCollapsePoses.pose(.card, page: page, style: tuckStyle)
            }
            self.motion = nil
            stopLink()
            flushRecorder()
        }
    }

    private func flushRecorder() {
        for line in recorder.finish() { print(line) }
    }
}

/// Buffers per-frame evidence for one motion; prints after it ends.
struct EdgeCollapseFrameRecorder {
    private var kind = ""
    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var maxGap: CFTimeInterval = 0
    private var maxGapAt: CFTimeInterval = 0
    private var frames = 0
    private var lastSampleAt: CFTimeInterval = -1
    private var samples: [String] = []
    private var active = false

    mutating func begin(kind: String, start: CFTimeInterval) {
        self = EdgeCollapseFrameRecorder()
        self.kind = kind; self.start = start; active = true
    }

    mutating func record(now: CFTimeInterval, pose: EdgeCollapsePose) {
        guard active else { return }
        if last > 0, now - last > maxGap { maxGap = now - last; maxGapAt = now - start }
        last = now; frames += 1
        let t = now - start
        guard lastSampleAt < 0 || t - lastSampleAt >= 0.033 else { return }
        lastSampleAt = t
        samples.append(String(format: "[EdgeCollapse] sample anim=%@ t=%.0f body.w=%.1f capsule=%.0f,%.0f,%.0f,%.0f hero.w=%.1f hero.op=%.2f panel=%.2f content=%.2f",
                              kind, t * 1000, pose.body.width,
                              pose.capsule.minX, pose.capsule.minY, pose.capsule.width, pose.capsule.height,
                              pose.hero.width, pose.heroOpacity, pose.panelOpacity, pose.capsuleContentOpacity))
    }

    mutating func finish() -> [String] {
        guard active else { return [] }
        active = false
        let summary = String(format: "[EdgeCollapse] frames anim=%@ frames=%d maxGapMs=%.1f atMs=%.0f durationMs=%.0f",
                             kind, frames, maxGap * 1000, maxGapAt * 1000, (last - start) * 1000)
        return samples + [summary]
    }
}
