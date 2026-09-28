/**
 * [INPUT]: SwiftUI, MusicMiniPlayerCore's TourMotionPolicy.
 * [OUTPUT]: Exports TourHaloView — the highlight ring/pill over an anchor
 *           control (proposal §4.5).
 * [POS]: MusicMiniPlayerAppKit/Tour. Content for TourHaloWindow. A circle
 *        when width≈height (control anchors, 36-40pt per §3.3), a pill for
 *        the tucked sliver (18×72).
 */

import SwiftUI

struct TourHaloView: View {
    var size: CGSize
    var appeared: Bool
    var reduceMotion: Bool

    private var isPill: Bool { size.height > size.width * 1.4 }

    var body: some View {
        Group {
            if isPill {
                Capsule().stroke(Color.accentColor, lineWidth: 1.5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            } else {
                Circle().stroke(Color.accentColor, lineWidth: 1.5)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: Color.accentColor.opacity(0.35), radius: 3)
        // §4.5: appears 1.25x -> 1x, spring 0.9s, once, then static; beat-to-
        // beat repositioning is the window sliding (handled by TourController
        // moving TourHaloWindow's frame), not a scale animation here.
        .scaleEffect(appeared || reduceMotion ? 1 : 1.25)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .animation(reduceMotion ? .easeInOut(duration: 0.16) : .spring(response: 0.9, dampingFraction: 0.8), value: appeared)
        .accessibilityHidden(true)
    }
}
