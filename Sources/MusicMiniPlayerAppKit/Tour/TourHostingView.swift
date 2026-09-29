/**
 * [INPUT]: SwiftUI, AppKit.
 * [OUTPUT]: Exports TourHostingView — an NSHostingView for the tour's
 *           overlay windows.
 * [POS]: MusicMiniPlayerAppKit/Tour. Two behaviors the default hosting view
 *        lacks for a nonactivating overlay: it accepts the first click (the
 *        card is never the key window, so without this the first click on a
 *        button would only "activate" and be swallowed), and it never resizes
 *        its window (the controller owns every overlay frame; the first
 *        version let a swapped NSHostingController re-size the halo window and
 *        shifted it 42pt).
 */

import SwiftUI
import AppKit

final class TourHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
