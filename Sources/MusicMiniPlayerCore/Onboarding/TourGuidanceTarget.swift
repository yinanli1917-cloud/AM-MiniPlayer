/**
 * [INPUT]: TourModel's TourPhase/TourStep; TourAnchorRegistry's TourAnchorID;
 *          MusicController's PlayerPage; LiquidEdgeState.
 * [OUTPUT]: Exports TourRingSubject, TourRingMode, TourRingTarget, TourSurface,
 *           TourPanelHint, TourGuidanceResolver — the pure answer to "what is
 *           the ring on right now, and is it a hint or a press-now?".
 * [POS]: MusicMiniPlayerCore/Onboarding. Replaces the controller's old
 *        `currentAnchorRect`/`haloSize` switches, which pointed the ring at
 *        `beats[0] ? music : output` (so it vanished once the output beat
 *        ticked), at the panel frame for the tucked step (80pt off the strip),
 *        and were only evaluated once per card. No AppKit here: takes plain
 *        values, returns plain values, so `TourGuidanceResolverTests` can
 *        table-test every step / beat / page / control-visibility combination.
 *        Prototype section C: ring sizes C.4.1, dashed (hint) vs solid
 *        (press-now) C.4.1, "next unfinished beat" C.4.1 / C.5.3.
 */

import CoreGraphics

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Values
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// What the ring is drawn around.
public enum TourRingSubject: Equatable, Sendable {
    /// A control inside the panel (its rect comes from `TourAnchorRegistry`).
    case control(TourAnchorID)
    /// The tucked sliver at the screen edge.
    case sliver
    /// The capsule that peeks out of the sliver (`LiquidEdgeState.floating`).
    case peekCard
}

/// Prototype C.4.1: dashed / 0.7 = the thing is not reachable yet (a hint);
/// solid / 1.0 = press it now.
public enum TourRingMode: Equatable, Sendable {
    case hint, pressNow
}

public struct TourRingTarget: Equatable, Sendable {
    public var subject: TourRingSubject
    /// The ring's own size (independent of the control's real size: the
    /// prototype's 40 / 36 / 82x42 / 18x72 / 132x216).
    public var size: CGSize
    public var cornerRadius: CGFloat
    public var mode: TourRingMode

    public init(subject: TourRingSubject, size: CGSize, cornerRadius: CGFloat, mode: TourRingMode) {
        self.subject = subject
        self.size = size
        self.cornerRadius = cornerRadius
        self.mode = mode
    }

    static func circle(_ subject: TourRingSubject, _ diameter: CGFloat, _ mode: TourRingMode) -> TourRingTarget {
        TourRingTarget(subject: subject, size: CGSize(width: diameter, height: diameter), cornerRadius: diameter / 2, mode: mode)
    }
}

/// What the panel looks like right now, as far as the ring cares.
public struct TourSurface {
    public var page: PlayerPage
    /// The page's bottom/corner controls are shown (the mouse is over the panel).
    public var controlsVisible: Bool
    public var edge: LiquidEdgeState
    public var isPlaying: Bool

    public init(page: PlayerPage = .album, controlsVisible: Bool = false, edge: LiquidEdgeState = .card, isPlaying: Bool = false) {
        self.page = page
        self.controlsVisible = controlsVisible
        self.edge = edge
        self.isPlaying = isPlaying
    }
}

/// The panel-level hint (prototype C.4.2): shown instead of / next to a ring.
public enum TourPanelHint: Equatable, Sendable {
    case none
    /// Controls are hidden and the step needs the mouse over the panel:
    /// ghost cursor from the card's beak + panel-edge glow, both stopped the
    /// moment the mouse enters the panel.
    case hoverInvite
    /// The move step on the cover page: a soft glow around the panel edge
    /// says "this is the thing to push".
    case gestureInvite
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Resolver
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public enum TourGuidanceResolver {
    /// Ring sizes, prototype `haloGeo`.
    public static let controlDiameter: CGFloat = 40
    public static let lyricsDiameter: CGFloat = 36
    public static let musicSize = CGSize(width: 82, height: 42)
    public static let sliverSize = CGSize(width: 18, height: 72)
    public static let peekSize = CGSize(width: 132, height: 216)

    /// The ring drawn around `subject` (prototype `haloGeo`): size and corner radius.
    public static func ringShape(for subject: TourRingSubject) -> (size: CGSize, cornerRadius: CGFloat) {
        switch subject {
        case .control(.musicButton): return (musicSize, musicSize.height / 2)
        case .control(.lyricsNav): return (CGSize(width: lyricsDiameter, height: lyricsDiameter), lyricsDiameter / 2)
        case .control: return (CGSize(width: controlDiameter, height: controlDiameter), controlDiameter / 2)
        case .sliver: return (sliverSize, sliverSize.width / 2)
        case .peekCard: return (peekSize, 32)
        }
    }

    /// The control each beat of a step is about, in beat order (prototype
    /// `BEAT_TARGET`). Steps with one target return it for every beat.
    public static func beatSubjects(for step: TourStep) -> [TourRingSubject] {
        switch step {
        case .reveal: return [.control(.playPause), .control(.playPause)]
        case .corners: return [.control(.audioOutput), .control(.musicButton)]
        case .lyrics: return [.control(.lyricsNav)]
        case .translate: return [.control(.translate)]
        case .back: return [.sliver, .peekCard]
        case .moveTuck, .connect: return []
        }
    }

    /// The ring for `phase`, or nil when the step has no control to point at.
    /// `moveNeedsAlbumFirst`: the move step began with the panel on a page that
    /// cannot be nudged into a corner, so its first beat is "back to the cover".
    public static func target(phase: TourPhase, surface: TourSurface, moveNeedsAlbumFirst: Bool = false) -> TourRingTarget? {
        let mode: TourRingMode = surface.controlsVisible ? .pressNow : .hint
        switch phase {
        case .step(.reveal, _):
            return .circle(.control(.playPause), controlDiameter, mode)

        case .step(.corners, let beats):
            // The next UNFINISHED beat's control (either order is fine).
            if beats.indices.contains(0), !beats[0] { return .circle(.control(.audioOutput), controlDiameter, mode) }
            if beats.indices.contains(1), !beats[1] {
                return TourRingTarget(subject: .control(.musicButton), size: musicSize, cornerRadius: musicSize.height / 2, mode: mode)
            }
            return nil

        case .step(.lyrics, _):
            return .circle(.control(.lyricsNav), lyricsDiameter, mode)

        case .step(.translate, _), .deferredTip:
            let reachable = surface.page == .lyrics && surface.controlsVisible
            return .circle(.control(.translate), controlDiameter, reachable ? .pressNow : .hint)

        case .transitioning(let from, _) where from == .translate:
            return .circle(.control(.translate), controlDiameter, .hint)

        case .step(.moveTuck, _):
            // The only control the move step ever points at: the speech
            // bubble, which turns the lyrics page back into the cover.
            if moveNeedsAlbumFirst, surface.page != .album {
                return .circle(.control(.lyricsNav), lyricsDiameter, mode)
            }
            return nil

        case .step(.back, let beats):
            // The ring belongs to what is on screen at the edge NOW. Once the panel is on its way back
            // (`expanding`) or back (`card`) the strip and the peek card are gone, and a ring left on
            // their rect would hang over the returned panel (the click landed while the first beat's
            // feedback still played, so the ring was never taken down).
            switch surface.edge {
            case .card, .expanding: return nil
            case .tucked, .collapsing, .floating: break
            }
            if beats.indices.contains(0), !beats[0] {
                return TourRingTarget(subject: .sliver, size: sliverSize, cornerRadius: sliverSize.width / 2, mode: .pressNow)
            }
            if beats.indices.contains(1), !beats[1] {
                // The peek card exists only while it is out; between peeks the strip is what to point at.
                return surface.edge == .floating
                    ? TourRingTarget(subject: .peekCard, size: peekSize, cornerRadius: 32, mode: .pressNow)
                    : TourRingTarget(subject: .sliver, size: sliverSize, cornerRadius: sliverSize.width / 2, mode: .pressNow)
            }
            return nil

        default:
            return nil
        }
    }

    /// The panel-level hint for `phase` (ghost cursor + edge glow, or the
    /// gesture glow), independent of the ring.
    public static func panelHint(phase: TourPhase, surface: TourSurface) -> TourPanelHint {
        switch phase {
        case .step(.reveal, let beats):
            // Only while the mouse is not over the panel yet.
            return (beats.first == false && !surface.controlsVisible) ? .hoverInvite : .none
        case .step(.moveTuck, let beats):
            return (beats.contains(false) && surface.page == .album) ? .gestureInvite : .none
        default:
            return .none
        }
    }
}
