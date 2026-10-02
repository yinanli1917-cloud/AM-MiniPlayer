/**
 * [INPUT]: Depends on MusicMiniPlayerCore's GlobalShortcutAction;
 *          SettingsDemoMotion (timing / frames / DemoRun), SettingsDemoDrawing
 *          (Canvas painters + DemoPalette), SettingsPalette.
 * [OUTPUT]: Exports SettingsDemo (one case per settings row), SettingsDemoContext
 *           (live setting values + captions the stage reads), DemoStageModel
 *           (which scene shows, and the one run that may be moving),
 *           DemoTimelineSchedule, DemoStage (the 300×169 stage view),
 *           DemoWindowVisibilityObserver.
 * [POS]: Settings window's demo stage: a centred 16:9 rounded rectangle above the
 *        segmented control (creator's decision 2026-09-29; behaviour spec
 *        docs/design/2026-09-29-motion-prototype/spec.md §A). Idle = a static
 *        view: no TimelineView, no timer. A hover commit starts ONE run; its
 *        TimelineView uses a schedule that ENDS at the run's stop instant, so
 *        nothing keeps ticking after the picture comes to rest. Switching rows
 *        cross-fades two slots (0.28s) and freezes the outgoing one, so at most
 *        one clock ever runs. Reduce Motion: stills only, no fade.
 */

import SwiftUI
import AppKit
import MusicMiniPlayerCore

// ──────────────────────────────────────────────
// MARK: - SettingsDemo (one case per row that has a demo)
// ──────────────────────────────────────────────

/// One case per settings row (proposal §4.3). `SettingsWindowStructureTests`
/// pins `Set(SettingsDemo.allCases)` against the `demo:` values the rows in
/// `SettingsView.swift` declare — exact 1:1.
///
/// The proposal's prose count ("13 个 case") undercounts against the row tables
/// it lists (Player 4 + General 6 + Shortcuts 5 = 15); every row gets its own
/// case for a verifiable 1:1 mapping.
enum SettingsDemo: String, CaseIterable {
    // Player
    case fullscreenCover
    case edgeShowSongOnTrackChange
    case showTranslation
    case translateTo
    // General
    case launchAtLogin
    case showInDock
    case gettingToKnowNanoPod
    case musicAutomation
    case appleMusicAccess
    case playbackHistory
    // Shortcuts
    case playPauseShortcut
    case nextTrackShortcut
    case previousTrackShortcut
    case showHidePlayerShortcut
    case hideToEdgeShortcut

    /// The recorded-shortcut action a shortcut row's keycaps show.
    var shortcutAction: GlobalShortcutAction? {
        switch self {
        case .playPauseShortcut: return .togglePlayPause
        case .nextTrackShortcut: return .nextTrack
        case .previousTrackShortcut: return .previousTrack
        case .showHidePlayerShortcut: return .togglePanel
        case .hideToEdgeShortcut: return .hideToEdge
        default: return nil
        }
    }
}

extension SettingsDemo {
    /// The page's first scene plays once when its page appears (instead of sitting as a still until a
    /// row is hovered): the Launch at Login scene, which as a still read as a frozen, dimmed picture.
    var playsIntroOnAppear: Bool { self == .launchAtLogin }
}

extension SettingsTab {
    /// The scene the stage shows before any row has been rested on.
    var defaultDemo: SettingsDemo? {
        switch self {
        case .player: return .fullscreenCover
        case .general: return .launchAtLogin
        case .shortcuts: return .playPauseShortcut
        case .about: return nil
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        case .diagnostics: return nil
        #endif
        }
    }
}

/// What the scenes need to know from the running app — plain data, no
/// UserDefaults/service reads inside the drawing itself.
struct SettingsDemoContext {
    /// A sample line in the chosen translation language.
    var translationSampleText: String
    /// The user's recorded shortcuts (empty string = none recorded).
    var shortcutDescriptions: [GlobalShortcutAction: String]
    /// Switch states by row (a row without an entry counts as on).
    var switchStates: [SettingsDemo: Bool] = [:]
    /// The pill's row name and state text, by row.
    var captions: [SettingsDemo: String] = [:]
    var chips: [SettingsDemo: String] = [:]

    func shortcutLabel(for action: GlobalShortcutAction) -> String {
        shortcutDescriptions[action] ?? ""
    }

    func isOn(_ demo: SettingsDemo) -> Bool { switchStates[demo] ?? true }

    func options(for demo: SettingsDemo) -> DemoOptions {
        var o = DemoOptions()
        o.isOn = isOn(demo)
        o.translationTexts = DemoOptions.translations(startingWith: translationSampleText)
        if let action = demo.shortcutAction {
            o.keyLabels = DemoOptions.keyLabels(from: shortcutLabel(for: action))
        }
        return o
    }
}

// ──────────────────────────────────────────────
// MARK: - DemoStageModel
// ──────────────────────────────────────────────

/// Which scene the stage shows and which single run (if any) is moving.
/// Two slots so a row switch can cross-fade; the outgoing slot is frozen on its
/// last frame the moment it starts fading (spec A.4: at most one clock).
@MainActor
final class DemoStageModel: ObservableObject {

    enum Playback: Equatable {
        /// The scene's rest frame for the row's current switch state.
        case rest
        /// An exact frame (outgoing slot; test seam).
        case frozen(Double)
        case run(DemoRun)
    }

    struct Slot: Equatable {
        var demo: SettingsDemo
        var playback: Playback
    }

    @Published private(set) var slots: [Slot?] = [nil, nil]
    @Published private(set) var front = 0

    /// Reduce Motion: every scene is a still and rows swap without a fade.
    var reduceMotion = false
    /// Injectable so tests drive a fake clock.
    var now: () -> Date = { Date() }
    var frontSlot: Slot? { slots[front] }

    /// Runs whose picture is still changing at `date` (the invariant: never more than 1).
    func activeClockCount(at date: Date) -> Int {
        slots.compactMap { $0 }.filter { slot in
            if case .run(let run) = slot.playback { return !run.isFinished(at: date) }
            return false
        }.count
    }

    /// True when any slot holds a run object (finished or not) — i.e. a TimelineView is mounted.
    var hasMountedClock: Bool {
        slots.compactMap { $0 }.contains { if case .run = $0.playback { return true } else { return false } }
    }

    // MARK: commands

    /// Show `demo` at rest (first appearance, tab change).
    func show(_ demo: SettingsDemo) {
        if let f = frontSlot, f.demo == demo, f.playback == .rest { return }
        present(demo, .rest)
    }

    /// Play `demo`'s switched-ON story once from its first frame to its on-rest frame, then hold there. Only
    /// when `demo` is the scene on stage at rest, so it never cuts across something the user already started.
    /// One run, a schedule that ends at the last frame: no clock keeps ticking afterwards.
    func playIntro(_ demo: SettingsDemo) {
        guard demo.timing.isAnimated, !reduceMotion, let front = frontSlot, front.demo == demo, front.playback == .rest else { return }
        let end = demo.timing.restTime(on: true)
        slots[self.front]?.playback = .run(DemoRun(kind: .once(from: 0, to: end), start: now(), isOn: true, stopAt: nil))
    }

    /// The pointer rested on `demo`'s row: loop its scene (a still scene just fades in).
    /// `isOn` is the row's switch state now (it decides which frame the loop comes to rest on).
    func begin(_ demo: SettingsDemo, isOn: Bool = true) {
        guard demo.timing.isAnimated, !reduceMotion else { show(demo); return }
        let date = now()
        if let f = frontSlot, f.demo == demo, case .run(var run) = f.playback, run.kind == .loop, !run.isFinished(at: date) {
            // Already looping (or on its last lap): keep going, cancel the pending stop.
            run.stopAt = nil
            slots[front]?.playback = .run(run)
            return
        }
        present(demo, .run(DemoRun(kind: .loop, start: date, isOn: isOn, stopAt: nil)))
    }

    /// The row's switch flipped: play the change once, then hold.
    func replay(_ demo: SettingsDemo, isOn on: Bool) {
        guard !reduceMotion, let range = demo.timing.replayRange(on: on) else {
            if let f = frontSlot, f.demo == demo { slots[front]?.playback = .rest } else { present(demo, .rest) }
            return
        }
        present(demo, .run(DemoRun(kind: .once(from: range.lowerBound, to: range.upperBound), start: now(), isOn: on, stopAt: nil)))
    }

    /// The pointer is on `row` now (nil = on no row). A loop whose own row lost the
    /// pointer plays out to its next rest frame and stops there.
    func pointerMoved(to row: SettingsDemo?) {
        guard let f = frontSlot, case .run(var run) = f.playback, run.kind == .loop, run.stopAt == nil, row != f.demo else { return }
        run.leave(at: now(), timing: f.demo.timing)
        slots[front]?.playback = .run(run)
    }

    /// Stop all motion at once and rest (window hidden / closed, Reduce Motion switched on).
    func settle() {
        for i in slots.indices {
            if case .run = slots[i]?.playback { slots[i]?.playback = .rest }
        }
    }

    #if DEBUG
    /// Test seam: put `demo` on stage frozen at scene time `t`, with no fade.
    func debugFreeze(_ demo: SettingsDemo, at t: Double) {
        slots = [Slot(demo: demo, playback: .frozen(t)), nil]
        front = 0
    }
    #endif

    // MARK: plumbing

    private func present(_ demo: SettingsDemo, _ playback: Playback) {
        if var f = frontSlot, f.demo == demo {
            f.playback = playback
            slots[front] = f
            return
        }
        // First scene on an empty stage: nothing to fade from.
        if frontSlot == nil {
            slots[front] = Slot(demo: demo, playback: playback)
            return
        }
        // The outgoing slot stops dead on its last frame while it fades out: one clock only.
        if var out = frontSlot, case .run(let run) = out.playback {
            out.playback = .frozen(run.sceneTime(at: now(), timing: out.demo.timing))
            slots[front] = out
        }
        let back = 1 - front
        slots[back] = Slot(demo: demo, playback: playback)
        front = back
    }
}

// ──────────────────────────────────────────────
// MARK: - Timeline schedule that ends
// ──────────────────────────────────────────────

/// Frame ticks from "now" up to `end`, then nothing. `.animation` schedules never
/// finish; this one does, so a run that has come to rest costs no ticks at all.
/// The last tick lands exactly on `end`, so the final render is the rest frame.
struct DemoTimelineSchedule: TimelineSchedule {
    let end: Date?
    var interval: TimeInterval = 1.0 / 120

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, end: end, interval: mode == .lowFrequency ? 1 : interval)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let end: Date?
        let interval: TimeInterval

        mutating func next() -> Date? {
            guard let current = upcoming else { return nil }
            guard let end else { upcoming = current.addingTimeInterval(interval); return current }
            if current >= end { upcoming = nil; return current }
            let following = current.addingTimeInterval(interval)
            upcoming = following >= end ? end : following
            return current
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - DemoStage
// ──────────────────────────────────────────────

struct DemoStage: View {
    @ObservedObject var model: DemoStageModel
    let context: SettingsDemoContext
    @Environment(\.colorScheme) private var colorScheme

    /// The row-to-row fade (spec A.4: 0.28s ease-in-out); none under Reduce Motion.
    static func crossFade(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.28)
    }

    /// Only a run mounts a TimelineView; rest and frozen slots are plain static views.
    static func usesTimeline(_ playback: DemoStageModel.Playback) -> Bool {
        if case .run = playback { return true }
        return false
    }

    var body: some View {
        let palette = DemoPalette.make(dark: colorScheme == .dark)
        ZStack {
            Canvas { ctx, size in
                var c = ctx
                DemoDrawing.drawWallpaper(&c, size: size, palette: palette)
            }
            ForEach(0..<2, id: \.self) { index in
                if let slot = model.slots[index] {
                    DemoSlotView(slot: slot, context: context, palette: palette)
                        .opacity(index == model.front ? 1 : 0)
                }
            }
        }
        .frame(width: DemoDrawing.stageSize.width, height: DemoDrawing.stageSize.height)
        .clipShape(RoundedRectangle(cornerRadius: DemoDrawing.stageCornerRadius, style: .circular))
        .animation(Self.crossFade(reduceMotion: model.reduceMotion), value: model.front)
        .accessibilityHidden(true)
    }
}

/// One slot: the scene canvas plus the row-name pill. A run mounts a TimelineView
/// (keyed by the run so a changed stop instant restarts the schedule); everything
/// else is static.
private struct DemoSlotView: View {
    let slot: DemoStageModel.Slot
    let context: SettingsDemoContext
    let palette: DemoPalette

    private struct RunKey: Hashable { let start: Date; let stopAt: Double? }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            switch slot.playback {
            case .rest:
                canvas(at: slot.demo.timing.restTime(on: context.isOn(slot.demo)))
            case .frozen(let t):
                canvas(at: t)
            case .run(let run):
                TimelineView(DemoTimelineSchedule(end: run.endDate)) { tick in
                    canvas(at: run.sceneTime(at: tick.date, timing: slot.demo.timing))
                }
                .id(RunKey(start: run.start, stopAt: run.stopAt))
            }
            DemoCaptionPill(name: context.captions[slot.demo] ?? slot.demo.rawValue,
                            chip: context.chips[slot.demo], palette: palette)
                .padding(8)
        }
        .frame(width: DemoDrawing.stageSize.width, height: DemoDrawing.stageSize.height)
    }

    private func canvas(at t: Double) -> some View {
        let frame = slot.demo.frame(at: t, options: context.options(for: slot.demo))
        return DemoSceneCanvas(frame: frame, palette: palette)
    }
}

/// The scene canvas: the prototype's 320×180 composition scaled into the 300×169 stage.
struct DemoSceneCanvas: View {
    let frame: DemoFrame
    let palette: DemoPalette

    var body: some View {
        Canvas { ctx, _ in
            var c = ctx
            c.scaleBy(x: DemoDrawing.sceneScale, y: DemoDrawing.sceneScale)
            DemoDrawing.drawScene(frame, in: &c, palette: palette)
        }
        .frame(width: DemoDrawing.stageSize.width, height: DemoDrawing.stageSize.height)
    }
}

/// Bottom-left pill: row name, then the state chip (prototype `.stagecap`).
struct DemoCaptionPill: View {
    let name: String
    let chip: String?
    let palette: DemoPalette

    var body: some View {
        HStack(spacing: 6) {
            Text(name).foregroundColor(palette.capInk)
            if let chip { Text(chip).fontWeight(.semibold).foregroundColor(palette.pageInk) }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Capsule().fill(palette.menubar))
        .frame(maxWidth: DemoDrawing.stageSize.width - 16, alignment: .leading)
    }
}

// ──────────────────────────────────────────────
// MARK: - Window visibility
// ──────────────────────────────────────────────

/// Calls `onHidden` when the hosting window is closed or fully occluded, so a run in
/// flight can settle on its rest frame instead of animating something nobody sees.
struct DemoWindowVisibilityObserver: NSViewRepresentable {
    let onHidden: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.onHidden = onHidden
        return v
    }

    func updateNSView(_ view: ObserverView, context: Context) { view.onHidden = onHidden }

    final class ObserverView: NSView {
        var onHidden: (() -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.onHidden?()
            })
            tokens.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
                if let window, !window.occlusionState.contains(.visible) { self?.onHidden?() }
            })
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
