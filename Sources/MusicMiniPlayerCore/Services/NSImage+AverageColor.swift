import AppKit

extension NSImage {
    func dominantColor() -> NSColor? {
        // Resize to small grid for performance
        let size = CGSize(width: 40, height: 40)
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
        
        var bestColor: (r: CGFloat, g: CGFloat, b: CGFloat, score: CGFloat) = (0, 0, 0, -1)
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = CGFloat(pixelData[offset]) / 255.0
                let g = CGFloat(pixelData[offset + 1]) / 255.0
                let b = CGFloat(pixelData[offset + 2]) / 255.0
                
                // Convert to Saturation/Brightness
                let maxComp = max(r, max(g, b))
                let minComp = min(r, min(g, b))
                let diff = maxComp - minComp
                let saturation = maxComp == 0 ? 0 : diff / maxComp
                let brightness = maxComp
                
                // Score based on saturation and brightness (favor vibrant colors)
                // Penalize very dark or very white colors
                // HEAVILY favor saturation to catch the "red sofa"
                if saturation > 0.2 && brightness > 0.15 && brightness < 0.95 {
                    let score = (saturation * 3.0) + (brightness * 0.5)
                    if score > bestColor.score {
                        bestColor = (r, g, b, score)
                    }
                }
            }
        }
        
        // Fallback to average if no vibrant color found
        if bestColor.score == -1 {
            return self.averageColor()
        }
        
        return NSColor(red: bestColor.r, green: bestColor.g, blue: bestColor.b, alpha: 1.0)
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
