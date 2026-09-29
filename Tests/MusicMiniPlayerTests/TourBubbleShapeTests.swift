import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

/// §11.1 TourBubbleShapeTests: the beak's position/edge math (proposal §4.3's
/// beak clamp) across all four sides.
final class TourBubbleShapeTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 236, height: 150)

    func test_bodyRect_insetByBeakSize_onTheBeakSide() {
        for side: TourCardSide in [.left, .right, .top, .bottom] {
            let shape = TourBubbleShape(beakSide: side, beakOffset: 60)
            let body = shape.bodyRect(in: rect)
            switch side {
            case .left:
                XCTAssertEqual(body.minX, rect.minX + shape.beakSize)
                XCTAssertEqual(body.width, rect.width - shape.beakSize)
                XCTAssertEqual(body.height, rect.height)
            case .right:
                XCTAssertEqual(body.width, rect.width - shape.beakSize)
                XCTAssertEqual(body.maxX, rect.maxX - shape.beakSize, "the beak occupies the rightmost beakSize points")
                XCTAssertEqual(body.minX, rect.minX)
            case .top:
                XCTAssertEqual(body.minY, rect.minY + shape.beakSize)
                XCTAssertEqual(body.height, rect.height - shape.beakSize)
            case .bottom:
                XCTAssertEqual(body.height, rect.height - shape.beakSize)
                XCTAssertEqual(body.minY, rect.minY)
            }
        }
    }

    func test_beakTip_touchesTheOuterEdge_onItsOwnSide() {
        let left = TourBubbleShape(beakSide: .left, beakOffset: 40)
        XCTAssertEqual(left.beakTip(in: rect).x, rect.minX)

        let right = TourBubbleShape(beakSide: .right, beakOffset: 40)
        XCTAssertEqual(right.beakTip(in: rect).x, rect.maxX)

        let top = TourBubbleShape(beakSide: .top, beakOffset: 40)
        XCTAssertEqual(top.beakTip(in: rect).y, rect.minY)

        let bottom = TourBubbleShape(beakSide: .bottom, beakOffset: 40)
        XCTAssertEqual(bottom.beakTip(in: rect).y, rect.maxY)
    }

    func test_beakOffset_clampsAwayFromCorners() {
        let shape = TourBubbleShape(beakSide: .left, beakOffset: 2) // far too close to the top corner
        let body = shape.bodyRect(in: rect)
        let clamped = shape.clampedOffset(in: body)
        XCTAssertGreaterThanOrEqual(clamped, shape.cornerRadius + shape.beakSize / 2)
    }

    func test_beakOffset_clampsAtTheFarCornerToo() {
        let shape = TourBubbleShape(beakSide: .left, beakOffset: 10_000) // absurdly large
        let body = shape.bodyRect(in: rect)
        let clamped = shape.clampedOffset(in: body)
        XCTAssertLessThanOrEqual(clamped, body.height - shape.cornerRadius - shape.beakSize / 2)
    }

    func test_beakTip_tracksTheClampedOffset_notTheRawOne() {
        let shape = TourBubbleShape(beakSide: .left, beakOffset: 2)
        let body = shape.bodyRect(in: rect)
        let tip = shape.beakTip(in: rect)
        XCTAssertEqual(tip.y, body.minY + shape.clampedOffset(in: body))
        XCTAssertNotEqual(tip.y, body.minY + 2, "an unclamped offset would have put the beak inside the rounded corner")
    }

    func test_path_boundingBox_matchesTheFullRect_forLeftRightBeaks() {
        for side: TourCardSide in [.left, .right] {
            let shape = TourBubbleShape(beakSide: side, beakOffset: 75)
            let path = shape.path(in: rect)
            let box = path.boundingRect
            XCTAssertEqual(box.minX, rect.minX, accuracy: 0.5)
            XCTAssertEqual(box.maxX, rect.maxX, accuracy: 0.5)
        }
    }

    /// Founder 2026-09-29: the beak drew as a separate blob beside the body.
    /// Body + beak are added as two sub-paths that only touch at an edge, and
    /// glass samples the path's distance field, so the seam showed. The shape
    /// must be ONE closed contour on every side.
    func test_path_isOneClosedContour_onEverySide() {
        for side: TourCardSide in [.left, .right, .top, .bottom] {
            let shape = TourBubbleShape(beakSide: side, beakOffset: 75)
            var moves = 0, closes = 0
            shape.path(in: rect).forEach { element in
                switch element {
                case .move: moves += 1
                case .closeSubpath: closes += 1
                default: break
                }
            }
            XCTAssertEqual(moves, 1, "\(side): body and beak must merge into a single sub-path")
            XCTAssertEqual(closes, 1, "\(side): and it must be closed")
        }
    }
}
