/**
 * [INPUT]: AppKit's NSApp.applicationIconImage (the running app's own icon) and the main bundle's
 *          icon keys; SettingsDemoDrawing's scene scale.
 * [OUTPUT]: Exports DemoAppIcon (`source` seam, `draw(in:rect:)`).
 * [POS]: The demo stage draws nanoPod's REAL icon wherever it shows "nanoPod's icon" (the Dock
 *        scene's block, the Automation still), instead of the accent-gradient stand-in. The icon is the
 *        app's own, asked for at runtime (the same source the About page uses), never a copy bundled
 *        into the code. A process whose bundle declares no icon (unit tests, `swift run`) has no source and
 *        the stand-in is drawn; tests that want the real artwork set `source` to the repo's
 *        Resources/AppIcon.icns. The icon is re-rendered at the exact backing-pixel size of the slot it
 *        fills (2x of the stage's scale), so the downscale happens once with high-quality interpolation
 *        instead of the Canvas shrinking a 1024px bitmap, and its transparent margin is trimmed so the
 *        visible body fills the slot like the stand-in did.
 */

import SwiftUI
import AppKit

enum DemoAppIcon {

    /// The icon to draw; nil = use the stand-in. Production: the running app's own icon when its bundle
    /// declares one.
    nonisolated(unsafe) static var source: () -> NSImage? = {
        let info = Bundle.main
        guard info.object(forInfoDictionaryKey: "CFBundleIconName") != nil
            || info.object(forInfoDictionaryKey: "CFBundleIconFile") != nil else { return nil }
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { NSApp?.applicationIconImage }
    }

    struct Rendered {
        let image: CGImage
        /// The visible body (alpha > 0.5) as fractions of the bitmap, top-left origin.
        let content: CGRect
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Int: Rendered] = [:]

    /// Forget rendered sizes (tests that swap `source`).
    static func resetCache() {
        lock.lock(); cache = [:]; lock.unlock()
    }

    /// The icon rendered `pixels` square, or nil when there is no source.
    static func rendered(pixels: Int) -> Rendered? {
        lock.lock()
        if let hit = cache[pixels] { lock.unlock(); return hit }
        lock.unlock()
        guard let image = source(), let made = render(image, pixels: pixels) else { return nil }
        lock.lock(); cache[pixels] = made; lock.unlock()
        return made
    }

    private static func render(_ image: NSImage, pixels: Int) -> Rendered? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }

        // Tight box of the visible body, so the margin the icon grid leaves does not shrink it.
        var minX = pixels, minY = pixels, maxX = -1, maxY = -1
        for y in 0..<pixels {
            for x in 0..<pixels where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let n = CGFloat(pixels)
        let content = CGRect(x: CGFloat(minX) / n, y: CGFloat(minY) / n,
                             width: CGFloat(maxX - minX + 1) / n, height: CGFloat(maxY - minY + 1) / n)
        return Rendered(image: cg, content: content)
    }

    /// Draw the icon so its visible body fills `rect` (scene units). False = no source; the caller draws the stand-in.
    @discardableResult
    static func draw(in ctx: inout GraphicsContext, rect: CGRect) -> Bool {
        let pixels = max(16, Int((rect.width * DemoDrawing.sceneScale * 2).rounded()))
        guard let r = rendered(pixels: pixels), r.content.width > 0, r.content.height > 0 else { return false }
        let full = CGRect(
            x: rect.minX - r.content.minX / r.content.width * rect.width,
            y: rect.minY - r.content.minY / r.content.height * rect.height,
            width: rect.width / r.content.width,
            height: rect.height / r.content.height)
        ctx.draw(Image(decorative: r.image, scale: 1), in: full)
        return true
    }
}
