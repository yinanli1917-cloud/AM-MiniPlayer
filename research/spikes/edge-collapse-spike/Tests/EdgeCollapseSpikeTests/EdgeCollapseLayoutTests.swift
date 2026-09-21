import XCTest
@testable import EdgeCollapseSpike

/// (c) `EdgeCollapseLayout.rects` for every state × variant — top-level task
/// instruction #10(c)/#8: aspect ≥3:1 OR corner ≤ half short side for every
/// glass/black shape; floating bodies never extend past the fixed 320×360
/// container (they're geometrically nested inside where the card ALSO sits,
/// since both dock to the same right edge — but `.card` and `.floating` are
/// two different `VisualLayout` cases, never rendered simultaneously by
/// construction, see `RootContentView`'s single `switch visualLayout`); the
/// tucked stalk is flush to the container's right edge.
final class EdgeCollapseLayoutTests: XCTestCase {

    private let variants: [EdgeCollapseVariant] = [.h, .v]
    private let titleWidths: [CGFloat] = [0, 40, 90, 260] // empty, short, medium, longer-than-max-bar

    // MARK: - Aspect ≥3:1 OR corner ≤ half short side (design §3)

    private func aspectOrCornerHolds(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> Bool {
        let longSide = max(width, height)
        let shortSide = min(width, height)
        guard shortSide > 0 else { return false }
        let aspectOK = (longSide / shortSide) >= 3.0
        let cornerOK = cornerRadius <= shortSide / 2 + 0.0001
        return aspectOK || cornerOK
    }

    func test_card_satisfiesCornerRule() {
        let frames = EdgeCollapseLayout.rects(for: EdgePresentation.card, variant: .h, titleWidth: 0)
        XCTAssertTrue(aspectOrCornerHolds(width: frames.body.width, height: frames.body.height, cornerRadius: EdgeCollapseTokens.cardCornerRadius))
        XCTAssertTrue(frames.body.contains(frames.control!), ".card parks the control body inside the card")
    }

    func test_tucked_satisfiesAspectRule_stalkIsTallAndThin() {
        for variant in variants {
            let frames = EdgeCollapseLayout.rects(for: EdgePresentation.tucked, variant: variant, titleWidth: 0)
            // The stalk is a capsule (cornerRadius == height/2 by construction
            // in RootContentView) — verify via the aspect clause directly too,
            // since 8×96 is genuinely ≥3:1 regardless of corner radius.
            // v5: the tucked state is an island (44×96, inner corners 22 = half the short side).
            XCTAssertTrue(aspectOrCornerHolds(width: frames.body.width, height: frames.body.height, cornerRadius: EdgeCollapseTokens.islandCornerRadius))
            XCTAssertEqual(frames.body.maxX, EdgeCollapseTokens.containerSize.width, accuracy: 0.01, "island must be flush with the edge")
        }
    }

    func test_floatingBar_and_controls_satisfyAspectOrCornerRule() {
        for variant in variants {
            for titleWidth in titleWidths {
                let frames = EdgeCollapseLayout.rects(for: EdgePresentation.floating, variant: variant, titleWidth: titleWidth)
                let bodyCorner: CGFloat = variant == .h ? frames.body.height / 2 : EdgeCollapseTokens.floatingDropCornerRadiusV
                XCTAssertTrue(
                    aspectOrCornerHolds(width: frames.body.width, height: frames.body.height, cornerRadius: bodyCorner),
                    "variant=\(variant) titleWidth=\(titleWidth): body \(frames.body) corner=\(bodyCorner) fails aspect/corner rule"
                )
                guard let control = frames.control else {
                    XCTFail("floating must always have a control body")
                    continue
                }
                XCTAssertTrue(
                    aspectOrCornerHolds(width: control.width, height: control.height, cornerRadius: EdgeCollapseTokens.floatingControlCornerRadius),
                    "variant=\(variant): control \(control) fails aspect/corner rule"
                )
            }
        }
    }

    // MARK: - Bar width clamps regardless of title length

    func test_floatingBarH_widthClampsBetweenMinAndMax() {
        for titleWidth in titleWidths {
            let frames = EdgeCollapseLayout.rects(for: EdgePresentation.floating, variant: .h, titleWidth: titleWidth)
            XCTAssertGreaterThanOrEqual(frames.body.width, EdgeCollapseTokens.floatingBarMinWidth - 0.0001)
            XCTAssertLessThanOrEqual(frames.body.width, EdgeCollapseTokens.floatingBarMaxWidth + 0.0001)
        }
    }

    // MARK: - Stalk flush to the right edge (design §3)

    func test_tucked_flushToRightEdge() {
        for variant in variants {
            let frames = EdgeCollapseLayout.rects(for: EdgePresentation.tucked, variant: variant, titleWidth: 0)
            XCTAssertEqual(frames.body.maxX, EdgeCollapseLayout.containerSize.width, accuracy: 0.0001)
        }
    }

    func test_card_flushToRightEdge() {
        let frames = EdgeCollapseLayout.rects(for: EdgePresentation.card, variant: .h, titleWidth: 0)
        XCTAssertEqual(frames.body.maxX, EdgeCollapseLayout.containerSize.width, accuracy: 0.0001)
    }

    // MARK: - Everything fits inside the fixed 320×360 container (instruction #3:
    // the window never resizes, so nothing may be laid out past its bounds)

    func test_everyStateVariant_fitsInsideFixedContainer() {
        // Tiny outward tolerance for floating-point rounding only — a real
        // escape (e.g. a mis-added gap) is off by whole points, not 0.01pt.
        let container = CGRect(origin: .zero, size: EdgeCollapseLayout.containerSize).insetBy(dx: -0.01, dy: -0.01)
        for state in EdgePresentation.allCases {
            for variant in variants {
                for titleWidth in titleWidths {
                    let frames = EdgeCollapseLayout.rects(for: state, variant: variant, titleWidth: titleWidth)
                    XCTAssertTrue(container.contains(frames.body), "state=\(state) variant=\(variant): body \(frames.body) escapes container \(container)")
                    if let control = frames.control {
                        XCTAssertTrue(container.contains(control), "state=\(state) variant=\(variant): control \(control) escapes container \(container)")
                    }
                }
            }
        }
    }

    // MARK: - `.floating` is never the same VisualLayout as `.card` (they can
    // never be simultaneously mounted, so they structurally cannot overlap —
    // RootContentView's single `switch visualLayout` enforces this; this test
    // pins that the 5-case state machine always normalizes to exactly one of
    // the 3 mutually-exclusive layouts).

    func test_everyState_normalizesToExactlyOneVisualLayout() {
        for state in EdgePresentation.allCases {
            let layout = EdgeCollapseLayout.visualLayout(for: state)
            switch state {
            case .card, .expanding:
                XCTAssertEqual(layout, .card)
            case .tucked, .collapsing:
                XCTAssertEqual(layout, .tucked)
            case .floating:
                XCTAssertEqual(layout, .floating)
            }
        }
    }

    // MARK: - Hover region expands beyond the raw body/control union

    func test_hoverRegion_expandsUnion() {
        let frames = EdgeCollapseLayout.rects(for: EdgePresentation.floating, variant: .h, titleWidth: 40)
        let region = EdgeCollapseLayout.hoverRegion(for: EdgePresentation.floating, variant: .h, titleWidth: 40, expand: EdgeCollapseTokens.floatingHoverExitExpand)
        XCTAssertTrue(region.contains(frames.union))
        XCTAssertGreaterThan(region.width, frames.union.width)
    }
}
