/**
 * [INPUT]: SwiftUI; MusicMiniPlayerCore's TourMotionPolicy/TourCardSide/L10n;
 *          this Tour/ folder's TourCardModel/TourBubbleShape/TourCardStyle/
 *          TourCardMaterial/TourCompletionFeedback/TourGestureGlyph.
 * [OUTPUT]: Exports TourCardView (the card's content, pure values in), TourCardStore
 *           (what the persistent card window observes), TourCardRoot.
 * [POS]: MusicMiniPlayerAppKit/Tour. Layout pinned to storyboard.html `.card`
 *        (proposal §4.7): head = title (left) + 28pt ring (top right), then
 *        body, chip, beats, gesture, note, footer; footer = two text links or a
 *        link and a capsule button, never system-styled controls. One glass
 *        shape per card (body + beak); buttons are solid capsules.
 */

import SwiftUI
import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Store (persistent window content state)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The card window's content is ONE hosting view for the whole tour, fed by
/// this object. (The first version swapped in a brand-new NSHostingController
/// on every change, so no state could ever animate into the next.)
@MainActor
final class TourCardStore: ObservableObject {
    @Published var model: TourCardModel
    @Published var beakSide: TourCardSide = .right
    /// Y-down / x-right distance to the beak tip (TourBubbleShape's convention).
    @Published var beakOffset: CGFloat = 40
    @Published var gestureKind: TourGestureKind?
    /// Bumps when a DIFFERENT card (not just a checked beat) takes over, so
    /// SwiftUI cross-fades the content instead of morphing it.
    @Published var contentKey = 0
    @Published var arm: TourCardMaterialArm

    let feedback: TourCompletionFeedback

    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onStop: (() -> Void)?
    var onSkipStep: (() -> Void)?
    var onFallback: (() -> Void)?

    init(model: TourCardModel, feedback: TourCompletionFeedback, arm: TourCardMaterialArm = .current()) {
        self.model = model
        self.feedback = feedback
        self.arm = arm
    }
}

struct TourCardRoot: View {
    @ObservedObject var store: TourCardStore

    var body: some View {
        TourCardView(
            model: store.model, beakSide: store.beakSide, beakOffset: store.beakOffset,
            gestureKind: store.gestureKind, arm: store.arm, feedback: store.feedback,
            contentKey: store.contentKey,
            onPrimary: store.onPrimary, onSecondary: store.onSecondary, onStop: store.onStop,
            onSkipStep: store.onSkipStep, onFallback: store.onFallback
        )
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct TourCardView: View {
    typealias M = TourCardMetrics

    var model: TourCardModel
    var beakSide: TourCardSide
    var beakOffset: CGFloat
    var gestureKind: TourGestureKind?
    var arm: TourCardMaterialArm = .glass
    var feedback: TourCompletionFeedback
    var contentKey = 0
    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onStop: (() -> Void)?
    var onSkipStep: (() -> Void)?
    var onFallback: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var palette: TourCardPalette { .resolve(dark: colorScheme == .dark) }
    private var shape: TourBubbleShape { TourBubbleShape(beakSide: beakSide, beakOffset: beakOffset) }

    /// Window width = body + beak on the beak's side.
    static func windowWidth(beakSide: TourCardSide) -> CGFloat {
        switch beakSide {
        case .left, .right: return M.bodyWidth + M.beakSize
        case .top, .bottom: return M.bodyWidth
        }
    }

    /// The card body's rectangle in screen space (window minus the beak) — the
    /// finale confetti launches from its top edge.
    static func bodyFrame(inWindowFrame f: CGRect, beakSide: TourCardSide) -> CGRect {
        var r = f
        switch beakSide {
        case .left: r.origin.x += M.beakSize; r.size.width -= M.beakSize
        case .right: r.size.width -= M.beakSize
        case .top: r.size.height -= M.beakSize
        case .bottom: r.origin.y += M.beakSize; r.size.height -= M.beakSize
        }
        return r
    }

    /// Screen point (AppKit, y up) of the progress ring's center for a card
    /// window at `f` — where the completion sparks fly out from.
    static func ringCenter(inWindowFrame f: CGRect, beakSide: TourCardSide) -> CGPoint {
        let r = TourMotionPolicy.Tokens.ringOuterDiameter / 2
        return CGPoint(
            x: f.maxX - (beakSide == .right ? M.beakSize : 0) - M.paddingSide - r,
            y: f.maxY - (beakSide == .top ? M.beakSize : 0) - M.paddingTop - r
        )
    }

    var body: some View {
        content
            .frame(width: M.bodyWidth, alignment: .leading)
            .padding(.top, beakSide == .top ? M.beakSize : 0)
            .padding(.bottom, beakSide == .bottom ? M.beakSize : 0)
            .padding(.leading, beakSide == .left ? M.beakSize : 0)
            .padding(.trailing, beakSide == .right ? M.beakSize : 0)
            .fixedSize(horizontal: false, vertical: true)
            .tourCardMaterial(arm, shape: shape, dark: colorScheme == .dark)
            .overlay(shape.stroke(palette.hairline, lineWidth: 0.5))
            // The card window is never key. Controls and materials that dim
            // themselves in inactive windows must still read as active here.
            .environment(\.controlActiveState, .key)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            // The completion handoff (spec §B.2) fades three blocks: title,
            // body (+ chip), and everything from the beats down. The ring is
            // not part of any block.
            if !model.body.isEmpty {
                Text(model.body)
                    .font(.system(size: M.bodySize))
                    .foregroundStyle(palette.muted)
                    .lineSpacing(M.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, M.bodyTop)
                    .tourFeedbackBlock(1, feedback)
            }
            if let chip = model.chip { chipView(chip).tourFeedbackBlock(1, feedback) }
            if !model.beats.isEmpty { beatsView.tourFeedbackBlock(2, feedback) }
            if let gestureKind {
                TourGestureGlyph(kind: gestureKind, reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity)
                    .padding(.top, M.gestureTop)
                    .tourFeedbackBlock(2, feedback)
            }
            if isMoveStep, let note = model.footNote { noteView(note).tourFeedbackBlock(2, feedback) }
            if let confirm = model.confirm {
                Text(confirm)
                    .font(.system(size: M.confirmSize, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .padding(.top, M.confirmTop)
                    .tourFeedbackBlock(2, feedback)
            }
            footer.tourFeedbackBlock(2, feedback)
            if !isMoveStep, let note = model.footNote, hasFooter { noteView(note).tourFeedbackBlock(2, feedback) }
        }
        .padding(.top, M.paddingTop)
        .padding(.horizontal, M.paddingSide)
        .padding(.bottom, M.paddingBottom)
        .id(contentKey)
        .transition(.opacity)
    }

    private var isMoveStep: Bool { if case .step(.moveTuck) = model.kind { return true }; return false }

    private var head: some View {
        HStack(alignment: .top, spacing: M.headGap) {
            Text(model.title)
                .font(.system(size: M.titleSize, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineSpacing(M.titleLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, M.titleTopInset)
                .tourFeedbackBlock(0, feedback)
            TourFeedbackRing(
                completed: model.ringCompleted, closed: model.ringClosed,
                stepLabel: model.stepLabel, palette: palette, feedback: feedback
            )
        }
    }

    private func chipView(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color(hex: 0x22A06B))
            Text(text).font(.system(size: M.noteSize)).foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(palette.track))
        .padding(.top, M.chipTop)
    }

    private var beatsView: some View {
        VStack(alignment: .leading, spacing: M.beatGap) {
            ForEach(model.beats) { beat in
                TourFeedbackBeatRow(beat: beat, palette: palette, size: M.beatSize, feedback: feedback)
            }
        }
        .padding(.top, M.beatsTop)
    }

    private func noteView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: M.noteSize))
            .foregroundStyle(palette.muted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, M.noteTop)
    }

    // MARK: Footer

    private var hasFooter: Bool {
        model.primaryTitle != nil || model.secondaryTitle != nil || model.showStop || model.showSkipStep || model.showFallbackButton
    }

    /// Left slot: "stop here" on step cards; the secondary action on the
    /// welcome / connect / finale cards. Right slot: the primary capsule, the
    /// fallback capsule (move step), or "skip this one".
    @ViewBuilder
    private var footer: some View {
        if hasFooter {
            HStack(spacing: 8) {
                leftSlot
                Spacer(minLength: 0)
                rightSlot
            }
            .padding(.top, M.footTop)
        }
    }

    @ViewBuilder
    private var leftSlot: some View {
        if model.showStop, let onStop {
            link(L10n.localized("tour.stop"), onStop)
        } else if !model.showFallbackButton, let title = model.secondaryTitle, let onSecondary {
            if case .finale = model.kind {
                Button(title, action: onSecondary).buttonStyle(TourSecondaryButtonStyle(palette: palette))
            } else {
                link(title, onSecondary)
            }
        }
    }

    @ViewBuilder
    private var rightSlot: some View {
        if let title = model.primaryTitle, let onPrimary {
            Button(title, action: onPrimary).buttonStyle(TourPrimaryButtonStyle(palette: palette))
        } else if model.showFallbackButton, let title = model.secondaryTitle, let onFallback {
            Button(title, action: onFallback).buttonStyle(TourSecondaryButtonStyle(palette: palette))
        } else if model.showSkipStep, let onSkipStep {
            link(L10n.localized("tour.skipStep"), onSkipStep)
        }
    }

    private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(TourLinkStyle(palette: palette))
    }
}
