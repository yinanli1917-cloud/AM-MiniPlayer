import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// C1 贴边形变（research/c1-edge-morph-design-2026-09-12.md §8/§9 commit 1）:
// 穷举 (EdgePresentation × SnapEvent) 全部组合，钉死合法转移 + 非法组合保持
// current 不变。镜像 NativeLyricsMaskExhaustiveHandoffTests 的穷举风格。
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class EdgePresentationReducerTests: XCTestCase {

    private static let allStates: [EdgePresentation] = [
        .card, .hidingToPill, .pill, .peeking, .restoringToCard
    ]
    private static let allEvents: [SnapEvent] = [
        .hideRequested, .restoreRequested, .peekEntered, .peekExited, .settled
    ]

    /// 合法转移表，见 EdgePresentation.swift 头部注释的完整表格。
    private static let legalTransitions: [EdgePresentation: [SnapEvent: EdgePresentation]] = [
        .card: [.hideRequested: .hidingToPill],
        .hidingToPill: [.restoreRequested: .restoringToCard, .settled: .pill],
        .pill: [.restoreRequested: .restoringToCard, .peekEntered: .peeking],
        .peeking: [.restoreRequested: .restoringToCard, .peekExited: .pill],
        .restoringToCard: [.hideRequested: .hidingToPill, .settled: .card],
    ]

    func test_exhaustive_transitionTable() {
        for state in Self.allStates {
            for event in Self.allEvents {
                let expected = Self.legalTransitions[state]?[event] ?? state
                let actual = EdgePresentationReducer.reduce(current: state, event: event)
                XCTAssertEqual(
                    actual, expected,
                    "reduce(\(state), \(event)) expected \(expected), got \(actual)"
                )
            }
        }
    }

    func test_illegalCombos_returnCurrentUnchanged() {
        // 一些明确不该转移的组合，逐一命名以防表格本身写错。
        XCTAssertEqual(EdgePresentationReducer.reduce(current: .card, event: .restoreRequested), .card)
        XCTAssertEqual(EdgePresentationReducer.reduce(current: .card, event: .peekEntered), .card)
        XCTAssertEqual(EdgePresentationReducer.reduce(current: .card, event: .peekExited), .card)
        XCTAssertEqual(EdgePresentationReducer.reduce(current: .card, event: .settled), .card)
        XCTAssertEqual(EdgePresentationReducer.reduce(current: .pill, event: .hideRequested), .pill)
        XCTAssertEqual(EdgePresentationReducer.reduce(current: .pill, event: .settled), .pill)
        XCTAssertEqual(EdgePresentationReducer.reduce(current: .peeking, event: .peekEntered), .peeking)
        XCTAssertEqual(EdgePresentationReducer.reduce(current: .peeking, event: .hideRequested), .peeking)
        XCTAssertEqual(EdgePresentationReducer.reduce(current: .hidingToPill, event: .peekEntered), .hidingToPill)
        XCTAssertEqual(EdgePresentationReducer.reduce(current: .restoringToCard, event: .peekExited), .restoringToCard)
    }

    func test_interruption_hideRequestedDuringRestore() {
        // 设计文档 §1 表格：restore 途中反悔重新贴边，几何动画允许被打断重定向。
        XCTAssertEqual(
            EdgePresentationReducer.reduce(current: .restoringToCard, event: .hideRequested),
            .hidingToPill
        )
    }

    @MainActor
    func test_model_appliesReducerAndPublishes() {
        let model = EdgePresentationModel()
        XCTAssertEqual(model.presentation, .card)

        model.apply(.hideRequested)
        XCTAssertEqual(model.presentation, .hidingToPill)

        model.apply(.settled)
        XCTAssertEqual(model.presentation, .pill)

        model.apply(.peekEntered)
        XCTAssertEqual(model.presentation, .peeking)

        model.apply(.restoreRequested)
        XCTAssertEqual(model.presentation, .restoringToCard)

        model.apply(.settled)
        XCTAssertEqual(model.presentation, .card)
    }
}
