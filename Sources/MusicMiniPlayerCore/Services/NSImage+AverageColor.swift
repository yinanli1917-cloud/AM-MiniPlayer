import AppKit

extension NSImage {
    // 🔑 共享 CIContext，避免重复创建（性能优化）
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    func dominantColor() -> NSColor? {
        // 🔑 减小采样尺寸：50x50 -> 30x30（减少 64% 像素计算）
        let size = CGSize(width: 30, height: 30)
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let context = Self.sharedCIContext  // 🔑 复用共享 context
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
            print("⚠️ No vibrant color found, using average")
            return self.averageColor()
        }

        // 极端增强饱和度和明度以便测试
        let nsColor = NSColor(red: bestColor.r, green: bestColor.g, blue: bestColor.b, alpha: 1.0)

        // 转换到HSB色彩空间进行增强
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // 大幅增强：匹配图片中红沙发的鲜艳度
        let enhancedSaturation = min(saturation * 3.5, 0.95)  // 3.5x enhancement, max 95%
        let enhancedBrightness = max(brightness * 0.75, 0.40)  // Retain 75% brightness, min 40%
        let finalAlpha: CGFloat = 0.7  // 70% transparency for Liquid Glass layering

        let finalColor = NSColor(hue: hue, saturation: enhancedSaturation, brightness: enhancedBrightness, alpha: finalAlpha)
        print("🎨 Enhanced color: H=\(hue) S=\(saturation)→\(enhancedSaturation) B=\(brightness)→\(enhancedBrightness) A=\(finalAlpha)")
        return finalColor
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
        let context = Self.sharedCIContext  // 🔑 复用共享 context

        context.render(outputImage,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)

        let nsColor = NSColor(red: CGFloat(bitmap[0]) / 255,
                       green: CGFloat(bitmap[1]) / 255,
                       blue: CGFloat(bitmap[2]) / 255,
                       alpha: CGFloat(bitmap[3]) / 255)

        // 对averageColor也进行同样的大幅增强
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let enhancedSaturation = min(saturation * 3.5, 0.95)  // 3.5x enhancement, max 95%
        let enhancedBrightness = max(brightness * 0.75, 0.40)  // Retain 75% brightness, min 40%
        let alphaValue: CGFloat = 0.7  // 70% transparency for Liquid Glass layering

        print("🎨 Enhanced average color: H=\(hue) S=\(saturation)→\(enhancedSaturation) B=\(brightness)→\(enhancedBrightness) A=\(alphaValue)")
        return NSColor(hue: hue, saturation: enhancedSaturation, brightness: enhancedBrightness, alpha: alphaValue)
    }
}
