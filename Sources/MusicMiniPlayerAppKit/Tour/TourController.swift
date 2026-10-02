/**
 * [INPUT]: AppKit/SwiftUI/Combine; MusicMiniPlayerCore's TourMachine/TourState/
 *          TourPersistence/TourDetectors/TourHookBus/TourDeferredWatcher/
 *          TourPlacement/TourAnchorRegistry/TourGuidanceResolver/TourMotionPolicy/
 *          OnboardingState/MusicController/LyricsService/SnappablePanel/
 *          LiquidEdgeController; this Tour/ folder's TourCardWindow/TourCardView
 *          (+TourCardStore)/TourCompletionFeedback/TourGuidance (motion shell).
 * [OUTPUT]: Exports TourController — the @MainActor effect executor that
 *           turns TourMachine's pure output into real windows.
 * [POS]: MusicMiniPlayerAppKit/Tour. Owned by AppMain; constructed once the
 *        floating panel and its LiquidEdgeController exist. This is the ONLY
 *        piece of the tour that touches a window, a timer, or a haptic.
 *        Two layers of "what is on screen": the CARD (content + placement,
 *        `presentCard`) and the GUIDANCE (the ring, the ghost cursor, the panel
 *        glow, `refreshGuidance`). The guidance is re-derived from live state
 *        (page, controls visible, anchors, edge state, panel frame) on every
 *        change — it used to be computed once per card, so it went stale the
 *        moment the panel's controls slid in.
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
    /// The ring / ghost cursor / panel-glow overlay (click-through, spans the panel's screen).
    private var haloWindow: TourHaloWindow?
    /// The motion behind the card's position and the ring (prototype section C).
    let guidance: TourGuidance
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
    private var releaseWork: DispatchWorkItem?
    private var skipWork: DispatchWorkItem?
    private var stallWork: DispatchWorkItem?
    private var resumeWork: DispatchWorkItem?
    private var storeObserver: AnyCancellable?
    private var connectDenied = false
    /// The last model actually shown — needed for the S4L-completion "closing
    /// flash" (§5.2's `deferredTip` completion): the reducer already flips
    /// `state.phase` to `.idle` in the SAME effects batch as the beat-check/
    /// ring-grow that's meant to flash on screen first, so there is no
    /// current-phase card model left to render at that point without this.
    private var lastPresentedModel: TourCardModel?
    /// S4L closing flash: hide the card once the feedback has had its second.
    private var closingFlashPending = false

    // The Music beat's trip to the player app (founder 2026-10-02: Music's own window animation plus our celebration at once is too much)
    /// The user tapped the Music capsule: the player app is opening. The beat shows its small check, nothing else happens
    /// (no ring, no celebration, no handoff) until the user is back. Costs nothing while it lasts: two subscriptions, no timer, no display link.
    private(set) var isHoldingForMusicReturn = false
    private var musicReturnObservers = Set<AnyCancellable>()
    /// Who the card names where the copy says "{player}" (the edition's player app).
    var playerApp: PlayerAppIdentity = .appleMusic
    /// App activations as bundle identifiers (test seam; default: NSWorkspace's didActivateApplicationNotification).
    var appActivations: AnyPublisher<String?, Never> = NSWorkspace.shared.notificationCenter
        .publisher(for: NSWorkspace.didActivateApplicationNotification)
        .map { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
        .eraseToAnyPublisher()
    var ownBundleIdentifier: String? = Bundle.main.bundleIdentifier

    // Guidance bookkeeping
    /// The current step began with the panel on a page that lacks its control (corners on the
    /// queue, translate off the lyrics page, move off the cover): its first beat walks the user
    /// to the right page. Fixed at step entry, so a step begun in the right place never grows one.
    private var preface: TourPreface?
    private var ringHeld = false
    private var ringHoldToken = 0
    private var lastRingSubject: TourRingSubject?
    private var entryGeneration = 0
    private var hintGeneration = -1
    /// The card stepped aside while the user moves the panel (C.2 "让路").
    private var cardYielded = false
    /// "这一步先不做" was pressed: the card shows the acknowledgement until the quiet transition.
    private var skipping = false
    /// The pose the handoff already started moving the card to (C.3 "H + 40").
    private var pendingHandoffPose: TourCardPose?
    private var measured: (key: TourCardLayoutKey, side: TourCardSide, gesture: TourGestureKind?, size: CGSize)?
    /// The system's Automation permission for Music (test seam: counting it proves which events pay for the query).
    var automationStatusProvider: () -> OnboardingAuthorizationStatus = { OnboardingState.shared.automationStatus }
    /// Where the card's anchor was when the card was last placed (a height change under the SAME anchor is a relayout, not a move).
    private var lastPlacedAnchorMidY: CGFloat?
    private var measuringHost: TourHostingView<TourCardView>?
    private let measuringFeedback = TourCompletionFeedback(autoTick: false)

    #if DEBUG || LOCAL_DEVELOPER_BUILD
    static var debugForceShow = false
    #endif

    /// Test seam (§11.1 TourTeardownTests): how many of the three overlay
    /// windows are currently allocated, and whether any of the timers
    /// (transition / finale auto-dismiss / closing-flash / release) are still armed.
    var debugAllocatedWindowCount: Int {
        [cardWindow != nil, haloWindow != nil, feedback.debugSparkOverlay.window != nil].filter { $0 }.count
    }
    var debugFeedback: TourCompletionFeedback { feedback }
    var debugCardStore: TourCardStore? { cardStore }
    var debugHasPendingTimers: Bool {
        transitionWork != nil || finaleWork != nil || closingFlashWork != nil || finaleCardWork != nil
            || releaseWork != nil || skipWork != nil || stallWork != nil || resumeWork != nil
    }
    var debugIsDeferredWatcherArmed: Bool { deferredWatcher.isArmed }
    /// Geometry seams for TourCardPlacementIntegrationTests (screen coordinates).
    var debugCardFrame: NSRect? { cardWindow?.frame }
    /// The ring's rect right now (springs included), nil when no ring is showing.
    var debugHaloFrame: NSRect? {
        let f = guidance.motion.makeFrame()
        return f.ringVisible && f.ringOpacity > 0.05 ? f.ring.rect : nil
    }
    var debugRingIsDashed: Bool { guidance.motion.makeFrame().ringDashed }
    var debugOverlayWindow: NSWindow? { haloWindow }
    var debugCardWindow: TourCardWindow? { cardWindow }
    private(set) var debugLastPlacement: TourCardPlacement?
    private(set) var debugLastAnchorRect: CGRect?

    init(panel: SnappablePanel, liquidEdge: LiquidEdgeController,
         musicController: MusicController = .shared, lyricsService: LyricsService = .shared,
         defaults: UserDefaults = .standard, feedback: TourCompletionFeedback? = nil, guidance: TourGuidance? = nil,
         gestureLogWriter: TourGestureLogWriter? = nil, traceGesturesAlways: Bool = false) {
        self.traceGesturesAlways = traceGesturesAlways
        self.defaults = defaults
        self.feedback = feedback ?? TourCompletionFeedback()
        self.guidance = guidance ?? TourGuidance()
        self.panel = panel
        self.liquidEdge = liquidEdge
        self.musicController = musicController
        self.lyricsService = lyricsService
        self.state = TourPersistence.load(from: defaults)
        self.gestureLogWriter = gestureLogWriter

        panel.onSnappedToCorner = { [weak self] _, corner in self?.snappedCornerSubject.send(corner) }
        self.feedback.applyCardOffset = { [weak self] dy in self?.bounceCard(by: dy) }
        self.feedback.onHandoffStart = { [weak self] in self?.handoffDidStart() }
        wireDetectors()
        wireGuidanceTriggers()
        if traceGesturesAlways { gestureTrace.start(panel: panel) }
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
    /// "Again" starts from the welcome card like a first run (it used to send
    /// `.start` and jumped straight to the second step, skipping the welcome).
    func requestTour(fromStart: Bool) {
        if fromStart {
            teardown()
            TourPersistence.reset(defaults)
            state = TourState()
            send(.launch)
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
            // Every CHANGE of playback is a toggle (initial value dropped): the
            // reveal step's second beat takes pause exactly like play.
            isPlaying: musicController.$isPlaying.dropFirst().removeDuplicates().eraseToAnyPublisher(),
            audioOutputMenuOpened: TourHookBus.shared.audioOutputMenuOpened.eraseToAnyPublisher(),
            musicButtonTapped: TourHookBus.shared.musicButtonTapped.eraseToAnyPublisher(),
            currentPageIsLyrics: musicController.$currentPage.map { $0 == .lyrics }.eraseToAnyPublisher(),
            // The translation switch changing in EITHER direction finishes the step.
            showTranslationEnabled: lyricsService.$showTranslation.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            snappedCorner: snappedCornerSubject.eraseToAnyPublisher(),
            liquidEdgeState: liquidEdge.statePublisher.eraseToAnyPublisher()
        )
        detectors.events.sink { [weak self] event in
            guard let self else { return }
            // Playback toggles OUTSIDE the tour (a track ending, Music's own play key) are not
            // the user answering the reveal step's question: they are never held back as an
            // "early" completion. (Hover, lyrics and translation early-completions are real
            // user acts and stay recorded.)
            if case .signal(.isPlaying) = event, case .idle = self.state.phase { return }
            self.send(event)
        }.store(in: &cancellables)
    }

    /// Everything the ring / card depend on that can change without a tour event.
    private func wireGuidanceTriggers() {
        TourHookBus.shared.controlsVisible.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.surfaceDidChange() }.store(in: &cancellables)
        TourAnchorRegistry.shared.$anchors.dropFirst()
            .sink { [weak self] _ in
                // @Published fires BEFORE the value lands: read it on the next turn.
                DispatchQueue.main.async { self?.refreshGuidance() }
            }.store(in: &cancellables)
        musicController.$currentPage.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.surfaceDidChange() } }.store(in: &cancellables)
        musicController.$isPlaying.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.surfaceDidChange() } }.store(in: &cancellables)
        liquidEdge.statePublisher.removeDuplicates()
            .sink { [weak self] edge in self?.edgeStateDidChange(edge) }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] _ in self?.panelDidMove() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: Notification.Name("windowMovementBegan"), object: panel)
            .sink { [weak self] _ in self?.panelMovementBegan() }.store(in: &cancellables)
    }

    // MARK: - Event pump

    /// `automationAuthorized` is read by the machine for `.start` ONLY (does the tour begin with Music already connected?),
    /// and reading it is a synchronous system query (`AEDeterminePermissionToAutomateTarget`: 30-45 ms on the main thread, it
    /// talks to the TCC daemon). It used to run on EVERY event, so every step completion paid it on the very frame its check
    /// began: the "laggy checkmark" (founder 2026-09-29). Now only `.start` pays.
    private func makeSnapshot(for event: TourEvent) -> TourSnapshot {
        var needsAutomation = false
        if case .start = event { needsAutomation = true }
        return TourSnapshot(
            automationAuthorized: needsAutomation && automationStatusProvider() == .authorized,
            canTranslate: lyricsService.canTranslate,
            showTranslation: lyricsService.showTranslation,
            onLyricsPage: musicController.currentPage == .lyrics
        )
    }

    /// Internal (not `private`) so tests can drive the machine directly via
    /// `@testable import` without hosting real button clicks.
    func send(_ event: TourEvent) {
        if case .signal(.musicButtonTapped) = event, beginMusicHoldIfNeeded() { return }
        process(event)
    }

    private func process(_ event: TourEvent) {
        let (next, effects) = TourMachine.reduce(state, event, snapshot: makeSnapshot(for: event))
        let previous = state
        state = next
        noteStepEntry(previous: previous.phase, next: next.phase)
        apply(effects, userCompletion: Self.isUserCompletion(event))
        scheduleTransitionIfNeeded()
        scheduleFinaleAutoDismissIfNeeded()
        if isHoldingForMusicReturn, !Self.isCornersStep(state.phase) { endMusicHold() }   // skipped, stopped or moved on while away
        refreshGuidance()
    }

    // MARK: - Music beat: hold while the user is in the player app

    private static func isCornersStep(_ phase: TourPhase) -> Bool {
        if case .step(.corners, _) = phase { return true }
        return false
    }

    /// The Music capsule was tapped on the corners step with that beat still open: tick only its small check, say
    /// "pick up when you're back", and wait. Returns false when this tap is not that moment (the machine takes it as usual).
    private func beginMusicHoldIfNeeded() -> Bool {
        guard !isHoldingForMusicReturn, case .step(.corners, let beats) = state.phase, beats.count == 2, !beats[1] else { return false }
        isHoldingForMusicReturn = true
        stallWork?.cancel(); stallWork = nil
        cardStore?.stalled = false
        // Back = the cursor enters the panel again (a real false -> true, not the hover the tap itself came from),
        // or another app takes the front. Whichever first. No timeout: while the user is still in the player app, we wait.
        var sawAway = !TourHookBus.shared.controlsVisible.value
        TourHookBus.shared.controlsVisible.removeDuplicates().sink { [weak self] visible in
            if !visible { sawAway = true } else if sawAway { self?.musicReturned() }
        }.store(in: &musicReturnObservers)
        appActivations.sink { [weak self] id in
            guard let self, TourMusicReturn.isReturn(activatedBundleID: id, player: self.playerApp, ownBundleID: self.ownBundleIdentifier) else { return }
            self.musicReturned()
        }.store(in: &musicReturnObservers)
        // The beat's check, alone: the body crossfades to the waiting line, the ring goes down.
        if let model = cardModel(for: state.phase, in: state) {
            lastPresentedModel = model
            presentCard(model: model, gestureKind: nil)
            if let store = cardStore { beginFeedback(store: store, pops: [1], ringTo: nil, spark: false, closes: false, confetti: false, holdForFinale: false) }
        }
        refreshGuidance()
        return true
    }

    private func musicReturned() {
        guard isHoldingForMusicReturn else { return }
        endMusicHold()
        process(.signal(.musicButtonTapped))   // the tap, delivered now: the usual celebration and transition
    }

    private func endMusicHold() {
        isHoldingForMusicReturn = false
        musicReturnObservers.removeAll()
    }

    /// Per-step bookkeeping that is not part of the pure machine.
    private func noteStepEntry(previous: TourPhase, next: TourPhase) {
        guard case .step(let step, _) = next else { preface = nil; return }
        if case .step(let was, _) = previous, was == step { return }
        preface = TourPreface.needed(for: step, on: musicController.currentPage)
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
        // handoff (the feedback calls `presentFinaleCard()`). Unless that card
        // already left: clicking the peek card starts the panel's return, and the
        // old card steps out of its way first (below); then the finale card grows
        // in and the ring closes on IT.
        let holdForFinale = userCompletion && cardStore != nil && lastPresentedModel != nil && guidance.motion.cardVisible
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
                let wasChecked = onScreen.first { $0.id == index }?.checked ?? false
                if patchDisplayedCard(fromLast: holdForFinale, { model in
                    guard let at = model.beats.firstIndex(where: { $0.id == index }), case .step(let shown) = model.kind, shown == step else { return false }
                    model.beats[at].checked = true
                    return true
                }), !wasChecked { pops.append(index) }
            case .growRing(let to):
                ringTo = to
                patchDisplayedCard(fromLast: holdForFinale) { model in model.ringCompleted = to; return true }
            case .spark: spark = true
            case .pulseRing: closes = true
            case .confetti: confetti = true
            case .haptic(let kind): haptics.append(kind)
            case .relocateCardToPanel: cardYielded = false; presentCurrentCard()
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
            let target = guidance.motion.targetPose
            // The window may be mid-approach — or not yet the size of the card that is arriving (the finale card
            // replaces a shorter one): the sparks and the confetti fly from where the card WILL rest, at the size
            // it WILL have. (Only the origin was taken from the pose before: with a stale height the ring centre
            // and the confetti's launch line were ~165pt below the real ones.)
            var frame = window.frame
            if let target { frame = NSRect(x: target.x, y: target.top - target.height, width: target.width, height: target.height) }
            event.ringCenterOnScreen = TourCardView.ringCenter(inWindowFrame: frame, beakSide: store.beakSide)
            event.cardFrameOnScreen = TourCardView.bodyFrame(inWindowFrame: frame, beakSide: store.beakSide)
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

    // MARK: - Gesture trace (evidence for "the two-finger drag stops working during the tour")

    /// Always on while the tour is on screen, nothing standing outside it (`TourGestureTrace`): per two-finger gesture, where it
    /// went, what the panel decided, what the tour was doing; a gesture that looks like a failure is written to
    /// `~/Library/Logs/nanoPod/tour-gesture.log` (off the main thread). Started with the tour's windows, stopped when they go.
    private let gestureLogWriter: TourGestureLogWriter?
    private(set) lazy var gestureTrace = TourGestureTrace(
        environment: TourGestureTrace.Environment(
            page: { [weak self] in self.map { "\($0.musicController.currentPage)" } ?? "gone" },
            tourState: { [weak self] in self.map { Self.traceDescription(of: $0.state.phase) } ?? "gone" },
            cardYielded: { [weak self] in self?.cardYielded ?? false }
        ),
        writer: gestureLogWriter ?? TourGestureFileWriter()
    )

    private func installGestureTrace() {
        guard let panel, !gestureTrace.isRunning else { return }
        gestureTrace.start(panel: panel)
    }

    private func removeGestureTrace() {
        guard !traceGesturesAlways else { return }
        gestureTrace.stop()
    }

    /// 2026-10-01: the founder can't two-finger-drag the panel even with the tour closed, and nothing covers the panel —
    /// so for now the same cheap trace (ring buffer; a failed-looking gesture is written off-main) runs for the whole app
    /// session, not just the tour. Remove once the cause is pinned.
    private let traceGesturesAlways: Bool

    private static func traceDescription(of phase: TourPhase) -> String {
        switch phase {
        case .idle(let armed): return "idle(deferredArmed:\(armed))"
        case .welcome: return "welcome"
        case .step(let step, let beats): return "step(\(step.rawValue) beats:\(beats.map { $0 ? "1" : "0" }.joined()))"
        case .transitioning(let from, let to): return "transitioning(\(from?.rawValue ?? "-")->\(to?.rawValue ?? "-"))"
        case .finale: return "finale"
        case .deferredTip(let step): return "deferredTip(\(step.rawValue))"
        }
    }

    // MARK: - Teardown (§11.2: zero standing cost afterward)

    private func teardown() {
        transitionWork?.cancel(); transitionWork = nil
        finaleWork?.cancel(); finaleWork = nil
        finaleCardWork?.cancel(); finaleCardWork = nil
        closingFlashWork?.cancel(); closingFlashWork = nil
        skipWork?.cancel(); skipWork = nil
        skipping = false
        cardYielded = false
        preface = nil
        endMusicHold()
        hideCard()
        TourAnchorRegistry.shared.reset()
    }

    /// The card steps out (C.2: 0.16 s ease-in, toward its anchor), the ring and
    /// the hints go with it, then every overlay window is released — the window
    /// OBJECTS must go, not just become invisible (§11.2), so a second later
    /// nothing of the tour is left. With Reduce Motion, or when nothing is on
    /// screen, it is immediate.
    private func hideCard(approach: Double? = nil) {
        closingFlashWork?.cancel(); closingFlashWork = nil
        finaleCardWork?.cancel(); finaleCardWork = nil
        stallWork?.cancel(); stallWork = nil
        resumeWork?.cancel(); resumeWork = nil
        closingFlashPending = false
        lastPresentedModel = nil
        feedback.cancel()
        ringHeld = false
        ringHoldToken += 1
        lastRingSubject = nil
        guard cardWindow != nil || haloWindow != nil else { releaseWindows(); return }
        guidance.syncReduceMotion()
        if guidance.motion.cardVisible, !guidance.motion.reduceMotion {
            guidance.motion.dismissCard(approach: approach ?? TourGuidanceTokens.disappearApproach)
            guidance.motion.hideRing()
            guidance.motion.stopHint()
            guidance.kick()
            releaseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.releaseWindows() }
            releaseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TourGuidanceTokens.disappearDuration + 0.06, execute: work)
        } else {
            releaseWindows()
        }
    }

    private func releaseWindows() {
        releaseWork?.cancel(); releaseWork = nil
        guidance.stop()
        guidance.attach(card: nil, overlay: nil)
        guidance.reset()
        storeObserver = nil
        cardWindow?.contentView = nil
        cardWindow?.orderOut(nil)
        cardWindow = nil
        cardStore = nil
        haloWindow?.contentView = nil
        haloWindow?.orderOut(nil)
        haloWindow = nil
        feedback.releaseOverlay()
        removeGestureTrace()
        pendingHandoffPose = nil
        measured = nil
        measuringHost = nil
        lastPlacedAnchorMidY = nil
    }

    // MARK: - Card content assembly (proposal §3.3/§9)

    private func presentCurrentCard() {
        guard let model = cardModel(for: state.phase, in: state) else { hideCard(); return }
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
        let live = fromLast ? nil : cardModel(for: state.phase, in: state)
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

    private func cardModel(for phase: TourPhase, in state: TourState) -> TourCardModel? {
        let L = { (key: String) in L10n.localized(key) }
        let total = TourStep.orderedSteps.count
        let surface = currentSurface()

        /// Body text for the steps that need the controls out (prototype C.5.3):
        /// while the mouse is away the card asks for it back.
        func awayOr(_ text: String) -> String {
            surface.controlsVisible ? text : L("tour.body.away")
        }

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
            // Ask for the action the panel actually offers (pause while playing,
            // play while paused); either toggle finishes the beat.
            let playing = surface.isPlaying
            let beat2 = playing ? L("tour.reveal.beat2pause") : L("tour.reveal.beat2")
            var body = L("tour.reveal.body")
            var pending = false
            if beats[0], !beats[1] {
                if surface.controlsVisible {
                    body = L(playing ? "tour.reveal.bodyArmedPause" : "tour.reveal.bodyArmedPlay")
                    pending = true
                } else {
                    body = L("tour.body.away")
                }
            }
            var list = [TourBeatModel(id: 0, text: L("tour.reveal.beat1"), checked: beats[0]),
                        TourBeatModel(id: 1, text: beat2, checked: beats[1])]
            list[1].pending = pending
            markSkipped(&list)
            return TourCardModel(
                kind: .step(.reveal), title: L("tour.reveal.title"), body: skipBody() ?? body, beats: list,
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.reveal.index(in: total))"
            )

        case .step(.corners, let beats):
            var list: [TourBeatModel] = []
            var body = beats.allSatisfy { $0 } ? L("tour.corners.body") : awayOr(L("tour.corners.body"))
            if isHoldingForMusicReturn {
                body = L("tour.corners.bodyWaiting")                                       // away in the player app: wait for them
            } else if beats[0], !beats[1] {
                body = awayOr(L10n.localized("tour.corners.bodyMusic", player: playerApp)) // the Music beat is current: say where the tap goes
            }
            if preface == .leaveQueue {
                // Not a machine beat: the corner buttons are not on the queue page.
                let there = TourPreface.leaveQueue.isDone(on: surface.page)
                list.append(TourBeatModel(id: 2, text: L("tour.corners.beat0"), checked: there || beats.contains(true)))
                if !there { body = L("tour.corners.bodyQueue") }
            }
            list.append(TourBeatModel(id: 0, text: L("tour.corners.beat1"), checked: beats[0]))
            list.append(TourBeatModel(id: 1, text: L("tour.corners.beat2"), checked: beats[1] || isHoldingForMusicReturn))
            markSkipped(&list)
            return TourCardModel(
                kind: .step(.corners), title: L("tour.corners.title"),
                body: skipBody() ?? body, beats: list,
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.corners.index(in: total))"
            )

        case .step(.lyrics, let beats):
            var list = [TourBeatModel(id: 0, text: L("tour.lyrics.beat1"), checked: beats[0])]
            markSkipped(&list)
            return TourCardModel(
                kind: .step(.lyrics), title: L("tour.lyrics.title"), body: skipBody() ?? awayOr(L("tour.lyrics.body")), beats: list,
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.lyrics.index(in: total))"
            )

        case .step(.translate, let beats):
            var list: [TourBeatModel] = []
            var body = awayOr(L("tour.translate.body"))
            if preface == .toLyrics {
                // Not a machine beat: the translate button exists only on the lyrics page.
                let there = TourPreface.toLyrics.isDone(on: surface.page)
                list.append(TourBeatModel(id: 2, text: L("tour.translate.beat0"), checked: there || beats[0]))
                if !there { body = L("tour.translate.bodyGoLyrics") }
            }
            list.append(TourBeatModel(id: 0, text: L("tour.translate.beat1"), checked: beats[0]))
            markSkipped(&list)
            return TourCardModel(
                kind: .step(.translate), title: L("tour.translate.title"), body: skipBody() ?? body, beats: list,
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.translate.index(in: total))"
            )

        case .step(.moveTuck, let beats):
            let tucked = beats[0]
            let onAlbum = surface.page == .album
            let rightward = (panel?.currentCorner() == .topRight || panel?.currentCorner() == .bottomRight) || liquidEdge.side != .left
            let body: String
            if tucked { body = L(rightward ? "tour.move.bodyTuckRight" : "tour.move.bodyTuckLeft") }
            else if !onAlbum { body = L("tour.move.bodyLyrics") }
            else { body = L("tour.move.body") }
            var list: [TourBeatModel] = []
            if preface == .backToCover {
                // Not a machine beat: a precondition the card walks the user through.
                list.append(TourBeatModel(id: 2, text: L("tour.move.beat0"), checked: onAlbum || tucked))
            }
            list.append(TourBeatModel(id: 0, text: L("tour.move.beat1"), checked: beats[0]))
            list.append(TourBeatModel(id: 1, text: L("tour.move.beat2"), checked: beats[1]))
            markSkipped(&list)
            var model = TourCardModel(
                kind: .step(.moveTuck),
                title: L("tour.move.title"),
                body: skipBody() ?? body,
                beats: list,
                secondaryTitle: L("tour.move.forMe"), footNote: L("tour.move.mouseNote"),
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.moveTuck.index(in: total))"
            )
            model.showFallbackButton = true
            return model

        case .step(.back, let beats):
            var list = [TourBeatModel(id: 0, text: L("tour.back.beat1"), checked: beats[0]),
                        TourBeatModel(id: 1, text: L("tour.back.beat2"), checked: beats[1])]
            markSkipped(&list)
            return TourCardModel(
                kind: .step(.back), title: L("tour.back.title"), body: skipBody() ?? "", beats: list,
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
                kind: .deferredTip, title: L("tour.later.title"), body: awayOr(L("tour.later.body")),
                ringCompleted: state.completedCount, stepLabel: "\(TourStep.translate.index(in: total))"
            )
            model.showStop = true; model.showSkipStep = false
            return model
        }
    }

    /// "这一步先不做" pressed: the unchecked dots turn dashed (C.5.4).
    private func markSkipped(_ beats: inout [TourBeatModel]) {
        guard skipping else { return }
        for i in beats.indices where !beats[i].checked { beats[i].skipped = true; beats[i].pending = false }
    }

    private func skipBody() -> String? { skipping ? L10n.localized("tour.skip.ack") : nil }

    /// The two-finger demo the CURRENT beat asks for, nil when the current beat has nothing to demonstrate.
    /// The move step's beats, in order: (leading, only off the cover) go back to the cover page -> nudge it to a
    /// corner -> push it into the edge. The demo belongs to the last two: on the leading beat the user is being
    /// walked to another page and a trackpad picture would be teaching a gesture that does not work there
    /// (founder 2026-09-29: it showed on "Back to the cover page").
    private func gestureKind(for phase: TourPhase) -> TourGestureKind? {
        guard case .step(.moveTuck, let beats) = phase, beats.count >= 2 else { return nil }
        if !beats[0] {
            return musicController.currentPage == .album ? .nudgeToCorner : nil
        }
        let rightward = (panel?.currentCorner() == .topRight || panel?.currentCorner() == .bottomRight) || liquidEdge.side != .left
        return .swipeToEdge(rightward: rightward)
    }

    // MARK: - Surface, anchors, targets

    private func currentSurface() -> TourSurface {
        TourSurface(page: musicController.currentPage, controlsVisible: TourHookBus.shared.controlsVisible.value,
                    edge: liquidEdge.state, isPlaying: musicController.isPlaying)
    }

    private func isSliverAnchored(_ phase: TourPhase) -> Bool {
        if case .step(.back, _) = phase { return true }
        if case .deferredTip = phase, liquidEdge.isActive { return true }
        return false
    }

    /// The screen rect of what the ring points at. Controls that have never been
    /// rendered (they only exist while hovered) fall back to their resting layout.
    private func rect(for subject: TourRingSubject) -> CGRect? {
        guard let panel else { return nil }
        switch subject {
        case .control(let id):
            return TourAnchorRegistry.shared.resolvedScreenRect(for: id, in: panel)
        case .sliver:
            let r = liquidEdge.tuckedRegionInScreen
            return r.isEmpty ? nil : r
        case .peekCard:
            let hit = liquidEdge.floatingHitRegionInScreen
            if !hit.isEmpty { return hit }
            let r = liquidEdge.tuckedRegionInScreen
            return r.isEmpty ? nil : r
        }
    }

    /// The rect the CARD points its beak at (and sits beside).
    private func cardAnchorRect(for phase: TourPhase) -> CGRect {
        guard let panel else { return .zero }
        if case .step(.moveTuck, _) = phase { return panel.frame }
        if let target = TourGuidanceResolver.target(phase: phase, surface: currentSurface(), preface: preface),
           let r = rect(for: target.subject) { return r }
        return panel.frame
    }

    // MARK: - Placement

    private struct Placed {
        var placement: TourCardPlacement
        var size: CGSize
        var anchor: CGRect
        var pose: TourCardPose
    }

    private func computePlacement(model: TourCardModel, phase: TourPhase, gestureKind: TourGestureKind?, arm: TourCardMaterialArm, currentSide: TourCardSide) -> Placed? {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return nil }
        let visibleFrame = screen.visibleFrame
        let anchor = cardAnchorRect(for: phase)

        // Two passes: the beak's side (hence the window's width/height) is a
        // product of the placement, and the placement needs the size.
        var beakSide = currentSide
        var cardSize = CGSize(width: TourCardView.windowWidth(beakSide: .left), height: 150)
        var placement = TourCardPlacement(origin: .zero, beakSide: beakSide, beakOffset: 40)
        for _ in 0..<2 {
            cardSize = measureCardSize(model: model, beakSide: beakSide, gestureKind: gestureKind, arm: arm)
            // (Until the panel has really tucked there is no strip to stand beside: the
            // regions are empty and the card would land 292pt off the screen's left edge.)
            if isSliverAnchored(phase), !liquidEdge.tuckedRegionInScreen.isEmpty {
                let edge: TourCardSide = liquidEdge.side == .left ? .left : .right
                let region = liquidEdge.tuckedRegionInScreen
                // The card stands 20pt off whatever is on screen at the edge: the strip while it is a
                // strip, the peek capsule's region only while the capsule is out. (The capsule's padded
                // hit region is ~150pt wide and exists as geometry even when only the strip is showing:
                // measuring from it left the beak ~160pt short of the strip.)
                let occupied = liquidEdge.state == .floating && !liquidEdge.floatingHitRegionInScreen.isEmpty
                    ? liquidEdge.floatingHitRegionInScreen : region
                placement = TourPlacement.placeNearSliver(
                    cardSize: cardSize, sliverEdge: edge,
                    floatingHitRegion: occupied,
                    sliverMidY: region.midY, visibleFrame: visibleFrame
                )
            } else {
                placement = TourPlacement.placeNearPanel(cardSize: cardSize, anchor: anchor, panelFrame: panel.frame, visibleFrame: visibleFrame)
            }
            if placement.beakSide == beakSide { break }
            beakSide = placement.beakSide
        }
        // A card that stands beside the whole panel (the move step) still points its beak at what the
        // ring is on right now, so the beak follows the ring when it changes control within the step.
        if case .step(.moveTuck, _) = phase,
           let target = TourGuidanceResolver.target(phase: phase, surface: currentSurface(), preface: preface),
           let aim = rect(for: target.subject) {
            placement = TourPlacement.aimBeak(placement, atMidY: aim.midY, cardHeight: cardSize.height)
        }
        let pose = TourCardPose(
            x: placement.origin.x, top: placement.origin.y + cardSize.height, width: cardSize.width, height: cardSize.height,
            beakSide: placement.beakSide, beakOffset: placement.beakOffsetFromTop(cardHeight: cardSize.height)
        )
        return Placed(placement: placement, size: cardSize, anchor: anchor, pose: pose)
    }

    private func measureCardSize(model: TourCardModel, beakSide: TourCardSide, gestureKind: TourGestureKind?, arm: TourCardMaterialArm) -> CGSize {
        if let m = measured, m.key == model.layoutKey, m.side == beakSide, m.gesture == gestureKind { return m.size }
        #if DEBUG
        let measureBegan = CACurrentMediaTime()
        defer { TourPerfProbe.mark(String(format: "measure card %.1fms", (CACurrentMediaTime() - measureBegan) * 1000)) }
        #endif
        // The footer's links and buttons only render when their handlers exist; a
        // measuring copy WITHOUT handlers is one footer row (~14pt) shorter than
        // the live card — the second reason the bottom links were cut off.
        // (A measuring copy is not fed the live feedback object: its frames never change the card's height, and a
        // hosting view subscribed to them would be re-evaluated on every feedback tick for nothing.)
        let view = TourCardView(model: model, beakSide: beakSide, beakOffset: 40, gestureKind: gestureKind, arm: arm, feedback: measuringFeedback,
                                onPrimary: {}, onSecondary: {}, onStop: {}, onSkipStep: {}, onFallback: {})
        // ONE measuring hosting view for the whole tour: building a hosting view is most of what a measure costs, and a
        // measure lands on the frame a check or a handoff is being drawn.
        let hosting: TourHostingView<TourCardView>
        if let existing = measuringHost { existing.rootView = view; hosting = existing }
        else { hosting = TourHostingView(rootView: view); measuringHost = hosting }
        let width = TourCardView.windowWidth(beakSide: beakSide)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        let fitting = hosting.fittingSize
        // No silent fallback height: a made-up size is what clipped every card
        // (fittingSize was (0, 0) and 150 was used instead).
        assert(fitting.height > 0, "TourHostingView must report its content size")
        let size = CGSize(width: width, height: max(fitting.height, 92))
        measured = (model.layoutKey, beakSide, gestureKind, size)
        return size
    }

    /// Places the card next to its anchor and puts `model` in it (C.2 / C.3).
    /// The first call of a tour builds the window + hosting view; every later
    /// call only feeds the store and moves the window through the guidance motion.
    private func presentCard(model: TourCardModel, gestureKind: TourGestureKind?) {
        guard panel != nil else { return }
        releaseWork?.cancel(); releaseWork = nil
        ensureWindows()
        guard let store = cardStore, let window = cardWindow else { return }
        guidance.syncReduceMotion()
        let phase = state.phase
        guard let placed = computePlacement(model: model, phase: phase, gestureKind: gestureKind, arm: store.arm, currentSide: store.beakSide) else { return }
        debugLastPlacement = placed.placement
        debugLastAnchorRect = placed.anchor
        let motion = guidance.motion
        // After a completion the phase is already "transitioning" (or idle, for the closing flash)
        // while the finished step's card is still up, checking its last dot: that card STAYS where it
        // is — re-placing it for a phase that has no anchor sent it toward the panel's middle at the
        // very moment it should sit still. The handoff moves it to the next anchor (C.3).
        var holdsPlace = false
        switch state.phase {
        case .transitioning(let from, _): holdsPlace = from != .translate
        case .idle: holdsPlace = true
        default: break
        }
        var pose = placed.pose
        if holdsPlace, motion.cardVisible, let target = motion.targetPose { pose = target }

        let newContent = store.model.kind != model.kind || store.model.title != model.title
        let appearing = !motion.cardVisible
        // A different card is taking over while the completion feedback waits
        // for exactly that: the feedback already faded the old content out and
        // fades the new one in — no fade of our own on top of it.
        let feedbackHandoff = !appearing && newContent && feedback.expectsSwap
        window.hasShadow = store.arm.needsWindowShadow

        func commit(_ store: TourCardStore, bumpKey: Bool) {
            store.beakSide = pose.beakSide
            store.beakOffset = CGFloat(pose.beakOffset)
            store.gestureKind = gestureKind
            store.model = model
            if bumpKey { store.contentKey += 1 }
        }

        if appearing {
            // First appearance, or the card is coming back after stepping aside.
            entryGeneration += 1
            commit(store, bumpKey: newContent)
            motion.presentCard(at: pose)
            motion.setGlyph(present: gestureKind != nil, animated: false)
            raiseTourWindows()
            holdRing(for: 0.3)
            scheduleStallHint()
        } else if feedbackHandoff {
            // C.3: the move already started at the handoff (H + 40 ms); the
            // content swaps now, the ring comes back 0.42 s later.
            entryGeneration += 1
            commit(store, bumpKey: true)
            motion.setGlyph(present: gestureKind != nil, animated: false)
            if pendingHandoffPose != pose { motion.moveCard(to: pose, delay: 0) }
            pendingHandoffPose = nil
            feedback.cardDidSwap()
            holdRing(for: 0.42)
            scheduleStallHint()
        } else if newContent {
            // A quiet step-to-step transition (skip, welcome -> first step, a
            // deferral note): fade out, move, swap, fade in — no tick, no sparks.
            feedback.cancel()
            entryGeneration += 1
            pendingHandoffPose = nil
            motion.hideRing()
            motion.stopHint()
            lastRingSubject = nil
            motion.fadeContentOut()
            motion.moveCard(to: pose)
            motion.schedule(after: 0.14) { [weak self] in
                guard let self, let store = self.cardStore else { return }
                commit(store, bumpKey: true)
                self.guidance.motion.setGlyph(present: gestureKind != nil, animated: false)
                self.guidance.motion.staggerContentIn()
            }
            holdRing(for: 0.56)
            raiseTourWindows()
            scheduleStallHint()
        } else {
            // Same card: a beat turned solid, the body text changed, the anchor moved.
            let bodyChanged = store.model.body != model.body
            // The demo comes and goes with the beat: it grows in (fades, scales in) when the beat that asks for the
            // gesture becomes current and folds away when it is done — on the card's own height spring, which the
            // re-measured pose below retargets in the same instant. A different demo replays from the top.
            let previousKind = store.gestureKind
            store.gestureKind = gestureKind
            guidance.motion.setGlyph(present: gestureKind != nil, animated: true, restart: previousKind != nil && gestureKind != nil && previousKind != gestureKind)
            if bodyChanged {
                motion.crossfadeBody { [weak self] in
                    guard let store = self?.cardStore else { return }
                    store.model = model
                }
            } else if store.model != model {
                store.model = model
            }
            store.beakSide = pose.beakSide
            store.beakOffset = CGFloat(pose.beakOffset)
            if let target = motion.targetPose, target != pose {
                // Same spot = the same x and the same ANCHOR (the card is centred on its anchor, clamped to the screen, so a
                // taller card's top moves and can even clamp: that is still the same anchor, and it must spring like the
                // height — treating it as an anchor move made the height wait 0.1 s and the demo band outgrow its bubble).
                if abs(target.x - pose.x) < 0.5, target.beakSide == pose.beakSide,
                   let was = lastPlacedAnchorMidY, abs(was - placed.anchor.midY) < 0.5 {
                    motion.relayoutCard(to: pose)        // same spot, new height / beak
                } else {
                    motion.moveCard(to: pose, delay: 0)  // the anchor moved (the ring jumped to the next control)
                }
            }
        }
        cardPlacedOrigin = NSPoint(x: pose.x, y: pose.top - pose.height)
        lastPlacedAnchorMidY = placed.anchor.midY
        feedback.raiseOverlay()
        guidance.kick()
    }

    /// The panel goes to the front of its level at every step, so a floating
    /// window from another app can no longer sit over it and swallow the hover
    /// and the two-finger gesture the step asks for (item 9). The tour's own
    /// windows live one level higher and are never re-ordered under it.
    private func raiseTourWindows() {
        gestureTrace.noteRaise()
        if let panel, panel.isVisible, !liquidEdge.isActive { panel.orderFrontRegardless() }
        cardWindow?.orderFront(nil)
        // (The ring overlay orders itself in when it has something to draw, and out when it has not.)
    }

    private func ensureWindows() {
        if cardWindow == nil {
            let store = TourCardStore(
                model: TourCardModel(kind: .welcome, title: "", body: "", ringCompleted: 0),
                feedback: feedback, arm: TourCardMaterialArm.current(defaults), guidance: guidance.store
            )
            store.onPrimary = { [weak self] in self?.handlePrimary() }
            store.onSecondary = { [weak self] in self?.handleSecondary() }
            store.onStop = { [weak self] in self?.send(.stopTour) }
            store.onSkipStep = { [weak self] in self?.handleSkipStepOrDeniedContinue() }
            store.onFallback = { [weak self] in self?.handleFallback() }
            store.onBeatHover = { [weak self] id, inside in self?.beatHovered(id, inside: inside) }
            store.onGlyphReplay = { [weak self] in
                self?.guidance.motion.replayGlyph()
                self?.guidance.kick()
            }
            let window = TourCardWindow(store: store)
            window.isDriven = true
            window.onContentSizeChanged = { [weak self] in self?.relayoutFromStore() }
            // The content is clipped to the driven height, so the hosting view cannot
            // say "I need more room" by itself: a model that changes under the window
            // (copy, font, state) is re-measured here.
            storeObserver = store.$model.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.relayoutFromStore() }
            }
            cardStore = store
            cardWindow = window
        }
        if haloWindow == nil {
            let window = TourHaloWindow()
            window.contentView = TourHostingView(rootView: TourGuidanceOverlayView(store: guidance.store.overlayStore))
            haloWindow = window
        }
        if let panel {
            // The overlay is sized to what it draws and stays parked until it draws something (TourGuidance);
            // it may grow anywhere on the panel's screen.
            guidance.screenFrame = { [weak panel] in (panel?.screen ?? NSScreen.main)?.frame ?? .zero }
            guidance.store.panelFrame = panel.frame
            TourFrameDriver.shared.screenProvider = { [weak panel] in panel?.screen ?? NSScreen.main }
        }
        guidance.attach(card: cardWindow, overlay: haloWindow)
        feedback.prewarmOverlay()
        installGestureTrace()
    }

    // MARK: - Ring, hints (prototype C.4)

    /// The ring stays down for `delay` seconds of motion time, then comes back.
    private func holdRing(for delay: Double) {
        ringHeld = true
        ringHoldToken += 1
        let token = ringHoldToken
        guidance.motion.schedule(after: delay) { [weak self] in
            guard let self, token == self.ringHoldToken else { return }
            self.ringHeld = false
            self.refreshGuidance()
        }
    }

    private func ringGeometry(for target: TourRingTarget, rect: CGRect) -> TourRingGeometry {
        TourRingGeometry(cx: rect.midX, cy: rect.midY, w: target.size.width, h: target.size.height, corner: target.cornerRadius)
    }

    /// Re-derives the ring, the ghost cursor and the panel glow from live state.
    /// Idempotent: called on every send, anchor change, page change, hover
    /// change, edge-state change and panel move.
    func refreshGuidance() {
        guard cardWindow != nil, let panel else { return }
        guidance.syncReduceMotion()
        let motion = guidance.motion
        guidance.store.panelFrame = panel.frame
        // Between a completion and the next card the ring belongs to the handoff.
        if case .transitioning(let from, _) = state.phase, from != .translate { return }
        if feedback.isActive, case .finale = state.phase { return }
        if cardYielded || skipping { return }
        if isHoldingForMusicReturn {
            // Away in the player app: the ring stops pulsing and goes down, nothing runs until they are back.
            if motion.ringVisible { motion.hideRing() }
            if motion.hintRunning { motion.stopHint() }
            lastRingSubject = nil
            guidance.kick()
            return
        }
        if ringHeld { return }

        let surface = currentSurface()
        let target = TourGuidanceResolver.target(phase: state.phase, surface: surface, preface: preface)
        if let target, let rect = rect(for: target.subject) {
            let geo = ringGeometry(for: target, rect: rect)
            if !motion.ringVisible || lastRingSubject != target.subject {
                motion.showRing(geo, mode: target.mode)
            } else {
                motion.retargetRing(geo)
                motion.setRingMode(target.mode)
            }
            lastRingSubject = target.subject
        } else {
            motion.hideRing()
            lastRingSubject = nil
        }

        // Panel-level hints: ONCE per step entry, and they stop the moment they no longer apply.
        switch TourGuidanceResolver.panelHint(phase: state.phase, surface: surface) {
        case .hoverInvite:
            if hintGeneration != entryGeneration {
                hintGeneration = entryGeneration
                motion.startHover(target: CGPoint(x: panel.frame.minX + panel.frame.width * 0.6, y: panel.frame.maxY - panel.frame.height * 0.669))
            }
        case .gestureInvite:
            if hintGeneration != entryGeneration {
                hintGeneration = entryGeneration
                motion.startGestureGlow()
            }
        case .none:
            if motion.hintRunning { motion.stopHint() }
        }
        guidance.kick()
    }

    /// A beat row was hovered: the ring temporarily points at that beat's
    /// control (C.4.1); leaving puts it back. A step with a single control just pulses.
    private func beatHovered(_ id: Int, inside: Bool) {
        guard case .step(let step, _) = state.phase, guidance.motion.ringVisible, !isHoldingForMusicReturn else { return }
        if !inside { refreshGuidance(); return }
        let subjects = TourGuidanceResolver.beatSubjects(for: step)
        let subject: TourRingSubject?
        if id == 2 { subject = preface == nil ? nil : .control(.lyricsNav) }   // the leading beat: the bubble
        else if step == .moveTuck { subject = nil }
        else { subject = subjects.indices.contains(id) ? subjects[id] : nil }
        guard let subject, subject != lastRingSubject, let rect = rect(for: subject) else {
            guidance.motion.pulseRing()
            guidance.kick()
            return
        }
        let shape = TourGuidanceResolver.ringShape(for: subject)
        guidance.motion.peekRing(TourRingGeometry(cx: rect.midX, cy: rect.midY, w: shape.size.width, h: shape.size.height, corner: shape.cornerRadius))
        guidance.kick()
    }

    // MARK: - Live state changes

    /// The page, the controls' visibility or playback changed: the card's text
    /// (body, beat labels) and the ring's mode may both need to follow.
    private func surfaceDidChange() {
        guard cardWindow != nil, !skipping, !cardYielded else { return }
        if case .transitioning(let from, _) = state.phase, from != .translate { return }
        if feedback.isActive { return }
        if cardModel(for: state.phase, in: state) != nil, guidance.motion.cardVisible, cardStore?.model != nil {
            presentCurrentCard()
        }
        refreshGuidance()
    }

    private func edgeStateDidChange(_ edge: LiquidEdgeState) {
        // Clicking the peek card starts the panel's return. The card stood 20pt from
        // the capsule, right where the returning panel lands: it steps out first
        // (0.16 s, C.2), and the finale card grows in once the panel is back.
        if edge == .expanding, case .step(.back, _) = state.phase, guidance.motion.cardVisible, !feedback.isActive {
            guidance.motion.dismissCard()
            guidance.motion.hideRing()
            guidance.motion.stopHint()
            guidance.kick()
            return
        }
        // The strip / peek regions only exist once the panel has tucked: the sliver-anchored
        // card and the ring find their place then.
        if cardWindow != nil {
            DispatchQueue.main.async { [weak self] in
                self?.surfaceDidChange()
                self?.refreshGuidance()
            }
        }
    }

    private func panelDidMove() {
        guard cardWindow != nil else { return }
        refreshGuidance()
        // A moving panel is not chased by the card: when it holds still again the card returns.
        if cardYielded { scheduleResume() }
    }

    private func panelMovementBegan() {
        #if DEBUG
        TourPerfProbe.mark("panel movement began")
        #endif
        guard cardWindow != nil, guidance.motion.cardVisible, !cardYielded, !feedback.isActive, !skipping else { return }
        if isSliverAnchored(state.phase) { return }
        switch state.phase {
        case .step, .welcome, .deferredTip, .finale: break
        default: return
        }
        cardYielded = true
        gestureTrace.noteYield(true)
        guidance.motion.dismissCard()
        guidance.motion.hideRing()
        guidance.motion.stopHint()
        lastRingSubject = nil
        guidance.kick()
        scheduleResume()
    }

    /// Debounced: comes back once the panel has been still for 0.4 s.
    private func scheduleResume() {
        resumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resumeWork = nil
            guard self.cardYielded else { return }
            self.cardYielded = false
            self.gestureTrace.noteYield(false)
            #if DEBUG
            TourPerfProbe.mark("resume after yield")
            #endif
            self.presentCurrentCard()
            self.refreshGuidance()
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Spec C.3 "H": the completion feedback is about to fade the old content
    /// out. The ring fades, the hints stop, and the card starts moving to where
    /// the next card goes — 40 ms in, the content swaps 100 ms after that.
    private func handoffDidStart() {
        guard cardWindow != nil, let store = cardStore else { return }
        guidance.syncReduceMotion()
        guidance.motion.hideRing()
        guidance.motion.stopHint()
        lastRingSubject = nil
        let nextState: TourState
        switch state.phase {
        case .transitioning(_, _):
            (nextState, _) = TourMachine.reduce(state, .advanceTransition, snapshot: makeSnapshot(for: .advanceTransition))
        case .finale:
            nextState = state
        default:
            guidance.kick()
            return
        }
        guard let model = cardModel(for: nextState.phase, in: nextState),
              let placed = computePlacement(model: model, phase: nextState.phase, gestureKind: gestureKind(for: nextState.phase),
                                            arm: store.arm, currentSide: store.beakSide) else { guidance.kick(); return }
        pendingHandoffPose = placed.pose
        guidance.motion.moveCard(to: placed.pose)
        guidance.kick()
    }

    /// The card's content wants a different height than the pose it is heading
    /// for (its text changed under a live window): spring the height, same top
    /// edge, same beak tip.
    private func relayoutFromStore() {
        guard let store = cardStore, guidance.motion.cardVisible, let target = guidance.motion.targetPose else { return }
        let size = measureCardSize(model: store.model, beakSide: store.beakSide, gestureKind: store.gestureKind, arm: store.arm)
        guard abs(size.height - target.height) > 0.5 else { return }
        var pose = target
        pose.height = size.height
        guidance.motion.relayoutCard(to: pose)
        guidance.kick()
    }

    private func scheduleStallHint() {
        stallWork?.cancel()
        cardStore?.stalled = false
        let work = DispatchWorkItem { [weak self] in
            self?.stallWork = nil
            self?.cardStore?.stalled = true
        }
        stallWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
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

    /// "这一步先不做" (C.5.4): the unfinished dots turn dashed, the body says
    /// "OK, we'll leave that for later", then a quiet transition (no tick, no
    /// sparks, no haptic) moves on. A retreat, not a punishment: no confirmation.
    private func handleSkipStepOrDeniedContinue() {
        if case .step(.connect, _) = state.phase, connectDenied {
            connectDenied = false
            send(.skipStep)
            return
        }
        guard case .step(let step, _) = state.phase, step != .connect, !skipping, !feedback.isActive else {
            send(.skipStep)
            return
        }
        skipping = true
        guidance.syncReduceMotion()
        guidance.motion.hideRing()
        guidance.motion.stopHint()
        lastRingSubject = nil
        presentCurrentCard()
        skipWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.skipWork = nil
            self.skipping = false
            self.send(.skipStep)
        }
        skipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (guidance.motion.reduceMotion ? 0.3 : 0.55), execute: work)
    }

    private func handleFallback() {
        guard case .step(.moveTuck, _) = state.phase else { return }
        panel?.hideToNearestEdge()
    }

    private func connectMusic() {
        OnboardingState.shared.requestAutomationAccess()
        if automationStatusProvider() == .authorized {
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
