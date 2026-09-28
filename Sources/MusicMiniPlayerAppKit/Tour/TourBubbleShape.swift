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
        var path = Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous)
        path.addPath(beakTriangle(in: rect, body: body))
        return path
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

    private func beakTriangle(in rect: CGRect, body: CGRect) -> Path {
        let offset = clampedOffset(in: body)
        var triangle = Path()
        switch beakSide {
        case .left:
            let tip = CGPoint(x: rect.minX, y: body.minY + offset)
            triangle.move(to: tip)
            triangle.addLine(to: CGPoint(x: body.minX, y: tip.y - beakSize / 2))
            triangle.addLine(to: CGPoint(x: body.minX, y: tip.y + beakSize / 2))
        case .right:
            let tip = CGPoint(x: rect.maxX, y: body.minY + offset)
            triangle.move(to: tip)
            triangle.addLine(to: CGPoint(x: body.maxX, y: tip.y - beakSize / 2))
            triangle.addLine(to: CGPoint(x: body.maxX, y: tip.y + beakSize / 2))
        case .top:
            let tip = CGPoint(x: body.minX + offset, y: rect.minY)
            triangle.move(to: tip)
            triangle.addLine(to: CGPoint(x: tip.x - beakSize / 2, y: body.minY))
            triangle.addLine(to: CGPoint(x: tip.x + beakSize / 2, y: body.minY))
        case .bottom:
            let tip = CGPoint(x: body.minX + offset, y: rect.maxY)
            triangle.move(to: tip)
            triangle.addLine(to: CGPoint(x: tip.x - beakSize / 2, y: body.maxY))
            triangle.addLine(to: CGPoint(x: tip.x + beakSize / 2, y: body.maxY))
        }
        triangle.closeSubpath()
        return triangle
    }
}
