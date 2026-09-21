/**
 * [INPUT]: EdgePresentation (or the reduced VisualLayout), EdgeCollapseVariant,
 *          an estimated title width (CGFloat).
 * [OUTPUT]: EdgeCollapseLayout.rects(for:variant:titleWidth:) -> Frames
 *           (body + optional control CGRect, in the fixed 320×360 container's
 *           local top-left-origin coordinate space) + .hoverRegion(...) +
 *           .visualLayout(for:) + .estimatedTitleWidth(_:).
 * [POS]: Standalone spike for top-level task instruction #3/#4: pure geometry,
 *        no SwiftUI/AppKit import — app-portable, drives both rendering
 *        (RootContentView positions each glass shape at these rects) and
 *        hover-region hit-testing (EdgeCollapsePanel's NSTrackingArea).
 * [PROTOCOL]: Pure function — no @Published reads, no Animation, no side
 *             effects. Every returned rect must fit inside `containerSize`
 *             (nothing may extend past the fixed window's bounds).
 */

import CoreGraphics

public enum EdgeCollapseLayout {

    public static let containerSize = EdgeCollapseTokens.containerSize

    public struct Frames: Equatable, Sendable {
        public let body: CGRect
        public let control: CGRect?

        public init(body: CGRect, control: CGRect?) {
            self.body = body
            self.control = control
        }

        /// Union of body + control (or just body) — the "hover-exit target"
        /// before expansion (design §6: "hover-exit hit region is the UNION
        /// of the floating bodies").
        public var union: CGRect {
            guard let control else { return body }
            return body.union(control)
        }
    }

    /// The 5-case state machine collapses to 3 actual on-screen layouts —
    /// `collapsing`/`expanding` are mid-animation BETWEEN two of these, never
    /// a layout of their own (top-level task instruction #1: "in
    /// collapsing/expanding it is simply mid-animation between those
    /// layouts — there are no separate collapsing/expanding layouts").
    /// `collapsing`'s single `withAnimation` moves the shared `body` glass
    /// identity straight to the `tucked` target; `expanding`'s moves it
    /// straight to the `card` target.
    public enum VisualLayout: Equatable, Sendable {
        case card
        case tucked
        case floating
    }

    public static func visualLayout(for state: EdgePresentation) -> VisualLayout {
        switch state {
        case .card, .expanding: return .card
        case .tucked, .collapsing: return .tucked
        case .floating: return .floating
        }
    }

    /// Rough text-width estimate for the floating H info bar's title (no
    /// real text-measurement API in this pure/no-SwiftUI file) — a
    /// documented approximation, not a font-metrics measurement. Clamped
    /// by `rects(for:variant:titleWidth:)` against `floatingBarMinWidth`/
    /// `floatingBarMaxWidth` regardless, so this only needs to be in the
    /// right ballpark.
    public static func estimatedTitleWidth(_ title: String) -> CGFloat {
        let perCharacter: CGFloat = 7.2
        return CGFloat(title.count) * perCharacter
    }

    public static func rects(for state: EdgePresentation, variant: EdgeCollapseVariant, titleWidth: CGFloat) -> Frames {
        rects(forLayout: visualLayout(for: state), variant: variant, titleWidth: titleWidth)
    }

    public static func rects(forLayout layout: VisualLayout, variant: EdgeCollapseVariant, titleWidth: CGFloat) -> Frames {
        switch layout {
        case .card:
            let size = EdgeCollapseTokens.cardSize
            let rect = CGRect(
                x: containerSize.width - size.width,
                y: (containerSize.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            return Frames(body: rect, control: nil)

        case .tucked:
            let size = EdgeCollapseTokens.tuckedSize
            let rect = CGRect(
                x: containerSize.width - size.width,
                y: (containerSize.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            return Frames(body: rect, control: nil)

        case .floating:
            return floatingRects(variant: variant, titleWidth: titleWidth)
        }
    }

    private static func floatingRects(variant: EdgeCollapseVariant, titleWidth: CGFloat) -> Frames {
        let t = EdgeCollapseTokens.self
        let trailingX = containerSize.width - t.floatingEdgeGap
        let gap = t.floatingBodyControlGap

        switch variant {
        case .h:
            let barWidth = min(max(titleWidth + t.floatingBarHorizontalPadding, t.floatingBarMinWidth), t.floatingBarMaxWidth)
            let barHeight = t.floatingBarHeight
            let controlSize = t.floatingControlSizeH
            let totalHeight = barHeight + gap + controlSize.height
            let top = (containerSize.height - totalHeight) / 2
            let bodyRect = CGRect(x: trailingX - barWidth, y: top, width: barWidth, height: barHeight)
            let controlRect = CGRect(x: trailingX - controlSize.width, y: top + barHeight + gap, width: controlSize.width, height: controlSize.height)
            return Frames(body: bodyRect, control: controlRect)

        case .v:
            let dropSize = t.floatingDropSizeV
            let controlSize = t.floatingControlSizeV
            let totalHeight = dropSize.height + gap + controlSize.height
            let top = (containerSize.height - totalHeight) / 2
            let bodyRect = CGRect(x: trailingX - dropSize.width, y: top, width: dropSize.width, height: dropSize.height)
            let controlRect = CGRect(x: trailingX - controlSize.width, y: top + dropSize.height + gap, width: controlSize.width, height: controlSize.height)
            return Frames(body: bodyRect, control: controlRect)
        }
    }

    /// The active hover hit-region for a given state — union of body+control
    /// expanded by `expand` (top-level task instruction #3: "compute 'over a
    /// body' from the model's layout rects ... expanded by 12pt").
    public static func hoverRegion(for state: EdgePresentation, variant: EdgeCollapseVariant, titleWidth: CGFloat, expand: CGFloat) -> CGRect {
        rects(for: state, variant: variant, titleWidth: titleWidth).union.insetBy(dx: -expand, dy: -expand)
    }
}
