/**
 * [INPUT]: SwiftUI, MusicMiniPlayerCore's TourMotionPolicy.
 * [OUTPUT]: Exports TourRingView — the continuous progress ring (proposal §4.7).
 * [POS]: MusicMiniPlayerAppKit/Tour. Pinned to the token table in
 *        TourMotionPolicy so its geometry/timing stay a single source of
 *        truth with the (already-tested) motion policy.
 */

import SwiftUI
import MusicMiniPlayerCore

struct TourRingView: View {
    /// 0...total.
    var completed: Int
    var total: Int = 7
    /// True only for the finale's full-circle close (§8.2) — bypasses the
    /// `completed/total` fraction so a deferred-translate finale (6/7) can
    /// still be told to render a full ring for the "环停在 6/7，不合圈" case
    /// simply by NOT setting this, i.e. `closed` is only ever true when the
    /// ring is meant to be a full circle.
    var closed: Bool = false
    var showCheckmark: Bool = false
    var stepLabel: String = ""
    var reduceMotion: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    private var diameter: CGFloat { TourMotionPolicy.Tokens.ringOuterDiameter }
    private var lineWidth: CGFloat { TourMotionPolicy.Tokens.ringLineWidth }

    private var progress: CGFloat {
        closed ? 1 : (total > 0 ? CGFloat(completed) / CGFloat(total) : 0)
    }

    /// §4.7: foreground Apple Music pink; light `#FA4058` / dark `#FB546C`.
    private var foreground: Color {
        colorScheme == .dark ? Color(red: 0xFB / 255, green: 0x54 / 255, blue: 0x6C / 255)
                              : Color(red: 0xFA / 255, green: 0x40 / 255, blue: 0x58 / 255)
    }

    /// §4.7: track = same hue, low opacity — light 22%, dark 28%.
    private var trackOpacity: Double { colorScheme == .dark ? 0.28 : 0.22 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(foreground.opacity(trackOpacity), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(foreground, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(fillAnimation, value: progress)

            if showCheckmark {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(foreground)
                    .transition(.opacity)
            } else {
                Text(stepLabel)
                    .font(.system(size: 9.5, weight: .semibold, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(foreground)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showCheckmark ? "已完成" : "第 \(stepLabel) 步，共 \(total) 步")
    }

    /// §8.1: 0.6s ease-out (cubic-bezier(.2,.8,.2,1)); §8.4 Reduce Motion:
    /// same duration but linear, no bounce.
    private var fillAnimation: Animation {
        reduceMotion
            ? .linear(duration: TourMotionPolicy.Tokens.ringFillDuration)
            : .timingCurve(0.2, 0.8, 0.2, 1, duration: TourMotionPolicy.Tokens.ringFillDuration)
    }
}
