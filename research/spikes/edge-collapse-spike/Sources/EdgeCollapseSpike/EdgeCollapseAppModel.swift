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
    init(_ pose: EdgeCollapsePose) { self.pose = pose }
}

@MainActor
public final class EdgeCollapseAppModel: ObservableObject {

    @Published public private(set) var presentation: EdgePresentation = .card
    public let poseStore = EdgeCollapsePoseStore(EdgeCollapsePoses.pose(for: .card))
    private var pose: EdgeCollapsePose {
        get { poseStore.pose }
        set { poseStore.pose = newValue }
    }
    @Published var reduceMotionFlashOpacity: Double = 0

    @Published public var tint: EdgeCollapseTint = .gradient
    @Published public var bounce: EdgeCollapseBounce = .bouncy
    @Published public var tempo: EdgeCollapseTempo = .normal
    @Published public var reduceMotionOverride: Bool?

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

    public init() {}

    // MARK: - Entry points

    public func requestCollapse(edge: EdgeCollapseEdge = .right) {
        guard presentation == .card else { return }
        transition(event: .collapseRequested(edge), settle: .settled, kind: .collapse)
    }

    public func requestHoverEnter() {
        guard presentation == .tucked else { return }
        transition(event: .hoverEntered, settle: nil, kind: .floatOut)
    }

    public func requestHoverExit() {
        guard presentation == .floating else { return }
        transition(event: .hoverExited, settle: nil, kind: .retract)
    }

    public func requestExpand() {
        guard presentation == .tucked || presentation == .floating else { return }
        transition(event: .expandRequested, settle: .settled, kind: .expand)
    }

    public func nextTrack() { MusicController.shared.nextTrack() }

    func activeHitRegion() -> CGRect {
        EdgeCollapseLayout.hitRegion(for: presentation)
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
        let target = EdgeCollapsePoses.pose(for: EdgeCollapseLayout.visualLayout(for: next))
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
            start = (pose.vector(), Array(repeating: 0, count: EdgeCollapsePose.channelCount))
        }
        let plan = EdgeCollapsePlan.plan(for: kind, bounce: bounce, tempo: tempo)
        motion = EdgeCollapseMotion(from: start.value, velocity: start.velocity, to: target.vector(), plan: plan)
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
