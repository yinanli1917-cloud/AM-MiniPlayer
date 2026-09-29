/**
 * [INPUT]: SwiftUI's Path.
 * [OUTPUT]: Exports DemoSVGPath.path(_:) — an SVG path-data (`d="…"`) parser.
 * [POS]: Lets the settings demo drawing reuse the prototype's own icon geometry
 *        (Apple logo, Wi-Fi, transport glyphs) instead of re-drawing it by eye.
 *        Supports M L H V C S Q A Z in absolute and relative form; arcs are
 *        converted to cubics per the SVG implementation notes (F.6.5).
 */

import SwiftUI

enum DemoSVGPath {

    static func path(_ d: String) -> Path {
        var parser = Parser(Array(d.unicodeScalars))
        return parser.parse()
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var path = Path()
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        init(_ scalars: [Unicode.Scalar]) { s = scalars }

        mutating func parse() -> Path {
            var cmd: Character = "M"
            while true {
                skipSeparators()
                guard i < s.count else { break }
                if let c = command(at: i) {
                    cmd = c
                    i += 1
                } else if cmd == "M" { cmd = "L" } else if cmd == "m" { cmd = "l" }
                execute(cmd)
                if cmd == "z" || cmd == "Z" { skipSeparators() }
            }
            return path
        }

        // MARK: tokens

        func command(at index: Int) -> Character? {
            let c = Character(s[index])
            return "MmLlHhVvCcSsQqAaZz".contains(c) ? c : nil
        }

        mutating func skipSeparators() {
            while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" { i += 1 }
        }

        mutating func number() -> CGFloat {
            skipSeparators()
            let begin = i
            if i < s.count, s[i] == "-" || s[i] == "+" { i += 1 }
            var seenDot = false
            while i < s.count {
                let c = s[i]
                if c.value >= 48, c.value <= 57 { i += 1 }
                else if c == ".", !seenDot { seenDot = true; i += 1 }
                else if (c == "e" || c == "E"), i + 1 < s.count {
                    i += 1
                    if s[i] == "-" || s[i] == "+" { i += 1 }
                } else { break }
            }
            return CGFloat(Double(String(String.UnicodeScalarView(s[begin..<i]))) ?? 0)
        }

        mutating func flag() -> Bool {
            skipSeparators()
            let v = i < s.count && s[i] == "1"
            i += 1
            return v
        }

        // MARK: commands

        mutating func point(relative: Bool) -> CGPoint {
            let x = number(), y = number()
            return relative ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }

        mutating func execute(_ cmd: Character) {
            let rel = cmd.isLowercase
            var newCubic: CGPoint?
            var newQuad: CGPoint?
            switch cmd {
            case "M", "m":
                let p = point(relative: rel)
                path.move(to: p); cur = p; start = p
            case "L", "l":
                let p = point(relative: rel)
                path.addLine(to: p); cur = p
            case "H", "h":
                let x = number()
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur)
            case "V", "v":
                let y = number()
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur)
            case "C", "c":
                let c1 = point(relative: rel), c2 = point(relative: rel), p = point(relative: rel)
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; newCubic = c2
            case "S", "s":
                let c1 = lastCubicControl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = point(relative: rel), p = point(relative: rel)
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; newCubic = c2
            case "Q", "q":
                let c = point(relative: rel), p = point(relative: rel)
                path.addQuadCurve(to: p, control: c); cur = p; newQuad = c
            case "A", "a":
                let rx = number(), ry = number(), rot = number()
                let large = flag(), sweep = flag()
                let p = point(relative: rel)
                addArc(to: p, rx: rx, ry: ry, xAxisRotation: rot, large: large, sweep: sweep)
                cur = p
            case "Z", "z":
                path.closeSubpath(); cur = start
            default:
                i += 1
            }
            lastCubicControl = newCubic
            lastQuadControl = newQuad
        }

        // MARK: arc → cubics (SVG 1.1 implementation notes F.6.5)

        mutating func addArc(to end: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, xAxisRotation: CGFloat, large: Bool, sweep: Bool) {
            var rx = abs(rxIn), ry = abs(ryIn)
            if rx == 0 || ry == 0 || (cur.x == end.x && cur.y == end.y) { path.addLine(to: end); return }
            let phi = xAxisRotation * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx2 = (cur.x - end.x) / 2, dy2 = (cur.y - end.y) / 2
            let x1p = cosPhi * dx2 + sinPhi * dy2
            let y1p = -sinPhi * dx2 + cosPhi * dy2
            let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
            if lambda > 1 { let k = sqrt(lambda); rx *= k; ry *= k }
            let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
            let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
            var coef = den == 0 ? 0 : sqrt(max(0, num / den))
            if large == sweep { coef = -coef }
            let cxp = coef * (rx * y1p / ry)
            let cyp = coef * -(ry * x1p / rx)
            let cx = cosPhi * cxp - sinPhi * cyp + (cur.x + end.x) / 2
            let cy = sinPhi * cxp + cosPhi * cyp + (cur.y + end.y) / 2

            func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                let dot = ux * vx + uy * vy
                let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
                var a = acos(max(-1, min(1, dot / len)))
                if ux * vy - uy * vx < 0 { a = -a }
                return a
            }
            let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
            var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
            if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
            if sweep && dTheta < 0 { dTheta += 2 * .pi }

            let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
            let delta = dTheta / CGFloat(segments)
            let t = 4.0 / 3.0 * tan(delta / 4)
            var a1 = theta1
            for _ in 0..<segments {
                let a2 = a1 + delta
                let p1 = CGPoint(x: cos(a1) - t * sin(a1), y: sin(a1) + t * cos(a1))
                let p2 = CGPoint(x: cos(a2) + t * sin(a2), y: sin(a2) - t * cos(a2))
                let p3 = CGPoint(x: cos(a2), y: sin(a2))
                func map(_ p: CGPoint) -> CGPoint {
                    let x = p.x * rx, y = p.y * ry
                    return CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
                }
                path.addCurve(to: map(p3), control1: map(p1), control2: map(p2))
                a1 = a2
            }
        }
    }
}
