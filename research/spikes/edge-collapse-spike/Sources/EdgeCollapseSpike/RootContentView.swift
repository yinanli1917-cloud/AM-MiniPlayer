/**
 * [INPUT]: EdgeCollapseAppModel (presentation + every published animation value)
 * [OUTPUT]: RootContentView — the panel's whole SwiftUI tree: mounts exactly
 *           the views the current `EdgePresentation` needs, hosts the ONE
 *           shared hero Namespace, and layers the black material overlay +
 *           metaball Canvas on top.
 * [POS]: Standalone spike root view, design §2 state → view mapping.
 * [PROTOCOL]: Only ONE of {CardView, pill overlay, TuckedStalkView,
 *             FloatingBodiesView} may render the "hero" matchedGeometryEffect
 *             id at a time — enforced by `HeroLocation`, never duplicate it.
 */

import SwiftUI

struct RootContentView: View {
    @ObservedObject var model: EdgeCollapseAppModel
    @Namespace private var heroNS

    var body: some View {
        ZStack(alignment: .trailing) {
            if showsCard {
                CardView(model: model, heroNS: heroNS)
            }

            if showsPill {
                pillOverlay
            }

            if model.presentation == .tucked {
                TuckedStalkView(model: model)
            }

            if model.presentation == .floating {
                FloatingBodiesView(model: model, heroNS: heroNS)
            }

            if model.gooMounted {
                gooOverlay
            }

            if showsCard {
                Color.black
                    .opacity(model.blackOverlayOpacity)
                    .allowsHitTesting(false)
                    .frame(width: EdgeCollapseTokens.cardSize.width, height: EdgeCollapseTokens.cardSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: EdgeCollapseTokens.cardCornerRadius, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Card + the two shape-morph states both use the card-sized window, and
    /// the card's OWN content view underlies the morphing black shape (design
    /// §7.1: "动画全部在卡片 frame 内画").
    private var showsCard: Bool {
        model.presentation == .card || model.presentation == .collapsing || model.presentation == .expanding
    }

    private var showsPill: Bool {
        model.presentation == .collapsing || model.presentation == .expanding
    }

    @ViewBuilder private var pillOverlay: some View {
        ZStack {
            CollapseShape(model.shape)
                .fill(Color.black)

            if model.heroLocation == .pill {
                HeroArtworkView(size: min(20, model.shape.width - 4), cornerRadius: 6)
                    .matchedGeometryEffect(id: "hero", in: heroNS)
            }
        }
        .frame(width: model.shape.width, height: model.shape.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .allowsHitTesting(false)
    }

    /// Bridges the current body to the eventual tucked sliver — see README
    /// "已知未验证" for how this approximates design §7.1's "两体粘连" beat
    /// (the window's own trailing alignment already keeps the pill flush
    /// with the physical edge, so there's no literal gap to bridge; the
    /// Canvas instead sells the "melting into the edge" read via blur +
    /// alphaThreshold on two near-overlapping blobs). During `.floating` the
    /// bridged body is an APPROXIMATE size (`currentBodyApproxSize`), not the
    /// exact FloatingBodiesView bounds — a documented simplification.
    @ViewBuilder private var gooOverlay: some View {
        GeometryReader { proxy in
            let edgeX = proxy.size.width
            let midY = proxy.size.height / 2
            let bodySize = currentBodyApproxSize
            let sliver = GooBlob(
                center: CGPoint(x: edgeX - EdgeCollapseTokens.tuckedSize.width / 2, y: midY),
                size: CGSize(width: EdgeCollapseTokens.tuckedSize.width, height: EdgeCollapseTokens.tuckedSize.height),
                cornerRadius: EdgeCollapseTokens.tuckedSize.width / 2
            )
            let body = GooBlob(
                center: CGPoint(x: edgeX - bodySize.width / 2 - model.floatingBodyOffset, y: midY),
                size: bodySize,
                cornerRadius: min(bodySize.width, bodySize.height) / 2
            )
            GooCanvas(blobs: [sliver, body], blurRadius: 8)
        }
        .allowsHitTesting(false)
    }

    private var currentBodyApproxSize: CGSize {
        switch model.presentation {
        case .collapsing, .expanding:
            return CGSize(width: model.shape.width, height: model.shape.height)
        case .floating, .tucked:
            return model.variant == .h
                ? CGSize(width: 100, height: 76)
                : CGSize(width: 32, height: 108)
        case .card:
            return EdgeCollapseTokens.cardSize
        }
    }
}
