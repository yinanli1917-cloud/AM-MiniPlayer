/**
 * [INPUT]: The current cover (NSImage, possibly still an undecoded JPEG).
 * [OUTPUT]: LiquidEdgeArtworkPrep — what the stage draws from the cover,
 *           computed on a background queue: a decoded hero CGImage no larger
 *           than the hero ever draws, and the edge-light colour.
 * [POS]: Liquid edge stage. A cover change used to decode the JPEG three
 *        times on the main thread inside the stage's Combine sink (a TIFF
 *        round trip plus per-pixel NSColor reads, 100ms measured), landing
 *        on whatever edge animation was running (track change auto-peek).
 *        The sink now only hands the image to this queue and applies the
 *        result when it comes back.
 */

import AppKit
import CoreGraphics

enum LiquidEdgeArtworkPrep {
    struct Prepared {
        let hero: CGImage?
        let glow: NSColor
    }

    /// The hero grows to the panel's cover (at most the panel width, 2x).
    static let heroMaxPixels = 640

    /// One utility queue, serial: covers arrive one at a time and only the newest matters.
    static let queue = DispatchQueue(label: "nanoPod.liquid-edge-artwork", qos: .userInitiated)

    /// Safe on any thread. The default accent is resolved to sRGB here, once,
    /// so no catalog-colour conversion (a synchronous XPC the first time)
    /// ever runs on the main thread.
    static func prepare(_ image: NSImage) -> Prepared {
        let fallback = defaultGlow()
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return Prepared(hero: nil, glow: fallback) }
        let hero = resized(cg, maxPixels: heroMaxPixels)
        return Prepared(hero: hero, glow: glowColor(from: cg) ?? fallback)
    }

    /// The system accent colour in sRGB (what the glow falls back to).
    static func defaultGlow() -> NSColor {
        NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
    }

    /// Decoded BGRA8 copy of `image`, scaled to fit `maxPixels` (never up).
    static func resized(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let side = max(image.width, image.height)
        let scale = side > maxPixels ? Double(maxPixels) / Double(side) : 1
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// One colour for the edge light: the most saturated, reasonably bright
    /// colour of the cover, lifted to full brightness; grey covers -> nil
    /// (the caller falls back to the accent). Same weighting as the original
    /// per-pixel NSColor version, reading a raw sRGB pixel buffer instead.
    static func glowColor(from image: CGImage) -> NSColor? {
        // About 32 samples a side, taken from a bitmap no bigger than needed.
        let target = 128
        guard let small = resized(image, maxPixels: target),
              let data = small.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        let w = small.width, h = small.height, bpr = small.bytesPerRow
        let step = max(1, min(w, h) / 32)
        var weight = [Double](repeating: 0, count: 12)
        var hueSum = [Double](repeating: 0, count: 12)
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let o = y * bpr + x * 4
                let a = Double(base[o + 3]) / 255
                // Premultiplied: undo it so a translucent pixel keeps its colour.
                // BGRA byte order.
                let b = a > 0 ? min(1, Double(base[o]) / 255 / a) : 0
                let g = a > 0 ? min(1, Double(base[o + 1]) / 255 / a) : 0
                let r = a > 0 ? min(1, Double(base[o + 2]) / 255 / a) : 0
                let (hue, sat, bri) = hsb(r, g, b)
                if bri > 0.2 {
                    let wgt = sat * sat * bri
                    let bucket = min(Int(hue * 12), 11)
                    weight[bucket] += wgt
                    hueSum[bucket] += hue * wgt
                }
                x += step
            }
            y += step
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0.5 else { return nil }
        return NSColor(hue: CGFloat(hueSum[best] / weight[best]), saturation: 0.62, brightness: 1.0, alpha: 1)
    }

    private static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard mx > 0 else { return (0, 0, 0) }
        let sat = d / mx
        guard d > 0 else { return (0, sat, mx) }
        var hue: Double
        if mx == r { hue = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { hue = (b - r) / d + 2 }
        else { hue = (r - g) / d + 4 }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, sat, mx)
    }
}
