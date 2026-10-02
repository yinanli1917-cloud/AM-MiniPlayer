/**
 * [INPUT]: CoreGraphics (CGRect, the CGWindowList key names) only.
 * [OUTPUT]: Exports TourMusicWindowLocator (picks the player app's main window out of a
 *           CGWindowListCopyWindowInfo array, converts CG space to AppKit screen space) and
 *           TourMusicWindowTracker (pure sampling policy: when is a frame "settled", when did
 *           the window move or go away, how often to look).
 * [POS]: MusicMiniPlayerCore/Onboarding. The corners step's Music beat opens the player app; the
 *        tour card hops over to that app's window (founder 2026-10-02). Everything here is a
 *        pure function of injected values — the live window list, the timer and the card live in
 *        `TourController` / `TourMusicWindowWatcher` (AppKit), so `TourMusicWindowTests` need no
 *        real window and never touch the real Music app.
 */

import CoreGraphics
import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourMusicWindowLocator
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public enum TourMusicWindowLocator {
    /// Anything smaller is a helper / shadow window, never the app's window.
    public static let minimumSide: CGFloat = 40

    /// The bounds (CG space: origin top-left of the primary display, y down) of the largest ordinary
    /// (layer 0), on-screen window owned by `ownerPID`. Window NAMES are not used: they need Screen
    /// Recording permission, owner PID and bounds do not.
    public static func mainWindowBounds(in infos: [[String: Any]], ownerPID: pid_t) -> CGRect? {
        var best: (rect: CGRect, area: CGFloat)?
        for info in infos {
            guard int(info[kCGWindowOwnerPID as String]) == Int(ownerPID) else { continue }
            guard (int(info[kCGWindowLayer as String]) ?? 0) == 0 else { continue }
            if let onscreen = info[kCGWindowIsOnscreen as String] as? Bool, !onscreen { continue }
            if let alpha = double(info[kCGWindowAlpha as String]), alpha <= 0.01 { continue }
            guard let rect = bounds(info[kCGWindowBounds as String]),
                  rect.width >= minimumSide, rect.height >= minimumSide else { continue }
            let area = rect.width * rect.height
            if best == nil || area > best!.area { best = (rect, area) }
        }
        return best?.rect
    }

    /// CG window bounds (y down from the primary display's top) -> AppKit screen rect (y up from its bottom).
    public static func appKitRect(fromCG rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func int(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? NSNumber { return v.intValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? NSNumber { return v.doubleValue }
        return nil
    }

    /// `kCGWindowBounds` is a {X, Y, Width, Height} dictionary (CFDictionary at runtime).
    private static func bounds(_ value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any],
              let x = double(dict["X"]), let y = double(dict["Y"]),
              let w = double(dict["Width"]), let h = double(dict["Height"]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - TourMusicWindowTracker
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// What to do with each sample of the player app's window frame while the tour waits for the user.
/// Searching (the app is still opening, its window animates in): a quick look about six times a second
/// until two consecutive frames agree, for at most `searchDeadline` seconds. Tracking (the card stands by
/// the window): a slow look every `trackInterval`, only to follow a moved window or notice a closed one.
public struct TourMusicWindowTracker {
    public struct Timing: Equatable {
        public var searchInterval: TimeInterval = 0.16
        public var searchDeadline: TimeInterval = 2.0
        public var trackInterval: TimeInterval = 0.5
        /// Two frames closer than this on every edge are "the same" (the window has stopped animating).
        public var settleTolerance: CGFloat = 2
        /// A tracked frame further than this on any edge moved.
        public var moveTolerance: CGFloat = 4
        /// Consecutive empty samples before the window counts as gone.
        public var missesToLose: Int = 2
        public init() {}
    }

    public enum Event: Equatable {
        /// A settled frame: the card can go over there.
        case found(CGRect)
        /// The window moved or resized while the card was there.
        case moved(CGRect)
        /// The window went away (closed, minimised, another Space): the card goes back beside the panel.
        case lost
        /// No window ever showed up within the search deadline: stay where we are.
        case gaveUp
    }

    private enum Mode { case searching, tracking, finished }

    public let timing: Timing
    private var mode: Mode = .searching
    private var lastSeen: CGRect?
    private var misses = 0

    public init(timing: Timing = Timing()) { self.timing = timing }

    /// How long to wait before the next sample; nil = done, take no more.
    public var nextInterval: TimeInterval? {
        switch mode {
        case .searching: return timing.searchInterval
        case .tracking: return timing.trackInterval
        case .finished: return nil
        }
    }

    public var isFinished: Bool { mode == .finished }

    /// `frame` = the window's frame in AppKit screen space right now, nil = none; `elapsed` = seconds since the search began.
    public mutating func observe(_ frame: CGRect?, elapsed: TimeInterval) -> Event? {
        switch mode {
        case .finished:
            return nil

        case .searching:
            if let frame {
                if let previous = lastSeen, Self.close(previous, frame, timing.settleTolerance) {
                    mode = .tracking; lastSeen = frame; misses = 0
                    return .found(frame)
                }
                lastSeen = frame
            } else {
                lastSeen = nil
            }
            guard elapsed >= timing.searchDeadline else { return nil }
            // Out of time: a window that is still on screen is as settled as it will get; no window = give up.
            if let frame = lastSeen {
                mode = .tracking; misses = 0
                return .found(frame)
            }
            mode = .finished
            return .gaveUp

        case .tracking:
            guard let frame else {
                misses += 1
                if misses >= timing.missesToLose { mode = .finished; return .lost }
                return nil
            }
            misses = 0
            if let previous = lastSeen, !Self.close(previous, frame, timing.moveTolerance) {
                lastSeen = frame
                return .moved(frame)
            }
            return nil
        }
    }

    private static func close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }
}
