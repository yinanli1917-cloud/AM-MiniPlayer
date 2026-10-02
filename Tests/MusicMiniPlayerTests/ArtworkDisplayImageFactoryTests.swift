import AppKit
import XCTest
@testable import MusicMiniPlayerCore

final class ArtworkDisplayImageFactoryTests: XCTestCase {
    func testEffectArtworkDownsamplesLargeArtworkWithoutChangingAspectRatio() {
        let image = makeBitmapImage(width: 2048, height: 1024)

        let resized = ArtworkDisplayImageFactory.makeEffectArtwork(from: image, maxPixelDimension: 512)
        let pixels = ArtworkDisplayImageFactory.pixelDimensions(of: resized)

        XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), 512)
        XCTAssertEqual(pixels.width, 512)
        XCTAssertEqual(pixels.height, 256)
    }

    func testEffectArtworkKeepsSmallArtworkInstance() {
        let image = makeBitmapImage(width: 300, height: 300)

        let resized = ArtworkDisplayImageFactory.makeEffectArtwork(from: image, maxPixelDimension: 512)

        XCTAssertTrue(resized === image)
    }

    func testSignatureChangesWhenArtworkObjectChangesWithSameMetadata() {
        let first = makeBitmapImage(width: 300, height: 300)
        let second = makeBitmapImage(width: 300, height: 300)

        let firstSignature = ArtworkDisplayImageFactory.signature(
            for: first,
            trackID: "track",
            title: "Song",
            artist: "Artist"
        )
        let secondSignature = ArtworkDisplayImageFactory.signature(
            for: second,
            trackID: "track",
            title: "Song",
            artist: "Artist"
        )

        XCTAssertNotEqual(firstSignature, secondSignature)
    }

    // MARK: - Display copy (decoded off the main thread at the fetch sites)

    private func jpegImage(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<height { for x in 0..<width { rep.setColor(NSColor(srgbRed: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height), blue: 0.4, alpha: 1), atX: x, y: y) } }
        let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
        return NSImage(data: data)!
    }

    private func cgImage(_ image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func testDisplayArtworkIsDecodedPremultipliedBGRA_andKeepsPointSizeAndPixels() throws {
        let jpeg = jpegImage(width: 300, height: 200)
        let display = ArtworkDisplayImageFactory.makeDisplayArtwork(from: jpeg)
        let cg = try XCTUnwrap(cgImage(display))
        XCTAssertEqual(cg.bitsPerComponent, 8)
        XCTAssertEqual(cg.alphaInfo, .premultipliedFirst)
        XCTAssertEqual(cg.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Little, "the layout Core Animation takes without a colour-conversion pass")
        XCTAssertEqual(cg.width, 300)
        XCTAssertEqual(cg.height, 200)
        XCTAssertEqual(display.size, jpeg.size, "layout in points does not change")
    }

    func testDisplayArtworkBoundsALargeCover_keepingAspect() throws {
        let display = ArtworkDisplayImageFactory.makeDisplayArtwork(from: jpegImage(width: 400, height: 200), maxPixelDimension: 100)
        let cg = try XCTUnwrap(cgImage(display))
        XCTAssertEqual(cg.width, 100)
        XCTAssertEqual(cg.height, 50)
    }

    func testDisplayArtworkIsIdempotent() {
        let once = ArtworkDisplayImageFactory.makeDisplayArtwork(from: jpegImage(width: 120, height: 120))
        XCTAssertTrue(ArtworkDisplayImageFactory.makeDisplayArtwork(from: once) === once, "a copy that is already native is returned as it is")
    }

    func testDisplayArtworkKeepsAWideGamutCoversColourSpace() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: p3, components: [1, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let source = NSImage(cgImage: try XCTUnwrap(ctx.makeImage()), size: NSSize(width: 64, height: 64))
        let cg = try XCTUnwrap(cgImage(ArtworkDisplayImageFactory.makeDisplayArtwork(from: source)))
        XCTAssertEqual(cg.colorSpace?.name as String?, CGColorSpace.displayP3 as String, "a P3 cover is not clipped to sRGB")
    }

    private func makeBitmapImage(width: Int, height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        image.addRepresentation(rep)
        return image
    }
}
