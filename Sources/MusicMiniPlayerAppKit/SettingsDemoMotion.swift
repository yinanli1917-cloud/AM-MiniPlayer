/**
 * [INPUT]: Foundation only. SettingsDemo (SettingsDemoStage) is the row → demo identity.
 * [OUTPUT]: Exports DemoEase, DemoStep, demoStateValue / demoBump (the prototype's
 *           `sv` / `bump`), DemoTiming, DemoOptions, DemoFrame + the per-scene frame
 *           structs, SettingsDemo.timing / SettingsDemo.frame(at:options:), DemoRun
 *           (one loop / one-shot run on the wall clock).
 * [POS]: The settings demo stage's MOTION LAYER — no drawing, no SwiftUI. Every
 *        number is a transcription of docs/design/2026-09-29-motion-prototype/
 *        prototype.html (`SCENES.*`, `E`, `sv`, `bump`) and spec.md §A.6. A scene
 *        is a pure function `frame(at: t) -> DemoFrame`; the drawing layer only
 *        paints what the frame says, so a fake clock can assert every keyframe.
 */

import Foundation

// ──────────────────────────────────────────────
// MARK: - Easing (prototype `E`, cubic-bezier solved by 22-step bisection)
// ──────────────────────────────────────────────

enum DemoEase {
    /// cubic-bezier(.42, 0, .58, 1): the trackpad recording's 0.9s ease-in-out, no overshoot.
    case io
    /// cubic-bezier(.2, .8, .2, 1)
    case out
    /// cubic-bezier(.4, 0, 1, 1)
    case `in`
    case linear

    func value(_ t: Double) -> Double {
        switch self {
        case .io: return Self.bezier(t, 0.42, 0, 0.58, 1)
        case .out: return Self.bezier(t, 0.2, 0.8, 0.2, 1)
        case .in: return Self.bezier(t, 0.4, 0, 1, 1)
        case .linear: return min(1, max(0, t))
        }
    }

    private static func bezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        var lo = 0.0, hi = 1.0, u = t
        for _ in 0..<22 {
            u = (lo + hi) / 2
            let x = 3 * pow(1 - u, 2) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u
            if x < t { lo = u } else { hi = u }
        }
        return 3 * pow(1 - u, 2) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u
    }
}

/// One tween of a scene state variable: from wherever the variable is at `t0`
/// to `to`, over `dur` seconds, shaped by `ease`.
struct DemoStep {
    let t0: Double
    let to: Double
    let ease: DemoEase
    let dur: Double
    init(_ t0: Double, _ to: Double, _ ease: DemoEase, _ dur: Double) {
        self.t0 = t0; self.to = to; self.ease = ease; self.dur = dur
    }
}

/// Prototype `sv(t, init, events)`: a state variable driven by consecutive steps.
/// A step that is not the last one is cut off (snapped to `to`) when the next begins.
func demoStateValue(_ t: Double, initial: Double, _ steps: [DemoStep]) -> Double {
    var cur = initial
    for i in steps.indices {
        let s = steps[i]
        if t < s.t0 { return cur }
        let p = s.ease.value((t - s.t0) / s.dur)
        let next = i + 1 < steps.count ? steps[i + 1].t0 : Double.infinity
        if t >= next { cur = s.to; continue }
        return cur + (s.to - cur) * p
    }
    return cur
}

/// Prototype `bump(t, t0, d)`: half a sine over `[t0, t0 + d]`, else 0.
func demoBump(_ t: Double, _ t0: Double, _ d: Double) -> Double {
    let u = (t - t0) / d
    return u <= 0 || u >= 1 ? 0 : sin(Double.pi * u)
}

@inline(__always) func demoClamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, x)) }
@inline(__always) func demoLerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// ──────────────────────────────────────────────
// MARK: - Timing table (prototype `SCENES.*.loop / once / rest`)
// ──────────────────────────────────────────────

struct DemoTiming: Equatable {
    /// Loop length in seconds; 0 = a still (nothing moves).
    let loop: Double
    /// Play-once ranges when the row's switch flips (nil = no switch replay).
    let onRange: ClosedRange<Double>?
    let offRange: ClosedRange<Double>?
    private let restOn: Double
    private let restOff: Double

    init(loop: Double, on: ClosedRange<Double>? = nil, off: ClosedRange<Double>? = nil, restOn: Double, restOff: Double) {
        self.loop = loop; onRange = on; offRange = off; self.restOn = restOn; self.restOff = restOff
    }

    var isAnimated: Bool { loop > 0 }

    /// The frame the scene comes to rest on: switch on = the effect completed, off = the initial state.
    func restTime(on: Bool) -> Double { on ? restOn : restOff }

    /// The next rest instant strictly after run-time `t` (prototype `nextRestT`).
    func nextRest(after t: Double, on: Bool) -> Double {
        let rt = restTime(on: on)
        let k = floor((t - rt) / loop) + 1
        return rt + k * loop
    }

    /// The one-shot replay for a switch flip. A replay never runs past the rest
    /// frame it is meant to land on (the prototype's peek-on range overshoots its
    /// own rest frame and would freeze on a card that is already leaving).
    func replayRange(on: Bool) -> ClosedRange<Double>? {
        guard let r = on ? onRange : offRange else { return nil }
        let rest = restTime(on: on)
        let end = on ? min(r.upperBound, max(rest, r.lowerBound)) : r.upperBound
        return r.lowerBound...end
    }
}

// ──────────────────────────────────────────────
// MARK: - Options (live values a scene reads)
// ──────────────────────────────────────────────

struct DemoOptions: Equatable {
    /// The row's switch state (rows without a switch: true).
    var isOn = true
    /// The user's translation language sample first, then up to three others
    /// (prototype `CYCLE`: 中 / 日 / 한 / Fr).
    var translationTexts = DemoOptions.defaultTranslations
    /// One entry per keycap (modifier glyphs, then the key); empty = nothing recorded.
    var keyLabels: [String] = []

    static let defaultTranslations = ["我们去看海吧", "海を見に行こう", "바다 보러 가자", "Allons voir la mer"]

    /// `sample` first, then the default rotation without it (always four entries).
    static func translations(startingWith sample: String) -> [String] {
        [sample] + defaultTranslations.filter { $0 != sample }.prefix(3)
    }

    /// "⌥⌘P" → ["⌥", "⌘", "P"]; a key name longer than a glyph ("Space", "F12") stays one keycap.
    static func keyLabels(from description: String) -> [String] {
        let modifiers: Set<Character> = ["\u{2303}", "\u{2325}", "\u{21E7}", "\u{2318}"]
        var labels: [String] = []
        var rest = Substring(description)
        while let c = rest.first, modifiers.contains(c) { labels.append(String(c)); rest = rest.dropFirst() }
        if !rest.isEmpty { labels.append(String(rest)) }
        return labels
    }
}

// ──────────────────────────────────────────────
// MARK: - Frames (what to paint at time t)
// ──────────────────────────────────────────────

/// A frame of the album panel scenes: `s` 0 = cover inset, 1 = cover fills the panel.
struct CoverFrame: Equatable {
    var s: Double
    // Derived, in panel widths ("em").
    var artSide: Double { demoLerp(0.68, 1, s) }
    var artLeft: Double { (1 - artSide) / 2 }
    var artTop: Double { demoLerp(0.075, 0, s) }
    var artRadius: Double { demoLerp(0.04, 0, s) }
    var titleTop: Double { demoLerp(0.885, 0.79, s) }
    var artistTop: Double { demoLerp(0.94, 0.845, s) }
    var controlsTop: Double { demoLerp(1.0, 0.915, s) }
    /// Share of the cover (from its bottom) that fades into the blurred colour underlay.
    var fadeBand: Double { 0.4 * s }
    var artOpacityAtBottom: Double { 1 - s }
    var blurUnderlayOpacity: Double { s }
    var artHasShadow: Bool { s <= 0.98 }

    /// How every demo panel is drawn unless the scene is the Fullscreen Cover contrast itself
    /// (creator's decision, 2026-09-29: the fullscreen-cover look is the default look).
    static let fullscreenLook = CoverFrame(s: 1)
}

struct PeekFrame: Equatable {
    var tuck: Double
    var cp: Double
    var pulse: Double
    /// Pink progress light height on the edge strip, percent of the strip.
    var fillPercent: Double
    var panelOffsetX: Double { tuck * 170 }
    var panelOpacity: Double { 1 - DemoEase.io.value(demoClamp((tuck - 0.55) / 0.45)) }
    /// The strip and the card never show together: the card replaces the strip. The strip has
    /// faded and slid back into the edge before the card clears the screen edge (`cp` ≈ 0.16),
    /// and on the way back it returns only once the card is off screen again.
    var stripHandoff: Double { DemoEase.io.value(demoClamp(cp / 0.12)) }
    var stripOpacity: Double { DemoEase.io.value(demoClamp((tuck - 0.5) / 0.5)) * (1 - stripHandoff) }
    var stripOffsetX: Double { (1 - stripOpacity) * 5 }
    var cardOffsetX: Double { (1 - cp) * 80 }
    var cardOpacity: Double { demoClamp(cp * 3) }
    /// What of the card is actually on screen: its opacity × the share of its 60pt width inside the
    /// screen (the card rests at x = 253…313 and slides in from beyond the right edge at 320).
    var cardPresence: Double { cardOpacity * demoClamp((67 - cardOffsetX) / 60) }
}

struct LyricsFrame: Equatable {
    /// Translation presence 0…1 (opacity, slide, blur, and the room the lines below make).
    var s: Double
    var textA: String
    var textB: String
    var opacityA: Double
    var opacityB: Double
    var translationOffsetY: Double { (1 - s) * -3 }
    var translationBlur: Double { (1 - s) * 1.6 }
    /// The two lines under the current one move down by one translation line.
    var followingLinesOffsetY: Double { s * 20 }
}

struct ShowHideFrame: Equatable {
    var press: Double
    var panelOpacity: Double
    var panelScale: Double
    var keys: [String]
    var showsBackgroundWindow: Bool
}

struct HideEdgeFrame: Equatable {
    var press: Double
    var tuck: Double
    var keys: [String]
    var panelOffsetX: Double { tuck * 170 }
    var panelOpacity: Double { 1 - DemoEase.io.value(demoClamp((tuck - 0.55) / 0.45)) }
    var stripOpacity: Double { DemoEase.io.value(demoClamp((tuck - 0.5) / 0.5)) }
    var stripOffsetX: Double { (1 - stripOpacity) * 5 }
}

struct LoginFrame: Equatable {
    /// 0 = lit, 1 = the screen fully dark.
    var dim: Double
    var noteScale: Double
    var noteOpacity: Double
}

struct DockFrame: Equatable {
    /// nanoPod's dock slot: 0 = absent, 1 = seated.
    var presence: Double
}

enum DemoStillKind: Equatable { case tour, automation, appleMusic, history }

enum DemoFrame: Equatable {
    case cover(CoverFrame)
    case peek(PeekFrame)
    case lyrics(LyricsFrame)
    case showHide(ShowHideFrame)
    case hideEdge(HideEdgeFrame)
    case login(LoginFrame)
    case dock(DockFrame)
    case still(DemoStillKind)

    /// The cover state the scene draws its album panel in (nil = the scene has no album panel).
    /// Only the Fullscreen Cover scene animates it; every other album panel is fullscreen-look.
    var panelCover: CoverFrame? {
        switch self {
        case .cover(let f): return f
        case .peek, .showHide, .hideEdge, .login: return .fullscreenLook
        case .still(let kind): return kind == .history ? nil : .fullscreenLook
        case .lyrics, .dock: return nil
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - SettingsDemo → timing + frame
// ──────────────────────────────────────────────

extension SettingsDemo {
    var timing: DemoTiming {
        switch self {
        case .fullscreenCover:
            return DemoTiming(loop: 6.2, on: 0.7...2.7, off: 3.7...5.4, restOn: 2.7, restOff: 0.3)
        case .edgeShowSongOnTrackChange:
            return DemoTiming(loop: 8.4, on: 1.9...5.9, off: 1.9...3.6, restOn: 5.0, restOff: 3.4)
        case .showTranslation:
            return DemoTiming(loop: 6.0, on: 0.7...2.6, off: 3.9...5.4, restOn: 2.6, restOff: 0.3)
        case .translateTo:
            return DemoTiming(loop: 6.8, restOn: 1.2, restOff: 1.2)
        case .showHidePlayerShortcut:
            return DemoTiming(loop: 6.6, restOn: 0.3, restOff: 0.3)
        case .hideToEdgeShortcut:
            return DemoTiming(loop: 7.0, restOn: 0.3, restOff: 0.3)
        case .launchAtLogin:
            return DemoTiming(loop: 4.6, on: 0.5...2.3, off: 3.1...4.3, restOn: 2.6, restOff: 0.3)
        case .showInDock:
            return DemoTiming(loop: 5.0, on: 0.6...2.5, off: 3.1...4.6, restOn: 2.6, restOff: 0.3)
        case .gettingToKnowNanoPod, .musicAutomation, .appleMusicAccess, .playbackHistory,
             .playPauseShortcut, .nextTrackShortcut, .previousTrackShortcut:
            return DemoTiming(loop: 0, restOn: 0, restOff: 0)
        }
    }

    /// The frame at scene time `t`. Pure: same inputs, same frame.
    func frame(at t: Double, options o: DemoOptions) -> DemoFrame {
        switch self {
        case .fullscreenCover:
            let s = demoStateValue(t, initial: 0, [DemoStep(0.9, 1, .io, 0.9), DemoStep(3.9, 0, .io, 0.9)])
            return .cover(CoverFrame(s: s))

        case .edgeShowSongOnTrackChange:
            let tuck = demoStateValue(t, initial: 0, [DemoStep(0.7, 1, .io, 0.92), DemoStep(6.7, 0, .io, 0.92)])
            let cp = o.isOn ? demoStateValue(t, initial: 0, [DemoStep(2.4, 1, .io, 0.8), DemoStep(5.7, 0, .io, 0.8)]) : 0
            // The strip lights up at the track change, then hands over to the card (cp starts at 2.4).
            return .peek(PeekFrame(tuck: tuck, cp: cp, pulse: demoBump(t, 1.6, 0.9),
                                   fillPercent: t < 2.4 ? 62 : 8 + (t - 2.4) * 1.5))

        case .showTranslation:
            let s = demoStateValue(t, initial: 0, [DemoStep(1.1, 1, .out, 0.55), DemoStep(4.2, 0, .out, 0.5)])
            return .lyrics(LyricsFrame(s: s, textA: o.translationTexts[0], textB: "", opacityA: 1, opacityB: 0))

        case .translateTo:
            let seg = 1.7
            let i = Int(floor(t / seg)) % 4
            let u = (t.truncatingRemainder(dividingBy: seg)) / seg
            let f = DemoEase.io.value(demoClamp(u / 0.18))
            let texts = o.translationTexts
            return .lyrics(LyricsFrame(s: 1, textA: texts[i % texts.count], textB: texts[(i + 3) % texts.count],
                                       opacityA: f, opacityB: 1 - f))

        case .showHidePlayerShortcut:
            let press = max(demoBump(t, 0.9, 0.34), demoBump(t, 3.4, 0.34))
            let op = demoStateValue(t, initial: 1, [DemoStep(1.0, 0, .out, 0.32), DemoStep(3.5, 1, .out, 0.42)])
            return .showHide(ShowHideFrame(press: press, panelOpacity: op, panelScale: demoLerp(0.955, 1, op),
                                           keys: o.keyLabels, showsBackgroundWindow: true))

        case .hideToEdgeShortcut:
            let press = max(demoBump(t, 0.9, 0.34), demoBump(t, 3.9, 0.34))
            let tuck = demoStateValue(t, initial: 0, [DemoStep(1.05, 1, .io, 0.92), DemoStep(4.05, 0, .io, 0.92)])
            return .hideEdge(HideEdgeFrame(press: press, tuck: tuck, keys: o.keyLabels))

        case .launchAtLogin:
            // Screen dark → lit over 0.4s, then the menu-bar note pops in (0.6 → 1 scale, 0.5s).
            let dim = demoStateValue(t, initial: 1, [DemoStep(0.7, 0, .io, 0.4), DemoStep(3.4, 1, .io, 0.4)])
            let pop = demoStateValue(t, initial: 0, [DemoStep(1.0, 1, .io, 0.5), DemoStep(3.3, 0, .io, 0.3)])
            return .login(LoginFrame(dim: dim * 0.62, noteScale: demoLerp(0.6, 1, pop), noteOpacity: pop))

        case .showInDock:
            // nanoPod's block drops into the dock and pushes its neighbours aside (0.9s), reverse when off.
            let p = demoStateValue(t, initial: 0, [DemoStep(0.8, 1, .io, 0.9), DemoStep(3.4, 0, .io, 0.9)])
            return .dock(DockFrame(presence: p))

        case .gettingToKnowNanoPod: return .still(.tour)
        case .musicAutomation: return .still(.automation)
        case .appleMusicAccess: return .still(.appleMusic)
        case .playbackHistory: return .still(.history)
        case .playPauseShortcut, .nextTrackShortcut, .previousTrackShortcut:
            return .showHide(ShowHideFrame(press: 0, panelOpacity: 1, panelScale: 1,
                                           keys: o.keyLabels, showsBackgroundWindow: false))
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - DemoRun (one run on the wall clock)
// ──────────────────────────────────────────────

/// One playback of a scene, started at `start`. The stage keeps at most one.
///  - `.loop`: repeats until the pointer leaves; `stopAt` (run seconds) is then
///    set to the next rest instant, and the run holds the rest frame after it.
///  - `.once`: plays `from…to` (the switch replay) and holds the last frame.
struct DemoRun: Equatable {
    enum Kind: Equatable {
        case loop
        case once(from: Double, to: Double)
    }

    var kind: Kind
    var start: Date
    var isOn: Bool
    /// Loop only: run-time at which the loop stops on its rest frame.
    var stopAt: Double?

    func runTime(at now: Date) -> Double { max(0, now.timeIntervalSince(start)) }

    var isLeaving: Bool { stopAt != nil }

    /// Seconds of run-time after which nothing moves (nil = never: an unbounded loop).
    var duration: Double? {
        switch kind {
        case .loop: return stopAt
        case .once(let from, let to): return to - from
        }
    }

    func isFinished(at now: Date) -> Bool {
        guard let duration else { return false }
        return runTime(at: now) >= duration
    }

    /// The scene time to paint at `now`.
    func sceneTime(at now: Date, timing: DemoTiming) -> Double {
        let rt = runTime(at: now)
        switch kind {
        case .loop:
            if let stopAt, rt >= stopAt { return timing.restTime(on: isOn) }
            return rt.truncatingRemainder(dividingBy: timing.loop)
        case .once(let from, let to):
            return min(to, from + rt)
        }
    }

    /// The wall-clock instant the run stops changing the picture (nil = unbounded).
    var endDate: Date? { duration.map { start.addingTimeInterval($0) } }

    /// Mark the loop as leaving: it will stop on the next rest frame.
    mutating func leave(at now: Date, timing: DemoTiming) {
        guard case .loop = kind, stopAt == nil else { return }
        stopAt = timing.nextRest(after: runTime(at: now), on: isOn)
    }
}
