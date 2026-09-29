/**
 * [INPUT]: SwiftUI, this folder's TourCardStyle (palette).
 * [OUTPUT]: Exports TourHaloView, TourHaloStore, TourHaloRoot — the highlight
 *           ring/pill over an anchor control (proposal §4.5).
 * [POS]: MusicMiniPlayerAppKit/Tour. Content for TourHaloWindow. A circle
 *        when width≈height (control anchors, 36-40pt per §3.3), a pill for
 *        the tucked sliver (18×72). Colors are the tour's own pink, NOT the
 *        system accent (a blue-accent Mac used to get a blue halo).
 */

import SwiftUI

@MainActor
final class TourHaloStore: ObservableObject {
    @Published var size: CGSize = CGSize(width: 40, height: 40)
    @Published var appeared = false
}

struct TourHaloRoot: View {
    @ObservedObject var store: TourHaloStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TourHaloView(size: store.size, appeared: store.appeared, reduceMotion: reduceMotion)
    }
}

struct TourHaloView: View {
    var size: CGSize
    var appeared: Bool
    var reduceMotion: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var palette: TourCardPalette { .resolve(dark: colorScheme == .dark) }
    private var isPill: Bool { size.height > size.width * 1.4 }

    var body: some View {
        Group {
            if isPill {
                Capsule().strokeBorder(palette.accent, lineWidth: 1.5)
                    .background(Capsule().fill(palette.ringTrack))
            } else {
                Circle().strokeBorder(palette.accent, lineWidth: 1.5)
                    .background(Circle().fill(palette.ringTrack))
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: palette.accent.opacity(0.35), radius: 3)
        // §4.5: appears 1.25x -> 1x, spring 0.9s, once, then static; beat-to-
        // beat repositioning is the window sliding (handled by TourController
        // moving TourHaloWindow's frame), not a scale animation here.
        .scaleEffect(appeared || reduceMotion ? 1 : 1.25)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .animation(reduceMotion ? .easeInOut(duration: 0.16) : .spring(response: 0.9, dampingFraction: 0.8), value: appeared)
        .accessibilityHidden(true)
    }
}
