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
        // The system's own rendering of the icon at this size, in the icon's own colour space. Redrawing it into an
        // untagged deviceRGB bitmap (the first version) made it read noticeably darker than the real Dock icon
        // (founder 2026-10-02; mean green 119 vs 139).
        var proposed = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let space = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let cgx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Exactly `pixels` square, scaled once with high quality, in the source's own colour space.
        cgx.interpolationQuality = .high
        cgx.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let cg = cgx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }

        // Tight box of the visible body, so the margin the icon grid leaves does not shrink it.
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let content = CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
                             width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h))
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
