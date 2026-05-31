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
