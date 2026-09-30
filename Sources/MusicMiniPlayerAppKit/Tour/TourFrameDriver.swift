/**
 * [INPUT]: AppKit, QuartzCore (CADisplayLink, macOS 14+ public API).
 * [OUTPUT]: Exports TourFrameDriver (ONE display link for every tour clock) and TourFeedbackTicker
 *           (a client of it: start / stop / onTick).
 * [POS]: MusicMiniPlayerAppKit/Tour. The card's motion (TourGuidance) and the step-completion feedback
 *        (TourCompletionFeedback) each used to own a display link, so two callbacks per refresh each ended in
 *        its own SwiftUI publish. Now there is one link for the whole tour: every active client ticks inside
 *        the same callback, in the order they became active, and the resulting SwiftUI / window changes are
 *        committed together by the one run-loop turn that follows. The link exists only while a client is
 *        active (a tour resting on a card owns no timer at all) and runs at the screen's full rate.
 */

import AppKit
import QuartzCore

@MainActor
final class TourFrameDriver: NSObject {
    static let shared = TourFrameDriver()

    /// The screen whose refresh the link follows (the panel's screen); nil = the main screen.
    var screenProvider: () -> NSScreen? = { NSScreen.main }

    private struct Client { var order: Int; weak var owner: AnyObject?; var fire: () -> Void }
    private var clients: [ObjectIdentifier: Client] = [:]
    private var nextOrder = 0
    private var link: CADisplayLink?
    private var timer: Timer?
    private var lastCallback: CFTimeInterval = 0
    /// Display-link callbacks so far (a cost seam: one per refresh no matter how many clients are active).
    private(set) var callbackCount = 0

    var isRunning: Bool { link != nil || timer != nil }
    var activeClientCount: Int { clients.count }

    func activate(_ id: ObjectIdentifier, owner: AnyObject, fire: @escaping () -> Void) {
        if clients[id] == nil {
            nextOrder += 1
            clients[id] = Client(order: nextOrder, owner: owner, fire: fire)
        } else {
            clients[id]?.fire = fire
        }
        startIfNeeded()
    }

    func deactivate(_ id: ObjectIdentifier) {
        clients[id] = nil
        if clients.isEmpty { stopLink() }
    }

    func isActive(_ id: ObjectIdentifier) -> Bool { clients[id] != nil }

    private func startIfNeeded() {
        guard link == nil, timer == nil else { return }
        lastCallback = 0
        if let screen = screenProvider() ?? NSScreen.main {
            let l = screen.displayLink(target: self, selector: #selector(fire))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func stopLink() {
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
    }

    @objc private func fire() {
        callbackCount += 1
        #if DEBUG
        let began = CACurrentMediaTime()
        let interval = lastCallback == 0 ? 0 : began - lastCallback
        lastCallback = began
        #endif
        // Clients may stop themselves (or each other) while ticking: snapshot the order, re-check each.
        let ids = clients.sorted { $0.value.order < $1.value.order }.map(\.key)
        for id in ids {
            guard let client = clients[id] else { continue }
            // An owner that went away without stopping must not keep the link alive.
            guard client.owner != nil else { clients[id] = nil; continue }
            client.fire()
        }
        if clients.isEmpty { stopLink() }
        #if DEBUG
        TourPerfProbe.tick("driver", interval: interval, apply: CACurrentMediaTime() - began)
        #endif
    }
}

/// One clock of the tour: `start()` / `stop()` join and leave the shared driver.
@MainActor
final class TourFeedbackTicker: NSObject {
    var onTick: (() -> Void)?
    var isRunning: Bool { TourFrameDriver.shared.isActive(ObjectIdentifier(self)) }

    func start() {
        guard !isRunning else { return }
        TourFrameDriver.shared.activate(ObjectIdentifier(self), owner: self) { [weak self] in self?.onTick?() }
    }

    func stop() {
        TourFrameDriver.shared.deactivate(ObjectIdentifier(self))
    }
}
