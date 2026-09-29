/**
 * [INPUT]: AppKit/SwiftUI/Combine; MusicMiniPlayerCore's TourMachine/TourState/
 *          TourPersistence/TourDetectors/TourHookBus/TourDeferredWatcher/
 *          TourPlacement/TourAnchorRegistry/TourMotionPolicy/OnboardingState/
 *          MusicController/LyricsService/SnappablePanel/LiquidEdgeController;
 *          this Tour/ folder's TourCardWindow/TourCardView (+TourCardStore)/
 *          TourCompletionFeedback/TourHaloView.
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
    private let defaults: UserDefaults

    private(set) var state: TourState
    private var cancellables = Set<AnyCancellable>()
    private let deferredWatcher = TourDeferredWatcher()
    private let snappedCornerSubject = PassthroughSubject<ScreenCorner, Never>()

    private var cardWindow: TourCardWindow?
    /// ONE persistent hosting view + store for the card window's whole life —
    /// changes flow through `cardStore`, never through a new hosting controller.
    private var cardStore: TourCardStore?
    private var haloWindow: TourHaloWindow?
    private var haloStore: TourHaloStore?
    /// The "you finished it" animation (sparks and confetti included, in its
    /// own FX window): the controller calls `begin(_:onSwapDue:)`,
    /// `cardDidSwap()` and `cancel()`.
    private let feedback: TourCompletionFeedback
    private var transitionWork: DispatchWorkItem?
    private var finaleWork: DispatchWorkItem?
    /// Fallback for the finale card swap (the feedback normally triggers it).
    private var finaleCardWork: DispatchWorkItem?
    /// Where the card window sits when nothing bounces it (finale bounce base).
    private var cardPlacedOrigin: NSPoint?
    private var cardBounceBase: NSPoint?
    private var closingFlashWork: DispatchWorkItem?
    private var connectDenied = false
    /// The last model actually shown — needed for the S4L-completion "closing
    /// flash" (§5.2's `deferredTip` completion): the reducer already flips
    /// `state.phase` to `.idle` in the SAME effects batch as the beat-check/
    /// ring-grow that's meant to flash on screen first, so there is no
    /// current-phase card model left to render at that point without this.
    private var lastPresentedModel: TourCardModel?
    /// S4L closing flash: hide the card once the feedback has had its second.
    private var closingFlashPending = false

    #if DEBUG || LOCAL_DEVELOPER_BUILD
    static var debugForceShow = false
    #endif

    /// Test seam (§11.1 TourTeardownTests): how many of the three overlay
    /// windows are currently allocated, and whether any of the three timers
    /// (transition / finale auto-dismiss / closing-flash) are still armed.
    var debugAllocatedWindowCount: Int {
        [cardWindow != nil, haloWindow != nil, feedback.debugSparkOverlay.window != nil].filter { $0 }.count
    }
    var debugFeedback: TourCompletionFeedback { feedback }
    var debugCardStore: TourCardStore? { cardStore }
    var debugHasPendingTimers: Bool {
        transitionWork != nil || finaleWork != nil || closingFlashWork != nil || finaleCardWork != nil
    }
    var debugIsDeferredWatcherArmed: Bool { deferredWatcher.isArmed }
    /// Geometry seams for TourCardPlacementIntegrationTests (screen coordinates).
    var debugCardFrame: NSRect? { cardWindow?.frame }
    var debugHaloFrame: NSRect? { haloWindow?.isVisible == true ? haloWindow?.frame : nil }
    private(set) var debugLastPlacement: TourCardPlacement?
    private(set) var debugLastAnchorRect: CGRect?

    init(panel: SnappablePanel, liquidEdge: LiquidEdgeController,
         musicController: MusicController = .shared, lyricsService: LyricsService = .shared,
         defaults: UserDefaults = .standard, feedback: TourCompletionFeedback? = nil) {
        self.defaults = defaults
        self.feedback = feedback ?? TourCompletionFeedback()
        self.panel = panel
        self.liquidEdge = liquidEdge
        self.musicController = musicController
        self.lyricsService = lyricsService
        self.state = TourPersistence.load(from: defaults)

        panel.onSnappedToCorner = { [weak self] _, corner in self?.snappedCornerSubject.send(corner) }
        self.feedback.applyCardOffset = { [weak self] dy in self?.bounceCard(by: dy) }
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
            TourPersistence.reset(defaults)
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
        if path.hasPrefix("material/") {
            let arm = String(path.dropFirst("material/".count))
            defaults.set(TourCardMaterialArm(rawValue: arm)?.rawValue ?? "glass", forKey: TourCardMaterialArm.defaultsKey)
            return true
        }
        if path == "reset" {
            teardown()
            TourPersistence.reset(defaults)
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
        apply(effects, userCompletion: Self.isUserCompletion(event))
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

    /// Events that mean the USER just did something (as opposed to a launch,
    /// resume or skip that merely pre-fills already-done steps): only these
    /// play the completion feedback.
    private static func isUserCompletion(_ event: TourEvent) -> Bool {
        switch event {
        case .signal, .panelSettled, .panelTucked, .panelExpanded: return true
        default: return false
        }
    }

    private func apply(_ effects: [TourEffect], userCompletion: Bool) {
        var pops: [Int] = []
        var ringTo: Int?
        var spark = false
        var closes = false
        var confetti = false
        var haptics: [TourHaptic] = []
        // The finale (spec §B.3): the last step's card STAYS while the ring
        // closes and the confetti flies; the finale card takes over at the
        // handoff (the feedback calls `presentFinaleCard()`).
        let holdForFinale = userCompletion && cardStore != nil && lastPresentedModel != nil
            && effects.contains { if case .showFinaleCard = $0 { return true }; return false }
            && effects.contains { if case .growRing = $0 { return true }; return false }
        for effect in effects {
            switch effect {
            case .showWelcomeCard: connectDenied = false; presentCurrentCard()
            case .showStepCard: connectDenied = false; presentCurrentCard()
            case .showDeferralNote: presentCurrentCard()
            case .showFinaleCard: if !holdForFinale { presentCurrentCard() }
            case .showDeferredTipCard: presentCurrentCard()
            case .hideCard: hideCard()
            case .checkBeat(let step, let index):
                // Only a dot that is not yet solid on screen animates.
                let onScreen = cardStore?.model.beats ?? []
                let wasChecked = onScreen.indices.contains(index) ? onScreen[index].checked : false
                if patchDisplayedCard(fromLast: holdForFinale, { model in
                    guard model.beats.indices.contains(index), case .step(let shown) = model.kind, shown == step else { return false }
                    model.beats[index].checked = true
                    return true
                }), !wasChecked { pops.append(index) }
            case .growRing(let to):
                ringTo = to
                patchDisplayedCard(fromLast: holdForFinale) { model in model.ringCompleted = to; return true }
            case .spark: spark = true
            case .pulseRing: closes = true
            case .confetti: confetti = true
            case .haptic(let kind): haptics.append(kind)
            case .relocateCardToPanel: presentCurrentCard()
            case .persist: TourPersistence.save(state, to: defaults)
            case .armDeferredWatcher: armDeferredWatcher()
            case .cancelDeferredWatcher: deferredWatcher.cancel()
            case .teardown: teardown()
            }
        }
        if userCompletion, let store = cardStore, !pops.isEmpty || ringTo != nil {
            // The feedback owns the haptics of a completion (they land on the
            // frame the check lands / the ring seals, spec §B.8).
            beginFeedback(store: store, pops: pops, ringTo: ringTo, spark: spark, closes: closes,
                          confetti: confetti, holdForFinale: holdForFinale)
        } else {
            haptics.forEach { performHaptic($0) }
        }
        if closingFlashPending { closingFlashPending = false; scheduleClosingFlashHide() }
    }

    private func beginFeedback(store: TourCardStore, pops: [Int], ringTo: Int?, spark: Bool, closes: Bool,
                               confetti: Bool, holdForFinale: Bool) {
        let total = TourStep.orderedSteps.count
        var event = TourFeedbackEvent(ringFrom: ringTo ?? 0, ringTo: ringTo ?? 0, total: total, beatIndices: pops)
        if let to = ringTo {
            event.ringTo = to
            event.ringFrom = max(0, to - 1)
            event.closesRing = closes && to >= total
        }
        event.sparks = spark
        event.confetti = confetti
        if let window = cardWindow {
            event.ringCenterOnScreen = TourCardView.ringCenter(inWindowFrame: window.frame, beakSide: store.beakSide)
            event.cardFrameOnScreen = TourCardView.bodyFrame(inWindowFrame: window.frame, beakSide: store.beakSide)
        }
        var onSwapDue: (() -> Void)?
        if holdForFinale {
            // The finale card replaces the last step's card at the handoff.
            event.handsOff = true
            onSwapDue = { [weak self] in self?.presentFinaleCard() }
            scheduleFinaleCardFallback()
        } else if ringTo != nil, case .transitioning = state.phase {
            // The next step's card replaces this one at the handoff.
            event.handsOff = true
            onSwapDue = { [weak self] in self?.advanceTransitionNow() }
        }
        cardBounceBase = cardWindow?.frame.origin
        feedback.begin(event, onSwapDue: onSwapDue)
    }

    /// The feedback asked for the next step's card (its fade-out is done).
    private func advanceTransitionNow() {
        transitionWork?.cancel(); transitionWork = nil
        send(.advanceTransition)
    }

    private func presentFinaleCard() {
        finaleCardWork?.cancel(); finaleCardWork = nil
        guard case .finale = state.phase else { return }
        presentCurrentCard()
    }

    private func scheduleFinaleCardFallback() {
        finaleCardWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.presentFinaleCard() }
        finaleCardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: work)
    }

    /// Finale bounce: move the real card window (nothing clips at its edge).
    private func bounceCard(by dy: CGFloat) {
        let base = dy == 0 ? (cardPlacedOrigin ?? cardBounceBase) : cardBounceBase
        guard let window = cardWindow, let base else { return }
        window.setFrameOrigin(NSPoint(x: base.x, y: base.y - dy))
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
        TourCompletionFeedback.performSystemHaptic(kind)
    }

    // MARK: - Teardown (§11.2: zero standing cost afterward)

    private func teardown() {
        transitionWork?.cancel(); transitionWork = nil
        finaleWork?.cancel(); finaleWork = nil
        finaleCardWork?.cancel(); finaleCardWork = nil
        closingFlashWork?.cancel(); closingFlashWork = nil
        hideCard()
        TourAnchorRegistry.shared.reset()
    }

    /// Fully releases the overlay windows (not just orders them out) —
    /// §11.2's "结束后无窗口...effectViews 清单必须回到引导前" means the
    /// window OBJECTS must go, not just become invisible. Nothing else holds
    /// a strong reference to them, so dropping these is deinit or nothing.
    private func hideCard() {
        closingFlashWork?.cancel(); closingFlashWork = nil
        finaleCardWork?.cancel(); finaleCardWork = nil
        closingFlashPending = false
        lastPresentedModel = nil
        feedback.cancel()
        cardWindow?.contentView = nil
        cardWindow?.orderOut(nil)
        cardWindow = nil
        cardStore = nil
        haloWindow?.contentView = nil
        haloWindow?.orderOut(nil)
        haloWindow = nil
        haloStore = nil
    }

    // MARK: - Card content assembly (proposal §3.3/§9)

    private func presentCurrentCard() {
        guard let model = cardModel(for: state.phase) else { hideCard(); return }
        lastPresentedModel = model
        presentCard(model: model, gestureKind: gestureKind(for: state.phase))
    }

    /// Updates the card that is ALREADY on screen in place (a beat turned
    /// solid, the ring grew) — same window, same hosting view, same store —
    /// so the feedback animation has a live view to play on. The base is the
    /// current phase's card, or (when the reducer has already moved on to the
    /// transition/idle phase, e.g. the last step's completion or S4L's
    /// closing flash) the last card shown. Returns whether it changed.
    @discardableResult
    private func patchDisplayedCard(fromLast: Bool = false, _ patch: (inout TourCardModel) -> Bool) -> Bool {
        let live = fromLast ? nil : cardModel(for: state.phase)
        var model: TourCardModel
        if let live { model = live } else if let last = lastPresentedModel { model = last } else { return false }
        guard patch(&model) else { return false }
        lastPresentedModel = model
        if fromLast, let store = cardStore {
            // Finale hold: the card stays exactly where it is (re-placing it
            // would use the finale phase's anchor); a checked dot / longer
            // ring changes no layout.
            store.model = model
            return true
        }
        presentCard(model: model, gestureKind: live == nil ? nil : gestureKind(for: state.phase))
        if live == nil, case .idle = state.phase { closingFlashPending = true }
        return true
    }

    private func scheduleClosingFlashHide() {
        closingFlashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideCard() }
        closingFlashWork = work
        // The closing seal (disc, flash, halo) runs about 1.1s: let it finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + TourMotionPolicy.Tokens.stepCompletionFeedback + 0.25, execute: work)
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
                ringCompleted: state.completedCount, stepLabel: "\(state.completedCount)"
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
                ringCompleted: deferred ? total - 1 : total, ringClosed: !deferred,
                stepLabel: deferred ? "\(total - 1)" : ""
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
        guard let panel else { return nil }
        // Anchors are stored as SwiftUI global rects; placement runs in
        // screen space — convert through the panel's real hosting view.
        func screen(_ id: TourAnchorID) -> CGRect? { TourAnchorRegistry.shared.screenRect(for: id, in: panel) }
        switch state.phase {
        case .step(.reveal, _):
            return screen(.playPause)
        case .step(.corners, let beats):
            return screen(beats[0] ? .musicButton : .audioOutput)
        case .step(.lyrics, _):
            return screen(.lyricsNav)
        case .step(.translate, _), .deferredTip:
            return screen(.translate)
        case .transitioning(let from, _) where from == .translate:
            return screen(.translate)
        default:
            return panel.frame
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

    /// Places the card next to its anchor and puts `model` in it. The first
    /// call of a tour builds the window + hosting view; every later call only
    /// feeds the store and moves the window.
    private func presentCard(model: TourCardModel, gestureKind: TourGestureKind?) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let anchor = currentAnchorRect() ?? panel.frame
        ensureWindows()
        guard let store = cardStore, let window = cardWindow else { return }

        // Two passes: the beak's side (hence the window's width/height) is a
        // product of the placement, and the placement needs the size.
        var beakSide = store.beakSide
        var cardSize = CGSize(width: TourCardView.windowWidth(beakSide: .left), height: 150)
        var placement = TourCardPlacement(origin: .zero, beakSide: beakSide, beakOffset: 40)
        for _ in 0..<2 {
            cardSize = measureCardSize(model: model, beakSide: beakSide, gestureKind: gestureKind, arm: store.arm)
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
            if placement.beakSide == beakSide { break }
            beakSide = placement.beakSide
        }
        debugLastPlacement = placement
        debugLastAnchorRect = anchor

        let newContent = store.model.kind != model.kind || store.model.title != model.title
        // A different card is taking over while the completion feedback waits
        // for exactly that: the feedback already faded the old content out and
        // fades the new one in — no crossfade of our own on top of it.
        let feedbackHandoff = newContent && feedback.expectsSwap
        let apply = {
            store.beakSide = placement.beakSide
            store.beakOffset = placement.beakOffsetFromTop(cardHeight: cardSize.height)
            store.gestureKind = gestureKind
            store.model = model
            if newContent { store.contentKey += 1 }
        }
        if feedbackHandoff {
            apply()
            feedback.cardDidSwap()
        } else if newContent {
            feedback.cancel()
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { apply() } else {
                withAnimation(.easeOut(duration: TourMotionPolicy.Tokens.cardDismissDuration)) { apply() }
            }
        } else {
            apply()
        }

        window.hasShadow = store.arm.needsWindowShadow
        let target = NSRect(origin: placement.origin, size: cardSize)
        if window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window.frame != target {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = TourMotionPolicy.Tokens.cardTravelResponse
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.0, 0.5, 1.0)
                window.animator().setFrame(target, display: true)
            }
        } else {
            window.setFrame(target, display: true)
        }
        window.orderFront(nil)
        feedback.raiseOverlay()
        cardPlacedOrigin = target.origin

        positionHalo(anchor: anchor)
    }

    private func measureCardSize(model: TourCardModel, beakSide: TourCardSide, gestureKind: TourGestureKind?, arm: TourCardMaterialArm) -> CGSize {
        let view = TourCardView(model: model, beakSide: beakSide, beakOffset: 40, gestureKind: gestureKind, arm: arm, feedback: feedback)
        let hosting = TourHostingView(rootView: view)
        let width = TourCardView.windowWidth(beakSide: beakSide)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        let fitting = hosting.fittingSize
        return CGSize(width: width, height: max(fitting.height > 0 ? fitting.height : 150, 92))
    }

    private func positionHalo(anchor: CGRect) {
        guard let size = haloSize(for: state.phase) else {
            haloWindow?.orderOut(nil)
            haloStore?.appeared = false
            return
        }
        ensureWindows()
        guard let haloWindow, let haloStore else { return }
        let frame = NSRect(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2, width: size.width, height: size.height)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if haloWindow.isVisible {
            haloStore.size = size
            if reduce || haloWindow.frame == frame {
                haloWindow.setFrame(frame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.42
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.1, 0.4, 1.0)
                    haloWindow.animator().setFrame(frame, display: true)
                }
            }
        } else {
            haloStore.size = size
            haloStore.appeared = false
            haloWindow.setFrame(frame, display: true)
            haloWindow.orderFront(nil)
            DispatchQueue.main.async { haloStore.appeared = true }
        }
    }

    private func ensureWindows() {
        if cardWindow == nil {
            let store = TourCardStore(
                model: TourCardModel(kind: .welcome, title: "", body: "", ringCompleted: 0),
                feedback: feedback, arm: TourCardMaterialArm.current(defaults)
            )
            store.onPrimary = { [weak self] in self?.handlePrimary() }
            store.onSecondary = { [weak self] in self?.handleSecondary() }
            store.onStop = { [weak self] in self?.send(.stopTour) }
            store.onSkipStep = { [weak self] in self?.handleSkipStepOrDeniedContinue() }
            store.onFallback = { [weak self] in self?.handleFallback() }
            let window = TourCardWindow()
            window.contentView = TourHostingView(rootView: TourCardRoot(store: store))
            cardStore = store
            cardWindow = window
        }
        if haloWindow == nil {
            let store = TourHaloStore()
            let window = TourHaloWindow()
            window.contentView = TourHostingView(rootView: TourHaloRoot(store: store))
            haloStore = store
            haloWindow = window
        }
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
