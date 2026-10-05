/**
 * [INPUT]: Foundation, QuartzCore.
 * [OUTPUT]: Exports TourCardTrace — a DEBUG-only, off-by-default ring buffer of every write that moves the card:
 *           window frame writes (old -> new, by call site) and motion target commands (presentCard / moveCard /
 *           relayoutCard, by the controller branch that issued them).
 * [POS]: MusicMiniPlayerAppKit/Tour. The card was reported "always moving, unstable" (founder 2026-10-05); a
 *        jitter detector needs to say WHICH code wrote each move, so every writer reports itself here. Armed only by
 *        tests (`enabled`), compiled out of release builds, so the shipping card pays nothing.
 */

import Foundation
import QuartzCore

#if DEBUG
enum TourCardTrace {
    struct Event {
        var t: CFTimeInterval
        var site: String
        var detail: String
        var old: CGRect?
        var new: CGRect?
    }

    private static let lock = NSLock()
    private static var storage: [Event] = []
    private static var armed = false
    private static let capacity = 20_000

    static var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return armed }
        set { lock.lock(); armed = newValue; lock.unlock() }
    }

    static var events: [Event] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    static func reset() {
        lock.lock(); storage = []; lock.unlock()
    }

    /// A motion command or store write, with what it asked for.
    static func note(_ site: String, _ detail: @autoclosure () -> String = "") {
        lock.lock(); defer { lock.unlock() }
        guard armed else { return }
        append(Event(t: CACurrentMediaTime(), site: site, detail: detail(), old: nil, new: nil))
    }

    /// A write to the card window's frame.
    static func frameWrite(_ site: String, old: CGRect, new: CGRect, _ detail: @autoclosure () -> String = "") {
        lock.lock(); defer { lock.unlock() }
        guard armed else { return }
        append(Event(t: CACurrentMediaTime(), site: site, detail: detail(), old: old, new: new))
    }

    private static func append(_ e: Event) {
        if storage.count >= capacity { storage.removeFirst(capacity / 4) }
        storage.append(e)
    }
}
#endif
