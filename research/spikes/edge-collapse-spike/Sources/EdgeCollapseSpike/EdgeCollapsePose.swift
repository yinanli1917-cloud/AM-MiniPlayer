/**
 * [INPUT]: EdgePresentation + variant + title width.
 * [OUTPUT]: EdgeCollapsePose — every animatable channel of the whole
 *           composition (body frame + corner radii, control offset, hero
 *           artwork frame, material swap, content opacities) — plus
 *           `EdgeCollapsePlan`: which spring/delay each channel gets for a
 *           given transition. Channels are animated separately so the shape
 *           leads, the second body drips off later, and content lands last
 *           (the stagger the three reference videos show).
 * [POS]: App-portable pure data; no SwiftUI views.
 * [PROTOCOL]: Poses are pure functions of state; the model applies a plan by
 *             issuing one withAnimation PER CHANNEL, all in the same frame.
 */

import SwiftUI

public struct EdgeCollapsePose: Equatable {
    // Body (glass id "body")
    public var bodyRect: CGRect
    public var cornerInner: CGFloat   // corners facing the screen interior
    public var cornerEdge: CGFloat    // corners touching the screen edge
    // Control body (glass id "control"): rect where it sits; parked inside body when hidden
    public var controlRect: CGRect
    public var controlContentOpacity: Double
    // Hero artwork
    public var heroRect: CGRect
    public var heroCorner: CGFloat
    // Material tint blend: 1 = glass tinted with the artwork's one colour (panel look), 0 = black tint (edge look)
    public var artworkTint: Double
    // Content groups
    public var cardContentOpacity: Double
    public var barTextOpacity: Double
    public var contentBlur: CGFloat   // ref4: content blurs while shapes morph
    public var progressOpacity: Double
}

public enum EdgeCollapsePoses {
    static var container: CGSize { EdgeCollapseTokens.containerSize }

    public static func pose(for layout: EdgeCollapseLayout.VisualLayout, variant: EdgeCollapseVariant, titleWidth: CGFloat) -> EdgeCollapsePose {
        let t = EdgeCollapseTokens.self
        switch layout {
        case .card:
            let s = t.cardSize
            let body = CGRect(x: container.width - s.width, y: (container.height - s.height) / 2, width: s.width, height: s.height)
            // Fullscreen-cover layout (nanoPod default): cover fills the width, flush top.
            let hero = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.width)
            return EdgeCollapsePose(
                bodyRect: body, cornerInner: t.cardCornerRadius, cornerEdge: t.cardCornerRadius,
                controlRect: parked(in: body), controlContentOpacity: 0,
                heroRect: hero, heroCorner: t.cardCornerRadius,
                artworkTint: 1, cardContentOpacity: 1, barTextOpacity: 0, contentBlur: 0, progressOpacity: 0)

        case .tucked:
            // Docked pill (vertical only, v7): cover on top, pause ring + next
            // inside the same pill (the control body is parked inside it).
            let s = t.dockSize
            let body = CGRect(x: container.width - s.width, y: (container.height - s.height) / 2, width: s.width, height: s.height)
            let a = t.dockArtwork
            let hero = CGRect(x: body.minX + (s.width - a) / 2, y: body.minY + 8, width: a, height: a)
            let control = CGRect(x: body.minX + 4, y: hero.maxY + 6, width: s.width - 8, height: body.maxY - hero.maxY - 12)
            return EdgeCollapsePose(
                bodyRect: body, cornerInner: t.dockCornerRadius, cornerEdge: 0,
                controlRect: control, controlContentOpacity: 1,
                heroRect: hero, heroCorner: 12,
                artworkTint: 0, cardContentOpacity: 0, barTextOpacity: 0, contentBlur: 0, progressOpacity: 1)

        case .floating:
            // Hover: the pill widens off the edge, shows title/artist under a
            // bigger cover, and the controls drip off into their own body.
            let w = t.hoverWidth
            let a = t.hoverArtwork
            let bodyH = 12 + a + 6 + t.hoverTextHeight + 12
            let c = t.hoverControlSize
            let total = bodyH + t.floatingBodyControlGap + c.height
            let top = (container.height - total) / 2
            let trailingX = container.width - t.floatingEdgeGap
            let body = CGRect(x: trailingX - w, y: top, width: w, height: bodyH)
            let hero = CGRect(x: body.midX - a / 2, y: body.minY + 12, width: a, height: a)
            let control = CGRect(x: trailingX - c.width, y: body.maxY + t.floatingBodyControlGap, width: c.width, height: c.height)
            return EdgeCollapsePose(
                bodyRect: body, cornerInner: t.hoverCornerRadius, cornerEdge: t.hoverCornerRadius,
                controlRect: control, controlContentOpacity: 1,
                heroRect: hero, heroCorner: 16,
                artworkTint: 0, cardContentOpacity: 0, barTextOpacity: 1, contentBlur: 0, progressOpacity: 0)
        }
    }

    /// Control body parked fully inside the body so the container unions it away.
    static func parked(in body: CGRect) -> CGRect {
        let w = min(EdgeCollapseTokens.floatingControlSizeH.width, body.width - 4)
        let h = min(EdgeCollapseTokens.floatingControlSizeH.height, body.height - 4)
        return CGRect(x: body.midX - w / 2, y: body.midY - h / 2, width: max(w, 2), height: max(h, 2))
    }
}

/// Per-channel animation for one transition. Delays are what make the
/// second body drip off and the content trail behind the shape.
public struct EdgeCollapsePlan {
    public var bodyHeight: Animation
    public var bodyWidth: Animation
    public var bodyPosition: Animation
    public var corners: Animation
    public var control: Animation
    public var hero: Animation
    public var material: Animation
    public var cardContent: Animation
    public var barText: Animation
    public var progress: Animation

    public static func plan(for kind: EdgeCollapseTransitionKind, bounce: EdgeCollapseBounce, tempo: EdgeCollapseTempo) -> EdgeCollapsePlan {
        let k = tempo.rawValue
        func spring(_ d: Double, _ b: Double, delay: Double = 0) -> Animation {
            .spring(duration: d * k, bounce: b).delay(delay * k)
        }
        func ease(_ d: Double, delay: Double = 0) -> Animation {
            .easeInOut(duration: d * k).delay(delay * k)
        }
        let stalkBounce = bounce == .bouncy ? 0.45 : 0.35
        switch kind {
        case .collapse:
            // height collapses first (video 1), width pinches into a stalk with
            // rebound, the stalk travels to the edge last, hero detaches late
            // and lands last (video 2), fluid swaps to glass in the first 100ms.
            return EdgeCollapsePlan(
                bodyHeight: spring(0.22, 0.10),
                bodyWidth: spring(0.30, stalkBounce, delay: 0.06),
                bodyPosition: spring(0.32, 0.18, delay: 0.16),
                corners: spring(0.30, 0.0, delay: 0.06),
                control: spring(0.20, 0),
                hero: spring(0.38, 0.42, delay: 0.18),
                material: ease(0.10),
                cardContent: ease(0.08),
                barText: ease(0.08),
                progress: ease(0.12, delay: 0.30))
        case .floatOut:
            // island bulges into the bar, control drips off 120ms later, text last.
            return EdgeCollapsePlan(
                bodyHeight: spring(0.30, 0.28),
                bodyWidth: spring(0.32, 0.28, delay: 0.02),
                bodyPosition: spring(0.30, 0.20),
                corners: spring(0.30, 0.0),
                control: spring(0.34, 0.36, delay: 0.20),
                hero: spring(0.30, 0.25, delay: 0.04),
                material: ease(0.10),
                cardContent: ease(0.08),
                barText: ease(0.14, delay: 0.26),
                progress: ease(0.08))
        case .retract:
            return EdgeCollapsePlan(
                bodyHeight: spring(0.26, 0.15, delay: 0.06),
                bodyWidth: spring(0.26, 0.15, delay: 0.06),
                bodyPosition: spring(0.26, 0.15, delay: 0.06),
                corners: spring(0.26, 0.0, delay: 0.06),
                control: spring(0.22, 0.10),
                hero: spring(0.26, 0.15, delay: 0.06),
                material: ease(0.10),
                cardContent: ease(0.08),
                barText: ease(0.06),
                progress: ease(0.10, delay: 0.20))
        case .expand:
            // bulge round first (video 1), stretch to the panel, material swaps
            // back at ~50%, hero flies back and lands last, page content last.
            return EdgeCollapsePlan(
                bodyHeight: spring(0.36, 0.30),
                bodyWidth: spring(0.34, 0.30),
                bodyPosition: spring(0.34, 0.20),
                corners: spring(0.34, 0.0),
                control: spring(0.22, 0),
                hero: spring(0.40, 0.40, delay: 0.10),
                material: ease(0.14, delay: 0.14),
                cardContent: ease(0.14, delay: 0.24),
                barText: ease(0.06),
                progress: ease(0.06))
        }
    }
}

public enum EdgeCollapseTransitionKind: String, Sendable {
    case collapse, floatOut, retract, expand
}
