/**
 * [INPUT]: Depends on MusicMiniPlayerCore's MicroInteractionFeel (spring/duration
 *          tokens), ProgressHoverIntentEngine (row hover-intent dwell gate) and
 *          OnboardingAuthorizationStatus (permission-row demo state).
 * [OUTPUT]: Exports SettingsDemo, SettingsDemoContext, SettingsDemoPhase,
 *           DemoStage, SettingsRowHoverIntentHost, and the shared demo
 *           primitives (DemoMiniScreen/DemoMiniPanel/DemoLyricSheet/DemoKeycap).
 * [POS]: Settings window's animated "demo stage" (docs/design/2026-09-25-menu-
 *        settings/proposal.md §4) — every Player/General/Shortcuts row maps to
 *        exactly one SettingsDemo case, rendered here with no bitmaps, only
 *        SwiftUI shapes/text, so it themes automatically in light/dark and
 *        respects Reduce Motion.
 */

import SwiftUI
import MusicMiniPlayerCore
import QuartzCore
import KeyboardShortcuts

// ──────────────────────────────────────────────
// MARK: - SettingsDemo (one case per row that has a demo)
// ──────────────────────────────────────────────

/// One case per settings row with a demo-stage illustration (proposal §4.3).
/// `SettingsWindowStructureTests` pins `Set(SettingsDemo.allCases)` against the
/// set of `demo:` values every row in `SettingsView.swift` declares — the two
/// must stay in exact 1:1 correspondence.
///
/// The proposal's prose count ("13 个 case") undercounts by two against the
/// row tables it itself lists (Player 4 + General 6 + Shortcuts 5 = 15); every
/// row gets its own case here for a clean, verifiable 1:1 mapping rather than
/// forcing two rows to share one case to hit an exact headline number.
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

    /// Frozen frame for the current settings value — used both as the Reduce
    /// Motion still frame and as the DemoStage's idle (not-hovering) frame.
    @ViewBuilder
    func restingFrame(state: SettingsDemoContext) -> some View {
        frame(state: state, phase: restingPhase(state: state))
    }

    /// Which phase represents "how things are right now" — Reduce Motion and
    /// the idle stage both freeze here instead of playing the transition.
    private func restingPhase(state: SettingsDemoContext) -> SettingsDemoPhase {
        switch self {
        case .fullscreenCover: return state.fullscreenCoverOn ? .end : .start
        case .edgeShowSongOnTrackChange: return state.edgeShowSongOn ? .end : .start
        case .showTranslation: return state.showTranslationOn ? .end : .start
        case .translateTo: return .end
        case .launchAtLogin: return state.launchAtLoginOn ? .end : .start
        case .showInDock: return state.showInDockOn ? .end : .start
        case .gettingToKnowNanoPod: return .start
        case .musicAutomation: return state.automationStatus == .authorized ? .end : .start
        case .appleMusicAccess: return state.appleMusicStatus == .authorized ? .end : .start
        case .playbackHistory: return .start
        case .playPauseShortcut, .nextTrackShortcut, .previousTrackShortcut,
             .showHidePlayerShortcut, .hideToEdgeShortcut:
            return .start
        }
    }

    /// Rendered content for one phase. `PhaseAnimator` (in `DemoStage`) calls
    /// this once per phase and interpolates the Animatable values that differ
    /// between calls; `restingFrame` calls it once, directly, with no animator.
    @ViewBuilder
    func frame(state: SettingsDemoContext, phase: SettingsDemoPhase) -> some View {
        switch self {
        case .fullscreenCover:
            DemoMiniPanel(coverFraction: phase == .start ? 0.68 : 1.0, showTitleBars: phase == .start)

        case .edgeShowSongOnTrackChange:
            DemoMiniScreen(edgePeek: state.edgeShowSongOn ? (phase == .end) : false)

        case .showTranslation:
            DemoLyricSheet(translationOpacity: (phase == .end && state.showTranslationOn) ? 1 : 0, translationText: state.translationSampleText)

        case .translateTo:
            DemoLyricSheet(translationOpacity: phase == .end ? 1 : 0.4, translationText: state.translationSampleText)

        case .launchAtLogin:
            DemoMiniScreen(brightness: phase == .end ? 1.0 : 0.35, showMenuBarNote: phase == .end)

        case .showInDock:
            DemoMiniScreen(dockHasAppBlock: phase == .end)

        case .gettingToKnowNanoPod:
            DemoTourCard()

        case .musicAutomation:
            DemoPermissionFlow(status: state.automationStatus, revealed: phase == .end)

        case .appleMusicAccess:
            DemoMiniPanel(coverFraction: 1.0, showTitleBars: true, coverFilled: state.appleMusicStatus == .authorized && phase == .end)

        case .playbackHistory:
            DemoHistoryRows(fadeOut: phase == .end)

        case .playPauseShortcut:
            HStack(spacing: 10) {
                DemoKeycap(label: state.shortcutLabel(for: .togglePlayPause), pressed: phase == .end)
                DemoMiniPanel(coverFraction: 1.0, showTitleBars: true, playing: phase == .start)
            }

        case .nextTrackShortcut:
            HStack(spacing: 10) {
                DemoKeycap(label: state.shortcutLabel(for: .nextTrack), pressed: phase == .end)
                DemoMiniPanel(coverFraction: 1.0, showTitleBars: true, trackSlide: phase == .end ? 1 : 0)
            }

        case .previousTrackShortcut:
            HStack(spacing: 10) {
                DemoKeycap(label: state.shortcutLabel(for: .previousTrack), pressed: phase == .end)
                DemoMiniPanel(coverFraction: 1.0, showTitleBars: true, trackSlide: phase == .end ? -1 : 0)
            }

        case .showHidePlayerShortcut:
            HStack(spacing: 10) {
                DemoKeycap(label: state.shortcutLabel(for: .togglePanel), pressed: phase == .end)
                DemoMiniScreen(panelOpacity: phase == .end ? 0 : 1)
            }

        case .hideToEdgeShortcut:
            HStack(spacing: 10) {
                DemoKeycap(label: state.shortcutLabel(for: .hideToEdge), pressed: phase == .end)
                DemoMiniScreen(edgePeek: false, panelCollapsedToEdge: phase == .end)
            }
        }
    }
}

/// Two-phase timeline every demo animates across (proposal §4.4: `PhaseAnimator`
/// walks the phases once per `playToken` bump and stops on the last one).
enum SettingsDemoPhase: CaseIterable {
    case start
    case end
}

/// Everything a demo needs to know about the current settings values — plain
/// data, no UserDefaults/service reads inside the demo views themselves.
struct SettingsDemoContext {
    var fullscreenCoverOn: Bool
    var edgeShowSongOn: Bool
    var showTranslationOn: Bool
    var translationSampleText: String
    var launchAtLoginOn: Bool
    var showInDockOn: Bool
    var automationStatus: OnboardingAuthorizationStatus
    var appleMusicStatus: OnboardingAuthorizationStatus
    var shortcutDescriptions: [GlobalShortcutAction: String]

    func shortcutLabel(for name: KeyboardShortcuts.Name) -> String {
        guard let action = GlobalShortcutAction.allCases.first(where: { $0.name == name }) else { return "" }
        return shortcutDescriptions[action] ?? ""
    }
}

// ──────────────────────────────────────────────
// MARK: - DemoStage
// ──────────────────────────────────────────────

/// The 440×120 stage above the segmented control (proposal §4.2). Renders the
/// resting frame when idle or under Reduce Motion; renders a `PhaseAnimator`
/// walk when actively demoing a hover/toggle. `reduceMotion` is an explicit
/// initializer parameter (not read from `\.accessibilityReduceMotion` here) so
/// tests can construct this view directly and reflect its `body`'s static type
/// without needing an environment injection.
struct DemoStage: View {
    let demo: SettingsDemo?
    let context: SettingsDemoContext
    let playToken: Int
    let reduceMotion: Bool
    let caption: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

            Group {
                if let demo {
                    if reduceMotion {
                        demo.restingFrame(state: context)
                    } else {
                        PhaseAnimator(SettingsDemoPhase.allCases, trigger: playToken) { phase in
                            demo.frame(state: context, phase: phase)
                        } animation: { _ in
                            .smooth(duration: 0.35)
                        }
                    }
                } else if let demo = SettingsDemo.allCases.first {
                    demo.restingFrame(state: context)
                }
            }
            .padding(16)

            if !caption.isEmpty {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(EdgeInsets(top: 0, leading: 11, bottom: 8, trailing: 0))
            }
        }
        .frame(width: 440, height: 120)
        .accessibilityHidden(true)
    }
}

// ──────────────────────────────────────────────
// MARK: - Row hover-intent host (reuses ProgressHoverIntentEngine's numbers)
// ──────────────────────────────────────────────

/// Drives which row's demo is showing. Reuses `ProgressHoverIntentEngine`'s
/// exact numbers as the progress bar (`Config.default` = 150ms dwell / 4pt
/// tolerance / 80ms exit grace — proposal §4.4 cites the same engine). A
/// settings row has no meaningful drift geometry the way the progress bar's
/// wide hit rect does, so this host only ever calls `enter`/`exit`/
/// `timerFired` (never `move`) — a fast pass still enters `.pending` and then
/// `.exit`s before the dwell timer fires, which the engine already resets
/// with zero visual change, so plain hover in/out gating is suffient.
///
/// `nowProvider`/`scheduleProvider` are injectable so tests can drive this
/// with a fake clock instead of sleeping on the real one (CLAUDE.md's
/// "手感类验证...可控的假时钟" rule).
final class SettingsRowHoverIntentHost {
    private(set) var state: ProgressHoverIntentEngine.State = .idle
    private var workItem: DispatchWorkItem?
    var onCommitChanged: (Bool) -> Void = { _ in }
    var nowProvider: () -> TimeInterval = { CACurrentMediaTime() }
    var scheduleProvider: (TimeInterval, @escaping () -> Void) -> Void = { delay, fire in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fire)
    }

    func hoverChanged(_ hovering: Bool) {
        let now = nowProvider()
        let result = hovering
            ? ProgressHoverIntentEngine.enter(state: state, at: .zero, now: now, config: .default)
            : ProgressHoverIntentEngine.exit(state: state, now: now, config: .default)
        apply(result)
    }

    /// Test seam: fire the currently-armed timer directly instead of waiting.
    func fireTimerForTesting() {
        apply(ProgressHoverIntentEngine.timerFired(state: state, now: nowProvider()))
    }

    private func apply(_ result: (ProgressHoverIntentEngine.State, ProgressHoverIntentEngine.Effect)) {
        state = result.0
        switch result.1 {
        case .none:
            break
        case .cancelTimer:
            workItem?.cancel()
            workItem = nil
        case .armTimer(let deadline):
            workItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.timerFiredFromSchedule() }
            workItem = item
            scheduleProvider(max(0, deadline - nowProvider()), item.perform)
        case .commit:
            onCommitChanged(true)
        case .uncommit:
            onCommitChanged(false)
        }
    }

    private func timerFiredFromSchedule() {
        apply(ProgressHoverIntentEngine.timerFired(state: state, now: nowProvider()))
    }
}

// ──────────────────────────────────────────────
// MARK: - Shared demo primitives (SwiftUI shapes only — no bitmaps)
// ──────────────────────────────────────────────

/// 200×125 "screen" with a 10pt menu-bar strip, an optional Dock capsule row,
/// an optional right-edge peek strip+capsule, and an optional hosted mini panel.
struct DemoMiniScreen: View {
    var edgePeek: Bool = false
    var brightness: Double = 1.0
    var showMenuBarNote: Bool = false
    var dockHasAppBlock: Bool = false
    var panelOpacity: Double = 1.0
    var panelCollapsedToEdge: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06 + 0.10 * brightness))
                .frame(width: 200, height: 125)

            // Menu bar strip
            HStack {
                if showMenuBarNote {
                    Image(systemName: "music.note")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(width: 200, height: 10)
            .background(Color.primary.opacity(0.14))

            // Right-edge peek strip
            if edgePeek || panelCollapsedToEdge {
                HStack {
                    Spacer()
                    Capsule()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(width: edgePeek ? 34 : 6, height: 28)
                        .padding(.trailing, edgePeek ? 4 : 2)
                }
                .frame(width: 200, height: 125)
            } else {
                HStack {
                    Spacer()
                    Capsule()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 4, height: 40)
                        .padding(.trailing, 2)
                }
                .frame(width: 200, height: 125)
            }

            // Hosted mini panel (Show/Hide Player demo)
            DemoMiniPanel(coverFraction: 1.0, showTitleBars: true)
                .opacity(panelOpacity)
                .offset(y: 6)

            // Dock row
            VStack {
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                    if dockHasAppBlock {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.bottom, 3)
            }
            .frame(width: 200, height: 125)
        }
        .frame(width: 200, height: 125)
    }
}

/// 62.5×71 panel — a quarter-scale stand-in for the real 250×284 panel — with
/// a cover square, two text bars, and three control dots.
struct DemoMiniPanel: View {
    var coverFraction: CGFloat = 0.68
    var showTitleBars: Bool = true
    var coverFilled: Bool = true
    var playing: Bool = true
    /// -1 = previous-track slide, 0 = none, 1 = next-track slide.
    var trackSlide: CGFloat = 0

    private let panelSize = CGSize(width: 62.5, height: 71)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: panelSize.width, height: panelSize.height)

            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(coverFilled ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.3))
                    .frame(width: panelSize.width * coverFraction, height: panelSize.width * coverFraction)
                    .offset(x: trackSlide * 6)

                if showTitleBars {
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary.opacity(0.55))
                            .frame(width: panelSize.width * 0.6, height: 3)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: panelSize.width * 0.4, height: 3)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 6))
                        .contentTransition(.symbolEffect(.replace))
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 4, height: 4)
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 4, height: 4)
                }
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
    }
}

/// Three lyric bars, the middle one highlighted, with an optional translation
/// bar fading in beneath it.
struct DemoLyricSheet: View {
    var translationOpacity: Double = 0
    var translationText: String = ""

    var body: some View {
        VStack(spacing: 6) {
            lyricBar(width: 120, opacity: 0.35)
            lyricBar(width: 160, opacity: 1.0, accent: true)
            if translationOpacity > 0 {
                Text(translationText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .opacity(translationOpacity)
                    .transition(.opacity)
            }
            lyricBar(width: 110, opacity: 0.35)
        }
    }

    private func lyricBar(width: CGFloat, opacity: Double, accent: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(accent ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.4))
            .frame(width: width, height: 6)
            .opacity(opacity)
    }
}

/// A rounded key cap showing the user's recorded shortcut description, or a
/// dashed empty cap when nothing is recorded.
struct DemoKeycap: View {
    let label: String
    var pressed: Bool = false

    var body: some View {
        Group {
            if label.isEmpty {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: 54, height: 24)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .overlay(
                        Text(label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    )
                    .frame(width: 54, height: 24)
            }
        }
        .scaleEffect(pressed ? 0.92 : 1.0)
    }
}

/// Static "Getting to know nanoPod" card — deliberately motionless (proposal
/// §4.3: "静态示意…不动"), both phases render identically.
struct DemoTourCard: View {
    var body: some View {
        HStack(spacing: 10) {
            DemoMiniPanel(coverFraction: 0.68, showTitleBars: true)
            Circle()
                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                .frame(width: 28, height: 28)
                .overlay(Circle().trim(from: 0, to: 0.4).stroke(Color.accentColor, lineWidth: 2).rotationEffect(.degrees(-90)))
        }
    }
}

/// Icon → arrow → panel permission flow (Music Automation / Apple Music rows).
struct DemoPermissionFlow: View {
    let status: OnboardingAuthorizationStatus
    var revealed: Bool

    private var authorized: Bool { status == .authorized && revealed }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.25))
                .overlay(Image(systemName: "music.note").font(.system(size: 12)))
                .frame(width: 28, height: 28)

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(authorized ? .primary : .secondary)
                .opacity(authorized ? 1 : 0.5)

            DemoMiniPanel(coverFraction: 1.0, showTitleBars: authorized, coverFilled: authorized)
        }
    }
}

/// Three history rows that fade out once (Playback History "Clear" demo).
struct DemoHistoryRows: View {
    var fadeOut: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.3)).frame(width: 14, height: 14)
                    RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.35)).frame(width: 90 - CGFloat(index) * 12, height: 4)
                }
            }
        }
        .opacity(fadeOut ? 0 : 1)
    }
}
