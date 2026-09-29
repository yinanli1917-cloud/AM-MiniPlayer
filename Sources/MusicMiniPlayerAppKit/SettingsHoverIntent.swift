/**
 * [INPUT]: Depends on MusicMiniPlayerCore's ProgressHoverIntentEngine (dwell
 *          150ms / drift 4pt / exit grace — the progress bar's own gate) and
 *          on AppKit tracking areas for pointer position.
 * [OUTPUT]: Exports SettingsHoverIntentModel (row highlight + demo-stage
 *           commit state machine), SettingsRowHoverTracker (NSTrackingArea
 *           bridge that reports enter / MOVE / exit with positions).
 * [POS]: Settings window's hover layer. Two channels, deliberately separate:
 *        `highlightedRow` follows the pointer immediately (the row lights up,
 *        so you can see where you are); `stageDemo` changes only after the
 *        pointer has rested on a row (≥150ms, drift ≤4pt), so sweeping across
 *        rows never churns the demo stage. Leaving all rows leaves the stage
 *        on the last committed still.
 */

import SwiftUI
import AppKit
import QuartzCore
import MusicMiniPlayerCore

// ──────────────────────────────────────────────
// MARK: - Model
// ──────────────────────────────────────────────

@MainActor
final class SettingsHoverIntentModel: ObservableObject {

    /// Row under the pointer right now — drives the row's highlight fill.
    @Published private(set) var highlightedRow: SettingsDemo?
    /// Row whose still the pointer has rested on (nil = none yet on this page:
    /// the stage then shows the page's first row).
    @Published private(set) var stageDemo: SettingsDemo?

    private(set) var candidate: SettingsDemo?
    private(set) var engineState: ProgressHoverIntentEngine.State = .idle
    private var workItem: DispatchWorkItem?

    var config: ProgressHoverIntentEngine.Config = .default
    /// Injectable so tests drive a fake clock (no sleeping).
    var now: () -> TimeInterval = { CACurrentMediaTime() }
    var schedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, item in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// True while a dwell / grace timer is armed (idle window ⇒ false).
    var hasPendingTimer: Bool { workItem != nil }

    // MARK: pointer input (row-local coordinates)

    func pointerEntered(_ row: SettingsDemo, at point: CGPoint) {
        highlightedRow = row
        if candidate != row {
            // A different row starts from scratch: it must earn its own dwell.
            cancelTimer()
            engineState = .idle
            candidate = row
        }
        apply(ProgressHoverIntentEngine.enter(state: engineState, at: point, now: now(), config: config))
    }

    func pointerMoved(_ row: SettingsDemo, to point: CGPoint) {
        guard candidate == row else { return }
        apply(ProgressHoverIntentEngine.move(state: engineState, to: point, now: now(), config: config))
    }

    func pointerExited(_ row: SettingsDemo) {
        if highlightedRow == row { highlightedRow = nil }
        guard candidate == row else { return }
        apply(ProgressHoverIntentEngine.exit(state: engineState, now: now(), config: config))
    }

    /// Tab switch: the stage goes back to the new page's first row; any
    /// half-finished hover decision is dropped.
    func resetStage() {
        cancelTimer()
        engineState = .idle
        candidate = nil
        highlightedRow = nil
        stageDemo = nil
    }

    // MARK: engine plumbing

    private func apply(_ result: (ProgressHoverIntentEngine.State, ProgressHoverIntentEngine.Effect)) {
        engineState = result.0
        switch result.1 {
        case .none:
            break
        case .cancelTimer:
            cancelTimer()
        case .armTimer(let deadline):
            cancelTimer()
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.timerFired() }
            }
            workItem = item
            schedule(max(0, deadline - now()), item)
        case .commit:
            cancelTimer()
            if let candidate { stageDemo = candidate }
        case .uncommit:
            // Leaving all rows keeps the last still — nothing to undo.
            cancelTimer()
        }
    }

    private func timerFired() {
        workItem = nil
        apply(ProgressHoverIntentEngine.timerFired(state: engineState, now: now()))
    }

    private func cancelTimer() {
        workItem?.cancel()
        workItem = nil
    }
}

// ──────────────────────────────────────────────
// MARK: - Tracking-area bridge
// ──────────────────────────────────────────────

/// Sits in a row's `.background`; reports position-carrying enter / move / exit
/// so the dwell gate sees the drift `.onHover` cannot give it. Never intercepts
/// clicks (`hitTest` → nil).
struct SettingsRowHoverTracker: NSViewRepresentable {
    let demo: SettingsDemo
    let model: SettingsHoverIntentModel

    func makeNSView(context: Context) -> SettingsRowHoverTrackerView {
        let view = SettingsRowHoverTrackerView()
        view.demo = demo
        view.model = model
        return view
    }

    func updateNSView(_ view: SettingsRowHoverTrackerView, context: Context) {
        view.demo = demo
        view.model = model
    }
}

final class SettingsRowHoverTrackerView: NSView {
    var demo: SettingsDemo?
    weak var model: SettingsHoverIntentModel?
    private var area: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(new)
        area = new
        syncToPointer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let demo, let model {
            MainActor.assumeIsolated { model.pointerExited(demo) }
        }
    }

    override func mouseEntered(with event: NSEvent) { forward(event) { $0.pointerEntered($1, at: $2) } }
    override func mouseMoved(with event: NSEvent) { forward(event) { $0.pointerMoved($1, to: $2) } }
    override func mouseExited(with event: NSEvent) { forward(event) { m, d, _ in m.pointerExited(d) } }

    private func forward(_ event: NSEvent, _ body: @MainActor (SettingsHoverIntentModel, SettingsDemo, CGPoint) -> Void) {
        guard let demo, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated { body(model, demo, point) }
    }

    /// The row can appear (tab switch, scroll) under a resting pointer, which
    /// AppKit reports as no event at all. Ask the screen where the pointer is.
    private func syncToPointer() {
        guard let window, let demo, let model else { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = convert(inWindow, from: nil)
        guard bounds.contains(local) else { return }
        MainActor.assumeIsolated {
            if model.highlightedRow != demo { model.pointerEntered(demo, at: local) }
        }
    }
}
