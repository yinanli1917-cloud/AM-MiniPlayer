import XCTest
import SwiftUI
@testable import EdgeCollapseSpike

/// One outline for the whole object: parts closer than the neck width join
/// with a smooth neck, further apart they are two pieces.
final class LiquidOutlineTests: XCTestCase {
    private func subpaths(_ p: Path) -> Int {
        var n = 0
        p.forEach { if case .move = $0 { n += 1 } }
        return n
    }

    private let handle = LiquidPart(rect: CGRect(x: 308, y: 160, width: 30, height: 40), radius: 6)

    func test_closeParts_joinWithANeck() {
        let drop = LiquidPart(rect: CGRect(x: 281, y: 169, width: 22, height: 22), radius: 11)  // gap 5
        let path = LiquidOutline.path(parts: [handle, drop], neck: 14)
        XCTAssertEqual(subpaths(path), 1, "one piece")
        XCTAssertTrue(path.cgPath.contains(CGPoint(x: 305.5, y: 180)), "the gap is filled by the neck")
        XCTAssertTrue(path.cgPath.contains(CGPoint(x: 292, y: 180)))
        XCTAssertTrue(path.cgPath.contains(CGPoint(x: 320, y: 180)))
        XCTAssertFalse(path.cgPath.contains(CGPoint(x: 305.5, y: 162)), "the neck is narrower than the parts")
    }

    func test_farParts_areTwoPieces() {
        let drop = LiquidPart(rect: CGRect(x: 240, y: 169, width: 22, height: 22), radius: 11)
        let path = LiquidOutline.path(parts: [handle, drop], neck: 14)
        XCTAssertEqual(subpaths(path), 2)
        XCTAssertFalse(path.cgPath.contains(CGPoint(x: 285, y: 180)))
    }

    func test_partInsideAnother_isTheOuterShape() {
        let card = LiquidPart(rect: CGRect(x: 54, y: 22, width: 250, height: 316), radius: 16)
        let parked = LiquidPart(rect: CGRect(x: 178, y: 179, width: 2, height: 2), radius: 1)
        XCTAssertEqual(LiquidOutline.path(parts: [card, parked], neck: 14).boundingRect.integral, card.rect.integral)
    }

    /// Runs every frame on the main thread; must fit well inside 8.3ms.
    /// Budget holds for an optimized build (swift test -c release
    /// -Xswiftc -enable-testing); a debug build is ~10x slower.
    func test_contour_isCheapEnoughForEveryFrame() {
        #if DEBUG
        let budget = 0.030
        #else
        let budget = 0.002
        #endif
        let big = LiquidPart(rect: CGRect(x: 40, y: 40, width: 200, height: 260), radius: 30)
        let near = LiquidPart(rect: CGRect(x: 236, y: 120, width: 60, height: 80), radius: 30)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { _ = LiquidOutline.path(parts: [big, near], neck: 14) }
        let perCall = (CFAbsoluteTimeGetCurrent() - start) / 20
        print("LIQUID contour ms", perCall * 1000)
        XCTAssertLessThan(perCall, budget)
    }
}
