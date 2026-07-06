import AppKit
import QuartzCore

final class NativeLyricsDisplayLinkScheduler {
    private let lock = NSLock()
    private var isTickQueued = false
    private var latestDisplayInterval: TimeInterval?
    private var latestDisplayTimestamp: TimeInterval?

    func enqueue(
        displayInterval: TimeInterval?,
        displayTimestamp: TimeInterval?,
        perform: @escaping (TimeInterval?, TimeInterval?) -> Void
    ) {
        var shouldQueue = false
        lock.lock()
        latestDisplayInterval = displayInterval
        latestDisplayTimestamp = displayTimestamp
        if !isTickQueued {
            isTickQueued = true
            shouldQueue = true
        }
        lock.unlock()

        guard shouldQueue else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let payload = self.consumeQueuedTick()
            perform(payload.displayInterval, payload.displayTimestamp)
        }
    }

    func reset() {
        lock.lock()
        isTickQueued = false
        latestDisplayInterval = nil
        latestDisplayTimestamp = nil
        lock.unlock()
    }

    private func consumeQueuedTick() -> (displayInterval: TimeInterval?, displayTimestamp: TimeInterval?) {
        lock.lock()
        let payload: (displayInterval: TimeInterval?, displayTimestamp: TimeInterval?) = (
            latestDisplayInterval,
            latestDisplayTimestamp
        )
        latestDisplayInterval = nil
        latestDisplayTimestamp = nil
        isTickQueued = false
        lock.unlock()
        return payload
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Implicit-animation hygiene
//
// Every layer this renderer creates is INERT: property changes apply instantly, never via
// Core Animation's implicit 0.25s default actions. All intended motion comes from (a)
// per-tick property sets driven by the presentation engine, or (b) explicit CAAnimations
// added by name (the translation loading dots) — explicit adds bypass the action search,
// so they keep working.
//
// WHY layer-level and not call-site CATransaction wraps: these are manual sublayers of
// layer-backed NSViews. AppKit only suppresses implicit actions for a view's OWN backing
// layer. Text/mask/dot sublayer frames are assigned inside NSView.layout(), which AppKit
// runs in its own, un-wrapped transaction — no amount of call-site wrapping covers it.
// Un-blocked, a translation layer whose committed frame is .zero implicitly animates
// position+bounds from the origin when its real frame arrives ("drifts in from top-left"),
// reflows ghost mid-flight, and per-tick wavefront/dot sets each spawn an interrupted
// animation (smear/lag). The delegate is the FIRST stop in CA's action search, so
// returning NSNull() kills every implicit action without enumerating keys.
// Guarded by NativeLyricsImplicitAnimationTests.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsInertLayerDelegate: NSObject, CALayerDelegate {
    static let shared = NativeLyricsInertLayerDelegate()
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

extension CALayer {
    /// Marks this renderer-managed layer as inert (no implicit actions) and returns it,
    /// so creation sites read `CATextLayer().lyricsInert()`.
    func lyricsInert() -> Self {
        delegate = NativeLyricsInertLayerDelegate.shared
        return self
    }
}

final class NativeLyricsSweepMaskLineLayer: CALayer {
    private let solidLayer = CALayer().lyricsInert()
    private let fadeLayer = CALayer().lyricsInert()

    // Mask line layers are created in per-tick batches; short-circuit the whole action
    // search at the class level instead of relying on the delegate slot.
    override func action(forKey event: String) -> CAAction? { NSNull() }

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        masksToBounds = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        solidLayer.backgroundColor = NSColor.black.cgColor
        solidLayer.contentsScale = contentsScale
        fadeLayer.contents = Self.fadeImage
        fadeLayer.contentsGravity = .resize
        fadeLayer.minificationFilter = .linear
        fadeLayer.magnificationFilter = .linear
        fadeLayer.contentsScale = contentsScale
        addSublayer(solidLayer)
        addSublayer(fadeLayer)
    }

    @discardableResult
    func apply(wavefrontX: CGFloat, fadeHalfPoint: CGFloat, width: CGFloat) -> CGFloat {
        let width = max(1, width)
        let height = max(1, bounds.height)
        let left = wavefrontX - fadeHalfPoint
        let right = wavefrontX + fadeHalfPoint
        if right <= 0 {
            opacity = 0
            solidLayer.frame = .zero
            fadeLayer.frame = .zero
            return 0
        }

        opacity = 1
        if left >= width {
            solidLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
            fadeLayer.frame = .zero
            return width
        }

        let clampedLeft = max(0, min(width, left))
        let clampedRight = max(0, min(width, right))
        solidLayer.frame = CGRect(x: 0, y: 0, width: clampedLeft, height: height)
        fadeLayer.frame = CGRect(
            x: clampedLeft,
            y: 0,
            width: max(0, clampedRight - clampedLeft),
            height: height
        )
        return (clampedLeft + clampedRight) / 2
    }

    private static let fadeImage: CGImage = {
        let width = 64
        let height = 1
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CGImage.emptyMaskPixel
        }
        let colors = [
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else {
            return CGImage.emptyMaskPixel
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: width, y: 0),
            options: []
        )
        return context.makeImage() ?? CGImage.emptyMaskPixel
    }()
}

private extension CGImage {
    static let emptyMaskPixel: CGImage = {
        var pixel: UInt32 = 0
        let data = Data(bytes: &pixel, count: MemoryLayout<UInt32>.size)
        let provider = CGDataProvider(data: data as CFData)
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider!,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }()
}
