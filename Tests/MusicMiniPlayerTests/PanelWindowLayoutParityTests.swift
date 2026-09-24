import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerCore

/// Founder 2026-09-23: the panel window becomes exactly the panel (the
/// invisible 32pt title-bar strip on top is gone), and every page must stay
/// pixel-identical. The real MiniPlayerView is hosted twice — in the old
/// window (titled, 32pt taller, hosting view = content view, the title bar
/// giving the 32pt safe area) and through PanelWindowMetrics in a window the
/// size of the panel — and each page's rendering is compared byte for byte.
/// MusicController runs on preview data under XCTest (no Music.app).
@MainActor
final class PanelWindowLayoutParityTests: XCTestCase {
    private var windows: [NSWindow] = []
    private let music = MusicController.shared
    private var savedPage: PlayerPage = .album
    private var savedFullscreen: Any?

    override func setUp() {
        super.setUp()
        savedPage = music.currentPage
        savedFullscreen = UserDefaults.standard.object(forKey: "fullscreenAlbumCover")
    }

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        music.currentPage = savedPage
        UserDefaults.standard.set(savedFullscreen, forKey: "fullscreenAlbumCover")
        super.tearDown()
    }

    private var root: some View {
        MiniPlayerView()
            .environmentObject(music)
            .environmentObject(EdgePresentationModel())
    }

    private func titledWindow(_ size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height),
                         styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isOpaque = false
        w.backgroundColor = .clear
        windows.append(w)
        return w
    }

    /// The old window: 32pt taller than the panel it draws.
    private func oldHost(panel: NSSize) -> NSView {
        let w = titledWindow(NSSize(width: panel.width, height: panel.height + PanelWindowMetrics.tunedTopSafeArea))
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.masksToBounds = true
        w.contentView = host
        w.orderFront(nil)
        return host
    }

    /// The new window: the panel's size, content from PanelWindowMetrics.
    private func newHost(panel: NSSize) -> (window: NSWindow, host: NSView) {
        let w = titledWindow(panel)
        w.contentView = PanelWindowMetrics.makeContentView(root: root)
        w.orderFront(nil)
        return (w, w.contentView!.subviews[0])
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func bitmap(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func assertSame(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.pixelsWide, b.pixelsWide, label, file: file, line: line)
        XCTAssertEqual(a.pixelsHigh, b.pixelsHigh, label, file: file, line: line)
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              let da = a.bitmapData, let db = b.bitmapData else { return }
        let n = a.bytesPerRow * a.pixelsHigh
        var diff = 0
        for i in 0..<n where da[i] != db[i] { diff += 1 }
        XCTAssertEqual(diff, 0, "\(label): \(diff) of \(n) bytes differ", file: file, line: line)
    }

    private func comparePages(panel: NSSize) {
        let old = oldHost(panel: panel)
        let new = newHost(panel: panel)
        XCTAssertEqual(new.window.frame.size, panel, "the window is the panel")
        XCTAssertEqual(new.host.frame.size, old.frame.size, "the hosting view keeps its old geometry")

        let pages: [(String, PlayerPage, Bool)] = [
            ("album", .album, false), ("album full-screen cover", .album, true),
            ("lyrics", .lyrics, false), ("playlist", .playlist, false),
        ]
        for (label, page, fullscreen) in pages {
            UserDefaults.standard.set(fullscreen, forKey: "fullscreenAlbumCover")
            music.currentPage = page
            spin(1.2)
            let a = bitmap(old)
            XCTAssertGreaterThan(distinctPixels(a), 50, "\(label): the capture must not be blank")
            assertSame(a, bitmap(new.host), "\(label) at \(panel)")
        }
    }

    private func distinctPixels(_ rep: NSBitmapImageRep) -> Int {
        guard let d = rep.bitmapData else { return 0 }
        var set = Set<UInt32>()
        let bpp = rep.bitsPerPixel / 8
        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                let o = y * rep.bytesPerRow + x * bpp
                set.insert(UInt32(d[o]) << 16 | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]))
            }
        }
        return set.count
    }

    /// Control: simply shrinking the window (no tuned safe area) DOES change
    /// the pages, so the byte comparison above can catch a layout change.
    func test_control_naiveShrink_changesThePanel() {
        let panel = PanelWindowMetrics.defaultSize
        let old = oldHost(panel: panel)
        let w = titledWindow(panel)
        let host = NSHostingView(rootView: root)
        host.safeAreaRegions = []
        host.frame = NSRect(origin: .zero, size: NSSize(width: panel.width, height: panel.height + 32))
        let container = NSView(frame: NSRect(origin: .zero, size: panel))
        container.addSubview(host)
        w.contentView = container
        w.orderFront(nil)
        UserDefaults.standard.set(true, forKey: "fullscreenAlbumCover")
        music.currentPage = .album
        spin(1.2)
        let a = bitmap(old), b = bitmap(host)
        var diff = 0
        if let da = a.bitmapData, let db = b.bitmapData, a.pixelsHigh == b.pixelsHigh {
            for i in 0..<(a.bytesPerRow * a.pixelsHigh) where da[i] != db[i] { diff += 1 }
        }
        XCTAssertGreaterThan(diff, 1000, "without the tuned safe area the layout must differ")
    }

    func test_everyPage_pixelIdentical_atDefaultSize() {
        comparePages(panel: PanelWindowMetrics.defaultSize)
    }

    func test_everyPage_pixelIdentical_atAnotherSize() {
        comparePages(panel: PanelWindowMetrics.size(forWidth: 375))  // 375x426, whole points
    }

    /// The panel's full-bleed layers still reach into the 32pt the pages
    /// were tuned with: SwiftUI sees the same safe area as under the old
    /// title bar.
    func test_rootSeesTheTunedSafeArea() {
        var seen: EdgeInsets?
        var size: CGSize?
        let probe = GeometryReader { g in
            Color.clear.onAppear { seen = g.safeAreaInsets; size = g.size }
        }
        let w = titledWindow(PanelWindowMetrics.defaultSize)
        w.contentView = PanelWindowMetrics.makeContentView(root: probe)
        w.orderFront(nil)
        spin(0.3)
        XCTAssertEqual(seen?.top, PanelWindowMetrics.tunedTopSafeArea)
        XCTAssertEqual(size, CGSize(width: 250, height: 284))
    }

    /// Snapped to a top corner, the visible panel is 16pt from the screen's
    /// top edge (it was 48pt: 16 + the invisible strip).
    func test_topCornerSnap_panelIs16ptFromTheTop() throws {
        let v = try XCTUnwrap(NSScreen.main).visibleFrame
        let panel = SnappablePanel(contentRect: NSRect(x: v.maxX - 300, y: v.maxY - 330, width: 250, height: 284),
                                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.contentView = PanelWindowMetrics.makeContentView(root: Color.red)
        panel.reduceMotionProvider = { true }
        panel.orderFront(nil)
        windows.append(panel)
        var done = false
        panel.moveToEdgeCorner(.right) { done = true }
        XCTAssertTrue(done)
        XCTAssertEqual(v.maxY - panel.frame.maxY, 16, accuracy: 0.5)
        XCTAssertEqual(v.maxX - panel.frame.maxX, 16, accuracy: 0.5)
    }

    func test_sizeRules() {
        XCTAssertEqual(PanelWindowMetrics.defaultSize, NSSize(width: 250, height: 284))
        XCTAssertEqual(PanelWindowMetrics.minSize.width, 180)
        XCTAssertEqual(PanelWindowMetrics.minSize.height, 180 * 284 / 250, accuracy: 1e-9)
        XCTAssertEqual(PanelWindowMetrics.maxSize.height, 400 * 284 / 250, accuracy: 1e-9)
    }
}
