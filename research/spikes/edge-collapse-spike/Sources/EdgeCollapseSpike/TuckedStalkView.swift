/**
 * [INPUT]: EdgeCollapseAppModel (fakeProgress, presentation)
 * [OUTPUT]: TuckedStalkView — the settled `.tucked` state: a black 8×96
 *           capsule flush with the screen edge, progress-filled (design §5),
 *           drawn inside a hover/click hit-region padded window (design §6,
 *           top-level task instruction #3).
 * [POS]: Standalone spike content view for design §2/§3 `tucked`.
 * [PROTOCOL]: Hover enter and click both dispatch through
 *             `EdgeCollapseAppModel.request*` — never touch `presentation`
 *             directly from a view.
 */

import SwiftUI

struct TuckedStalkView: View {
    @ObservedObject var model: EdgeCollapseAppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            // Transparent hit-region padding — the window is
            // `EdgeCollapseTokens.tuckedWindowSize`, larger than the 8×96
            // visible capsule, so there's a real target to hover onto.
            Color.clear

            Capsule(style: .continuous)
                .fill(Color.black)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.32))
                        .frame(height: EdgeCollapseTokens.tuckedSize.height * model.fakeProgress)
                        .frame(maxHeight: EdgeCollapseTokens.tuckedSize.height, alignment: .bottom),
                    alignment: .bottom
                )
                .frame(width: EdgeCollapseTokens.tuckedSize.width, height: EdgeCollapseTokens.tuckedSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { model.requestExpand() }
        .onHover { hovering in
            guard hovering, model.presentation == .tucked else { return }
            model.requestHoverEnter()
        }
    }
}
