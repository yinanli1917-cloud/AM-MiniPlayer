/**
 * [INPUT]: up to two rounded rects (the edge body and the capsule) + a neck
 *          size.
 * [OUTPUT]: LiquidOutline.path(...) — ONE closed outline for the whole
 *           object: the smooth union of the rounded rects, so two parts that
 *           come close grow a neck and pinch off like liquid. LiquidShape —
 *           the same outline as a SwiftUI Shape (fill it black, or give it
 *           to glassEffect).
 * [POS]: Liquid edge (ported from research/spikes/edge-collapse-spike). System
 *        glass can never be pure black and blending two glass bodies shows
 *        the system's merge shapes, so the liquid outline is computed here.
 * [PROTOCOL]: Signed distance field of each rounded rect, joined with the
 *             polynomial smooth minimum (width `neck`), contoured by marching
 *             squares with linear interpolation. A single visible part skips
 *             the field and returns the exact rounded rect.
 */

import SwiftUI

public struct LiquidPart: Equatable, Sendable {
    public var rect: CGRect
    public var radius: CGFloat
    /// How big the part really is on screen (a body running past the screen
    /// edge is mostly off-screen). The neck between two parts is limited by
    /// the smaller one's size, so a shrinking part's pull fades out with it
    /// instead of dimpling its neighbour until it vanishes (founder: "卡顿的粘连").
    public var size: CGFloat
    public init(rect: CGRect, radius: CGFloat, size: CGFloat? = nil) {
        self.rect = rect; self.radius = radius
        self.size = size ?? min(rect.width, rect.height)
    }
    var isVisible: Bool { rect.width >= 1 && rect.height >= 1 }
}

public enum LiquidOutline {

    /// Rounded-rect signed distance (negative inside).
    @inline(__always)
    public static func sdf(_ x: Double, _ y: Double, cx: Double, cy: Double, hx: Double, hy: Double, r: Double) -> Double {
        let qx = abs(x - cx) - hx + r
        let qy = abs(y - cy) - hy + r
        let ox = max(qx, 0), oy = max(qy, 0)
        return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
    }

    @inline(__always)
    static func smin(_ a: Double, _ b: Double, _ k: Double) -> Double {
        guard k > 0 else { return min(a, b) }
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    public static func path(parts: [LiquidPart], neck: CGFloat) -> Path {
        let visible = parts.filter(\.isVisible)
        guard !visible.isEmpty else { return Path() }
        if visible.count == 1 {
            let p = visible[0]
            // Circular corners, the same as the distance-field contour, so
            // switching between the two never changes a corner's shape and
            // the progress line (an offset of this outline) stays concentric.
            return Path(roundedRect: p.rect, cornerRadius: min(p.radius, min(p.rect.width, p.rect.height) / 2), style: .circular)
        }
        // Far apart: two exact rounded rects, no field needed.
        let a = visible[0], b = visible[1]
        if !a.rect.insetBy(dx: -neck, dy: -neck).intersects(b.rect) {
            var path = Path()
            for p in [a, b] {
                let r = min(p.radius, min(p.rect.width, p.rect.height) / 2)
                path.addRoundedRect(in: p.rect, cornerSize: CGSize(width: r, height: r), style: .circular)
            }
            return path
        }
        // One part fully inside the other (with margin): the outer one.
        if a.rect.insetBy(dx: 2, dy: 2).contains(b.rect) { return path(parts: [a], neck: 0) }
        if b.rect.insetBy(dx: 2, dy: 2).contains(a.rect) { return path(parts: [b], neck: 0) }
        let k = min(neck, 2 * min(max(a.size, 0), max(b.size, 0)))
        return contour(a, b, k: Double(k))
    }

    /// Marching squares over the field of smin(sdfA, sdfB).
    static func contour(_ a: LiquidPart, _ b: LiquidPart, k: Double) -> Path {
        let box = a.rect.union(b.rect).insetBy(dx: -CGFloat(k) - 2, dy: -CGFloat(k) - 2)
        let step = max(0.5, min(2.0, Double(max(box.width, box.height)) / 160))
        let nx = Int((Double(box.width) / step).rounded(.up)) + 1
        let ny = Int((Double(box.height) / step).rounded(.up)) + 1
        let ox = Double(box.minX), oy = Double(box.minY)
        let pa = (cx: Double(a.rect.midX), cy: Double(a.rect.midY), hx: Double(a.rect.width) / 2, hy: Double(a.rect.height) / 2,
                  r: Double(min(a.radius, min(a.rect.width, a.rect.height) / 2)))
        let pb = (cx: Double(b.rect.midX), cy: Double(b.rect.midY), hx: Double(b.rect.width) / 2, hy: Double(b.rect.height) / 2,
                  r: Double(min(b.radius, min(b.rect.width, b.rect.height) / 2)))
        var f = [Double](repeating: 0, count: nx * ny)
        for j in 0..<ny {
            let y = oy + Double(j) * step
            for i in 0..<nx {
                let x = ox + Double(i) * step
                let da = sdf(x, y, cx: pa.cx, cy: pa.cy, hx: pa.hx, hy: pa.hy, r: pa.r)
                let db = sdf(x, y, cx: pb.cx, cy: pb.cy, hx: pb.hx, hy: pb.hy, r: pb.r)
                // The box edge is always outside, so every contour closes.
                let edge = i == 0 || j == 0 || i == nx - 1 || j == ny - 1
                f[j * nx + i] = edge ? max(smin(da, db, k), 0.01) : smin(da, db, k)
            }
        }

        // Edge ids: horizontal edge (i,j)-(i+1,j) = 2*(j*nx+i); vertical (i,j)-(i,j+1) = +1.
        func hEdge(_ i: Int, _ j: Int) -> Int { 2 * (j * nx + i) }
        func vEdge(_ i: Int, _ j: Int) -> Int { 2 * (j * nx + i) + 1 }
        func point(_ e: Int) -> CGPoint {
            let cell = e / 2, i = cell % nx, j = cell / nx
            let v0 = f[j * nx + i]
            if e % 2 == 0 {
                let v1 = f[j * nx + i + 1]
                let t = v0 / (v0 - v1)
                return CGPoint(x: ox + (Double(i) + t) * step, y: oy + Double(j) * step)
            } else {
                let v1 = f[(j + 1) * nx + i]
                let t = v0 / (v0 - v1)
                return CGPoint(x: ox + Double(i) * step, y: oy + (Double(j) + t) * step)
            }
        }

        var next = [Int: Int]()   // directed: edge → following edge (inside on the left)
        next.reserveCapacity(1024)
        func link(_ from: Int, _ to: Int) { next[from] = to }
        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let tl = f[j * nx + i] < 0, tr = f[j * nx + i + 1] < 0
                let br = f[(j + 1) * nx + i + 1] < 0, bl = f[(j + 1) * nx + i] < 0
                let top = hEdge(i, j), bottom = hEdge(i, j + 1), left = vEdge(i, j), right = vEdge(i + 1, j)
                switch (tl, tr, br, bl) {
                case (false, false, false, false), (true, true, true, true): break
                case (true, false, false, false): link(left, top)
                case (false, true, false, false): link(top, right)
                case (false, false, true, false): link(right, bottom)
                case (false, false, false, true): link(bottom, left)
                case (true, true, false, false): link(left, right)
                case (false, true, true, false): link(top, bottom)
                case (false, false, true, true): link(right, left)
                case (true, false, false, true): link(bottom, top)
                case (false, true, true, true): link(top, left)
                case (true, false, true, true): link(right, top)
                case (true, true, false, true): link(bottom, right)
                case (true, true, true, false): link(left, bottom)
                case (true, false, true, false):
                    let centre = (f[j * nx + i] + f[j * nx + i + 1] + f[(j + 1) * nx + i + 1] + f[(j + 1) * nx + i]) / 4
                    if centre < 0 { link(left, bottom); link(right, top) } else { link(left, top); link(right, bottom) }
                case (false, true, false, true):
                    let centre = (f[j * nx + i] + f[j * nx + i + 1] + f[(j + 1) * nx + i + 1] + f[(j + 1) * nx + i]) / 4
                    if centre < 0 { link(top, left); link(bottom, right) } else { link(top, right); link(bottom, left) }
                }
            }
        }

        var path = Path()
        var visited = Set<Int>()
        visited.reserveCapacity(next.count)
        for start in next.keys where !visited.contains(start) {
            var e = start
            path.move(to: point(e))
            visited.insert(e)
            var guardCount = 0
            while let n = next[e], n != start, guardCount < next.count {
                path.addLine(to: point(n))
                visited.insert(n)
                e = n
                guardCount += 1
            }
            path.closeSubpath()
        }
        return path
    }
}

/// The whole object as one Shape, in the container's coordinates.
public struct LiquidShape: Shape {
    public var parts: [LiquidPart]
    public var neck: CGFloat
    public func path(in rect: CGRect) -> Path { LiquidOutline.path(parts: parts, neck: neck) }
}
