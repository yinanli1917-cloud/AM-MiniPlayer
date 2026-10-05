/**
 * [INPUT]: MusicMiniPlayerCore's SnappablePanel/MiniPlayerView/PanelWindowMetrics/
 *          TourAnchorRegistry/LiquidEdgeController; MusicMiniPlayerAppKit's TourController.
 * [OUTPUT]: TourRealPanelFixture — the REAL MiniPlayerView in the REAL SnappablePanel
 *           (top-right of the main screen), plus the tour controller wired to it, and
 *           accessibility-tree lookups that give each control's true on-screen frame
 *           independently of the tour's own anchors.
 * [POS]: Tests. Shared by the anchor, gesture and window-walk tests so none of them
 *        needs a fake panel background (which is what hid the anchor bugs before).
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourRealPanelFixture {
    let music = MusicController.shared
    let lyricsService = LyricsService.shared
    let panel: SnappablePanel
    let liquidEdge: LiquidEdgeController
    let controller: TourController
    let defaults: UserDefaults
    /// Everything the tour's gesture trace writes lands here, never in the founder's ~/Library/Logs.
    let gestureWriter = TourRecordingGestureWriter()
    private let suiteName: String
    private let savedPage: PlayerPage
    private let savedPlaying: Bool
    private let savedShowTranslation: Bool
    private let savedLanguage: String?

    /// `corner`: where the panel starts (default the top-right of the main screen).
    init(corner: ScreenCorner = .topRight, dark: Bool = false, reduceMotion: Bool = false, page: PlayerPage = .album,
         translationOn: Bool = false, canTranslate: Bool = false, feedback: TourCompletionFeedback? = nil) {
        suiteName = "TourRealPanelFixture-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        savedPage = music.currentPage
        savedPlaying = music.isPlaying
        savedShowTranslation = LyricsService.shared.showTranslation
        savedLanguage = L10n.languageOverride
        L10n.languageOverride = "en"
        LyricsService.shared.showTranslation = translationOn
        LyricsService.shared.debugSetCanTranslate(canTranslate)
        TourAnchorRegistry.shared.reset()
        TourHookBus.shared.controlsVisible.send(false)
        TourHookBus.shared.audioOutputMenuPresented.send(false)
        // The lyrics page with no lyrics would otherwise fall back to the cover on its own.
        music.userManuallyOpenedLyrics = page == .lyrics
        music.currentPage = page

        let visible = NSScreen.main!.visibleFrame
        let size = PanelWindowMetrics.defaultSize
        let margin: CGFloat = 16
        let x = (corner == .topRight || corner == .bottomRight) ? visible.maxX - size.width - margin : visible.minX + margin
        let y = (corner == .topRight || corner == .topLeft) ? visible.maxY - size.height - margin : visible.minY + margin
        panel = SnappablePanel(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
                               styleMask: PanelWindowMetrics.styleMask, backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = MiniPlayerView().environmentObject(music).environmentObject(EdgePresentationModel())
        panel.contentView = PanelWindowMetrics.makeContentView(root: root)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        let music = self.music
        panel.currentPageProvider = { music.currentPage }
        panel.stageManagerEnabledProvider = { false }   // never read the machine's real Stage Manager setting
        panel.orderFrontRegardless()

        liquidEdge = LiquidEdgeController(card: panel)
        panel.liquidEdgeHandler = { [weak liquidEdge] edge in liquidEdge?.collapse(to: edge) ?? false }
        let guidance = TourGuidance(reduceMotion: { reduceMotion })
        controller = TourController(panel: panel, liquidEdge: liquidEdge, defaults: defaults, feedback: feedback, guidance: guidance, gestureLogWriter: gestureWriter)
        controller.musicWindowProvider = { nil }   // never ask the real window list (the founder's Music) unless a test injects a window
        spin(0.6)
    }

    func tearDown() {
        controller.send(.stopTour)
        spin(0.4)
        liquidEdge.reset()
        liquidEdge.stageWindow?.orderOut(nil)
        panel.orderOut(nil)
        TourAnchorRegistry.shared.reset()
        TourHookBus.shared.controlsVisible.send(false)
        TourHookBus.shared.audioOutputMenuPresented.send(false)
        music.isPlaying = savedPlaying
        music.userManuallyOpenedLyrics = false
        LyricsService.shared.debugSetCanTranslate(false)
        LyricsService.shared.showTranslation = savedShowTranslation
        L10n.languageOverride = savedLanguage
        music.currentPage = savedPage
        defaults.removePersistentDomain(forName: suiteName)
    }

    func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// Puts the controls in their SHOWN state without a mouse: switching the panel
    /// queue -> album runs the same "reveal the controls" path a hover does
    /// (MiniPlayerView.onChange(currentPage)). (Not through the lyrics page: that
    /// would also be the user opening the lyrics, which the tour counts.)
    func showControls(on page: PlayerPage) {
        if page == .album {
            music.currentPage = .playlist
            spin(0.4)
            music.currentPage = .album
        } else {
            music.currentPage = .album
            spin(0.4)
            music.userManuallyOpenedLyrics = true     // else a panel with no lyrics bounces back to the cover
            music.currentPage = .lyrics
        }
        spin(1.4)
        if music.currentPage != page { XCTFail("the fixture could not hold the panel on \(page); it is on \(music.currentPage)") }
    }

    func hideControls(on page: PlayerPage) {
        if page == .lyrics { music.userManuallyOpenedLyrics = true }
        music.currentPage = page
        spin(1.0)
    }

    // MARK: - Accessibility truth

    /// Every accessibility element under the panel's hosting view.
    func accessibilityElements() -> [(label: String, frame: NSRect)] {
        var out: [(String, NSRect)] = []
        func walk(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let obj = element as? NSObject {
                let label = (obj.value(forKey: "accessibilityLabel") as? String) ?? ""
                let frame = (obj.value(forKey: "accessibilityFrame") as? NSRect) ?? .zero
                if !label.isEmpty { out.append((label, frame)) }
                if let kids = obj.value(forKey: "accessibilityChildren") as? [Any] { kids.forEach { walk($0, depth: depth + 1) } }
            }
        }
        if let host = panel.contentView { walk(host, depth: 0) }
        return out
    }

    /// The first accessibility element whose label contains `needle`, as a
    /// screen rect (AppKit, y-up).
    func accessibilityFrame(containing needle: String) -> NSRect? {
        accessibilityElements().first { $0.label.contains(needle) && $0.frame.width > 1 }?.frame
    }
}

extension TourRealPanelFixture {
    /// Polls (spinning the run loop) until `condition` holds or `timeout` passes.
    @discardableResult
    func wait(_ timeout: Double = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            spin(0.05)
        }
        return condition()
    }

    /// Front-to-back rank of `window` among ALL on-screen windows (WindowServer's own order), or nil.
    func zRank(_ window: NSWindow) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.firstIndex { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }

    /// The ring's centre right now, screen space.
    var ringCenter: CGPoint? {
        controller.debugHaloFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// The card window as it is on screen right now.
    var cardWindow: TourCardWindow? {
        controller.debugCardWindow.flatMap { $0.isVisible ? $0 : nil }
    }

    /// Where the panel says each control rests (the published anchor rect, or the
    /// layout table before it has ever been rendered).
    func restingRect(_ id: TourAnchorID) -> CGRect {
        TourAnchorRegistry.shared.resolvedScreenRect(for: id, in: panel)
    }

    /// A phased, precise trackpad scroll event (the two-finger gesture) built from a CGEvent —
    /// synthetic wheel events from computer use carry no phases and cannot drive it.
    func gestureEvent(dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase = []) -> NSEvent? {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let cg = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return nil }
        // CGEvent's phase numbering is NOT NSEvent.Phase's (began 1, changed 2, ended 4,
        // cancelled 8, mayBegin 128; momentum begin 1, continue 2, end 3).
        let cgPhase: Int64
        switch phase {
        case .began: cgPhase = 1
        case .changed: cgPhase = 2
        case .ended: cgPhase = 4
        case .cancelled: cgPhase = 8
        case .mayBegin: cgPhase = 128
        default: cgPhase = 0
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: cgPhase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.isEmpty ? 0 : 2)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        let h = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: panel.frame.midX, y: h - panel.frame.midY)
        return NSEvent(cgEvent: cg)
    }

    /// Delivers one two-finger drag (`steps` change events, `dx`/`dy` points each) to the
    /// panel's own `sendEvent`, exactly where AppKit delivers a real trackpad gesture.
    func twoFingerDrag(dx: CGFloat, dy: CGFloat, steps: Int = 12) {
        if let e = gestureEvent(dx: 0, dy: 0, phase: .began) { panel.sendEvent(e) }
        for _ in 0..<steps {
            if let e = gestureEvent(dx: dx, dy: dy, phase: .changed) { panel.sendEvent(e) }
            spin(0.008)
        }
        if let e = gestureEvent(dx: 0, dy: 0, phase: .ended) { panel.sendEvent(e) }
    }
}
