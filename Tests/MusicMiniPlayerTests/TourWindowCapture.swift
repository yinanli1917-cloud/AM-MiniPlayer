/**
 * [INPUT]: CoreGraphics window-list capture (own windows only).
 * [OUTPUT]: TourWindowCapture: image(of:), composite(through:in:), writePNG, cgRect.
 * [POS]: Tests. WindowServer pixels of the tour's real windows, including Liquid Glass.
 */

import AppKit
import CoreGraphics
@testable import MusicMiniPlayerAppKit

/// Real-window capture for the tour card tests. `ImageRenderer` /
/// `cacheDisplay` only ever see the SwiftUI view — never the window's own
/// clipping, its transparency, or Liquid Glass (the render server draws that).
/// These helpers ask WindowServer for the composited pixels of OUR OWN windows
/// (no Screen Recording permission needed for a process's own windows).
enum TourWindowCapture {
    /// The window's composited pixels at backing scale, without the system
    /// shadow ring. Transparent parts of the window come back with alpha 0.
    static func image(of window: NSWindow) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                [.boundsIgnoreFraming, .bestResolution])
    }

    /// `window` plus everything below it inside `rect` (global CG coordinates,
    /// y-down), composited by WindowServer — real glass included. Pass an opaque
    /// backdrop window under the card and nothing else on screen shows through.
    /// (The array variant `CGImage(windowListFromArrayScreenBounds:)` silently
    /// dropped the nonactivating panel, so this one is used instead.)
    static func composite(through window: NSWindow, in rect: CGRect) -> CGImage? {
        CGWindowListCreateImage(rect, [.optionOnScreenBelowWindow, .optionIncludingWindow], CGWindowID(window.windowNumber),
                                [.bestResolution])
    }

    static func writePNG(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    /// Screen rect (AppKit, y-up) -> CG global rect (y-down from the primary
    /// screen's top-left).
    static func cgRect(_ r: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? r.maxY
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
