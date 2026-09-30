/**
 * [INPUT]: TourRealPanelFixture (the REAL panel with the REAL MiniPlayerView + the real TourController,
 *          card window and ring overlay), TourWindowCapture (WindowServer pixels of our own windows).
 * [OUTPUT]: TourWindowWalkShotTests — opt-in (TOUR_WALK_SHOTS=1) walk of every tour step in both control
 *           states, light and dark, saved as composite PNGs of ONLY this process's windows.
 * [POS]: Tests. Acceptance stills for the founder's 2026-09-29 walk: last time an agent shot a FAKE panel
 *        background, which hid the anchor bugs. Here the panel is real. Nothing of any other app may be
 *        in a PNG: an opaque backdrop window sits under everything, and before each capture every window
 *        between it and our topmost window is checked to be ours — otherwise the shot is skipped.
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourWindowWalkShotTests: XCTestCase {
    private let outDir = ProcessInfo.processInfo.environment["TOUR_WALK_SHOTS_DIR"]
        ?? "/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/tour-walk-shots"

    /// A busy, colourful wallpaper stand-in: glass needs texture behind it.
    private final class Wallpaper: NSView {
        var dark = false
        override func draw(_ dirtyRect: NSRect) {
            let a = dark ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.22, alpha: 1) : NSColor(srgbRed: 0.99, green: 0.78, blue: 0.60, alpha: 1)
            let b = dark ? NSColor(srgbRed: 0.42, green: 0.16, blue: 0.46, alpha: 1) : NSColor(srgbRed: 0.50, green: 0.70, blue: 0.96, alpha: 1)
            NSGradient(starting: a, ending: b)?.draw(in: bounds, angle: 35)
            let blobs: [(NSRect, NSColor)] = [
                (NSRect(x: bounds.minX + 30, y: bounds.maxY - 330, width: 300, height: 200), dark ? .systemPink.withAlphaComponent(0.5) : .systemPink.withAlphaComponent(0.55)),
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

    private var backdrop: NSWindow?

    private func makeBackdrop(dark: Bool, visible: NSRect) -> NSWindow {
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
        return w
    }

    /// Every window in front of the backdrop (up to our topmost window) that intersects `rect` must be ours.
    private func onlyOurWindowsAbove(_ backdrop: NSWindow, in rect: CGRect) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        guard let backIndex = list.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == backdrop.windowNumber }) else { return false }
        let cgRect = TourWindowCapture.cgRect(rect)
        for entry in list[..<backIndex] {
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int, owner != pid else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            guard layer < 20 else { continue }             // menu bar / dock / system UI are above our windows and never in the composite
            guard let b = entry[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.intersects(cgRect) { return false }
        }
        return true
    }

    private var savedAppearance: NSAppearance?

    private func shoot(_ name: String, dark: Bool, fixture f: TourRealPanelFixture) throws {
        let scheme = dark ? "dark" : "light"
        let tourWindows: [NSWindow] = [f.cardWindow, f.controller.debugOverlayWindow, f.panel].compactMap { $0 }
        var rect = f.panel.frame
        if let card = f.cardWindow?.frame { rect = rect.union(card) }
        rect = rect.insetBy(dx: -28, dy: -28)
        if let backdrop { rect = rect.intersection(backdrop.frame) }
        guard let backdrop else { return }
        // The composite is "everything below this window": it must be the front-most of ours.
        guard let top = tourWindows.min(by: { (f.zRank($0) ?? .max) < (f.zRank($1) ?? .max) }) else { return }
        guard onlyOurWindowsAbove(backdrop, in: rect) else {
            print("[walk] SKIPPED \(name)-\(scheme): another app's window sits between the backdrop and our windows")
            return
        }
        guard let image = TourWindowCapture.composite(through: top, in: TourWindowCapture.cgRect(rect)) else {
            return XCTFail("no image for \(name)")
        }
        TourWindowCapture.writePNG(image, to: "\(outDir)/\(name)-\(scheme).png")
    }

    private func walk(dark: Bool) throws {
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let bd = makeBackdrop(dark: dark, visible: visible)
        backdrop = bd
        bd.orderFrontRegardless()
        defer { bd.orderOut(nil); backdrop = nil; NSApplication.shared.appearance = savedAppearance }

        let all = Set(TourStep.orderedSteps)
        func fresh(page: PlayerPage = .album, translationOn: Bool = false) -> TourRealPanelFixture {
            let f = TourRealPanelFixture(dark: dark, page: page, translationOn: translationOn)
            bd.orderFrontRegardless()
            f.panel.orderFrontRegardless()
            return f
        }
        func settle(_ f: TourRealPanelFixture, _ s: Double = 2.4) { f.spin(s) }
        func done(_ f: TourRealPanelFixture) { f.tearDown(); bd.orderFrontRegardless() }

        // S0 welcome
        var f = fresh()
        f.controller.requestTour(fromStart: true)
        settle(f); try shoot("S0-welcome", dark: dark, fixture: f); done(f)

        // S1 reveal — controls hidden: dashed ring + ghost cursor + glow; then shown: solid ring
        f = fresh(); f.hideControls(on: .album)
        f.controller.send(.resume(completed: [.connect]))
        f.spin(1.7); try shoot("S1-reveal-hidden-ghost", dark: dark, fixture: f)
        settle(f, 9); try shoot("S1-reveal-hidden-rest", dark: dark, fixture: f)
        f.showControls(on: .album); TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.signal(.controlsRevealed))
        settle(f, 3); try shoot("S1-reveal-shown-beat1done", dark: dark, fixture: f); done(f)

        // S1 on the lyrics page (the founder's case): the copy is page-neutral, the ring is on play
        f = fresh(page: .lyrics); f.showControls(on: .lyrics)
        f.controller.send(.resume(completed: [.connect]))
        settle(f, 3); try shoot("S1-reveal-onLyricsPage", dark: dark, fixture: f); done(f)

        // S2 corners: output, then the ring has jumped to Music
        f = fresh(); f.showControls(on: .album); TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect, .reveal]))
        settle(f, 2.6); try shoot("S2-corners-output", dark: dark, fixture: f)
        f.controller.send(.signal(.audioOutputMenuOpened))
        settle(f, 3); try shoot("S2-corners-music", dark: dark, fixture: f); done(f)

        // S3 lyrics
        f = fresh(); f.showControls(on: .album); TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect, .reveal, .corners]))
        settle(f, 2.6); try shoot("S3-lyrics", dark: dark, fixture: f); done(f)

        // S4 translation (translation already on)
        f = TourRealPanelFixture(dark: dark, page: .lyrics, translationOn: true)
        bd.orderFrontRegardless(); f.panel.orderFrontRegardless()
        f.showControls(on: .lyrics); f.lyricsService.debugSetCanTranslate(true); f.spin(0.5)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect, .reveal, .corners, .lyrics]))
        settle(f, 2.6); try shoot("S4-translate", dark: dark, fixture: f); done(f)

        // S5 move — on the cover, then started from the lyrics page
        f = fresh(); f.controller.send(.resume(completed: all.subtracting([.moveTuck, .back])))
        f.spin(1.4); try shoot("S5-move-cover-glyph", dark: dark, fixture: f)
        settle(f, 9); try shoot("S5-move-cover-rest", dark: dark, fixture: f); done(f)
        f = fresh(page: .lyrics); f.showControls(on: .lyrics); TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: all.subtracting([.moveTuck, .back])))
        settle(f, 2.6); try shoot("S5-move-lyrics-backToCover", dark: dark, fixture: f); done(f)

        // S6 back — strip, peek card, then the finale
        // (the real path: the move card's "Tuck it for me" button, then the strip, the peek, the click)
        f = fresh(); f.controller.send(.resume(completed: all.subtracting([.moveTuck, .back])))
        f.spin(1.0)
        f.controller.debugCardStore?.onFallback?()
        f.wait(6) { f.liquidEdge.state == .tucked }
        settle(f, 3.0); try shoot("S6-back-strip", dark: dark, fixture: f)
        f.liquidEdge.hoverEntered()
        f.wait(4) { f.liquidEdge.state == .floating }
        settle(f, 2.4); try shoot("S6-back-peek", dark: dark, fixture: f)
        f.liquidEdge.expand()
        f.spin(0.5); try shoot("S6-back-afterClick-0.5s", dark: dark, fixture: f)
        f.wait(6) { f.controller.state.phase == .finale }
        settle(f, 3.2); try shoot("S7-finale", dark: dark, fixture: f); done(f)
    }

    /// The translation step begun on the cover page: the leading beat and the ring on the bubble, then the
    /// panel on the lyrics page (beat ticked, ring on the translate button). Same capture rules as the walk.
    private func translateFromCover(dark: Bool) throws {
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let bd = makeBackdrop(dark: dark, visible: visible)
        backdrop = bd
        bd.orderFrontRegardless()
        defer { bd.orderOut(nil); backdrop = nil; NSApplication.shared.appearance = savedAppearance }

        let f = TourRealPanelFixture(dark: dark, page: .album)
        bd.orderFrontRegardless(); f.panel.orderFrontRegardless()
        f.showControls(on: .album); f.lyricsService.debugSetCanTranslate(true); f.spin(0.5)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect, .reveal, .corners, .lyrics]))
        f.spin(2.6); try shoot("tf3-S4-translate-cover", dark: dark, fixture: f)
        f.music.userManuallyOpenedLyrics = true
        f.music.currentPage = .lyrics
        f.spin(0.4)
        f.lyricsService.debugSetCanTranslate(true)
        TourHookBus.shared.controlsVisible.send(true)
        f.spin(2.6); try shoot("tf3-S4-translate-afterSwitch", dark: dark, fixture: f)
        f.tearDown(); bd.orderFrontRegardless()
    }

    func test_translateFromCover_stills_lightAndDark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOUR_WALK_SHOTS"] == "1", "opt-in: puts windows on the screen for a few seconds")
        savedAppearance = NSApplication.shared.appearance
        try translateFromCover(dark: false)
        try translateFromCover(dark: true)
    }

    func test_walkEveryStep_realPanel_lightAndDark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOUR_WALK_SHOTS"] == "1", "opt-in: puts windows on the screen for a couple of minutes")
        savedAppearance = NSApplication.shared.appearance
        try walk(dark: false)
        try walk(dark: true)
    }
}
