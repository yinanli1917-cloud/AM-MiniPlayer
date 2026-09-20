/**
 * [INPUT]: [GooBlob] (center + size + corner radius, in the parent view's
 *          local coordinate space)
 * [OUTPUT]: GooCanvas — SwiftUI Canvas view drawing the blobs through
 *           `.alphaThreshold` + `.blur` so adjacent/overlapping blobs visually
 *           melt together (a metaball bridge).
 * [POS]: Standalone spike for research/edge-collapse-redesign-2026-09-19.md §8:
 *        "小 Canvas，画两块黑，context.addFilter(.blur(radius)) +
 *        .alphaThreshold(min: 0.5)". Mounted only for the documented windows
 *        (collapsing 200–320ms, both floating moves) — see AppModel's
 *        `gooMounted` — and unmounted otherwise, per the blur-economy rule in
 *        CLAUDE.md ("Resident CIGaussianBlur on static... rows" trap):
 *        settled/idle frames carry zero filters.
 * [PROTOCOL]: Public API only — Canvas + GraphicsContext.addFilter/.drawLayer,
 *             no CABackdropLayer, no private API.
 */

import SwiftUI

struct GooBlob: Equatable {
    var center: CGPoint
    var size: CGSize
    var cornerRadius: CGFloat
}

/// Filter order matches Apple's own Canvas metaball recipe: alphaThreshold
/// added BEFORE blur, then the blobs are drawn inside `drawLayer` so both
/// filters apply to the flattened result.
struct GooCanvas: View {
    let blobs: [GooBlob]
    var blurRadius: CGFloat = 8
    var color: Color = .black

    var body: some View {
        Canvas { context, _ in
            context.addFilter(.alphaThreshold(min: 0.5, color: color))
            context.addFilter(.blur(radius: blurRadius))
            context.drawLayer { layerContext in
                for blob in blobs {
                    let rect = CGRect(
                        x: blob.center.x - blob.size.width / 2,
                        y: blob.center.y - blob.size.height / 2,
                        width: blob.size.width,
                        height: blob.size.height
                    )
                    guard rect.width > 0, rect.height > 0 else { continue }
                    let path = Path(roundedRect: rect, cornerRadius: blob.cornerRadius)
                    layerContext.fill(path, with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
