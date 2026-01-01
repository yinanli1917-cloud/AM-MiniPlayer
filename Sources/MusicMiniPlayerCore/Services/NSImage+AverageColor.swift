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
        return finalColor
    }

    /// 创建纵向延伸的模糊图像（用于全屏封面模式）
    /// - Parameters:
    ///   - blurRadius: 模糊半径
    ///   - extensionRatio: 底部延伸比例（相对于原图高度）
    /// - Returns: 模糊后且底部延伸的完整图像
    func blurredWithBottomExtension(blurRadius: CGFloat = 30, extensionRatio: CGFloat = 0.3) -> NSImage? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let context = Self.sharedCIContext
        var inputImage = CIImage(cgImage: cgImage)
        let originalExtent = inputImage.extent
        let originalWidth = originalExtent.width
        let originalHeight = originalExtent.height
        let extensionHeight = originalHeight * extensionRatio

        // 🔑 先对整个图片进行高斯模糊
        if let blurFilter = CIFilter(name: "CIGaussianBlur") {
            blurFilter.setValue(inputImage, forKey: kCIInputImageKey)
            blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
            if let blurredOutput = blurFilter.outputImage {
                inputImage = blurredOutput.cropped(to: originalExtent)
            }
        }

        // 🔑 提取底部像素条（用于延伸）
        let stripHeight: CGFloat = 2
        let bottomStripRect = CGRect(
            x: originalExtent.origin.x,
            y: originalExtent.origin.y,
            width: originalWidth,
            height: stripHeight
        )
        let bottomStrip = inputImage.cropped(to: bottomStripRect)

        // 🔑 创建新的画布（原图高度 + 延伸高度）
        let newHeight = originalHeight + extensionHeight
        let newSize = NSSize(width: originalWidth, height: newHeight)

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()

        // 绘制延伸部分（底部像素条拉伸）- 在画布底部
        if let stripCGImage = context.createCGImage(bottomStrip, from: bottomStrip.extent) {
            let stripNSImage = NSImage(cgImage: stripCGImage, size: NSSize(width: originalWidth, height: stripHeight))
            // 拉伸到延伸区域
            stripNSImage.draw(in: NSRect(x: 0, y: 0, width: originalWidth, height: extensionHeight),
                              from: NSRect(x: 0, y: 0, width: stripNSImage.size.width, height: stripNSImage.size.height),
                              operation: .copy,
                              fraction: 1.0)
        }

        // 绘制模糊后的原图 - 在延伸部分上方
        if let blurredCGImage = context.createCGImage(inputImage, from: inputImage.extent) {
            let blurredNSImage = NSImage(cgImage: blurredCGImage, size: NSSize(width: originalWidth, height: originalHeight))
            blurredNSImage.draw(in: NSRect(x: 0, y: extensionHeight, width: originalWidth, height: originalHeight),
                                from: NSRect(x: 0, y: 0, width: blurredNSImage.size.width, height: blurredNSImage.size.height),
                                operation: .copy,
                                fraction: 1.0)
        }

        newImage.unlockFocus()
        return newImage
    }

    /// 提取图片底部边缘的平均颜色（备用方法）
    /// - Parameter blurRadius: 模糊半径，用于模拟封面底部的渐进模糊效果
    /// - Returns: 模糊后的底部边缘颜色
    func bottomEdgeColor(blurRadius: CGFloat = 20) -> NSColor? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let context = Self.sharedCIContext
        var inputImage = CIImage(cgImage: cgImage)

        // 🔑 先对整个图片进行高斯模糊（模拟封面底部的渐进模糊效果）
        if let blurFilter = CIFilter(name: "CIGaussianBlur") {
            blurFilter.setValue(inputImage, forKey: kCIInputImageKey)
            blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
            if let blurredOutput = blurFilter.outputImage {
                // 裁剪回原始尺寸（模糊会扩展边界）
                inputImage = blurredOutput.cropped(to: inputImage.extent)
            }
        }

        // 🔑 提取模糊图片底部 15% 区域的平均颜色
        let imageHeight = inputImage.extent.height
        let sampleHeight = imageHeight * 0.15  // 底部 15%
        let bottomRect = CGRect(
            x: inputImage.extent.origin.x,
            y: inputImage.extent.origin.y,  // CIImage Y轴从底部开始
            width: inputImage.extent.width,
            height: sampleHeight
        )

        let extentVector = CIVector(x: bottomRect.origin.x,
                                    y: bottomRect.origin.y,
                                    z: bottomRect.width,
                                    w: bottomRect.height)

        guard let avgFilter = CIFilter(name: "CIAreaAverage",
                                       parameters: [kCIInputImageKey: inputImage,
                                                    kCIInputExtentKey: extentVector]) else { return nil }
        guard let outputImage = avgFilter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)

        context.render(outputImage,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)

        // 返回模糊后的底部颜色
        return NSColor(red: CGFloat(bitmap[0]) / 255,
                       green: CGFloat(bitmap[1]) / 255,
                       blue: CGFloat(bitmap[2]) / 255,
                       alpha: 1.0)
    }

    /// 创建用于底部延伸的像素条（全部使用 CIImage 处理，避免坐标系混淆）
    /// - Parameters:
    ///   - targetSize: 目标正方形尺寸（与封面显示尺寸一致）
    ///   - blurRadius: 模糊半径
    ///   - stripHeight: 底部像素条高度
    /// - Returns: 模糊后的底部像素条（可用于纵向拉伸）
    func blurredBottomStrip(targetSize: CGFloat, blurRadius: CGFloat = 25, stripHeight: CGFloat = 4) -> NSImage? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)
        var inputImage = CIImage(cgImage: cgImage)

        // 🔑 Step 1: 用 CIImage 模拟 scaledToFill + clipped
        // 计算缩放比例（填满正方形）
        let scale = max(targetSize / originalWidth, targetSize / originalHeight)

        // 缩放
        guard let scaleFilter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        scaleFilter.setValue(inputImage, forKey: kCIInputImageKey)
        scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
        scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let scaledImage = scaleFilter.outputImage else { return nil }

        // 居中裁剪成正方形
        // CIImage 坐标系：Y=0 在底部
        let scaledWidth = originalWidth * scale
        let scaledHeight = originalHeight * scale
        let cropX = (scaledWidth - targetSize) / 2
        let cropY = (scaledHeight - targetSize) / 2
        let squareImage = scaledImage.cropped(to: CGRect(x: cropX, y: cropY, width: targetSize, height: targetSize))

        // 🔑 Step 2: 高斯模糊
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(squareImage, forKey: kCIInputImageKey)
        blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let blurredImage = blurFilter.outputImage else { return nil }

        // 裁剪回正方形尺寸（模糊会扩展边界）
        // 注意：cropped 后 extent.origin 会保持原来的值
        let blurredExtent = squareImage.extent
        let croppedBlurred = blurredImage.cropped(to: blurredExtent)

        // 🔑 Step 3: 提取底部像素条
        // CIImage 坐标系：Y=0 在底部，所以从 extent.origin.y 开始就是底边
        let bottomStripRect = CGRect(
            x: croppedBlurred.extent.origin.x,
            y: croppedBlurred.extent.origin.y,  // 底边
            width: targetSize,
            height: stripHeight
        )
        let bottomStripCI = croppedBlurred.cropped(to: bottomStripRect)

        // 转换为 NSImage
        guard let stripCGImage = Self.sharedCIContext.createCGImage(bottomStripCI, from: bottomStripCI.extent) else { return nil }
        return NSImage(cgImage: stripCGImage, size: NSSize(width: targetSize, height: stripHeight))
    }

    /// 计算图片的感知亮度（0-1，0=黑，1=白）
    /// 用于判断是否需要使用深色 UI 元素
    func perceivedBrightness() -> CGFloat {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0.5 }

        let inputImage = CIImage(cgImage: cgImage)
        let extentVector = CIVector(x: inputImage.extent.origin.x,
                                    y: inputImage.extent.origin.y,
                                    z: inputImage.extent.size.width,
                                    w: inputImage.extent.size.height)

        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: inputImage,
                                                 kCIInputExtentKey: extentVector]) else { return 0.5 }
        guard let outputImage = filter.outputImage else { return 0.5 }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = Self.sharedCIContext

        context.render(outputImage,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)

        let r = CGFloat(bitmap[0]) / 255.0
        let g = CGFloat(bitmap[1]) / 255.0
        let b = CGFloat(bitmap[2]) / 255.0

        // 使用感知亮度公式（人眼对绿色更敏感）
        let perceivedBrightness = 0.299 * r + 0.587 * g + 0.114 * b
        return perceivedBrightness
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

        return NSColor(hue: hue, saturation: enhancedSaturation, brightness: enhancedBrightness, alpha: alphaValue)
    }
}
