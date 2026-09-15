/**
 * [INPUT]: MicroInteractionFeel.EdgeMorphMode, EdgeMorphHost pure helpers,
 *          EdgePresentation
 * [OUTPUT]: Unit tests for the C1 edgeMorph A/B channel
 * [POS]: research/c1-edge-morph-design-2026-09-12.md §9 commit 2 — pins the
 *        resolve-clamp contract and the pill/backdrop visibility tables.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class EdgeMorphFeelTests: XCTestCase {

    override func tearDown() {
        MicroInteractionFeel.reset()
        super.tearDown()
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Resolve clamp
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_resolve_absentValue_fallsBackToMorph() {
        XCTAssertEqual(MicroInteractionFeel.EdgeMorphMode.resolve(from: nil), .v0)
    }

    func test_resolve_unknownValue_fallsBackToMorph() {
        XCTAssertEqual(MicroInteractionFeel.EdgeMorphMode.resolve(from: "glassy"), .v0)
        XCTAssertEqual(MicroInteractionFeel.EdgeMorphMode.resolve(from: ""), .v0)
    }

    func test_resolve_knownValues_caseInsensitive() {
        XCTAssertEqual(MicroInteractionFeel.EdgeMorphMode.resolve(from: "v0"), .v0)
        XCTAssertEqual(MicroInteractionFeel.EdgeMorphMode.resolve(from: "V0"), .v0)
        XCTAssertEqual(MicroInteractionFeel.EdgeMorphMode.resolve(from: "morph"), .morph)
        XCTAssertEqual(MicroInteractionFeel.EdgeMorphMode.resolve(from: "MORPH"), .morph)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - apply/reset round trip
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_apply_setsDefaultsBackedValue_untilReset() {
        MicroInteractionFeel.testingEdgeMorph = nil
        _ = MicroInteractionFeel.apply(channel: "edgeMorph", value: "v0")
        XCTAssertEqual(
            MicroInteractionFeel.EdgeMorphMode.resolve(
                from: UserDefaults.standard.string(forKey: MicroInteractionFeel.edgeMorphDefaultsKey)
            ),
            .v0
        )

        MicroInteractionFeel.reset()
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.edgeMorphDefaultsKey))
    }

    func test_apply_unknownValue_clampsToV0InDefaults() {
        _ = MicroInteractionFeel.apply(channel: "edgemorph", value: "bogus")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: MicroInteractionFeel.edgeMorphDefaultsKey),
            MicroInteractionFeel.EdgeMorphMode.v0.rawValue
        )
        MicroInteractionFeel.reset()
    }

    func test_apply_reset_channel_clearsEdgeMorph() {
        _ = MicroInteractionFeel.apply(channel: "edgemorph", value: "v0")
        _ = MicroInteractionFeel.apply(channel: "reset", value: "reset")
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.edgeMorphDefaultsKey))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - showsPill / baseBackdropHidden tables
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private let allPresentations: [EdgePresentation] = [
        .card, .hidingToPill, .pill, .peeking, .restoringToCard
    ]

    func test_showsPill_v0_neverShows() {
        for presentation in allPresentations {
            XCTAssertFalse(
                EdgeMorphHost.showsPill(presentation: presentation, arm: .v0),
                "v0 must never show the pill for \(presentation)"
            )
        }
    }

    func test_showsPill_morph_showsForEveryNonCardState() {
        for presentation in allPresentations {
            let expected = presentation != .card
            XCTAssertEqual(
                EdgeMorphHost.showsPill(presentation: presentation, arm: .morph),
                expected,
                "morph mismatch for \(presentation)"
            )
        }
    }

    func test_baseBackdropHidden_mirrorsShowsPill() {
        for arm in MicroInteractionFeel.EdgeMorphMode.allCases {
            for presentation in allPresentations {
                XCTAssertEqual(
                    EdgeMorphHost.baseBackdropHidden(presentation: presentation, arm: arm),
                    EdgeMorphHost.showsPill(presentation: presentation, arm: arm),
                    "baseBackdropHidden must mirror showsPill for \(arm)/\(presentation)"
                )
            }
        }
    }
}
