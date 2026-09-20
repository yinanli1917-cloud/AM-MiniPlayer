/**
 * [INPUT]: EdgePresentation (current state) + EdgeCollapseEvent
 * [OUTPUT]: EdgeCollapseReducer.reduce(state:event:) -> EdgePresentation
 * [POS]: Standalone spike for research/edge-collapse-redesign-2026-09-19.md §2.
 *        App-portable pure state machine — no SwiftUI/AppKit import, safe to
 *        lift into Sources/MusicMiniPlayerCore verbatim (replaces the design
 *        doc's placeholder "SnapEvent 五个事件改名对应" note).
 * [PROTOCOL]: The reduce() switch MUST stay exhaustive over all 5 states ×
 *             5 events (25 cells). A cell with no defined transition in
 *             design §2/§4 returns the SAME state (no-op) rather than being
 *             omitted — never add a `default:` catch-all, so the compiler
 *             keeps this file honest when a 6th state/event is added.
 */

/// The five settled/transitional presentations from design §2. `collapsing`
/// and `expanding` are themselves animated transitions (one gesture/click ==
/// one uninterrupted morph), not just "in progress" flags — see design §0's
/// critique of the old two-step version.
public enum EdgePresentation: String, CaseIterable, Equatable, Sendable {
    case card
    case collapsing
    case tucked
    case floating
    case expanding
}

/// Which screen edge a collapse targets. Design §3 note: only left/right are
/// handled; up/down never trigger collapse (menu bar / Dock in the way).
public enum EdgeCollapseEdge: Equatable, Sendable {
    case left
    case right
}

/// design §2: `collapseRequested(edge)`, `hoverEntered`, `hoverExited`,
/// `expandRequested`, `settled`. (`reduceMotionChanged` is a side input to
/// the clock scheduler, not a state-machine event — it never changes WHICH
/// state we're in, only how we animate getting there.)
public enum EdgeCollapseEvent: Equatable, Sendable {
    case collapseRequested(EdgeCollapseEdge)
    case hoverEntered
    case hoverExited
    case expandRequested
    case settled
}

public enum EdgeCollapseReducer {
    /// Pure, exhaustive 5×5 transition table. Any (state, event) pair not
    /// explicitly called out in design §2/§4 is a no-op — the state does not
    /// change. This satisfies "unknown-event no-op": there is no truly
    /// "unknown" Swift enum case (the compiler forbids that), so the
    /// portable contract is instead "every UNDEFINED transition is a no-op",
    /// which the exhaustive `default: return state` per case enforces.
    public static func reduce(state: EdgePresentation, event: EdgeCollapseEvent) -> EdgePresentation {
        switch state {
        case .card:
            switch event {
            case .collapseRequested:
                return .collapsing
            case .hoverEntered, .hoverExited, .expandRequested, .settled:
                return .card
            }

        case .collapsing:
            switch event {
            case .settled:
                return .tucked
            case .collapseRequested, .hoverEntered, .hoverExited, .expandRequested:
                // Mid-gesture: one collapse is already an uninterrupted morph
                // (design §0), so nothing else can interrupt or re-trigger it.
                return .collapsing
            }

        case .tucked:
            switch event {
            case .hoverEntered:
                return .floating
            case .expandRequested:
                // §4 table, tucked row, click column: "浮出并展开" — a click
                // on the narrow stalk pops out and expands in one go; there is
                // no dedicated "popping out" state, so it goes straight to
                // `.expanding` (the expand clock plan reads the resting
                // tucked frame as its geometry start).
                return .expanding
            case .collapseRequested, .hoverExited, .settled:
                return .tucked
            }

        case .floating:
            switch event {
            case .hoverExited:
                return .tucked
            case .expandRequested:
                return .expanding
            case .collapseRequested, .hoverEntered, .settled:
                return .floating
            }

        case .expanding:
            switch event {
            case .settled:
                return .card
            case .collapseRequested, .hoverEntered, .hoverExited, .expandRequested:
                return .expanding
            }
        }
    }
}
