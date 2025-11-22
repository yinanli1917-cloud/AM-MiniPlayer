import AppKit

extension NSImage {
    func dominantColor() -> NSColor? {
        // Resize to small grid for performance
        let size = CGSize(width: 50, height: 50)
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let context = CIContext(options: nil)
        let inputImage = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CILanczosScaleTransform")
        filter?.setValue(inputImage, forKey: kCIInputImageKey)
        filter?.setValue(size.width / CGFloat(cgImage.width), forKey: kCIInputScaleKey)
        filter?.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let outputImage = filter?.outputImage,
              let resizedCGImage = context.createCGImage(outputImage, from: outputImage.extent) else { return nil }

        let width = resizedCGImage.width
        let height = resizedCGImage.height
        let dataSize = width * height * 4
        var pixelData = [UInt8](repeating: 0, count: dataSize)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixelData,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 4 * width,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        ctx.draw(resizedCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Collect vibrant colors with their frequency
        var colorBuckets: [String: (r: CGFloat, g: CGFloat, b: CGFloat, count: Int, saturation: CGFloat, brightness: CGFloat)] = [:]

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = CGFloat(pixelData[offset]) / 255.0
                let g = CGFloat(pixelData[offset + 1]) / 255.0
                let b = CGFloat(pixelData[offset + 2]) / 255.0

                // Convert to HSB
                let maxComp = max(r, max(g, b))
                let minComp = min(r, min(g, b))
                let diff = maxComp - minComp
                let saturation = maxComp == 0 ? 0 : diff / maxComp
                let brightness = maxComp

                // Only consider vibrant colors
                if saturation > 0.3 && brightness > 0.2 && brightness < 0.9 {
                    // Quantize to reduce similar colors (16 buckets per channel)
                    let rBucket = Int(r * 15)
                    let gBucket = Int(g * 15)
                    let bBucket = Int(b * 15)
                    let key = "\(rBucket)-\(gBucket)-\(bBucket)"

                    if var existing = colorBuckets[key] {
                        existing.count += 1
                        colorBuckets[key] = existing
                    } else {
                        colorBuckets[key] = (r, g, b, 1, saturation, brightness)
                    }
                }
            }
        }

        // Find the most prominent vibrant color (high saturation + high frequency)
        var bestColor: (r: CGFloat, g: CGFloat, b: CGFloat, score: CGFloat) = (0, 0, 0, -1)

        for (_, colorInfo) in colorBuckets {
            // Score = saturation * 5 + frequency weight + brightness
            let frequencyWeight = CGFloat(colorInfo.count) / CGFloat(width * height) * 100.0
            let score = colorInfo.saturation * 5.0 + frequencyWeight * 2.0 + colorInfo.brightness * 0.3

            if score > bestColor.score {
                bestColor = (colorInfo.r, colorInfo.g, colorInfo.b, score)
            }
        }

        // Fallback to average if no vibrant color found
        if bestColor.score == -1 {
            return self.averageColor()
        }

        // Enhance saturation by 30% to make the color more vibrant
        let color = NSColor(red: bestColor.r, green: bestColor.g, blue: bestColor.b, alpha: 1.0)
        let hsbColor = color.usingColorSpace(.deviceRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        hsbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        // Boost saturation but REDUCE brightness significantly for vintage/deep colors
        let enhancedSaturation = min(1.0, saturation * 1.5)
        let enhancedBrightness = max(0.25, min(0.6, brightness * 0.75))

        return NSColor(hue: hue, saturation: enhancedSaturation, brightness: enhancedBrightness, alpha: 1.0)
    }

    func averageColor() -> NSColor? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        
        let inputImage = CIImage(cgImage: cgImage)
        let extentVector = CIVector(x: inputImage.extent.origin.x,
                                    y: inputImage.extent.origin.y,
                                    z: inputImage.extent.size.width,
                                    w: inputImage.extent.size.height)
        
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: inputImage,
                                                 kCIInputExtentKey: extentVector]) else { return nil }
        guard let outputImage = filter.outputImage else { return nil }
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull!])
        
        context.render(outputImage,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)
        
        return NSColor(red: CGFloat(bitmap[0]) / 255,
                       green: CGFloat(bitmap[1]) / 255,
                       blue: CGFloat(bitmap[2]) / 255,
                       alpha: CGFloat(bitmap[3]) / 255)
    }
}
