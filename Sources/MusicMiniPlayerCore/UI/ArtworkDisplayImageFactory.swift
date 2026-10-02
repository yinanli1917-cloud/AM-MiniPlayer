import AppKit

enum ArtworkDisplayImageFactory {
    static let effectMaxPixelDimension = 768

    /// The longest side a decoded display copy keeps (the panel shows a cover at most 500px wide).
    static let displayMaxPixelDimension = 1600

    /// A cover as Core Animation wants it: decoded, premultiplied BGRA8, in the cover's own
    /// colour space. A freshly downloaded JPEG (or an NSImage from Music.app) is none of
    /// that, so every view that shows it, and every sampler that reads it, paid the decode
    /// and a Planar16/vImage colour conversion on the MAIN thread, one per consumer: 15-20ms
    /// each, five or six in a row at a track change, landing inside the edge animation that
    /// a track change starts (measured, EdgeHitchHarness). Call this where the image is
    /// produced, off the main thread; later `cgImage` reads and layer commits are plain copies.
    /// Idempotent; returns the input when it cannot be redrawn.
    static func makeDisplayArtwork(
        from image: NSImage,
        maxPixelDimension: Int = displayMaxPixelDimension
    ) -> NSImage {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              source.width > 0, source.height > 0 else { return image }

        let bgra = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let side = max(source.width, source.height)
        let alreadyNative = source.bitsPerComponent == 8
            && source.bitmapInfo.rawValue & (CGBitmapInfo.alphaInfoMask.rawValue | CGBitmapInfo.byteOrderMask.rawValue) == bgra
        if alreadyNative, side <= maxPixelDimension { return image }

        let scale = side > maxPixelDimension ? Double(maxPixelDimension) / Double(side) : 1
        let w = max(1, Int((Double(source.width) * scale).rounded()))
        let h = max(1, Int((Double(source.height) * scale).rounded()))
        // The cover's own RGB space keeps wide-gamut art wide. A device space (an untagged
        // JPEG) has no ICC profile and would still cost a per-pixel colour conversion on the
        // main thread at every commit, so it, and anything else (grey, CMYK, indexed), is
        // drawn into sRGB, which is what an untagged cover means anyway.
        let own = source.colorSpace.flatMap { $0.model == .rgb && $0.copyICCData() != nil ? $0 : nil }
        let spaces = [own, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        for space in spaces {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: bgra) else { continue }
            ctx.interpolationQuality = .high
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let out = ctx.makeImage() { return NSImage(cgImage: out, size: image.size) }
        }
        return image
    }

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
                // BGRA premultiplied: the layout Core Animation takes without a conversion pass.
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
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
