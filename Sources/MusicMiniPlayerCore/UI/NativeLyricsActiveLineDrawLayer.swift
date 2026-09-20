import AppKit
import QuartzCore

/// v2.8-faithful single-pass renderer for the ACTIVE syllable-synced line (2026-09-20, founder:
/// "按 v2.8 / AMLL 的方式"). One layer draws the whole line every frame from ONE layout:
///   1. dim pass  — every run at the dim alpha, translated by its float (dim floats WITH bright);
///   2. bright pass per visual line — same runs at the bright alpha (emphasis runs scaled/lifted/
///      glowed), then a destination-in horizontal gradient at that line's wavefront.
/// No per-glyph tiles, no hollowed base string, no mask sublayers, no second font resolution:
/// there is exactly one glyph geometry, so nothing can double, drift, or hand off between layers.
final class NativeLyricsActiveLineDrawLayer: CALayer {
    struct RunInput: Equatable {
        let lineIndex: Int
        let charRange: NSRange
        let rect: CGRect
        let floatY: CGFloat
        let isEmphasis: Bool
        let scale: CGFloat
        let liftY: CGFloat
        let glowOpacity: CGFloat
        let glowRadius: CGFloat
    }
    struct LineInput: Equatable {
        let maskRect: CGRect
        let wavefrontX: CGFloat
    }
    struct FrameInput: Equatable {
        let runs: [RunInput]
        let lines: [LineInput]
        let dimAlpha: CGFloat
        let brightAlpha: CGFloat
        let fadeHalfPoint: CGFloat
    }

    private var layoutKey: String?
    private var textLayoutManager: NSLayoutManager?
    private var textContainer: NSTextContainer?
    private var textStorage: NSTextStorage?
    private(set) var frameInput: FrameInput?
    #if DEBUG
    private(set) var debugDrawCount = 0
    #endif

    override func action(forKey event: String) -> CAAction? { NSNull() }

    override init() {
        super.init()
        isOpaque = false
        needsDisplayOnBoundsChange = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    /// The single layout this layer draws from. Same attributes as the sweep layout (system
    /// semibold, wrap by word, zero padding) so run/glyph rects from the sweep plan line up.
    @discardableResult
    func prepareLayout(text: String, width: CGFloat, fontSize: CGFloat) -> NSLayoutManager {
        let key = "\(fontSize)|\(width)|\(text)"
        if layoutKey == key, let textLayoutManager { return textLayoutManager }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        paragraph.lineSpacing = 0
        let storage = NSTextStorage(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.white
        ])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        textLayoutManager = manager
        textContainer = container
        textStorage = storage
        layoutKey = key
        return manager
    }

    func update(_ input: FrameInput) {
        // Redraw only when something visible changed (a held float + unchanged wavefront is a
        // no-op frame); the compositor keeps the last bitmap.
        guard frameInput != input else { return }
        frameInput = input
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        guard let input = frameInput, let layoutManager = textLayoutManager, let textContainer else { return }
        #if DEBUG
        debugDrawCount += 1
        #endif
        // Normalise to a top-left origin regardless of how CA handed us the context.
        if ctx.ctm.d > 0 {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        // v2.8 drew with `.disablesSubpixelQuantization`: glyph origins must NOT snap to whole
        // pixels, otherwise a 2pt float rendered over ~60 frames steps one pixel at a time
        // (founder: "每一行都是抖的"). Fractional positioning keeps the float continuous.
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.setShouldSubpixelQuantizeFonts(false)

        func glyphRange(_ run: RunInput) -> NSRange {
            layoutManager.glyphRange(forCharacterRange: run.charRange, actualCharacterRange: nil)
        }

        // 1. Dim pass: the whole line, each run carried by its own float.
        for run in input.runs {
            let range = glyphRange(run)
            guard range.length > 0 else { continue }
            ctx.saveGState()
            ctx.setAlpha(input.dimAlpha)
            ctx.translateBy(x: 0, y: run.floatY)
            layoutManager.drawGlyphs(forGlyphRange: range, at: .zero)
            ctx.restoreGState()
        }

        // 2. Bright pass, one transparency layer per visual line, masked by that line's wavefront.
        for (lineIndex, line) in input.lines.enumerated() {
            let runs = input.runs.filter { $0.lineIndex == lineIndex }
            guard !runs.isEmpty else { continue }
            let leftEdge = line.wavefrontX - input.fadeHalfPoint
            let rightEdge = line.wavefrontX + input.fadeHalfPoint
            // Fully ahead of the sweep: nothing bright on this line yet (v2.8 `fullyAhead`).
            guard rightEdge > line.maskRect.minX else { continue }
            ctx.saveGState()
            ctx.clip(to: line.maskRect)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for run in runs {
                let range = glyphRange(run)
                guard range.length > 0 else { continue }
                // Runs entirely right of the fade band contribute nothing; skip the draw.
                if run.rect.minX >= rightEdge && !run.isEmphasis { continue }
                ctx.saveGState()
                ctx.setAlpha(input.brightAlpha)
                if run.isEmphasis, run.scale != 1 {
                    let cx = run.rect.midX, cy = run.rect.midY
                    ctx.translateBy(x: cx, y: cy)
                    ctx.scaleBy(x: run.scale, y: run.scale)
                    ctx.translateBy(x: -cx, y: -cy)
                }
                ctx.translateBy(x: 0, y: run.floatY + (run.isEmphasis ? run.liftY : 0))
                if run.isEmphasis, run.glowOpacity > 0.001, run.glowRadius > 0 {
                    ctx.setShadow(
                        offset: .zero, blur: run.glowRadius,
                        color: NSColor.white.withAlphaComponent(run.glowOpacity).cgColor
                    )
                }
                layoutManager.drawGlyphs(forGlyphRange: range, at: .zero)
                ctx.restoreGState()
            }
            // Destination-in gradient: white up to the wavefront's fade band, clear after it.
            let width = max(1, line.maskRect.width)
            let l = max(0, min(1, (leftEdge - line.maskRect.minX) / width))
            let r = max(l, min(1, (rightEdge - line.maskRect.minX) / width))
            let colors = [
                NSColor.white.cgColor, NSColor.white.cgColor,
                NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0).cgColor
            ] as CFArray
            let locations: [CGFloat] = [0, l, r, 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                ctx.setBlendMode(.destinationIn)
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: line.maskRect.minX, y: line.maskRect.midY),
                    end: CGPoint(x: line.maskRect.maxX, y: line.maskRect.midY),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        _ = textContainer
    }
}
