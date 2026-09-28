/**
 * [INPUT]: SwiftUI (PreferenceKey/GeometryReader), Combine (ObservableObject).
 * [OUTPUT]: Exports TourAnchorID, TourAnchorKey, `View.tourAnchor(_:active:)`,
 *           TourAnchorRegistry.
 * [POS]: MusicMiniPlayerCore/Onboarding. Screen-space frames for the six
 *        controls the tour points at (proposal §4.2/§6), collected the same
 *        way `PlaylistView.swift`'s `SectionOffsetKey` already does —
 *        `.background(GeometryReader{...preference...})` up, `.onPreferenceChange`
 *        down at the content root.
 */

import SwiftUI

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

    public func rect(for id: TourAnchorID) -> CGRect? { anchors[id] }

    /// Called once the tour tears down — a stale rect from a torn-down tour
    /// must never leak into the next run's first placement.
    public func reset() { anchors = [:] }
}
