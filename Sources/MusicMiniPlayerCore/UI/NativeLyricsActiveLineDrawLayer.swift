import AppKit
import QuartzCore

/// Active syllable-synced line, AMLL/v2.8 model with cached glyph bitmaps (2026-09-20).
///
/// ONE layout (NSLayoutManager over the whole line) is the single geometry source. Each word run
/// is rasterized ONCE from that layout into a bitmap (so the font is whatever AppKit resolved for
/// the line, identical for dim and bright), then only MOVED per frame via layer position: the
/// float, lift and scale are compositor transforms, never a re-rasterization — no per-frame
/// anti-aliasing shimmer, no CPU text drawing in the presentation loop.
///
/// Structure: `dimContainer` (all runs, alpha = dim tier) and `brightContainer` (same bitmaps,
/// alpha = bright) whose `mask` holds one gradient band per visual line at that line's wavefront.
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
    /// Evidence ring (last 240 accepted inputs): wall ms, per-run floatY, per-line wavefront, dim alpha.
    private(set) var recentInputs: [(wall: Double, floats: [CGFloat], waves: [CGFloat], dim: CGFloat, bright: CGFloat)] = []

    private let dimContainer = CALayer()
    private let brightContainer = CALayer()
    private let brightMask = CALayer()
    private var dimRunLayers: [CALayer] = []
    private var brightRunLayers: [CALayer] = []
    private var maskLineLayers: [NativeLyricsSweepMaskLineLayer] = []
    private var runImageCache: [String: (image: CGImage, frame: CGRect)] = [:]
    #if DEBUG
    private(set) var debugRasterizations = 0
    #endif

    override func action(forKey event: String) -> CAAction? { NSNull() }

    override init() {
        super.init()
        isOpaque = false
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        for l in [dimContainer, brightContainer, brightMask] {
            _ = l.lyricsInert()
            l.contentsScale = contentsScale
        }
        brightContainer.mask = brightMask
        addSublayer(dimContainer)
        addSublayer(brightContainer)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var bounds: CGRect {
        didSet {
            dimContainer.frame = bounds
            brightContainer.frame = bounds
            brightMask.frame = bounds
        }
    }

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
        runImageCache.removeAll()
        return manager
    }

    /// Rasterize one run's glyphs from the shared layout. The bitmap is padded so glow/scale
    /// never clip; `frame` is where it sits in this layer's (top-left) coordinates at rest.
    private func runImage(for run: RunInput) -> (image: CGImage, frame: CGRect)? {
        let key = "\(run.charRange.location):\(run.charRange.length)"
        if let cached = runImageCache[key] { return cached }
        guard let layoutManager = textLayoutManager else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: run.charRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        let pad: CGFloat = 8
        let frame = run.rect.insetBy(dx: -pad, dy: -pad)
        let scale = contentsScale
        let w = Int((frame.width * scale).rounded(.up)), h = Int((frame.height * scale).rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // CG bitmap is y-up; text layout is y-down. Flip, then shift so `frame.origin` maps to 0.
        ctx.translateBy(x: 0, y: frame.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        #if DEBUG
        debugRasterizations += 1
        #endif
        runImageCache[key] = (image, frame)
        return (image, frame)
    }

    /// Pre-rasterize this line's run bitmaps ahead of activation (called for the NEXT row during
    /// idle frames) so the activation frame only positions cached images.
    func prewarm(text: String, width: CGFloat, fontSize: CGFloat, runs: [(charRange: NSRange, rect: CGRect)]) {
        prepareLayout(text: text, width: width, fontSize: fontSize)
        ensureRunLayers(runs.count)
        for (i, run) in runs.enumerated() {
            guard let (image, restFrame) = runImage(for: .init(lineIndex: 0, charRange: run.charRange, rect: run.rect, floatY: 0,
                                                              isEmphasis: false, scale: 1, liftY: 0, glowOpacity: 0, glowRadius: 0))
            else { continue }
            for l in [dimRunLayers[i], brightRunLayers[i]] {
                l.contents = image
                l.bounds = CGRect(origin: .zero, size: restFrame.size)
                l.position = CGPoint(x: restFrame.midX, y: restFrame.midY)
                l.isHidden = true
            }
        }
    }

    private func ensureRunLayers(_ count: Int) {
        while dimRunLayers.count < count {
            let d = CALayer().lyricsInert(), b = CALayer().lyricsInert()
            for l in [d, b] {
                l.contentsScale = contentsScale
                l.contentsGravity = .resize
                l.magnificationFilter = .linear
                l.minificationFilter = .linear
                l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            }
            dimContainer.addSublayer(d)
            brightContainer.addSublayer(b)
            dimRunLayers.append(d)
            brightRunLayers.append(b)
        }
        for i in count..<dimRunLayers.count {
            dimRunLayers[i].isHidden = true
            brightRunLayers[i].isHidden = true
        }
    }

    private func ensureMaskLineLayers(_ count: Int) {
        while maskLineLayers.count < count {
            let l = NativeLyricsSweepMaskLineLayer()
            l.contentsScale = contentsScale
            brightMask.addSublayer(l)
            maskLineLayers.append(l)
        }
        for i in count..<maskLineLayers.count { maskLineLayers[i].isHidden = true }
    }

    func update(_ input: FrameInput) {
        guard frameInput != input else { return }
        frameInput = input
        recentInputs.append((Date().timeIntervalSince1970 * 1000, input.runs.map(\.floatY), input.lines.map(\.wavefrontX), input.dimAlpha, input.brightAlpha))
        if recentInputs.count > 240 { recentInputs.removeFirst(recentInputs.count - 240) }

        dimContainer.opacity = Float(input.dimAlpha)
        brightContainer.opacity = Float(input.brightAlpha)
        ensureRunLayers(input.runs.count)
        for (i, run) in input.runs.enumerated() {
            let dim = dimRunLayers[i], bright = brightRunLayers[i]
            guard let (image, restFrame) = runImage(for: run) else {
                dim.isHidden = true; bright.isHidden = true; continue
            }
            for l in [dim, bright] {
                if l.contents == nil || (l.contents as! CGImage) !== image { l.contents = image }
                l.isHidden = false
                l.bounds = CGRect(origin: .zero, size: restFrame.size)
            }
            // Dim carries the float; bright carries the float plus emphasis lift/scale (v2.8).
            dim.position = CGPoint(x: restFrame.midX, y: restFrame.midY + run.floatY)
            dim.transform = CATransform3DIdentity
            let brightY = restFrame.midY + run.floatY + (run.isEmphasis ? run.liftY : 0)
            bright.position = CGPoint(x: restFrame.midX, y: brightY)
            bright.transform = (run.isEmphasis && run.scale != 1)
                ? CATransform3DMakeScale(run.scale, run.scale, 1) : CATransform3DIdentity
            if run.isEmphasis, run.glowOpacity > 0.001 {
                bright.shadowColor = NSColor.white.cgColor
                bright.shadowOpacity = Float(run.glowOpacity)
                bright.shadowRadius = run.glowRadius
                bright.shadowOffset = .zero
            } else if bright.shadowOpacity != 0 {
                bright.shadowOpacity = 0
                bright.shadowRadius = 0
            }
        }
        ensureMaskLineLayers(input.lines.count)
        for (i, line) in input.lines.enumerated() {
            let m = maskLineLayers[i]
            m.isHidden = false
            m.frame = line.maskRect
            m.apply(wavefrontX: line.wavefrontX - line.maskRect.minX, fadeHalfPoint: input.fadeHalfPoint, width: line.maskRect.width)
        }
    }
}
