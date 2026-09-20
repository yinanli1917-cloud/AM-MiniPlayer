/**
 * [INPUT]: Depends on NativeLyricsTextSweepLayout's NativeLyricsUnifiedTextBuild (the shared
 *          NSLayoutManager/NSTextContainer/NSTextStorage triple also used to position the
 *          per-glyph dim/bright tiles in NativeLyricsRowView).
 * [OUTPUT]: Exports NativeLyricsUnifiedDimDrawLayer — a CALayer subclass that paints the active
 *           row's whole-line dim base by calling drawGlyphs(forGlyphRange:at:) against that SAME
 *           layout object, instead of CATextLayer's own independent string-wrap engine.
 * [POS]: Rendering primitive within MusicMiniPlayerCore's native lyrics layer renderer
 *        (NativeLyricsRowView). Stage bundle 3m (2026-09-19): unifies the two layout engines that
 *        previously only agreed by matching CONFIGURATION (banned-patterns.md's per-glyph-float
 *        ban is untouched — this layer paints ONE whole-line pass, never per-glyph, never
 *        floating; see NativeLyricsTextSweepLayout.NativeLyricsUnifiedTextBuild's doc comment).
 */
import AppKit
import QuartzCore

final class NativeLyricsUnifiedDimDrawLayer: CALayer {
    /// The shared layout object this frame's dim base must draw from. Set by the row view every
    /// frame it is active; nil (or content unchanged) means "nothing new to paint".
    // Named `textLayoutManager` (not `layoutManager`) — CALayer already declares its own
    // `layoutManager: (any CALayoutManager)?` property; that name collision is a compile error.
    var textLayoutManager: NSLayoutManager?
    var textContainer: NSTextContainer?
    var glyphRange: NSRange = NSRange(location: 0, length: 0)

    // Mask line layers / other renderer layers all short-circuit the action search at the class
    // level (see NativeLyricsSweepMaskLineLayer) rather than relying solely on the delegate slot —
    // matches that pattern for consistency; `.lyricsInert()` is still applied at the call site.
    override func action(forKey event: String) -> CAAction? { NSNull() }

    override init() {
        super.init()
        isOpaque = false
        needsDisplayOnBoundsChange = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Repaints from the CURRENT layoutManager/textContainer/glyphRange. The row view calls this
    /// after updating those three (and after mutating the shared textStorage's per-run
    /// `.foregroundColor` alpha for any word that must stay blanked here because a floating
    /// per-glyph tile is already drawing it) — never on every property write, only when content
    /// actually changed, matching every other renderer-created layer's frugal invalidation.
    func repaint() {
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        guard let textLayoutManager, let textContainer, glyphRange.length > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = nsContext
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        // origin is .zero: this layer's frame/bounds are set by the row view to exactly match
        // mainTextLayer's frame — text container coordinates and layer-local coordinates coincide,
        // the same convention `NativeLyricsTextSweepLayout`'s glyph `rect`s already use.
        textLayoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
        textLayoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
    }
}
