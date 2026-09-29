import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit

/// Offscreen rendering helpers for the tour's view tests (ImageRenderer: no
/// window, no screen, no capture — just the SwiftUI view's own pixels).
/// ImageRenderer cannot draw `glassEffect` or NSViewRepresentable material,
/// so card renders use `TourCardMaterialArm.simulated`.
struct TourPixels {
    let width: Int
    let height: Int
    let scale: CGFloat
    /// RGBA8, premultiplied-last converted to straight alpha, row 0 = top.
    let data: [UInt8]

    func rgba(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
        let i = (y * width + x) * 4
        return (data[i], data[i + 1], data[i + 2], data[i + 3])
    }

    /// Point (top-left origin, in points) -> pixel sample.
    func rgba(atPoint p: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        rgba(x: Int((p.x * scale).rounded(.down)), y: Int((p.y * scale).rounded(.down)))
    }
}

enum TourRender {
    @MainActor
    static func pixels<V: View>(_ view: V, size: CGSize? = nil, scale: CGFloat = 2, dark: Bool = false) -> TourPixels? {
        let content = view.environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        if let size { renderer.proposedSize = ProposedViewSize(size) }
        guard let cg = renderer.cgImage else { return nil }
        return pixels(from: cg, scale: scale)
    }

    static func pixels(from cg: CGImage, scale: CGFloat) -> TourPixels {
        let w = cg.width, h = cg.height
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // un-premultiply
        for i in stride(from: 0, to: raw.count, by: 4) {
            let a = Int(raw[i + 3])
            if a > 0 && a < 255 {
                raw[i] = UInt8(min(255, Int(raw[i]) * 255 / a))
                raw[i + 1] = UInt8(min(255, Int(raw[i + 1]) * 255 / a))
                raw[i + 2] = UInt8(min(255, Int(raw[i + 2]) * 255 / a))
            }
        }
        return TourPixels(width: w, height: h, scale: scale, data: raw)
    }

    /// Strongly saturated Apple-Music pink (the ring's solid arc / solid dot),
    /// as opposed to the pale track or the card fill.
    static func isAccent(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        p.a > 200 && p.r > 215 && Int(p.r) - Int(p.g) > 120 && Int(p.r) - Int(p.b) > 90
    }

    static func writePNG(_ cg: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
