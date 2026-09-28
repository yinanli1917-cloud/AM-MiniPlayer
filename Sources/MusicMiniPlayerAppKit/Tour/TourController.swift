/**
 * [INPUT]: AppKit/SwiftUI/Combine; MusicMiniPlayerCore's TourMachine/TourState/
 *          TourPersistence/TourDetectors/TourHookBus/TourDeferredWatcher/
 *          TourPlacement/TourAnchorRegistry/TourMotionPolicy/OnboardingState/
 *          MusicController/LyricsService/SnappablePanel/LiquidEdgeController;
 *          this Tour/ folder's TourCardWindow/TourCardView/TourHaloView/
 *          TourCelebrationView.
 * [OUTPUT]: Exports TourController — the @MainActor effect executor that
 *           turns TourMachine's pure output into real windows.
 * [POS]: MusicMiniPlayerAppKit/Tour. Owned by AppMain; constructed once the
 *        floating panel and its LiquidEdgeController exist. This is the ONLY
 *        piece of the tour that touches a window, a timer, or a haptic.
 */

import AppKit
import SwiftUI
import Combine
import MusicMiniPlayerCore

@MainActor
final class TourController: ObservableObject {
    private weak var panel: SnappablePanel?
    private let liquidEdge: LiquidEdgeController
    private let musicController: MusicController
    private let lyricsService: LyricsService

    private(set) var state: TourState
    private var cancellables = Set<AnyCancellable>()
    private let deferredWatcher = TourDeferredWatcher()
    private let snappedCornerSubject = PassthroughSubject<ScreenCorner, Never>()

    private var cardWindow: TourCardWindow?
    private var haloWindow: TourHaloWindow?
    private var celebrationWindow: TourCelebrationWindow?
    private var transitionWork: DispatchWorkItem?
    private var finaleWork: DispatchWorkItem?
    private var closingFlashWork: DispatchWorkItem?
    private var connectDenied = false
    /// The last model actually shown — needed for the S4L-completion "closing
    /// flash" (§5.2's `deferredTip` completion): the reducer already flips
    /// `state.phase` to `.idle` in the SAME effects batch as the beat-check/
    /// ring-grow that's meant to flash on screen first, so there is no
    /// current-phase card model left to render at that point without this.
    private var lastPresentedModel: TourCardModel?

    #if DEBUG || LOCAL_DEVELOPER_BUILD
    static var debugForceShow = false
    #endif

    /// Test seam (§11.1 TourTeardownTests): how many of the three overlay
    /// windows are currently allocated, and whether any of the three timers
    /// (transition / finale auto-dismiss / closing-flash) are still armed.
    var debugAllocatedWindowCount: Int {
        [cardWindow != nil, haloWindow != nil, celebrationWindow != nil].filter { $0 }.count
    }
    var debugHasPendingTimers: Bool {
        transitionWork != nil || finaleWork != nil || closingFlashWork != nil
    }
    var debugIsDeferredWatcherArmed: Bool { deferredWatcher.isArmed }

    init(panel: SnappablePanel, liquidEdge: LiquidEdgeController,
         musicController: MusicController = .shared, lyricsService: LyricsService = .shared) {
        self.panel = panel
        self.liquidEdge = liquidEdge
        self.musicController = musicController
        self.lyricsService = lyricsService
        self.state = TourPersistence.load()

        panel.onSnappedToCorner = { [weak self] _, corner in self?.snappedCornerSubject.send(corner) }
        wireDetectors()
    }

    // MARK: - Entry points

    /// Called once at app launch, after `OnboardingState.incrementLaunchCount()`.
    func launchIfNeeded(launchCount: Int) {
        var forced = false
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        forced = Self.debugForceShow
        #endif
        guard TourPersistence.shouldPresent(status: state.status, launchCount: launchCount, resumeCount: state.resumeCount, forced: forced) else {
            if state.hasDeferredTranslate { send(.launch) } // deferred-watcher launch bookkeeping only
            return
        }
        send(.launch)
    }

    /// Settings › 通用's "接着认识 nanoPod" / "重新认识 nanoPod" row.
    func requestTour(fromStart: Bool) {
        if fromStart {
            TourPersistence.reset()
            state = TourState()
            send(.start)
        } else {
            send(.resume(completed: state.completedSteps))
        }
    }

    #if DEBUG || LOCAL_DEVELOPER_BUILD
    /// `nanopod://debug/tour/<show|reset|step/<id>>`.
    func handleDebugAction(_ path: String) -> Bool {
        if path == "show" {
            Self.debugForceShow = true
            requestTour(fromStart: false)
            return true
        }
        if path == "reset" {
            teardown()
            TourPersistence.reset()
            state = TourState()
            Self.debugForceShow = false
            return true
        }
        if path.hasPrefix("step/"), let step = TourStep(rawValue: String(path.dropFirst("step/".count))) {
            state.stepStates = Dictionary(uniqueKeysWithValues: TourStep.orderedSteps.prefix(while: { $0 != step }).map { ($0, .completed) })
            send(.resume(completed: state.completedSteps))
            return true
        }
        return false
    }
    #endif

    // MARK: - Detectors

    private func wireDetectors() {
        let detectors = TourDetectors(
            controlsRevealed: TourHookBus.shared.controlsRevealed.eraseToAnyPublisher(),
            isPlaying: musicController.$isPlaying.eraseToAnyPublisher(),
            audioOutputMenuOpened: TourHookBus.shared.audioOutputMenuOpened.eraseToAnyPublisher(),
            musicButtonTapped: TourHookBus.shared.musicButtonTapped.eraseToAnyPublisher(),
            currentPageIsLyrics: musicController.$currentPage.map { $0 == .lyrics }.eraseToAnyPublisher(),
            showTranslationEnabled: lyricsService.$showTranslation.filter { $0 }.map { _ in () }.eraseToAnyPublisher(),
            snappedCorner: snappedCornerSubject.eraseToAnyPublisher(),
            liquidEdgeState: liquidEdge.statePublisher.eraseToAnyPublisher()
        )
        detectors.events.sink { [weak self] event in self?.send(event) }.store(in: &cancellables)
    }

    // MARK: - Event pump

    /// Internal (not `private`) so tests can drive the machine directly via
    /// `@testable import` without hosting real button clicks.
    func send(_ event: TourEvent) {
        let snapshot = TourSnapshot(
            automationAuthorized: OnboardingState.shared.automationStatus == .authorized,
            canTranslate: lyricsService.canTranslate,
            showTranslation: lyricsService.showTranslation
        )
        let (next, effects) = TourMachine.reduce(state, event, snapshot: snapshot)
        state = next
        apply(effects)
        scheduleTransitionIfNeeded()
        scheduleFinaleAutoDismissIfNeeded()
    }

    private func scheduleTransitionIfNeeded() {
        guard case .transitioning(let from, _) = state.phase else { return }
        transitionWork?.cancel()
        let delay = (from == .translate) ? TourMotionPolicy.Tokens.deferralNoteHold : TourMotionPolicy.Tokens.stepCompletionFeedback
        let work = DispatchWorkItem { [weak self] in self?.send(.advanceTransition) }
        transitionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleFinaleAutoDismissIfNeeded() {
        guard case .finale = state.phase else { return }
        finaleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.send(.finaleDismiss) }
        finaleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TourMotionPolicy.Tokens.finaleAutoDismiss, execute: work)
    }

    // MARK: - Effects

    private func apply(_ effects: [TourEffect]) {
        for effect in effects {
            switch effect {
            case .showWelcomeCard: connectDenied = false; presentCurrentCard()
            case .showStepCard: connectDenied = false; presentCurrentCard()
            case .showDeferralNote: presentCurrentCard()
            case .showFinaleCard: presentCurrentCard()
            case .showDeferredTipCard: presentCurrentCard()
            case .hideCard: hideCard()
            case .checkBeat(let step, let index): flashBeatCheck(step, index)
            case .growRing(let to): flashRingGrowth(to: to)
            case .spark: playSpark()
            case .pulseRing: pulseRing()
            case .confetti: playConfetti()
            case .haptic(let kind): performHaptic(kind)
            case .relocateCardToPanel: presentCurrentCard()
            case .persist: TourPersistence.save(state)
            case .armDeferredWatcher: armDeferredWatcher()
            case .cancelDeferredWatcher: deferredWatcher.cancel()
            case .teardown: teardown()
            }
        }
    }

    private func armDeferredWatcher() {
        deferredWatcher.onEvent = { [weak self] in self?.send($0) }
        deferredWatcher.arm(
            canTranslate: lyricsService.$canTranslate.eraseToAnyPublisher(),
            trackTitle: musicController.$currentTrackTitle.dropFirst().eraseToAnyPublisher(),
            panelVisible: { [weak self] in self?.panel?.isVisible ?? false }
        )
    }

    private func performHaptic(_ kind: TourHaptic) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern = (kind == .alignment) ? .alignment : .levelChange
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .drawCompleted)
    }

    // MARK: - Teardown (§11.2: zero standing cost afterward)

    private func teardown() {
        transitionWork?.cancel(); transitionWork = nil
        finaleWork?.cancel(); finaleWork = nil
        closingFlashWork?.cancel(); closingFlashWork = nil
        hideCard()
        TourAnchorRegistry.shared.reset()
    }

    /// Fully releases the three overlay windows (not just orders them out) —
    /// §11.2's "结束后无窗口...effectViews 清单必须回到引导前" means the
    /// window OBJECTS must go, not just become invisible. Nothing else holds
    /// a strong reference to them, so dropping these is deinit or nothing.
    private func hideCard() {
        closingFlashWork?.cancel(); closingFlashWork = nil
        lastPresentedModel = nil
        cardWindow?.contentViewController = nil
        cardWindow?.orderOut(nil)
        cardWindow = nil
        haloWindow?.contentViewController = nil
        haloWindow?.orderOut(nil)
        haloWindow = nil
        celebrationWindow?.contentViewController = nil
        celebrationWindow?.orderOut(nil)
        celebrationWindow = nil
    }

    // MARK: - Card content assembly (proposal §3.3/§9)

    private func presentCurrentCard() {
        guard let model = cardModel(for: state.phase) else { hideCard(); return }
        lastPresentedModel = model
        presentCard(model: model, gestureKind: gestureKind(for: state.phase))
    }

    /// Beat-check / ring-growth normally just re-renders the current step's
    /// card. The one exception (§5.2's deferred-tip completion) already
    /// moved `state.phase` to `.idle` by the time this runs — patch the last
    /// model shown instead, flash it briefly, then hide.
    private func flashBeatCheck(_ step: TourStep, _ index: Int) {
        if let model = cardModel(for: state.phase) {
            lastPresentedModel = model
            presentCard(model: model, gestureKind: gestureKind(for: state.phase))
            return
        }
        guard var model = lastPresentedModel, model.beats.indices.contains(index) else { return }
        model.beats[index].checked = true
        lastPresentedModel = model
        presentCard(model: model, gestureKind: nil)
        scheduleClosingFlashHide()
    }

    private func flashRingGrowth(to: Int) {
        if let model = cardModel(for: state.phase) {
            lastPresentedModel = model
            presentCard(model: model, gestureKind: gestureKind(for: state.phase))
            return
        }
        guard var model = lastPresentedModel else { return }
        model.ringCompleted = to
        lastPresentedModel = model
        presentCard(model: model, gestureKind: nil)
        scheduleClosingFlashHide()
    }

    private func scheduleClosingFlashHide() {
        closingFlashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideCard() }
        closingFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TourMotionPolicy.Tokens.stepCompletionFeedback, execute: work)
    }

    private func cardModel(for phase: TourPhase) -> TourCardModel? {
        let L = { (key: String) in L10n.localized(key) }
        let total = TourStep.orderedSteps.count

        switch phase {
        case .idle:
            return nil

        case .welcome:
            let resuming = state.status == .inProgress
            var model = TourCardModel(
                kind: .welcome,
                title: L(resuming ? "tour.resume.title" : "tour.welcome.title"),
                body: L(resuming ? "tour.resume.body" : "tour.welcome.body"),
                primaryTitle: L("tour.welcome.primary"), secondaryTitle: L("tour.welcome.secondary"),
                footNote: L("tour.welcome.foot"),
                ringCompleted: state.completedCount
            )
            model.showStop = false; model.showSkipStep = false
            if state.stepStates[.connect] == .completed { model.chip = L("tour.welcome.chip") }
            return model

        case .step(.connect, _):
            if connectDenied {
                var model = TourCardModel(
                    kind: .connectDenied, title: L("tour.connect.denied.title"), body: L("tour.connect.denied.body"),
                    primaryTitle: nil, secondaryTitle: L("tour.connect.openSettings"),
                    ringCompleted: state.completedCount, stepLabel: "1"
                )
                model.showStop = false; model.showSkipStep = true
                return model
            }
            var model = TourCardModel(
                kind: .connect, title: L("tour.connect.title"), body: L("tour.connect.body"),
                primaryTitle: L("tour.connect.primary"), secondaryTitle: L("tour.connect.secondary"),
                ringCompleted: state.completedCount, stepLabel: "1"
            )
            model.showStop = false; model.showSkipStep = false
            return model

        case .step(.reveal, let beats):
            let beat2Label = musicController.isPlaying ? L("tour.reveal.beat2done") : L("tour.reveal.beat2")
            return TourCardModel(
                kind: .step(.reveal), title: L("tour.reveal.title"), body: L("tour.reveal.body"),
                beats: [TourBeatModel(id: 0, text: L("tour.reveal.beat1"), checked: beats[0]),
                        TourBeatModel(id: 1, text: beat2Label, checked: beats[1])],
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.reveal.index(in: total) )"
            )

        case .step(.corners, let beats):
            return TourCardModel(
                kind: .step(.corners), title: L("tour.corners.title"), body: L("tour.corners.body"),
                beats: [TourBeatModel(id: 0, text: L("tour.corners.beat1"), checked: beats[0]),
                        TourBeatModel(id: 1, text: L("tour.corners.beat2"), checked: beats[1])],
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.corners.index(in: total))"
            )

        case .step(.lyrics, _):
            return TourCardModel(
                kind: .step(.lyrics), title: L("tour.lyrics.title"), body: L("tour.lyrics.body"),
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.lyrics.index(in: total))"
            )

        case .step(.translate, _):
            return TourCardModel(
                kind: .step(.translate), title: L("tour.translate.title"), body: L("tour.translate.body"),
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.translate.index(in: total))"
            )

        case .step(.moveTuck, let beats):
            let tucked = beats[0]
            let rightward = (panel?.currentCorner() == .topRight || panel?.currentCorner() == .bottomRight) || liquidEdge.side != .left
            var model = TourCardModel(
                kind: .step(.moveTuck),
                title: L("tour.move.title"),
                body: tucked ? L(rightward ? "tour.move.bodyTuckRight" : "tour.move.bodyTuckLeft") : L("tour.move.body"),
                beats: [TourBeatModel(id: 0, text: L("tour.move.beat1"), checked: beats[0]),
                        TourBeatModel(id: 1, text: L("tour.move.beat2"), checked: beats[1])],
                secondaryTitle: L("tour.move.forMe"), footNote: L("tour.move.mouseNote"),
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.moveTuck.index(in: total))"
            )
            model.showFallbackButton = true
            return model

        case .step(.back, let beats):
            return TourCardModel(
                kind: .step(.back), title: L("tour.back.title"), body: "",
                beats: [TourBeatModel(id: 0, text: L("tour.back.beat1"), checked: beats[0]),
                        TourBeatModel(id: 1, text: L("tour.back.beat2"), checked: beats[1])],
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.back.index(in: total))"
            )

        case .transitioning(let from, _) where from == .translate:
            var model = TourCardModel(
                kind: .deferralNote, title: L("tour.translate.deferred.title"), body: L("tour.translate.deferred.body"),
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.translate.index(in: total))"
            )
            model.showStop = true; model.showSkipStep = false
            return model

        case .transitioning:
            return nil

        case .finale:
            let deferred = state.hasDeferredTranslate
            var model = TourCardModel(
                kind: .finale(deferred: deferred), title: L("tour.done.title"),
                body: L(deferred ? "tour.done.bodyDeferred" : "tour.done.body"),
                primaryTitle: L("tour.done.shortcut"), secondaryTitle: L("tour.done.ok"),
                footNote: L("tour.done.foot"),
                ringCompleted: deferred ? total - 1 : total, ringClosed: !deferred
            )
            model.showStop = false; model.showSkipStep = false
            return model

        case .deferredTip:
            var model = TourCardModel(
                kind: .deferredTip, title: L("tour.later.title"), body: L("tour.later.body"),
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.translate.index(in: total))"
            )
            model.showStop = true; model.showSkipStep = false
            return model
        }
    }

    private func gestureKind(for phase: TourPhase) -> TourGestureKind? {
        guard case .step(.moveTuck, let beats) = phase else { return nil }
        if !beats[0] { return .nudgeToCorner }
        let rightward = (panel?.currentCorner() == .topRight || panel?.currentCorner() == .bottomRight) || liquidEdge.side != .left
        return .swipeToEdge(rightward: rightward)
    }

    // MARK: - Anchors & placement

    private var isSliverAnchored: Bool {
        if case .step(.back, _) = state.phase { return true }
        if case .deferredTip = state.phase, liquidEdge.isActive { return true }
        return false
    }

    private func currentAnchorRect() -> CGRect? {
        switch state.phase {
        case .step(.reveal, _):
            return TourAnchorRegistry.shared.rect(for: .playPause)
        case .step(.corners, let beats):
            return TourAnchorRegistry.shared.rect(for: beats[0] ? .musicButton : .audioOutput)
        case .step(.lyrics, _):
            return TourAnchorRegistry.shared.rect(for: .lyricsNav)
        case .step(.translate, _), .deferredTip:
            return TourAnchorRegistry.shared.rect(for: .translate)
        case .transitioning(let from, _) where from == .translate:
            return TourAnchorRegistry.shared.rect(for: .translate)
        default:
            return panel?.frame
        }
    }

    private func haloSize(for phase: TourPhase) -> CGSize? {
        switch phase {
        case .step(.reveal, _), .step(.translate, _), .deferredTip: return CGSize(width: 40, height: 40)
        case .step(.corners, _): return CGSize(width: 40, height: 40)
        case .step(.lyrics, _): return CGSize(width: 36, height: 36)
        case .step(.back, _): return CGSize(width: 18, height: 72)
        case .transitioning(let from, _) where from == .translate: return CGSize(width: 40, height: 40)
        default: return nil
        }
    }

    private func presentCard(model: TourCardModel, gestureKind: TourGestureKind?) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let anchor = currentAnchorRect() ?? panel.frame

        let measuredHeight = measureCardHeight(model: model, gestureKind: gestureKind)
        let cardSize = CGSize(width: 236, height: max(measuredHeight, 92))

        let placement: TourCardPlacement
        if isSliverAnchored {
            let edge: TourCardSide = liquidEdge.side == .left ? .left : .right
            let region = liquidEdge.tuckedRegionInScreen
            placement = TourPlacement.placeNearSliver(
                cardSize: cardSize, sliverEdge: edge,
                floatingHitRegion: liquidEdge.floatingHitRegionInScreen.isEmpty ? region : liquidEdge.floatingHitRegionInScreen,
                sliverMidY: region.isEmpty ? panel.frame.midY : region.midY, visibleFrame: visibleFrame
            )
        } else {
            placement = TourPlacement.placeNearPanel(cardSize: cardSize, anchor: anchor, panelFrame: panel.frame, visibleFrame: visibleFrame)
        }

        ensureWindows()
        let content = buildCardView(model: model, placement: placement, gestureKind: gestureKind)
        cardWindow?.contentViewController = NSHostingController(rootView: content)
        cardWindow?.setFrame(NSRect(origin: placement.origin, size: cardSize), display: true)
        cardWindow?.orderFront(nil)

        positionHalo(anchor: anchor)
    }

    private func buildCardView(model: TourCardModel, placement: TourCardPlacement, gestureKind: TourGestureKind?) -> TourCardView {
        TourCardView(
            model: model, beakSide: placement.beakSide, beakOffset: placement.beakOffset, gestureKind: gestureKind,
            onPrimary: { [weak self] in self?.handlePrimary() },
            onSecondary: { [weak self] in self?.handleSecondary() },
            onStop: { [weak self] in self?.send(.stopTour) },
            onSkipStep: { [weak self] in self?.handleSkipStepOrDeniedContinue() },
            onFallback: { [weak self] in self?.handleFallback() }
        )
    }

    private func measureCardHeight(model: TourCardModel, gestureKind: TourGestureKind?) -> CGFloat {
        let view = buildCardView(model: model, placement: TourCardPlacement(origin: .zero, beakSide: .left, beakOffset: 40), gestureKind: gestureKind)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 236, height: 1)
        let fitting = hosting.fittingSize
        return fitting.height > 0 ? fitting.height : 150
    }

    private func positionHalo(anchor: CGRect) {
        guard let size = haloSize(for: state.phase) else {
            haloWindow?.orderOut(nil)
            return
        }
        ensureWindows()
        let frame = NSRect(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2, width: size.width, height: size.height)
        let alreadyVisible = haloWindow?.isVisible == true
        haloWindow?.contentViewController = NSHostingController(rootView: TourHaloView(size: size, appeared: true, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        haloWindow?.setFrame(frame, display: true)
        if !alreadyVisible {
            haloWindow?.contentViewController = NSHostingController(rootView: TourHaloView(size: size, appeared: false, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
            haloWindow?.orderFront(nil)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.haloWindow?.contentViewController = NSHostingController(rootView: TourHaloView(size: size, appeared: true, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
            }
        } else {
            haloWindow?.orderFront(nil)
        }
    }

    private func ensureWindows() {
        if cardWindow == nil { cardWindow = TourCardWindow() }
        if haloWindow == nil { haloWindow = TourHaloWindow() }
        if celebrationWindow == nil { celebrationWindow = TourCelebrationWindow() }
    }

    // MARK: - Celebration

    private func playSpark() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let cardWindow else { return }
        ensureWindows()
        let origin = CGPoint(x: cardWindow.frame.maxX - 28, y: cardWindow.frame.maxY - 28)
        let field = TourParticleField.sparks(origin: origin, at: Date().timeIntervalSinceReferenceDate)
        showCelebration(field: field, frame: cardWindow.frame.insetBy(dx: -60, dy: -60))
    }

    private func playConfetti() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let panel else { return }
        ensureWindows()
        let edge = CGRect(x: panel.frame.minX, y: panel.frame.maxY, width: panel.frame.width, height: 1)
        let field = TourParticleField.confetti(along: edge, at: Date().timeIntervalSinceReferenceDate)
        showCelebration(field: field, frame: panel.frame.insetBy(dx: -80, dy: -160).union(panel.frame))
    }

    private func showCelebration(field: TourParticleField, frame: CGRect) {
        celebrationWindow?.contentViewController = NSHostingController(
            rootView: TourCelebrationView(field: field, startTime: Date().timeIntervalSinceReferenceDate)
                .frame(width: frame.width, height: frame.height)
        )
        celebrationWindow?.setFrame(frame, display: true)
        celebrationWindow?.orderFront(nil)
        let longest = field.particles.map(\.lifetime).max() ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + longest + 0.1) { [weak self] in
            self?.celebrationWindow?.contentViewController = nil
            self?.celebrationWindow?.orderOut(nil)
        }
    }

    private func pulseRing() {
        // The ring's own view animates the pulse on `growRing`'s content
        // rebuild (scale/stroke handled inside TourRingView's animation
        // modifiers); nothing further to trigger here.
    }

    // MARK: - Button handlers

    private func handlePrimary() {
        switch state.phase {
        case .welcome: send(.start)
        case .step(.connect, _): connectMusic()
        case .finale: AppMain.shared?.showSettingsWindow(selectedTab: .shortcuts)
        default: break
        }
    }

    private func handleSecondary() {
        switch state.phase {
        case .welcome: send(.stopTour)
        case .step(.connect, _): send(.skipStep)
        case .finale: send(.finaleDismiss)
        default: break
        }
    }

    private func handleSkipStepOrDeniedContinue() {
        if case .step(.connect, _) = state.phase, connectDenied {
            connectDenied = false
            send(.skipStep)
        } else {
            send(.skipStep)
        }
    }

    private func handleFallback() {
        guard case .step(.moveTuck, _) = state.phase else { return }
        panel?.hideToNearestEdge()
    }

    private func connectMusic() {
        OnboardingState.shared.requestAutomationAccess()
        if OnboardingState.shared.automationStatus == .authorized {
            send(.signal(.automationAuthorized))
        } else {
            connectDenied = true
            presentCurrentCard()
        }
    }
}

private extension TourStep {
    /// 1-based position within the fixed 7-step order, for the ring's center label.
    func index(in total: Int) -> Int { TourStep.orderedSteps.firstIndex(of: self).map { $0 + 1 } ?? total }
}
