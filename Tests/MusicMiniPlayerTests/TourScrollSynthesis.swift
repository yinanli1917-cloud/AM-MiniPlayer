/**
 * [INPUT]: TourRealPanelFixture (the real panel + tour); AppKit's CGEvent/NSEvent; the Objective-C runtime.
 * [OUTPUT]: ScrollSynth + TourRealPanelFixture gesture helpers — phased trackpad scroll events built from CGEvents, routed
 *           to a window the way WindowServer's window number routes a real one, and delivered through `NSApp.sendEvent`
 *           (local monitors first, then the window).
 * [POS]: Tests. The earlier gesture tests called `panel.sendEvent` directly, which skips the local monitors and the
 *        application-level routing. A synthesized event carries no window (`NSEvent(cgEvent:)` ignores the window fields,
 *        and `postToPid` delivers it with window nil, so `NSApp.sendEvent` would drop it); `ScrollSynth.route` therefore
 *        attaches the target window to the event (a swizzle of `NSEvent.window` / `windowNumber` / `locationInWindow`, active only for events
 *        carrying that attachment). No HID posting: the events never touch the real cursor.
 */

import XCTest
import AppKit
import ObjectiveC
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

enum ScrollSynth {
    enum Momentum: Int64 { case none = 0, begin = 1, `continue` = 2, end = 3 }

    nonisolated(unsafe) private static var routedWindowKey: UInt8 = 0
    nonisolated(unsafe) private static var screenPointKey: UInt8 = 0

    /// Makes `event.window` / `event.locationInWindow` answer for `window` (events built from a CGEvent have none).
    static func route(_ event: NSEvent, to window: NSWindow, screenPoint: NSPoint) {
        _ = installRoutingOnce
        objc_setAssociatedObject(event, &routedWindowKey, window, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(event, &screenPointKey, NSValue(point: screenPoint), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static let installRoutingOnce: Void = {
        typealias WindowFn = @convention(c) (NSEvent, Selector) -> NSWindow?
        let windowSel = #selector(getter: NSEvent.window)
        if let m = class_getInstanceMethod(NSEvent.self, windowSel) {
            let orig = unsafeBitCast(method_getImplementation(m), to: WindowFn.self)
            let block: @convention(block) (NSEvent) -> NSWindow? = { ev in
                if let w = objc_getAssociatedObject(ev, &ScrollSynth.routedWindowKey) as? NSWindow { return w }
                return orig(ev, windowSel)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        typealias NumberFn = @convention(c) (NSEvent, Selector) -> Int
        let numberSel = #selector(getter: NSEvent.windowNumber)
        if let m = class_getInstanceMethod(NSEvent.self, numberSel) {
            let orig = unsafeBitCast(method_getImplementation(m), to: NumberFn.self)
            let block: @convention(block) (NSEvent) -> Int = { ev in
                if let w = objc_getAssociatedObject(ev, &ScrollSynth.routedWindowKey) as? NSWindow { return w.windowNumber }
                return orig(ev, numberSel)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        typealias PointFn = @convention(c) (NSEvent, Selector) -> NSPoint
        let locSel = #selector(getter: NSEvent.locationInWindow)
        if let m = class_getInstanceMethod(NSEvent.self, locSel) {
            let orig = unsafeBitCast(method_getImplementation(m), to: PointFn.self)
            let block: @convention(block) (NSEvent) -> NSPoint = { ev in
                if let w = objc_getAssociatedObject(ev, &ScrollSynth.routedWindowKey) as? NSWindow,
                   let v = objc_getAssociatedObject(ev, &ScrollSynth.screenPointKey) as? NSValue {
                    return w.convertPoint(fromScreen: v.pointValue)
                }
                return orig(ev, locSel)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }()

    /// One precise two-finger scroll event at `point` (screen, y up), aimed at `window` (nil: no window, like a global-monitor event).
    static func event(dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase, momentum: Momentum = .none,
                      window: NSWindow?, at point: NSPoint) -> NSEvent? {
        guard let src = CGEventSource(stateID: .privateState),
              let cg = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return nil }
        // CGEvent's phase numbering is NOT NSEvent.Phase's.
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
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        let h = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: point.x, y: h - point.y)
        cg.timestamp = mach_absolute_time()
        guard let event = NSEvent(cgEvent: cg) else { return nil }
        if let window { route(event, to: window, screenPoint: point) }
        return event
    }
}

@MainActor
extension TourRealPanelFixture {
    var panelCentre: NSPoint { NSPoint(x: panel.frame.midX, y: panel.frame.midY) }

    /// One scroll event through `NSApp.sendEvent`, aimed at the panel (or `window`) at the panel's centre (or `point`).
    func scroll(dx: CGFloat = 0, dy: CGFloat = 0, _ phase: NSEvent.Phase, momentum: ScrollSynth.Momentum = .none,
                to window: NSWindow? = nil, at point: NSPoint? = nil) {
        guard let e = ScrollSynth.event(dx: dx, dy: dy, phase: phase, momentum: momentum, window: window ?? panel, at: point ?? panelCentre) else {
            return XCTFail("could not synthesize a scroll event")
        }
        NSApp.sendEvent(e)
    }

    /// A whole realistic gesture: mayBegin, began, `steps` changed events, then `end` (ended or cancelled), then optional momentum.
    func gesture(dx: CGFloat, dy: CGFloat, steps: Int = 12, interval: Double = 0.008,
                 end: NSEvent.Phase = .ended, momentumEvents: Int = 0, to window: NSWindow? = nil) {
        scroll(.mayBegin, to: window)
        scroll(.began, to: window)
        for _ in 0..<steps { scroll(dx: dx, dy: dy, .changed, to: window); spin(interval) }
        scroll(end, to: window)
        for i in 0..<momentumEvents {
            scroll(dx: dx * 0.5, dy: dy * 0.5, [], momentum: i == 0 ? .begin : (i == momentumEvents - 1 ? .end : .continue), to: window)
            spin(interval)
        }
    }
}
