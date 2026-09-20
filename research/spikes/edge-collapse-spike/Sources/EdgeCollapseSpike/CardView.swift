/**
 * [INPUT]: EdgeCollapseAppModel (pageContentOpacity/Shift, heroLocation,
 *          isPlaying, trackTitle), shared hero Namespace
 * [OUTPUT]: CardView — the full 250×316 card page (top-level task
 *           instruction #4: fluid gradient background, ~200pt hero artwork
 *           placeholder, title line, two control glyphs)
 * [POS]: Standalone spike content view for design §7.1's card(page) state.
 * [PROTOCOL]: Reads model state only through @Published bindings — no timing
 *             math here, that all lives in AppModel/EdgeCollapseTokens.
 */

import SwiftUI

struct CardView: View {
    @ObservedObject var model: EdgeCollapseAppModel
    var heroNS: Namespace.ID

    private let warmGradient = LinearGradient(
        colors: [
            Color(red: 0.20, green: 0.10, blue: 0.28),
            Color(red: 0.45, green: 0.18, blue: 0.22),
            Color(red: 0.62, green: 0.36, blue: 0.20),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            warmGradient

            VStack(spacing: 16) {
                Spacer(minLength: 8)

                ZStack {
                    if model.heroLocation == .page {
                        HeroArtworkView(size: 200, cornerRadius: 28)
                            .matchedGeometryEffect(id: "hero", in: heroNS)
                    } else {
                        Color.clear.frame(width: 200, height: 200)
                    }
                }

                Text(model.trackTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 214)

                HStack(spacing: 30) {
                    Button(action: { model.toggleIsPlaying() }) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .buttonStyle(.plain)

                    Button(action: { model.nextTrack() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white)

                Spacer(minLength: 12)
            }
            .opacity(model.pageContentOpacity)
            .offset(x: model.pageContentShift)
        }
        .frame(width: EdgeCollapseTokens.cardSize.width, height: EdgeCollapseTokens.cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: EdgeCollapseTokens.cardCornerRadius, style: .continuous))
    }
}
