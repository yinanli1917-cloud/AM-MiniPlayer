/**
 * [INPUT]: Combine (Publisher/PassthroughSubject), TourModel's TourEvent/TourSignal.
 * [OUTPUT]: Exports TourHookBus (the 3 new SwiftUI-side completion hooks),
 *           TourDetectors (merges every raw publisher into one `TourEvent`
 *           stream), TourTranslateReadiness, TourCornerMatch — pure helpers
 *           the detector and `SnappablePanel` both use; TourMusicReturn (does
 *           an app activation mean the user is back from the player app?).
 * [POS]: MusicMiniPlayerCore/Onboarding. Every publisher `TourDetectors`
 *        consumes is passed in by the caller (`TourController`, AppKit) —
 *        this file never reaches into `MusicController.shared` itself, so
 *        `TourDetectorTests` can substitute `PassthroughSubject`s for all of
 *        them (§11.1).
 */

import Combine
import CoreGraphics

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourHookBus
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The 3 genuinely new completion hooks (§6's "真正的新钩子" minus the two
/// that live on `SnappablePanel`/`LiquidEdgeController` directly). SwiftUI
/// views in this same module call these `.send()` directly — no
/// `NotificationCenter`, no new `@EnvironmentObject` (the views researched
/// for this feature already keep a minimal environment surface).
@MainActor
public final class TourHookBus {
    public static let shared = TourHookBus()

    /// `MiniPlayerView`/`LyricsView`'s `showOverlayContent`/`showControls`
    /// turning true for the first time this reveal (§6 "控件出现").
    public let controlsRevealed = PassthroughSubject<Void, Never>()
    /// `AudioOutputSwitcherView.onMenuPresentedChanged(true)` (§6 "音频输出列表打开").
    public let audioOutputMenuOpened = PassthroughSubject<Void, Never>()
    /// `MusicButtonView`'s action firing (§6 "↖ Music 点击").
    public let musicButtonTapped = PassthroughSubject<Void, Never>()
    /// Whether the CURRENT page's controls are on screen (the mouse is over the
    /// panel). Sent by the page that is showing: `MiniPlayerView` for the cover
    /// and queue pages, `LyricsView` for the lyrics page. The tour needs this
    /// level (not just the "revealed" edge) to tell a hint ring (control not
    /// reachable yet) from a press-now ring, and to stop the ghost cursor the
    /// moment the mouse arrives (prototype C.4.2).
    public let controlsVisible = CurrentValueSubject<Bool, Never>(false)

    private init() {}
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourTranslateReadiness
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// §3.3 S4's deferral trigger list — "无歌词 / 网络不可达 / 已是目标语言" all
/// collapse to `LyricsService.canTranslate == false`; "displayState 仍在
/// searching 超过 3 s" is the one case that ISN'T decided yet and gets a
/// short grace window instead of an instant "deferred" card, so a fast
/// fetch racing the tour doesn't lose to it.
public enum TourTranslateReadiness {
    /// True once `canTranslate` may be trusted as final for this song.
    public static func isDecided(isSearching: Bool, secondsSearching: Double) -> Bool {
        guard isSearching else { return true }
        return secondsSearching > 3
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourCornerMatch
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// §6 "落到角落" — pure form of the ±1pt corner test `SnappablePanel` runs
/// when a spring animation settles, factored out so it's testable without a
/// live `NSWindow`/`NSScreen`.
public enum TourCornerMatch {
    public static func corner(origin: CGPoint, frameSize: CGSize, visibleFrame: CGRect, margin: CGFloat, tolerance: CGFloat = 1) -> ScreenCorner? {
        let candidates: [(ScreenCorner, CGPoint)] = [
            (.topRight, CGPoint(x: visibleFrame.maxX - frameSize.width - margin, y: visibleFrame.maxY - frameSize.height - margin)),
            (.topLeft, CGPoint(x: visibleFrame.minX + margin, y: visibleFrame.maxY - frameSize.height - margin)),
            (.bottomRight, CGPoint(x: visibleFrame.maxX - frameSize.width - margin, y: visibleFrame.minY + margin)),
            (.bottomLeft, CGPoint(x: visibleFrame.minX + margin, y: visibleFrame.minY + margin))
        ]
        for (corner, point) in candidates {
            if abs(point.x - origin.x) <= tolerance, abs(point.y - origin.y) <= tolerance { return corner }
        }
        return nil
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourDetectors
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Merges every raw source into one `TourEvent` stream. All sources are
/// injected — `TourController` wires the real ones (`$isPlaying`,
/// `TourHookBus.shared.*`, `SnappablePanel.onSnappedToCorner`,
/// `LiquidEdgeController.statePublisher`, …); tests wire
/// `PassthroughSubject`s standing in for each.
///
/// `LiquidEdgeState` transitions map to signals/events like this (§3.3 S6,
/// §5.2): `.tucked` (settled) → `panelTucked`; `.floating` → `signal(.liquidEdgeFloating)`
/// (back's beat ①); `.expanding` → nothing on its own — only `.card` (settled,
/// arriving FROM `.expanding`) counts as `panelExpanded` (back's beat ②).
/// `.expanding` reverting mid-flight (hover exit before the click lands) must
/// NOT count as either beat, which is why `.card` is only mapped when the
/// PREVIOUS state was `.expanding`, not unconditionally.
public struct TourDetectors {
    public let events: AnyPublisher<TourEvent, Never>

    public init(
        automationAuthorized: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        controlsRevealed: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        isPlaying: AnyPublisher<Bool, Never> = Empty().eraseToAnyPublisher(),
        audioOutputMenuOpened: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        musicButtonTapped: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        currentPageIsLyrics: AnyPublisher<Bool, Never> = Empty().eraseToAnyPublisher(),
        showTranslationEnabled: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        snappedCorner: AnyPublisher<ScreenCorner, Never> = Empty().eraseToAnyPublisher(),
        liquidEdgeState: AnyPublisher<LiquidEdgeState, Never> = Empty().eraseToAnyPublisher()
    ) {
        let automation = automationAuthorized.map { TourEvent.signal(.automationAuthorized) }
        let reveal = controlsRevealed.map { TourEvent.signal(.controlsRevealed) }
        // Every emission is a toggle (the caller drops the initial value and
        // repeats): pausing counts exactly like playing.
        let playing = isPlaying.map { _ in TourEvent.signal(.isPlaying) }
        let output = audioOutputMenuOpened.map { TourEvent.signal(.audioOutputMenuOpened) }
        let musicButton = musicButtonTapped.map { TourEvent.signal(.musicButtonTapped) }
        let lyricsPage = currentPageIsLyrics.filter { $0 }.map { _ in TourEvent.signal(.onLyricsPage) }
        let translation = showTranslationEnabled.map { TourEvent.signal(.translationEnabled) }
        let corner = snappedCorner.map { TourEvent.panelSettled(corner: $0) }

        var previousLiquidState: LiquidEdgeState?
        let liquidEdge = liquidEdgeState.compactMap { state -> TourEvent? in
            defer { previousLiquidState = state }
            switch state {
            case .tucked where previousLiquidState != .tucked:
                return .panelTucked
            case .floating where previousLiquidState != .floating:
                return .signal(.liquidEdgeFloating)
            case .card where previousLiquidState == .expanding:
                return .panelExpanded
            default:
                return nil
            }
        }

        events = Publishers.MergeMany(
            automation.eraseToAnyPublisher(),
            reveal.eraseToAnyPublisher(),
            playing.eraseToAnyPublisher(),
            output.eraseToAnyPublisher(),
            musicButton.eraseToAnyPublisher(),
            lyricsPage.eraseToAnyPublisher(),
            translation.eraseToAnyPublisher(),
            corner.eraseToAnyPublisher(),
            liquidEdge.eraseToAnyPublisher()
        ).eraseToAnyPublisher()
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourMusicReturn
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The corners step's Music beat opens the player app, which animates in on its own. The tour holds its
/// celebration until the user is back; this is the "back" half that comes from app activation (the other
/// half is the cursor re-entering the panel).
public enum TourMusicReturn {
    /// Another app took the front. Not a return: the player app itself (it is the trip), and nanoPod's own
    /// activation (pressing the panel's capsule can activate us a beat BEFORE the player app comes up).
    public static func isReturn(activatedBundleID: String?, player: PlayerAppIdentity, ownBundleID: String?) -> Bool {
        guard let id = activatedBundleID, !id.isEmpty else { return false }
        if id == player.bundleIdentifier { return false }
        if let own = ownBundleID, id == own { return false }
        return true
    }
}
