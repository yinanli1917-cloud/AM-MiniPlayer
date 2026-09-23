/**
 * [INPUT]: artwork NSImage.
 * [OUTPUT]: edgeGlowColor(_:) — one colour for the edge light: the most
 *           saturated, reasonably bright colour of the artwork, lifted so it
 *           still reads as light on a bright wallpaper.
 * [POS]: Spike-local (MusicMiniPlayerCore's dominantColor() is internal).
 */

import AppKit

func edgeGlowColor(_ image: NSImage) -> NSColor? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 0, h > 0 else { return nil }
    let step = max(1, min(w, h) / 32)
    // 12 hue buckets, weighted by saturation × brightness.
    var weight = [Double](repeating: 0, count: 12)
    var hueSum = [Double](repeating: 0, count: 12)
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
                c.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
                if bri > 0.2 {
                    let wgt = Double(sat * sat * bri)
                    let b = min(Int(hue * 12), 11)
                    weight[b] += wgt; hueSum[b] += Double(hue) * wgt
                }
            }
            x += step
        }
        y += step
    }
    guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0.5 else {
        return .controlAccentColor   // grey artwork: the system accent (white would vanish against the track)
    }
    let hue = hueSum[best] / weight[best]
    return NSColor(hue: hue, saturation: 0.62, brightness: 1.0, alpha: 1)
}
