//
//  LyricsSourceProfileTests.swift
//  Oracle-equality gate for the typed source registry (review proposal #4).
//
//  Every expected value below is the OLD hardcoded literal copied from the
//  pre-migration string ladders (LyricsScorer.sourceBonus switch,
//  LyricsResultSelection admission switch, LyricsFetcher source sets).
//  If a profile drifts from the legacy behavior, these tests fail.
//

import XCTest
@testable import MusicMiniPlayerCore

final class LyricsSourceProfileTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Raw strings (legacy spellings, byte-exact)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testRawValues_matchLegacySourceStrings() {
        XCTAssertEqual(LyricsSource.appleMusic.rawValue, "AppleMusic")
        XCTAssertEqual(LyricsSource.amll.rawValue, "AMLL")
        XCTAssertEqual(LyricsSource.netEase.rawValue, "NetEase")
        XCTAssertEqual(LyricsSource.qq.rawValue, "QQ")
        XCTAssertEqual(LyricsSource.lrclib.rawValue, "LRCLIB")
        XCTAssertEqual(LyricsSource.lrclibSearch.rawValue, "LRCLIB-Search")
        XCTAssertEqual(LyricsSource.genius.rawValue, "Genius")
        XCTAssertEqual(LyricsSource.lyricsOvh.rawValue, "lyrics.ovh")
        XCTAssertEqual(LyricsSource.allCases.count, 8)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Score bonus (old LyricsScorer.sourceBonus switch)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testBonus_equalsOldSourceBonusSwitch() {
        // Old switch: AppleMusic 12, AMLL 10, NetEase 8, QQ 6,
        //             LRCLIB 3, LRCLIB-Search 2, Genius 1, lyrics.ovh -2.
        let oldBonuses: [LyricsSource: Double] = [
            .appleMusic: 12,
            .amll: 10,
            .netEase: 8,
            .qq: 6,
            .lrclib: 3,
            .lrclibSearch: 2,
            .genius: 1,
            .lyricsOvh: -2,
        ]
        for source in LyricsSource.allCases {
            XCTAssertEqual(source.profile.bonus, oldBonuses[source],
                           "bonus drift for \(source.rawValue)")
            XCTAssertEqual(LyricsScorer.shared.sourceBonus(for: source), oldBonuses[source],
                           "scorer no longer reads the declared bonus for \(source.rawValue)")
        }
    }

    func testBoundaryMapping_unknownStringHasNoSilentDefault() {
        // The old switch returned a silent 0 for any unknown string. The
        // typed registry makes that unrepresentable: unknown strings fail
        // the one-shot boundary mapping (and CLAUDE.md's phantom "SimpMusic"
        // can never reach the scorer).
        XCTAssertNil(LyricsSource(rawValue: "SimpMusic"))
        XCTAssertNil(LyricsSource(rawValue: "netease"))   // case-sensitive on purpose
        XCTAssertNil(LyricsSource(rawValue: "QQ Music"))
        for source in LyricsSource.allCases {
            XCTAssertEqual(LyricsSource(rawValue: source.rawValue), source)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Synced admission ladder (old selectBestResult switch)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testSyncedAdmission_lrclibSearch_equalsOldLadder() {
        // Old: titleMatched && Δ<1.0 → score>=28; titleMatched && Δ<3.0 →
        //      score>=45; else score>=50.
        let admission = LyricsSource.lrclibSearch.profile.syncedAdmission
        XCTAssertEqual(admission.exactRungs, [
            LyricsSyncedAdmissionRung(maxDurationDiff: 1.0, minScore: 28, minLineCount: 0),
            LyricsSyncedAdmissionRung(maxDurationDiff: 3.0, minScore: 45, minLineCount: 0),
        ])
        XCTAssertEqual(admission.baseFloor, 50)
    }

    func testSyncedAdmission_lrclib_equalsOldLadder() {
        // Old: titleMatched && Δ<1.0 → score>=28; titleMatched && Δ<5.0 →
        //      score>=20 && lines>=10; else score>=45.
        let admission = LyricsSource.lrclib.profile.syncedAdmission
        XCTAssertEqual(admission.exactRungs, [
            LyricsSyncedAdmissionRung(maxDurationDiff: 1.0, minScore: 28, minLineCount: 0),
            LyricsSyncedAdmissionRung(maxDurationDiff: 5.0, minScore: 20, minLineCount: 10),
        ])
        XCTAssertEqual(admission.baseFloor, 45)
    }

    func testSyncedAdmission_defaultArmSources_equalOldLadder() {
        // Old `default:` arm for every other source:
        //      titleMatched && Δ<1.0 → score>=10; else score>=35.
        let defaultArmSources: [LyricsSource] = [.appleMusic, .amll, .netEase, .qq, .genius, .lyricsOvh]
        for source in defaultArmSources {
            let admission = source.profile.syncedAdmission
            XCTAssertEqual(admission.exactRungs, [
                LyricsSyncedAdmissionRung(maxDurationDiff: 1.0, minScore: 10, minLineCount: 0),
            ], "admission rung drift for \(source.rawValue)")
            XCTAssertEqual(admission.baseFloor, 35,
                           "admission base floor drift for \(source.rawValue)")
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Unsynced fallback floors (old selectUnsyncedFallback literals)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testUnsyncedFallbackRelaxation_equalsOldLiterals() {
        // Old: score >= 28 universally, OR
        //      (lyrics.ovh && score >= 24 && lines >= 16) OR (Genius && score >= 24).
        XCTAssertEqual(LyricsSource.lyricsOvh.profile.unsyncedFallbackRelaxation,
                       LyricsUnsyncedFallbackRelaxation(minScore: 24, minLineCount: 16))
        XCTAssertEqual(LyricsSource.genius.profile.unsyncedFallbackRelaxation,
                       LyricsUnsyncedFallbackRelaxation(minScore: 24, minLineCount: 0))
        for source in [LyricsSource.appleMusic, .amll, .netEase, .qq, .lrclib, .lrclibSearch] {
            XCTAssertNil(source.profile.unsyncedFallbackRelaxation,
                         "unexpected relaxed unsynced floor for \(source.rawValue)")
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Which checks fire (old string-set memberships)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testEarlyReturn_equalsOldEarlyReturnSourcesSet() {
        // Old: Set ["AppleMusic", "AMLL", "NetEase", "QQ"].
        let old: Set<LyricsSource> = [.appleMusic, .amll, .netEase, .qq]
        for source in LyricsSource.allCases {
            XCTAssertEqual(source.profile.canTriggerEarlyReturn, old.contains(source),
                           "early-return drift for \(source.rawValue)")
        }
    }

    func testIdentityWitness_equalsOldLyricIdentityValidationSourcesSet() {
        // Old: Set ["AMLL", "LRCLIB", "LRCLIB-Search", "lyrics.ovh", "Genius"].
        let old: Set<LyricsSource> = [.amll, .lrclib, .lrclibSearch, .lyricsOvh, .genius]
        for source in LyricsSource.allCases {
            XCTAssertEqual(source.profile.isLyricIdentityWitness, old.contains(source),
                           "identity-witness drift for \(source.rawValue)")
        }
    }

    func testRomanizedCJKCheck_lrclibPairOnly_neverAMLL() {
        // Old guards: `source == "LRCLIB" || source == "LRCLIB-Search"` in BOTH
        // detector copies. Adversarial-review correction: this trait is its own
        // boolean, NOT derived from the trust tier — AMLL is community-tier and
        // must NOT get the check.
        let old: Set<LyricsSource> = [.lrclib, .lrclibSearch]
        for source in LyricsSource.allCases {
            XCTAssertEqual(source.profile.appliesRomanizedCJKLyricsCheck, old.contains(source),
                           "romanized-check drift for \(source.rawValue)")
        }
        XCTAssertFalse(LyricsSource.amll.profile.appliesRomanizedCJKLyricsCheck,
                       "AMLL must never inherit the LRCLIB-only romanized check")
        XCTAssertEqual(LyricsSource.amll.profile.tier, .community)
    }

    func testHumanCurated_equalsOldIsPreferredHumanCuratedSource() {
        // Old: source == "NetEase" || "QQ" || "AppleMusic" || "AMLL".
        let old: Set<LyricsSource> = [.netEase, .qq, .appleMusic, .amll]
        for source in LyricsSource.allCases {
            XCTAssertEqual(source.profile.isPreferredHumanCurated, old.contains(source),
                           "human-curated drift for \(source.rawValue)")
        }
    }

    func testLibraryFallback_equalsOldIsLibraryFallbackSource() {
        // Old: source == "LRCLIB" || source == "LRCLIB-Search".
        let old: Set<LyricsSource> = [.lrclib, .lrclibSearch]
        for source in LyricsSource.allCases {
            XCTAssertEqual(source.profile.isLibraryFallback, old.contains(source),
                           "library-fallback drift for \(source.rawValue)")
        }
    }

    func testCJKNativeProvider_equalsOldNetEaseQQLiterals() {
        // Old: inline `["NetEase", "QQ"].contains(...)` literals (5 sites).
        let old: Set<LyricsSource> = [.netEase, .qq]
        for source in LyricsSource.allCases {
            XCTAssertEqual(source.profile.isCJKNativeProvider, old.contains(source),
                           "CJK-native-provider drift for \(source.rawValue)")
        }
    }

    func testSelfEvidentCatalogIdentity_equalsOldPersistentIdentityList() {
        // Old: source == "LRCLIB" || "LRCLIB-Search" || "AMLL" || "AppleMusic".
        let old: Set<LyricsSource> = [.lrclib, .lrclibSearch, .amll, .appleMusic]
        for source in LyricsSource.allCases {
            XCTAssertEqual(source.profile.hasSelfEvidentCatalogIdentity, old.contains(source),
                           "self-evident-identity drift for \(source.rawValue)")
        }
    }

    func testWideDurationUnavailableVerdict_equalsOldUnavailableIdentityList() {
        // Old (Δ<10s arm): source == "NetEase" || "QQ" || "LRCLIB".
        let old: Set<LyricsSource> = [.netEase, .qq, .lrclib]
        for source in LyricsSource.allCases {
            XCTAssertEqual(source.profile.trustsWideDurationUnavailableVerdict, old.contains(source),
                           "wide-unavailable drift for \(source.rawValue)")
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Mirror group (old mirroredLibrarySources sets, both copies)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testMirrorGroup_equalsOldMirroredLibrarySources() {
        XCTAssertEqual(LyricsSource.lrclib.profile.mirrorGroup, .lrclibLibrary)
        XCTAssertEqual(LyricsSource.lrclibSearch.profile.mirrorGroup, .lrclibLibrary)
        for source in [LyricsSource.appleMusic, .amll, .netEase, .qq, .genius, .lyricsOvh] {
            XCTAssertNil(source.profile.mirrorGroup,
                         "unexpected mirror group for \(source.rawValue)")
        }
    }

    func testIndependentWitnesses_matchOldAreIndependentLyricSources() {
        // Old: same source → false; both in {LRCLIB, LRCLIB-Search} → false;
        //      everything else → true.
        for source in LyricsSource.allCases {
            XCTAssertFalse(LyricsSource.areIndependentWitnesses(source, source))
        }
        XCTAssertFalse(LyricsSource.areIndependentWitnesses(.lrclib, .lrclibSearch))
        XCTAssertFalse(LyricsSource.areIndependentWitnesses(.lrclibSearch, .lrclib))
        XCTAssertTrue(LyricsSource.areIndependentWitnesses(.lrclib, .netEase))
        XCTAssertTrue(LyricsSource.areIndependentWitnesses(.netEase, .qq))
        XCTAssertTrue(LyricsSource.areIndependentWitnesses(.genius, .lyricsOvh))
        XCTAssertTrue(LyricsSource.areIndependentWitnesses(.amll, .appleMusic))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - QQ candidate guard binding + log fidelity
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testCandidateSearchLogTag_preservesQQMusicLabel() {
        // The old guard sniffed "qq" inside the log label "QQMusic". The label
        // is preserved for log continuity, while the guard binds to `.qq`.
        XCTAssertEqual(LyricsSource.qq.candidateSearchLogTag, "QQMusic")
        for source in LyricsSource.allCases where source != .qq {
            XCTAssertEqual(source.candidateSearchLogTag, source.rawValue)
        }
    }

    func testLogInterpolation_isByteIdenticalToStringEra() {
        // `\(source)` must print the legacy string; array dumps must keep the
        // String-style quotes so existing log greps survive the migration.
        XCTAssertEqual("\(LyricsSource.netEase)", "NetEase")
        XCTAssertEqual("\(LyricsSource.lyricsOvh)", "lyrics.ovh")
        XCTAssertEqual("\([LyricsSource.netEase, .qq])", #"["NetEase", "QQ"]"#)
        XCTAssertEqual([LyricsSource.qq, .amll, .netEase].sorted(),
                       [.amll, .netEase, .qq])  // lexical rawValue order
    }
}
