/**
 * [INPUT]: SwiftUI; MusicMiniPlayerCore's TourMotionPolicy/TourCardSide;
 *          this Tour/ folder's TourCardModel/TourBubbleShape/TourRingView/
 *          TourGestureGlyph.
 * [OUTPUT]: Exports TourCardView.
 * [POS]: MusicMiniPlayerAppKit/Tour. The card's SwiftUI content (proposal
 *        §4.6/§4.7): Liquid Glass on macOS 26 via `GlassEffectContainer` +
 *        `TourBubbleShape`, `.popover`-material `NSVisualEffectView` fallback
 *        on 14/15 — ONE glass shape per card (banned-patterns.md's
 *        glass-on-glass lesson), buttons are solid capsules, not their own
 *        glass.
 */

import SwiftUI
import MusicMiniPlayerCore

struct TourCardView: View {
    var model: TourCardModel
    var beakSide: TourCardSide
    var beakOffset: CGFloat
    var gestureKind: TourGestureKind?
    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onStop: (() -> Void)?
    var onSkipStep: (() -> Void)?
    var onFallback: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let cardWidth: CGFloat = 236
    private var shape: TourBubbleShape { TourBubbleShape(beakSide: beakSide, beakOffset: beakOffset) }

    var body: some View {
        content
            .padding(16)
            .frame(width: cardWidth, alignment: .leading)
            .background(background)
            .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var background: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            GlassEffectContainer {
                Color.clear.glassEffect(.regular, in: shape)
            }
        } else {
            TourVisualEffectBackground(shape: shape)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title + ring, ring right-aligned and top-aligned with the title (§4.7 v3.2).
            HStack(alignment: .top) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.ringCompleted > 0 || model.showRingCheckmark || model.ringClosed {
                    TourRingView(
                        completed: model.ringCompleted, closed: model.ringClosed,
                        showCheckmark: model.showRingCheckmark, stepLabel: model.stepLabel, reduceMotion: reduceMotion
                    )
                }
            }

            if !model.body.isEmpty {
                Text(model.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let chip = model.chip {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    Text(chip).font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }

            if !model.beats.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.beats) { beat in
                        HStack(spacing: 8) {
                            ZStack {
                                Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.2)
                                if beat.checked {
                                    Circle().fill(Color.accentColor)
                                    Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                            .frame(width: 14, height: 14)
                            Text(beat.text)
                                .font(.system(size: 12))
                                .foregroundStyle(beat.checked ? .secondary : .primary)
                        }
                    }
                }
            }

            if let gestureKind {
                HStack {
                    Spacer()
                    TourGestureGlyph(kind: gestureKind, reduceMotion: reduceMotion)
                    Spacer()
                }
                .padding(.vertical, 2)
            }

            if let confirm = model.confirm {
                Text(confirm)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .transition(.opacity)
            }

            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.primaryTitle != nil || model.secondaryTitle != nil || model.showStop || model.showSkipStep || model.showFallbackButton {
            HStack(spacing: 12) {
                if model.showStop, let onStop {
                    Button(L10n.localized("tour.stop"), action: onStop).buttonStyle(.link).font(.system(size: 11))
                }
                if model.showSkipStep, let onSkipStep {
                    Button(L10n.localized("tour.skipStep"), action: onSkipStep).buttonStyle(.link).font(.system(size: 11))
                }
                Spacer(minLength: 0)
                if model.showFallbackButton, let title = model.secondaryTitle, let onFallback {
                    Button(title, action: onFallback)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if let title = model.secondaryTitle, let onSecondary {
                    Button(title, action: onSecondary)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let title = model.primaryTitle, let onPrimary {
                    Button(title, action: onPrimary)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(.top, 2)

            if let foot = model.footNote {
                Text(foot)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// macOS 14/15 fallback (§4.6): `.popover` material masked to the same
/// `TourBubbleShape` the glass arm uses.
private struct TourVisualEffectBackground: NSViewRepresentable {
    var shape: TourBubbleShape

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { view.maskImage = nil; return }
        view.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            let path = shape.path(in: rect)
            NSColor.black.setFill()
            NSBezierPath(cgPath: path.cgPath).fill()
            return true
        }
    }
}
