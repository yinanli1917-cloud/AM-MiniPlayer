/**
 * [INPUT]: SwiftUI (Shape/Path), MusicMiniPlayerCore's TourCardSide.
 * [OUTPUT]: Exports TourBubbleShape — the card body + beak as ONE Shape
 *           (proposal §4.7: "箭头 12pt 等腰，同一形状").
 * [POS]: MusicMiniPlayerAppKit/Tour. Used both as the `.glassEffect(.regular,
 *        in: TourBubbleShape(...))` shape on macOS 26 and as the
 *        `NSVisualEffectView` mask on the 14/15 fallback (§4.6) — one shape,
 *        two consumers, so the glass and the fallback never drift apart.
 */

import SwiftUI
import MusicMiniPlayerCore

struct TourBubbleShape: Shape, Equatable {
    var beakSide: TourCardSide
    var beakOffset: CGFloat
    var cornerRadius: CGFloat = 14
    var beakSize: CGFloat = 12

    /// The rounded-rect body (excludes the beak protrusion), for callers
    /// that need to lay content out inside it without the beak's inset.
    func bodyRect(in rect: CGRect) -> CGRect {
        var body = rect
        switch beakSide {
        case .left: body.origin.x += beakSize; body.size.width -= beakSize
        case .right: body.size.width -= beakSize
        case .top: body.origin.y += beakSize; body.size.height -= beakSize
        case .bottom: body.size.height -= beakSize
        }
        return body
    }

    /// Clamped so the beak's own halfwidth never crosses into the rounded
    /// corner (§4.3's beak clamp, mirrored here for the shape itself).
    func clampedOffset(in body: CGRect) -> CGFloat {
        let axisLength = (beakSide == .left || beakSide == .right) ? body.height : body.width
        let lower = cornerRadius + beakSize / 2
        let upper = max(axisLength - cornerRadius - beakSize / 2, lower)
        return min(max(beakOffset, lower), upper)
    }

    func path(in rect: CGRect) -> Path {
        let body = bodyRect(in: rect)
        // ONE closed outline. Adding the triangle as a second sub-path leaves a
        // hairline seam on the shared edge, and Liquid Glass (which samples the
        // path's distance field) then draws the beak as a separate pale blob
        // floating beside the body (founder 2026-09-29). The beak's base runs
        // `overlap` into the body so the boolean union is one merged contour.
        return Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous)
            .union(beakTriangle(in: rect, body: body))
    }

    /// The beak's own tip point, in the same coordinate space as `path(in:)`
    /// — useful for placement math and tests.
    func beakTip(in rect: CGRect) -> CGPoint {
        let body = bodyRect(in: rect)
        let offset = clampedOffset(in: body)
        switch beakSide {
        case .left: return CGPoint(x: rect.minX, y: body.minY + offset)
        case .right: return CGPoint(x: rect.maxX, y: body.minY + offset)
        case .top: return CGPoint(x: body.minX + offset, y: rect.minY)
        case .bottom: return CGPoint(x: body.minX + offset, y: rect.maxY)
        }
    }

    /// The beak: tip, the two base corners on the body's edge, and two more
    /// points `overlap` inside the body so it merges with it.
    private func beakTriangle(in rect: CGRect, body: CGRect) -> Path {
        let offset = clampedOffset(in: body)
        let overlap: CGFloat = 2
        let half = beakSize / 2
        var beak = Path()
        switch beakSide {
        case .left:
            let tip = CGPoint(x: rect.minX, y: body.minY + offset)
            beak.move(to: tip)
            beak.addLine(to: CGPoint(x: body.minX, y: tip.y - half))
            beak.addLine(to: CGPoint(x: body.minX + overlap, y: tip.y - half))
            beak.addLine(to: CGPoint(x: body.minX + overlap, y: tip.y + half))
            beak.addLine(to: CGPoint(x: body.minX, y: tip.y + half))
        case .right:
            let tip = CGPoint(x: rect.maxX, y: body.minY + offset)
            beak.move(to: tip)
            beak.addLine(to: CGPoint(x: body.maxX, y: tip.y - half))
            beak.addLine(to: CGPoint(x: body.maxX - overlap, y: tip.y - half))
            beak.addLine(to: CGPoint(x: body.maxX - overlap, y: tip.y + half))
            beak.addLine(to: CGPoint(x: body.maxX, y: tip.y + half))
        case .top:
            let tip = CGPoint(x: body.minX + offset, y: rect.minY)
            beak.move(to: tip)
            beak.addLine(to: CGPoint(x: tip.x - half, y: body.minY))
            beak.addLine(to: CGPoint(x: tip.x - half, y: body.minY + overlap))
            beak.addLine(to: CGPoint(x: tip.x + half, y: body.minY + overlap))
            beak.addLine(to: CGPoint(x: tip.x + half, y: body.minY))
        case .bottom:
            let tip = CGPoint(x: body.minX + offset, y: rect.maxY)
            beak.move(to: tip)
            beak.addLine(to: CGPoint(x: tip.x - half, y: body.maxY))
            beak.addLine(to: CGPoint(x: tip.x - half, y: body.maxY - overlap))
            beak.addLine(to: CGPoint(x: tip.x + half, y: body.maxY - overlap))
            beak.addLine(to: CGPoint(x: tip.x + half, y: body.maxY))
        }
        beak.closeSubpath()
        return beak
    }
}
