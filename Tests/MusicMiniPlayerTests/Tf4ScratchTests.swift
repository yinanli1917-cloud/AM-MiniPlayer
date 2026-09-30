import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class Tf4ScratchTests: XCTestCase {
    func test_fxWindowDraws() throws {
        let fb = TourCompletionFeedback(autoTick: false, random: TourSeededRandom(seed: 7))
        var e = TourFeedbackEvent(ringFrom: 6, ringTo: 7, total: 7, beatIndices: [])
        e.closesRing = true
        e.confetti = true
        e.handsOff = false
        let visible = NSScreen.main!.visibleFrame
        e.ringCenterOnScreen = CGPoint(x: visible.midX, y: visible.midY)
        e.cardFrameOnScreen = CGRect(x: visible.midX - 130, y: visible.midY - 100, width: 260, height: 300)
        fb.begin(e)
        let w = try XCTUnwrap(fb.debugSparkOverlay.window)
        print("[scratch] window visible=\(w.isVisible) frame=\(w.frame) contentView=\(String(describing: w.contentView)) contentFrame=\(String(describing: w.contentView?.frame))")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print("[scratch] after 0.3: renders=\(TourPerfProbe.count(.fxRender)) visible=\(w.isVisible) occl=\(w.occlusionState.rawValue) onActiveSpace=\(w.isOnActiveSpace)")
        for _ in 0..<100 { fb.advance(by: 1.0 / 60.0) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print("[scratch] after adv: particles=\(fb.fx.particles.count) renders=\(TourPerfProbe.count(.fxRender)) frame=\(w.contentView?.frame ?? .zero)")
        if let img = TourWindowCapture.image(of: w) {
            let rep = NSBitmapImageRep(cgImage: img)
            var ink = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) { if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { ink += 1 } } }
            print("[scratch] ink=\(ink) size=\(rep.pixelsWide)x\(rep.pixelsHigh)")
        } else { print("[scratch] no image") }
        fb.cancel()
    }

    private func surfaces(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        var out: [NSView] = []
        if String(describing: type(of: view)).contains("NativeLyricsSurfaceView") { out.append(view) }
        for sub in view.subviews { out += surfaces(in: sub) }
        return out
    }

    func test_lyricsSurfaceAfterReturningToCover() throws {
        let f = TourRealPanelFixture(page: .album)
        defer { f.tearDown() }
        print("[scratch] album start: surfaces=\(surfaces(in: f.panel.contentView?.superview).count)")
        f.showControls(on: .lyrics)
        f.spin(1.0)
        let s1 = surfaces(in: f.panel.contentView?.superview)
        print("[scratch] on lyrics: surfaces=\(s1.count) windows=\(s1.map { $0.window === f.panel })")
        f.music.currentPage = .album
        f.spin(3.0)
        let s2 = surfaces(in: f.panel.contentView?.superview)
        print("[scratch] back on cover: surfaces=\(s2.count) attached=\(s2.map { $0.window === f.panel }) frames=\(s2.map { $0.frame })")
        // Does a phased diagonal drag reach the panel through NSApp.sendEvent (monitors included)?
        if let e = f.gestureEvent(dx: 0, dy: 0, phase: .began) {
            print("[scratch] NSEvent.window for a CGEvent-born scroll: \(String(describing: e.window)) windowNumber=\(e.windowNumber)")
        }
    }
}
