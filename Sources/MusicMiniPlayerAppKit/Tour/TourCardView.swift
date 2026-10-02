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
    /// The demo the current beat asks for; nil = the beat has no demo (the band is folded away).
    @Published var gestureKind: TourGestureKind? {
        didSet { if let gestureKind { lastGestureKind = gestureKind } }
    }
    /// The last demo shown: it stays drawn while its band folds away.
    private(set) var lastGestureKind: TourGestureKind?
    /// Bumps when a DIFFERENT card (not just a checked beat) takes over, so
    /// SwiftUI cross-fades the content instead of morphing it.
    @Published var contentKey = 0
    @Published var arm: TourCardMaterialArm
    /// The step has sat unfinished for a while: "skip this one" turns accent-ink.
    @Published var stalled = false

    let feedback: TourCompletionFeedback
    /// The card's motion (position, height, beak, scale, block fades) —
    /// written per frame by `TourGuidance`.
    let guidance: TourGuidanceStore

    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onStop: (() -> Void)?
    var onSkipStep: (() -> Void)?
    var onFallback: (() -> Void)?
    /// A beat row was hovered (`id`, `inside`): the ring peeks at its control.
    var onBeatHover: ((Int, Bool) -> Void)?
    /// The resting demo was hovered: play it again.
    var onGlyphReplay: (() -> Void)?

    init(model: TourCardModel, feedback: TourCompletionFeedback, arm: TourCardMaterialArm = .current(), guidance: TourGuidanceStore? = nil) {
        self.model = model
        self.feedback = feedback
        self.arm = arm
        self.guidance = guidance ?? TourGuidanceStore()
    }
}

struct TourCardRoot: View {
    @ObservedObject var store: TourCardStore
    @ObservedObject var guidance: TourCardVisualStore

    init(store: TourCardStore) {
        self.store = store
        self.guidance = store.guidance.cardStore
    }

    var body: some View {
        #if DEBUG
        TourPerfProbe.bump(.cardBody)
        #endif
        return TourCardView(
            model: store.model, beakSide: store.beakSide, beakOffset: store.beakOffset,
            gestureKind: store.gestureKind, arm: store.arm, feedback: store.feedback,
            contentKey: store.contentKey,
            guide: guidance.driven && guidance.visual.cardVisible ? guidance.visual : nil,
            fadingGestureKind: store.lastGestureKind,
            glyphClock: store.guidance.glyphClock,
            stalled: store.stalled,
            onPrimary: store.onPrimary, onSecondary: store.onSecondary, onStop: store.onStop,
            onSkipStep: store.onSkipStep, onFallback: store.onFallback, onBeatHover: store.onBeatHover,
            onGlyphReplay: store.onGlyphReplay
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
    /// Non-nil = the card is driven by `TourGuidanceMotion` (height, beak, scale
    /// and block fades come from the frame); nil = a static card (tests, renders).
    var guide: TourCardVisual?
    /// The demo that is folding away (`gestureKind` is already nil): drawn until its band is gone. Driven cards only.
    var fadingGestureKind: TourGestureKind?
    /// The demo's clock (driven cards); the demo observes it, the card does not.
    var glyphClock: TourGlyphClock?
    var stalled = false
    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onStop: (() -> Void)?
    var onSkipStep: (() -> Void)?
    var onFallback: (() -> Void)?
    var onBeatHover: ((Int, Bool) -> Void)?
    var onGlyphReplay: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var palette: TourCardPalette { .resolve(dark: colorScheme == .dark) }
    private var effectiveSide: TourCardSide { guide?.cardBeakSide ?? beakSide }
    private var effectiveOffset: CGFloat { guide.map { CGFloat($0.cardBeakOffset) } ?? beakOffset }
    private var shape: TourBubbleShape {
        TourBubbleShape(beakSide: effectiveSide, beakOffset: effectiveOffset, beakScale: guide.map { CGFloat($0.beakScale) } ?? 1)
    }

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
        let side = effectiveSide
        let laidOut = content
            .frame(width: M.bodyWidth, alignment: .leading)
            .padding(.top, side == .top ? M.beakSize : 0)
            .padding(.bottom, side == .bottom ? M.beakSize : 0)
            .padding(.leading, side == .left ? M.beakSize : 0)
            .padding(.trailing, side == .right ? M.beakSize : 0)
            .fixedSize(horizontal: false, vertical: true)
        return heightDriven(laidOut)
            .tourCardMaterial(arm, shape: shape, dark: colorScheme == .dark)
            // The big ring of the celebration moment (spec §B.10): above the content, never blurred or clipped by it.
            .overlay(TourCelebrationRingLayer(beakSide: side, stepLabel: model.stepLabel, closed: model.ringClosed,
                                               completed: model.ringCompleted, palette: palette, feedback: feedback))
            .overlay(shape.stroke(palette.hairline, lineWidth: 0.5))
            .modifier(TourCardScale(guide: guide))
            // The card window is never key. Controls and materials that dim
            // themselves in inactive windows must still read as active here.
            .environment(\.controlActiveState, .key)
    }

    /// While the height springs, the bubble is exactly the animated height and
    /// the content (natural size, top-aligned) is clipped to it.
    @ViewBuilder
    private func heightDriven<V: View>(_ view: V) -> some View {
        if let guide, guide.cardHeight > 1 {
            view.frame(height: CGFloat(guide.cardHeight), alignment: .top).clipped()
        } else {
            view
        }
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
                    .tourFeedbackBlock(1, feedback, guide: guide)
            }
            if let chip = model.chip { chipView(chip).tourFeedbackBlock(1, feedback, guide: guide) }
            if !model.beats.isEmpty { beatsView.tourFeedbackBlock(2, feedback, guide: guide) }
            if let kind = shownGestureKind {
                glyphBand(kind).tourFeedbackBlock(2, feedback, guide: guide)
            }
            if isMoveStep, let note = model.footNote { noteView(note).tourFeedbackBlock(2, feedback, guide: guide) }
            if let confirm = model.confirm {
                Text(confirm)
                    .font(.system(size: M.confirmSize, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .padding(.top, M.confirmTop)
                    .tourFeedbackBlock(2, feedback, guide: guide)
            }
            footer.tourFeedbackBlock(2, feedback, guide: guide)
            if !isMoveStep, let note = model.footNote, hasFooter { noteView(note).tourFeedbackBlock(2, feedback, guide: guide) }
        }
        .padding(.top, M.paddingTop)
        .padding(.horizontal, M.paddingSide)
        .padding(.bottom, M.paddingBottom)
        .modifier(TourCelebrationContent(feedback: feedback))
        .id(contentKey)
        .transition(.opacity)
    }

    /// The demo to draw: the one the beat asks for, or (driven cards) the one still folding away.
    private var shownGestureKind: TourGestureKind? {
        if let gestureKind { return gestureKind }
        if let guide, guide.glyphPresence > 0.003 { return fadingGestureKind }
        return nil
    }

    /// The trackpad demo's band. Driven, it grows in (and folds away) with the card's own height spring —
    /// `glyphPresence` is that spring — while the demo fades and scales in from its top edge; static cards
    /// show it fully. Its clock is the tour's (no clock of its own).
    private func glyphBand(_ kind: TourGestureKind) -> some View {
        let presence = guide.map { min(max($0.glyphPresence, 0), 1.25) } ?? 1
        let shown = min(presence, 1)
        let natural = M.gestureTop + TourGestureGlyphFace.size.height
        return Group {
            if guide != nil, let glyphClock {
                TourDrivenGestureGlyph(kind: kind, clock: glyphClock, reduceMotion: reduceMotion, onReplay: onGlyphReplay)
            } else {
                TourGestureGlyph(kind: kind, reduceMotion: reduceMotion)
            }
        }
        .padding(.top, M.gestureTop)
        .frame(maxWidth: .infinity)
        .frame(height: natural, alignment: .top)
        .opacity(shown)
        .scaleEffect(0.9 + 0.1 * shown, anchor: .top)
        .frame(height: natural * presence, alignment: .top)
        .clipped()
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
                .tourFeedbackBlock(0, feedback, guide: guide)
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
                TourFeedbackBeatRow(beat: beat, palette: palette, size: M.beatSize, feedback: feedback, onHover: onBeatHover)
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
            link(L10n.localized("tour.skipStep"), onSkipStep, emphasized: stalled)
        }
    }

    private func link(_ title: String, _ action: @escaping () -> Void, emphasized: Bool = false) -> some View {
        Button(title, action: action).buttonStyle(TourLinkStyle(palette: palette, emphasized: emphasized))
    }
}

/// Scales the whole bubble about its beak tip (C.2: the card grows from the
/// tip that points at the anchor, and shrinks back toward it).
private struct TourCardScale: ViewModifier {
    var guide: TourCardVisual?

    func body(content: Content) -> some View {
        guard let guide, abs(guide.cardScale - 1) > 0.0005 else { return AnyView(content) }
        let h = max(guide.cardHeight, 1)
        let anchor: UnitPoint
        switch guide.cardBeakSide {
        case .right: anchor = UnitPoint(x: 1, y: guide.cardBeakOffset / h)
        case .left: anchor = UnitPoint(x: 0, y: guide.cardBeakOffset / h)
        case .top: anchor = UnitPoint(x: 0.5, y: 0)
        case .bottom: anchor = UnitPoint(x: 0.5, y: 1)
        }
        return AnyView(content.scaleEffect(CGFloat(guide.cardScale), anchor: anchor))
    }
}
