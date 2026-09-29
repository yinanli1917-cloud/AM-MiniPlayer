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
 *        shifted it 42pt). It DOES report its content size (`fittingSize` /
 *        `intrinsicContentSize`) and says when that changes — `sizingOptions =
 *        []` used to make `fittingSize` (0, 0), so every card was measured with
 *        a silent 150pt fallback and clipped by its own window (2026-09-29).
 */

import SwiftUI
import AppKit

final class TourHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        // `.intrinsicContentSize` only: unlike `.minSize/.maxSize/.preferredContentSize`
        // it never lets the hosting view push a size onto its window.
        sizingOptions = [.intrinsicContentSize]
    }

    /// Fires (on the next run-loop turn, coalesced) when SwiftUI says the
    /// content wants a different size.
    var onContentSizeInvalidated: (() -> Void)?
    private var invalidationPending = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard onContentSizeInvalidated != nil, !invalidationPending else { return }
        invalidationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidationPending = false
            self.onContentSizeInvalidated?()
        }
    }

    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
