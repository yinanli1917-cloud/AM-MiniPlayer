import XCTest
import AppKit
@testable import MusicMiniPlayerCore

/// 2026-09-20 (founder: "切行时字体还是会变，亮度也有跳变"): the inactive whole-line base is a
/// CATextLayer; the active line is a CoreGraphics bitmap of the same layout. If the two
/// rasterizers put a different amount of ink on the same glyphs (font smoothing dilation,
/// different fallback font), the row visibly changes weight and brightness at activation.
/// This pins the two paths to the same ink coverage.
final class NativeLyricsActiveLineInkParityTests: XCTestCase {
    private let scale: CGFloat = 2

    private func attributed(_ text: String, size: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        let storage = NSTextStorage(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
        storage.fixAttributes(in: NSRange(location: 0, length: storage.length))
        return NSAttributedString(attributedString: storage)
    }

    private func bitmap(width: CGFloat, height: CGFloat) -> CGContext {
        let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        return ctx
    }

    /// Sum of alpha over the image, normalised to full-pixel units.
    private func ink(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var total = 0.0
        var i = 3
        while i < data.count { total += Double(data[i]); i += 4 }
        return total / 255
    }

    private func textLayerInk(_ text: String, size: CGFloat, width: CGFloat, height: CGFloat) -> Double {
        let layer = CATextLayer()
        layer.contentsScale = scale
        layer.isWrapped = true
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        layer.string = attributed(text, size: size)
        let ctx = bitmap(width: width, height: height)
        layer.render(in: ctx)
        return ink(ctx.makeImage()!)
    }

    private func bitmapInk(_ text: String, size: CGFloat, width: CGFloat, height: CGFloat) -> Double {
        let draw = NativeLyricsActiveLineDrawLayer()
        draw.contentsScale = scale
        let layout = draw.prepareLayout(text: text, width: width, fontSize: size)
        let range = NSRange(location: 0, length: (text as NSString).length)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: layout.textContainers[0])
        let image = draw.debugRunImage(text: text, width: width, fontSize: size, charRange: range, rect: rect)!
        return ink(image)
    }

    private func assertParity(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let size: CGFloat = 22
        let a = textLayerInk(text, size: size, width: 400, height: 80)
        let b = bitmapInk(text, size: size, width: 400, height: 80)
        let rel = abs(a - b) / max(a, 1)
        XCTAssertLessThan(rel, 0.02, "ink CATextLayer=\(a) bitmap=\(b) rel=\(rel) for \(text)", file: file, line: line)
    }

    func test_latinLine_sameInkOnBothRasterizers() { assertParity("hello brave new world") }
    func test_cjkLine_sameInkOnBothRasterizers() { assertParity("未来的旅程") }
}
