import AppKit

enum ArtworkDisplayImageFactory {
    static let effectMaxPixelDimension = 768

    static func signature(
        for image: NSImage?,
        trackID: String?,
        title: String,
        artist: String
    ) -> String {
        guard let image else { return "nil|\(trackID ?? "")|\(title)|\(artist)" }
        let pixelSize = pixelDimensions(of: image)
        let pointer = UInt(bitPattern: Unmanaged.passUnretained(image).toOpaque())
        return "\(trackID ?? "")|\(title)|\(artist)|\(pixelSize.width)x\(pixelSize.height)|\(pointer)"
    }

    static func makeEffectArtwork(
        from image: NSImage,
        maxPixelDimension: Int = effectMaxPixelDimension
    ) -> NSImage {
        guard maxPixelDimension > 0 else { return image }

        let pixelSize = pixelDimensions(of: image)
        let maxSide = max(pixelSize.width, pixelSize.height)
        guard maxSide > maxPixelDimension else { return image }

        var sourceRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil) else {
            return image
        }

        let scale = CGFloat(maxPixelDimension) / CGFloat(maxSide)
        let targetWidth = max(1, Int((CGFloat(pixelSize.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(pixelSize.height) * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let resized = context.makeImage() else { return image }
        return NSImage(cgImage: resized, size: NSSize(width: targetWidth, height: targetHeight))
    }

    static func pixelDimensions(of image: NSImage) -> (width: Int, height: Int) {
        var rect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return (max(cgImage.width, 1), max(cgImage.height, 1))
        }

        let representations = image.representations
        let width = representations.map(\.pixelsWide).max() ?? Int(image.size.width.rounded())
        let height = representations.map(\.pixelsHigh).max() ?? Int(image.size.height.rounded())
        return (max(width, 1), max(height, 1))
    }
}
