import SwiftUI
import AppKit

// MARK: - Progressive Blur Direction

public enum ProgressiveBlurDirection {
    case blurredTopClearBottom
    case blurredBottomClearTop
}

// MARK: - Progressive Blur NSView
// Based on aheze/VariableBlurView - uses private CAFilter API with NSVisualEffectView's CABackdropLayer

public class ProgressiveBlurNSView: NSVisualEffectView {
    
    public var maxBlurRadius: CGFloat = 20
    public var direction: ProgressiveBlurDirection = .blurredBottomClearTop
    private var isConfigured = false
    
    public init(
        gradientMask: NSImage? = nil,
        maxBlurRadius: CGFloat = 20,
        direction: ProgressiveBlurDirection = .blurredBottomClearTop
    ) {
        self.maxBlurRadius = maxBlurRadius
        self.direction = direction
        super.init(frame: .zero)
        
        // Configure NSVisualEffectView
        self.material = .hudWindow
        self.blendingMode = .withinWindow
        self.state = .active
        
        print("[ProgressiveBlur] init called, maxBlurRadius: \(maxBlurRadius), direction: \(direction)")
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.material = .hudWindow
        self.blendingMode = .withinWindow
        self.state = .active
    }
    
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Delay configuration to ensure view is in hierarchy
        DispatchQueue.main.async { [weak self] in
            self?.configureVariableBlur()
        }
    }
    
    public override func layout() {
        super.layout()
        // Reconfigure when size changes
        if bounds.width > 0 && bounds.height > 0 {
            configureVariableBlur()
        }
    }
    
    private func configureVariableBlur() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        
        // Debug: Print NSVisualEffectView structure
        print("[ProgressiveBlur] Bounds: \(bounds)")
        print("[ProgressiveBlur] Subviews count: \(subviews.count)")
        for (index, subview) in subviews.enumerated() {
            print("[ProgressiveBlur] Subview[\(index)]: \(type(of: subview)), layer: \(String(describing: subview.layer)), layer.filters: \(String(describing: subview.layer?.filters))")
        }
        print("[ProgressiveBlur] Self layer: \(String(describing: layer)), filters: \(String(describing: layer?.filters))")
        
        // Private QuartzCore class: "CAFilter" (base64 encoded)
        let filterClassStringEncoded = "Q0FGaWx0ZXI="
        guard let filterClassData = Data(base64Encoded: filterClassStringEncoded),
              let filterClassString = String(data: filterClassData, encoding: .utf8) else {
            print("[ProgressiveBlur] Couldn't decode filter class string")
            return
        }
        
        // Private method: "filterWithType:" (base64 encoded)
        let filterWithTypeEncoded = "ZmlsdGVyV2l0aFR5cGU6"
        guard let filterMethodData = Data(base64Encoded: filterWithTypeEncoded),
              let filterMethodString = String(data: filterMethodData, encoding: .utf8) else {
            print("[ProgressiveBlur] Couldn't decode filter method string")
            return
        }
        
        let filterSelector = Selector(filterMethodString)
        
        guard let filterClass = NSClassFromString(filterClassString) as AnyObject as? NSObjectProtocol else {
            print("[ProgressiveBlur] Couldn't create CAFilter class")
            return
        }
        
        guard filterClass.responds(to: filterSelector) else {
            print("[ProgressiveBlur] CAFilter doesn't respond to filterWithType:")
            return
        }
        
        // Create variable blur filter
        let variableBlur = filterClass.perform(filterSelector, with: "variableBlur").takeUnretainedValue()
        print("[ProgressiveBlur] Created variableBlur filter: \(variableBlur)")
        
        guard let variableBlurFilter = variableBlur as? NSObject else {
            print("[ProgressiveBlur] Couldn't cast blur filter")
            return
        }
        
        // Create gradient mask image
        guard let maskCGImage = createGradientMask(size: bounds.size) else {
            print("[ProgressiveBlur] Couldn't create gradient mask")
            return
        }
        print("[ProgressiveBlur] Created mask image: \(maskCGImage.width)x\(maskCGImage.height)")
        
        // Configure the filter:
        // - inputRadius: blur radius where mask is opaque
        // - inputMaskImage: gradient mask (alpha 1 = full blur, alpha 0 = no blur)
        // - inputNormalizeEdges: helps with edge artifacts
        variableBlurFilter.setValue(maxBlurRadius, forKey: "inputRadius")
        variableBlurFilter.setValue(maskCGImage, forKey: "inputMaskImage")
        variableBlurFilter.setValue(true, forKey: "inputNormalizeEdges")
        
        // Remove tint/dimming overlay to avoid hard line
        if subviews.count > 1 {
            let tintView = subviews[1]
            tintView.alphaValue = 0
            print("[ProgressiveBlur] Set tint view alpha to 0")
        }
        
        // Try applying to different layers
        // Option 1: First subview's layer (like UIVisualEffectView)
        if let firstSubview = subviews.first, let backdropLayer = firstSubview.layer {
            print("[ProgressiveBlur] Applying to first subview layer: \(backdropLayer)")
            backdropLayer.filters = [variableBlurFilter]
        }
        
        // Option 2: Also try self.layer
        if let selfLayer = self.layer {
            print("[ProgressiveBlur] Self layer class: \(type(of: selfLayer))")
            // Don't override self.layer.filters as it might break NSVisualEffectView
        }
        
        isConfigured = true
        print("[ProgressiveBlur] Configuration complete")
    }
    
    private func createGradientMask(size: CGSize) -> CGImage? {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        
        // Use RGBA context for proper alpha channel support
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        // The mask alpha controls blur intensity:
        // Alpha 1.0 (opaque) = full blur radius
        // Alpha 0.0 (transparent) = no blur
        let colors: [CGColor]
        let locations: [CGFloat]
        
        switch direction {
        case .blurredTopClearBottom:
            // Top is blurred, bottom is clear
            // CGContext origin is bottom-left, so we draw from bottom to top
            colors = [
                NSColor.clear.cgColor,           // bottom (no blur)
                NSColor.black.withAlphaComponent(0.3).cgColor,
                NSColor.black.withAlphaComponent(0.7).cgColor,
                NSColor.black.cgColor            // top (full blur)
            ]
            locations = [0.0, 0.3, 0.6, 1.0]
        case .blurredBottomClearTop:
            // Bottom is blurred, top is clear
            colors = [
                NSColor.black.cgColor,           // bottom (full blur)
                NSColor.black.withAlphaComponent(0.7).cgColor,
                NSColor.black.withAlphaComponent(0.3).cgColor,
                NSColor.clear.cgColor            // top (no blur)
            ]
            locations = [0.0, 0.4, 0.7, 1.0]
        }
        
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) else { return nil }
        
        // Draw vertical gradient
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: CGFloat(height)),
            options: []
        )
        
        return ctx.makeImage()
    }
}

// MARK: - SwiftUI Wrapper

public struct ProgressiveBlurView: NSViewRepresentable {
    public var maxBlurRadius: CGFloat
    public var direction: ProgressiveBlurDirection
    
    public init(
        maxBlurRadius: CGFloat = 20,
        direction: ProgressiveBlurDirection = .blurredBottomClearTop
    ) {
        self.maxBlurRadius = maxBlurRadius
        self.direction = direction
    }
    
    public func makeNSView(context: Context) -> ProgressiveBlurNSView {
        let view = ProgressiveBlurNSView(
            maxBlurRadius: maxBlurRadius,
            direction: direction
        )
        return view
    }
    
    public func updateNSView(_ nsView: ProgressiveBlurNSView, context: Context) {
        nsView.maxBlurRadius = maxBlurRadius
        nsView.direction = direction
    }
}

// MARK: - View Extension

public extension View {
    func progressiveBlurOverlay(
        maxBlurRadius: CGFloat = 20,
        direction: ProgressiveBlurDirection = .blurredBottomClearTop,
        height: CGFloat = 80,
        alignment: Alignment = .bottom
    ) -> some View {
        self.overlay(alignment: alignment) {
            ProgressiveBlurView(
                maxBlurRadius: maxBlurRadius,
                direction: direction
            )
            .frame(height: height)
        }
    }
}
