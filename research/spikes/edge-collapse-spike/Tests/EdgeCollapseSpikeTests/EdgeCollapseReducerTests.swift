import XCTest
@testable import EdgeCollapseSpike

/// (a) reducer table exhaustive, unknown-event no-op — design §2, top-level
/// task instruction #10(a).
final class EdgeCollapseReducerTests: XCTestCase {

    private let allEvents: [EdgeCollapseEvent] = [
        .collapseRequested(.right),
        .collapseRequested(.left),
        .hoverEntered,
        .hoverExited,
        .expandRequested,
        .settled,
    ]

    /// Exhaustive: every (state, event) pair returns a value without
    /// crashing/trapping — the switch in EdgeCollapseReducer has no `default:`
    /// so this alone proves the compiler enforced 5×5 coverage for the 5
    /// canonical events (collapseRequested's edge payload doesn't change the
    /// case matched).
    func test_exhaustive_everyStateEventPairProducesAState() {
        for state in EdgePresentation.allCases {
            for event in allEvents {
                _ = EdgeCollapseReducer.reduce(state: state, event: event)
            }
        }
    }

    // MARK: - Defined transitions (design §2/§4)

    func test_card_collapseRequested_goesToCollapsing() {
        XCTAssertEqual(EdgeCollapseReducer.reduce(state: .card, event: .collapseRequested(.right)), .collapsing)
    }

    func test_collapsing_settled_goesToTucked() {
        XCTAssertEqual(EdgeCollapseReducer.reduce(state: .collapsing, event: .settled), .tucked)
    }

    func test_tucked_hoverEntered_goesToFloating() {
        XCTAssertEqual(EdgeCollapseReducer.reduce(state: .tucked, event: .hoverEntered), .floating)
    }

    func test_tucked_expandRequested_goesToExpanding() {
        // §4 table, tucked × click = "浮出并展开" — one hop straight to expanding.
        XCTAssertEqual(EdgeCollapseReducer.reduce(state: .tucked, event: .expandRequested), .expanding)
    }

    func test_floating_hoverExited_goesToTucked() {
        XCTAssertEqual(EdgeCollapseReducer.reduce(state: .floating, event: .hoverExited), .tucked)
    }

    func test_floating_expandRequested_goesToExpanding() {
        XCTAssertEqual(EdgeCollapseReducer.reduce(state: .floating, event: .expandRequested), .expanding)
    }

    func test_expanding_settled_goesToCard() {
        XCTAssertEqual(EdgeCollapseReducer.reduce(state: .expanding, event: .settled), .card)
    }

    // MARK: - Undefined transitions are no-ops (the "unknown event" contract)

    func test_card_undefinedEvents_areNoOps() {
        for event: EdgeCollapseEvent in [.hoverEntered, .hoverExited, .expandRequested, .settled] {
            XCTAssertEqual(EdgeCollapseReducer.reduce(state: .card, event: event), .card, "\(event) must no-op on .card")
        }
    }

    func test_collapsing_cannotBeInterruptedMidGesture() {
        for event: EdgeCollapseEvent in [.collapseRequested(.right), .hoverEntered, .hoverExited, .expandRequested] {
            XCTAssertEqual(EdgeCollapseReducer.reduce(state: .collapsing, event: event), .collapsing, "\(event) must no-op on .collapsing")
        }
    }

    func test_tucked_undefinedEvents_areNoOps() {
        for event: EdgeCollapseEvent in [.collapseRequested(.right), .hoverExited, .settled] {
            XCTAssertEqual(EdgeCollapseReducer.reduce(state: .tucked, event: event), .tucked, "\(event) must no-op on .tucked")
        }
    }

    func test_floating_undefinedEvents_areNoOps() {
        for event: EdgeCollapseEvent in [.collapseRequested(.right), .hoverEntered, .settled] {
            XCTAssertEqual(EdgeCollapseReducer.reduce(state: .floating, event: event), .floating, "\(event) must no-op on .floating")
        }
    }

    func test_expanding_cannotBeInterruptedMidGesture() {
        for event: EdgeCollapseEvent in [.collapseRequested(.right), .hoverEntered, .hoverExited, .expandRequested] {
            XCTAssertEqual(EdgeCollapseReducer.reduce(state: .expanding, event: event), .expanding, "\(event) must no-op on .expanding")
        }
    }

    // MARK: - Full loop sanity

    func test_fullLoop_cardToTuckedToFloatingToCard() {
        var state = EdgePresentation.card
        state = EdgeCollapseReducer.reduce(state: state, event: .collapseRequested(.right))
        XCTAssertEqual(state, .collapsing)
        state = EdgeCollapseReducer.reduce(state: state, event: .settled)
        XCTAssertEqual(state, .tucked)
        state = EdgeCollapseReducer.reduce(state: state, event: .hoverEntered)
        XCTAssertEqual(state, .floating)
        state = EdgeCollapseReducer.reduce(state: state, event: .expandRequested)
        XCTAssertEqual(state, .expanding)
        state = EdgeCollapseReducer.reduce(state: state, event: .settled)
        XCTAssertEqual(state, .card)
    }
}
