/**
 * [INPUT]: LiquidEdgeArtworkPrep (cover -> decoded hero image + edge-light colour,
 *          computed off the main thread).
 * [OUTPUT]: Tests: colour choice (most saturated bright colour, grey -> none),
 *           hero downscale bound, safe off the main thread.
 * [POS]: Guards the stage's cover handling that used to decode three times on main.
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

final class LiquidEdgeArtworkPrepTests: XCTestCase {
    /// An sRGB image of `width` x `height`, with the left `split` fraction in `a` and the rest in `b`.
    private func image(width: Int = 64, height: Int = 64, a: NSColor, b: NSColor? = nil, split: CGFloat = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(a.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width) * split, height: CGFloat(height)))
        if let b {
            ctx.setFillColor(b.cgColor)
            ctx.fill(CGRect(x: CGFloat(width) * split, y: 0, width: CGFloat(width) * (1 - split), height: CGFloat(height)))
        }
        return ctx.makeImage()!
    }

    private func hue(_ c: NSColor) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
        c.usingColorSpace(.sRGB)!.getHue(&h, saturation: &s, brightness: &b, alpha: &al)
        return h
    }

    func test_glow_ofARedCover_isRed_liftedToFullBrightness() throws {
        let c = try XCTUnwrap(LiquidEdgeArtworkPrep.glowColor(from: image(a: NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))))
        let h = hue(c)
        XCTAssertTrue(h < 0.04 || h > 0.96, "red hue, got \(h)")
        var s: CGFloat = 0, b: CGFloat = 0, hh: CGFloat = 0, al: CGFloat = 0
        c.usingColorSpace(.sRGB)!.getHue(&hh, saturation: &s, brightness: &b, alpha: &al)
        XCTAssertEqual(s, 0.62, accuracy: 0.01)
        XCTAssertEqual(b, 1.0, accuracy: 0.01)
    }

    func test_glow_prefersTheMoreSaturatedColour_overTheLargerMutedArea() throws {
        let muted = NSColor(srgbRed: 0.55, green: 0.6, blue: 0.7, alpha: 1)     // saturation ~0.2
        let vivid = NSColor(srgbRed: 0.1, green: 0.9, blue: 0.2, alpha: 1)      // green
        let c = try XCTUnwrap(LiquidEdgeArtworkPrep.glowColor(from: image(a: muted, b: vivid, split: 0.7)))
        XCTAssertEqual(hue(c), 1.0 / 3.0, accuracy: 0.05, "the vivid green wins over 70% muted blue")
    }

    func test_glow_ofGreyOrDarkCover_isNone() {
        XCTAssertNil(LiquidEdgeArtworkPrep.glowColor(from: image(a: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))))
        XCTAssertNil(LiquidEdgeArtworkPrep.glowColor(from: image(a: NSColor(srgbRed: 0.1, green: 0.02, blue: 0.02, alpha: 1))))
    }

    func test_hero_isBoundedAndKeepsAspect_andSmallCoversAreNotEnlarged() throws {
        let big = try XCTUnwrap(LiquidEdgeArtworkPrep.resized(image(width: 2000, height: 1000, a: .red), maxPixels: 640))
        XCTAssertEqual(big.width, 640)
        XCTAssertEqual(big.height, 320)
        let small = try XCTUnwrap(LiquidEdgeArtworkPrep.resized(image(width: 300, height: 300, a: .red), maxPixels: 640))
        XCTAssertEqual(small.width, 300)
        XCTAssertEqual(small.height, 300)
    }

    func test_prepare_worksOffTheMainThread_andFallsBackToTheAccentForGrey() {
        let nsImage = NSImage(cgImage: image(a: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)), size: NSSize(width: 64, height: 64))
        let done = expectation(description: "prepared")
        var result: LiquidEdgeArtworkPrep.Prepared?
        LiquidEdgeArtworkPrep.queue.async {
            XCTAssertFalse(Thread.isMainThread)
            result = LiquidEdgeArtworkPrep.prepare(nsImage)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(result?.hero)
        XCTAssertEqual(result?.glow, LiquidEdgeArtworkPrep.defaultGlow(), "a grey cover falls back to the (sRGB-resolved) accent")
    }
}
