/**
 * [INPUT]: SwiftUI (PreferenceKey/GeometryReader), Combine (ObservableObject).
 * [OUTPUT]: Exports TourAnchorID, TourAnchorKey, `View.tourAnchor(_:active:)`,
 *           TourAnchorRegistry (+ `screenRect(for:in:)` — the ONLY place a
 *           SwiftUI global rect becomes an AppKit screen rect).
 * [POS]: MusicMiniPlayerCore/Onboarding. Screen-space frames for the six
 *        controls the tour points at (proposal §4.2/§6), collected the same
 *        way `PlaylistView.swift`'s `SectionOffsetKey` already does —
 *        `.background(GeometryReader{...preference...})` up, `.onPreferenceChange`
 *        down at the content root.
 */

import SwiftUI
import AppKit

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourAnchorID
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// One per control the tour ever anchors a card/halo to (§4.2 item 1). The
/// tucked sliver and floating hit-region are NOT here — those come straight
/// from `LiquidEdgeController` (§4.2 item 2), which already knows its own
/// screen rects without going through SwiftUI preferences.
public enum TourAnchorID: String, CaseIterable, Sendable {
    case playPause
    case musicButton
    case audioOutput
    case lyricsNav
    case translate
    case artwork
}

public struct TourAnchorKey: PreferenceKey {
    public static var defaultValue: [TourAnchorID: CGRect] = [:]
    public static func reduce(value: inout [TourAnchorID: CGRect], nextValue: () -> [TourAnchorID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

public extension View {
    /// Publishes this view's frame (screen/global space by default) as the
    /// tour anchor `id`, but ONLY while `active` — §4.2: "未激活时修饰符不发
    /// preference", so a control that's currently hidden (not hovered) never
    /// overwrites the registry's last-known rect with a zero one.
    func tourAnchor(_ id: TourAnchorID, active: Bool = true, coordinateSpace: CoordinateSpace = .global) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TourAnchorKey.self,
                    value: active ? [id: geo.frame(in: coordinateSpace)] : [:]
                )
            }
        )
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourAnchorRegistry
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Last-known screen rect per anchor. A zero rect is never stored — the
/// panel's `.onPreferenceChange` calls `update` on every body evaluation,
/// including ones where an inactive `.tourAnchor` contributed nothing for
/// its id, and `update` simply leaves that id's last value alone.
@MainActor
public final class TourAnchorRegistry: ObservableObject {
    public static let shared = TourAnchorRegistry()

    @Published public private(set) var anchors: [TourAnchorID: CGRect] = [:]

    public func update(_ incoming: [TourAnchorID: CGRect]) {
        for (id, rect) in incoming where rect != .zero {
            if anchors[id] != rect { anchors[id] = rect }
        }
    }

    /// The raw rect exactly as SwiftUI published it: `.global` space =
    /// the panel's HOSTING VIEW, top-left origin, y down. NOT a screen rect
    /// (the 2026-09-29 bug: it was fed straight into the screen-space
    /// placement math, so the card landed in the screen's lower-left).
    public func rect(for id: TourAnchorID) -> CGRect? { anchors[id] }

    /// The anchor as an AppKit SCREEN rect (bottom-left origin, y up) for the
    /// panel `window` it was published from. Follows the window: the stored
    /// rect is window-relative, so a moved panel needs no re-registration.
    public func screenRect(for id: TourAnchorID, in window: NSWindow) -> CGRect? {
        guard let global = anchors[id] else { return nil }
        return Self.screenRect(forGlobal: global, in: window)
    }

    /// Hosting-view (SwiftUI `.global`) rect -> screen rect. Goes through
    /// the real hosting view, so the panel's 32pt-taller hosting view
    /// (PanelWindowMetrics) and any future geometry change are handled by
    /// AppKit instead of a hardcoded offset.
    public static func screenRect(forGlobal rect: CGRect, in window: NSWindow) -> CGRect {
        let host = PanelWindowMetrics.hostingView(in: window)
        let inHost = host.isFlipped
            ? rect
            : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return window.convertToScreen(host.convert(inHost, to: nil))
    }

    /// Called once the tour tears down — a stale rect from a torn-down tour
    /// must never leak into the next run's first placement.
    public func reset() { anchors = [:] }
}
