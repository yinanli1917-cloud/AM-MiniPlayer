/**
 * [INPUT]: TourRealPanelFixture, TourWindowCapture (WindowServer pixels of this process's own windows).
 * [OUTPUT]: TourShotStudio — an opaque wallpaper window under the real panel + tour windows and a
 *           `shoot` that composites ONLY this process's windows (light or dark).
 * [POS]: Tests. Shared by the opt-in acceptance stills (TOUR_FIX4_SHOTS=1). Same rules as the walk test:
 *        nothing of any other app may be in a PNG — before each capture every window between the
 *        backdrop and our topmost window is checked to be ours, otherwise the shot is skipped.
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourShotStudio {
    static let outDir = ProcessInfo.processInfo.environment["TOUR_FIX4_SHOTS_DIR"]
        ?? "/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/tour-fix4-shots"

    /// A busy, colourful wallpaper stand-in: glass needs texture behind it.
    private final class Wallpaper: NSView {
        var dark = false
        override func draw(_ dirtyRect: NSRect) {
            let a = dark ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.22, alpha: 1) : NSColor(srgbRed: 0.99, green: 0.78, blue: 0.60, alpha: 1)
            let b = dark ? NSColor(srgbRed: 0.42, green: 0.16, blue: 0.46, alpha: 1) : NSColor(srgbRed: 0.50, green: 0.70, blue: 0.96, alpha: 1)
            NSGradient(starting: a, ending: b)?.draw(in: bounds, angle: 35)
            let blobs: [(NSRect, NSColor)] = [
                (NSRect(x: bounds.minX + 30, y: bounds.maxY - 330, width: 300, height: 200), .systemPink.withAlphaComponent(dark ? 0.5 : 0.55)),
                (NSRect(x: bounds.midX - 100, y: bounds.midY - 60, width: 320, height: 220), dark ? .systemTeal.withAlphaComponent(0.45) : .systemYellow.withAlphaComponent(0.6)),
                (NSRect(x: bounds.minX + 60, y: 40, width: 360, height: 200), dark ? .systemPurple.withAlphaComponent(0.5) : .systemGreen.withAlphaComponent(0.4)),
            ]
            for (r, c) in blobs { c.setFill(); NSBezierPath(ovalIn: r).fill() }
            (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.30).setFill()
            for row in 0..<26 {
                for col in 0..<28 {
                    NSBezierPath(roundedRect: NSRect(x: 20 + CGFloat(col) * 23 + CGFloat(row % 3) * 5, y: 16 + CGFloat(row) * 28, width: 15, height: 6), xRadius: 2, yRadius: 2).fill()
                }
            }
        }
    }

    let dark: Bool
    let backdrop: NSWindow
    private let savedAppearance: NSAppearance?
    private(set) var skipped: [String] = []

    init(dark: Bool) {
        self.dark = dark
        savedAppearance = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let visible = NSScreen.main!.visibleFrame
        let size = CGSize(width: 700, height: 780)
        let frame = NSRect(x: visible.maxX - size.width, y: visible.maxY - size.height, width: size.width, height: size.height)
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.hasShadow = false
        w.level = .floating
        w.isOpaque = true
        w.hidesOnDeactivate = false
        w.ignoresMouseEvents = true
        let v = Wallpaper(frame: NSRect(origin: .zero, size: size))
        v.dark = dark
        w.contentView = v
        backdrop = w
        w.orderFrontRegardless()
    }

    func finish() {
        backdrop.orderOut(nil)
        NSApplication.shared.appearance = savedAppearance
    }

    /// The backdrop goes back under everything (a fixture re-fronts its panel on creation).
    func settleBackdrop(_ f: TourRealPanelFixture) {
        backdrop.orderFrontRegardless()
        f.panel.orderFrontRegardless()
    }

    private func onlyOurWindowsAbove(in rect: CGRect) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        guard let backIndex = list.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == backdrop.windowNumber }) else { return false }
        let cgRect = TourWindowCapture.cgRect(rect)
        for entry in list[..<backIndex] {
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int, owner != pid else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            guard layer < 20 else { continue }
            guard let b = entry[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.intersects(cgRect) { return false }
        }
        return true
    }

    /// Composite of the panel + card (+ FX window when `includeFX`) over the backdrop, written to `name-light|dark.png`.
    @discardableResult
    func shoot(_ name: String, fixture f: TourRealPanelFixture, includeFX: Bool = false, extraRect: CGRect? = nil) -> CGImage? {
        var windows: [NSWindow] = [f.cardWindow, f.controller.debugOverlayWindow, f.panel].compactMap { $0 }
        var rect = f.panel.frame
        if let card = f.cardWindow?.frame { rect = rect.union(card) }
        if includeFX, let fx = f.controller.debugFeedback.debugSparkOverlay.window, fx.isVisible {
            windows.append(fx)
            rect = rect.union(fx.frame)
        }
        if let extraRect { rect = rect.union(extraRect) }
        rect = rect.insetBy(dx: -28, dy: -28).intersection(backdrop.frame)
        guard let top = windows.min(by: { (f.zRank($0) ?? .max) < (f.zRank($1) ?? .max) }) else { return nil }
        guard onlyOurWindowsAbove(in: rect) else {
            skipped.append(name)
            print("[shots] SKIPPED \(name): another app's window sits between the backdrop and our windows")
            return nil
        }
        guard let image = TourWindowCapture.composite(through: top, in: TourWindowCapture.cgRect(rect)) else { return nil }
        let scheme = dark ? "dark" : "light"
        TourWindowCapture.writePNG(image, to: "\(Self.outDir)/\(name)-\(scheme).png")
        return image
    }
}
