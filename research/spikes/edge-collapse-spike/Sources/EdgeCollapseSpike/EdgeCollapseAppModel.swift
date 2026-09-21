/**
 * [INPUT]: EdgeCollapseEvent (gesture/hover/click), control-window switches,
 *          MusicController.shared (artwork / title / playback).
 * [OUTPUT]: EdgeCollapseAppModel — drives EdgePresentation via the reducer
 *           and animates `pose` (every visual channel) with a per-channel
 *           spring/delay plan. All channel animations for one transition are
 *           issued in the same frame; the delays are what stagger shape →
 *           second body → content.
 * [POS]: Standalone spike app layer.
 * [PROTOCOL]: `applyPlan` is the only place that calls withAnimation for a
 *             presentation change. No asyncAfter relays.
 */

import AppKit
import SwiftUI
import QuartzCore
import Combine
import MusicMiniPlayerCore

@MainActor
public final class EdgeCollapseAppModel: ObservableObject {

    @Published public private(set) var presentation: EdgePresentation = .card
    @Published public private(set) var pose: EdgeCollapsePose
    @Published public private(set) var artworkColor: NSColor?
    @Published var reduceMotionFlashOpacity: Double = 0

    @Published public var variant: EdgeCollapseVariant = .h { didSet { snapPoseToState() } }
    @Published public var tint: EdgeCollapseTint = .gradient
    @Published public var bounce: EdgeCollapseBounce = .bouncy
    @Published public var tempo: EdgeCollapseTempo = .normal
    @Published public var reduceMotionOverride: Bool?

    private var cancellables = Set<AnyCancellable>()
    weak var hostingView: EdgeGestureHostingView<RootContentView>?

    public var trackTitle: String { MusicController.shared.currentTrackTitle }

    var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public init() {
        pose = EdgeCollapsePoses.pose(for: .card, variant: .h, titleWidth: 0)
        let music = MusicController.shared
        music.$currentTrackTitle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.presentation == .floating {
                    withAnimation(.spring(duration: 0.30, bounce: 0.25)) { self.snapPoseToState() }
                }
                self.hostingView?.refreshHitRegion()
            }
            .store(in: &cancellables)
        music.$currentArtwork
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                guard let self else { return }
                let color = image.flatMap { edgeCollapseArtworkColor($0) }
                withAnimation(.easeInOut(duration: 0.4)) { self.artworkColor = color }
            }
            .store(in: &cancellables)
    }

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

    public func toggleIsPlaying() { MusicController.shared.togglePlayPause() }
    public func nextTrack() { MusicController.shared.nextTrack() }

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

    // MARK: - Reducer + pose

    private func send(_ event: EdgeCollapseEvent) {
        let next = EdgeCollapseReducer.reduce(state: presentation, event: event)
        guard next != presentation else { return }
        presentation = next
    }

    private func targetPose(for state: EdgePresentation) -> EdgeCollapsePose {
        EdgeCollapsePoses.pose(
            for: EdgeCollapseLayout.visualLayout(for: state),
            variant: variant,
            titleWidth: EdgeCollapseLayout.estimatedTitleWidth(trackTitle))
    }

    private func snapPoseToState() {
        pose = targetPose(for: presentation)
    }

    private func transition(event: EdgeCollapseEvent, settle: EdgeCollapseEvent?, kind: EdgeCollapseTransitionKind) {
        let from = presentation
        let next = EdgeCollapseReducer.reduce(state: from, event: event)
        guard next != from else { return }
        let t0 = CACurrentMediaTime()
        let target = targetPose(for: next)
        EdgeCollapseLog.event(t0: t0, from: from, to: next, anim: kind.rawValue, event: "start")
        if let hostingView { EdgeCollapseProbe.record(view: hostingView, label: kind.rawValue) }

        if reduceMotion {
            var snap = Transaction(); snap.disablesAnimations = true
            withTransaction(snap) {
                send(event); pose = target
                if let settle { send(settle) }
            }
            hostingView?.refreshHitRegion()
            reduceMotionFlashOpacity = 1
            withAnimation(EdgeCollapseTokens.reduceMotionAnimation(tempo: tempo)) { reduceMotionFlashOpacity = 0 }
            EdgeCollapseLog.event(t0: t0, from: from, to: presentation, anim: "\(kind.rawValue)-reduceMotion", event: "settle")
            return
        }

        send(event)
        applyPlan(EdgeCollapsePlan.plan(for: kind, bounce: bounce, tempo: tempo), target: target) { [weak self] in
            guard let self else { return }
            let mid = self.presentation
            if let settle { self.send(settle) }
            EdgeCollapseLog.event(t0: t0, from: mid, to: self.presentation, anim: kind.rawValue, event: "settle")
        }
        hostingView?.refreshHitRegion()
    }

    /// One withAnimation per channel, all issued now. The longest channel's
    /// completion drives `settle`.
    private func applyPlan(_ plan: EdgeCollapsePlan, target: EdgeCollapsePose, completion: @escaping () -> Void) {
        withAnimation(plan.bodyHeight) {
            pose.bodyRect.size.height = target.bodyRect.height
            pose.bodyRect.origin.y = target.bodyRect.origin.y
        }
        withAnimation(plan.bodyWidth) {
            pose.bodyRect.size.width = target.bodyRect.width
        }
        withAnimation(plan.bodyPosition) {
            pose.bodyRect.origin.x = target.bodyRect.origin.x
        }
        withAnimation(plan.corners) {
            pose.cornerInner = target.cornerInner
            pose.cornerEdge = target.cornerEdge
        }
        withAnimation(plan.control) {
            pose.controlRect = target.controlRect
            pose.controlContentOpacity = target.controlContentOpacity
        }
        withAnimation(plan.hero, completionCriteria: .logicallyComplete) {
            pose.heroRect = target.heroRect
            pose.heroCorner = target.heroCorner
        } completion: { completion() }
        withAnimation(plan.material) { pose.artworkTint = target.artworkTint }
        withAnimation(plan.cardContent) { pose.cardContentOpacity = target.cardContentOpacity }
        // ref4: content is blurred while the shapes morph, then resolves.
        var noAnim = Transaction(); noAnim.disablesAnimations = true
        withTransaction(noAnim) { pose.contentBlur = 6 }
        withAnimation(plan.barText) {
            pose.barTextOpacity = target.barTextOpacity
            pose.contentBlur = 0
        }
        withAnimation(plan.progress) { pose.progressOpacity = target.progressOpacity }
    }
}
