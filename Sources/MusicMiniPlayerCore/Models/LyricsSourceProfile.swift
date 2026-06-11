/**
 * [INPUT]: 无外部依赖
 * [OUTPUT]: LyricsSource (typed provider identity) + LyricsSourceProfile (declared per-provider rules)
 * [POS]: Models 模块的歌词源注册表 — 编译器强制每个新源声明完整 trait profile
 */

import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - LyricsSource (typed registry of the 8 providers)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The 8 lyric providers, typed. Raw values are the exact legacy source
/// strings, so disk-cache rows, verifier JSON, and log greps keep working
/// unchanged across the typed migration.
///
/// Adding a source is a compiler-checked act: the `profile` switch below is
/// exhaustive, so a new case cannot ship without declaring every trait.
/// Strings only exist at data boundaries (disk cache rows, verifier JSON);
/// map them once via `LyricsSource(rawValue:)` and handle `nil` explicitly —
/// there is no silent default profile.
public enum LyricsSource: String, CaseIterable, Codable, Hashable, Sendable {
    case appleMusic = "AppleMusic"
    case amll = "AMLL"
    case netEase = "NetEase"
    case qq = "QQ"
    case lrclib = "LRCLIB"
    case lrclibSearch = "LRCLIB-Search"
    case genius = "Genius"
    case lyricsOvh = "lyrics.ovh"
}

extension LyricsSource: CustomStringConvertible, CustomDebugStringConvertible {
    /// `\(source)` interpolates as the legacy string — log lines stay byte-identical.
    public var description: String { rawValue }
    /// Arrays render elements via `debugDescription`; quote like String did so
    /// `\(results.map(\.source))` still prints `["NetEase", "QQ"]`.
    public var debugDescription: String { rawValue.debugDescription }
}

extension LyricsSource: Comparable {
    /// Lexical raw-value order — `sorted()` output matches the String era.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension LyricsSource {
    /// Log tag used by the NetEase/QQ candidate-search template. QQ has always
    /// logged as "QQMusic" there (and only there); preserved verbatim so
    /// session-log greps survive the migration. The old code *sniffed* the
    /// substring "qq" in this label to arm the QQ-only candidate guard — that
    /// guard now binds to `== .qq` directly and can never detach on a rename.
    public var candidateSearchLogTag: String {
        self == .qq ? "QQMusic" : rawValue
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Trait Profile
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Trust classification. Documentation-grade metadata: every behavioral rule
/// below is its OWN declared trait, never derived from the tier. (Deriving
/// risk checks from the tier is exactly how AMLL — community tier — would
/// wrongly inherit the LRCLIB-only romanized-lyrics rejection.)
public enum LyricsSourceTier: Sendable, Equatable {
    /// First-party catalog of the player itself (AppleMusic TTML).
    case official
    /// Commercial CN catalogs with editorial lyrics + translations (NetEase, QQ).
    case curated
    /// Community-maintained lyric database (AMLL-TTML-DB).
    case community
    /// Open lyric libraries with exact/fuzzy lookup (LRCLIB, LRCLIB-Search).
    case library
    /// Plain-text scrape fallbacks without timing (Genius, lyrics.ovh).
    case textScrape
}

/// Sources sharing a mirror group read the same underlying database and can
/// never serve as independent witnesses for each other.
public enum LyricsSourceMirrorGroup: Sendable, Equatable {
    /// LRCLIB `/get` and `/search` are two doors into one library.
    case lrclibLibrary
}

/// One rung of the synced-admission ladder: applies when the result has
/// direct title evidence AND a catalog duration delta below `maxDurationDiff`.
/// Rungs are tried in declaration order; the first match decides.
public struct LyricsSyncedAdmissionRung: Sendable, Equatable {
    public let maxDurationDiff: Double
    public let minScore: Double
    public let minLineCount: Int

    public init(maxDurationDiff: Double, minScore: Double, minLineCount: Int = 0) {
        self.maxDurationDiff = maxDurationDiff
        self.minScore = minScore
        self.minLineCount = minLineCount
    }
}

/// Score floors a synced result must clear in `selectBestResult` (after the
/// word-level-sync and independent-agreement admissions, which are universal).
public struct LyricsSyncedAdmission: Sendable, Equatable {
    /// Exact-evidence rungs (title matched + tight duration), tried in order.
    public let exactRungs: [LyricsSyncedAdmissionRung]
    /// Unconditional floor when no rung matches.
    public let baseFloor: Double

    public init(exactRungs: [LyricsSyncedAdmissionRung], baseFloor: Double) {
        self.exactRungs = exactRungs
        self.baseFloor = baseFloor
    }
}

/// Relaxed floor for the conservative unsynced fallback (the universal floor
/// is score >= 28; a relaxation admits lower scores under extra conditions).
public struct LyricsUnsyncedFallbackRelaxation: Sendable, Equatable {
    public let minScore: Double
    public let minLineCount: Int

    public init(minScore: Double, minLineCount: Int = 0) {
        self.minScore = minScore
        self.minLineCount = minLineCount
    }
}

/// Declared rules for one provider. Every field used to be a free-form string
/// comparison scattered across the pipeline; call sites now read the declared
/// trait, and the exhaustive `profile` switch forces new sources to choose.
public struct LyricsSourceProfile: Sendable {
    /// Trust classification (documentation — no call site branches on it).
    public let tier: LyricsSourceTier
    /// Score bonus added by `LyricsScorer.calculateScore` (was the `sourceBonus` switch).
    public let bonus: Double
    /// May cut the GAMMA race short on a high-score hit (was `earlyReturnSources`).
    public let canTriggerEarlyReturn: Bool
    /// Preferred over library fallbacks within 12 points (was `isPreferredHumanCuratedSource`).
    public let isPreferredHumanCurated: Bool
    /// CJK native provider: line-timed results are held back during the
    /// native-provider race and need an identity witness under an album hint
    /// (was the inline `["NetEase", "QQ"]` literals).
    public let isCJKNativeProvider: Bool
    /// Library fallback pair gating fast-exit / weak-result protections
    /// (was `isLibraryFallbackSource` / `isLibraryFallbackSourceName`).
    public let isLibraryFallback: Bool
    /// Counts as an identity witness for cross-source lyric validation
    /// (was `lyricIdentityValidationSources`).
    public let isLyricIdentityWitness: Bool
    /// Risk check: reject CJK-song lyrics that are romanized transliteration.
    /// OWN boolean by design — NOT derived from `tier`. Only the LRCLIB pair
    /// gets it; AMLL is community-tier and must NOT get it.
    public let appliesRomanizedCJKLyricsCheck: Bool
    /// Mirror group for independent-witness accounting (nil = independent).
    public let mirrorGroup: LyricsSourceMirrorGroup?
    /// Identity is self-evident from the source's own exact lookup, so results
    /// persist/return without album/title+duration evidence
    /// (was the `selectedHasPersistentIdentity` source list).
    public let hasSelfEvidentCatalogIdentity: Bool
    /// An `unavailable` verdict is trusted up to a 10s duration delta
    /// (was the `selectedHasUnavailableIdentity` source list).
    public let trustsWideDurationUnavailableVerdict: Bool
    /// Synced-admission ladder for `selectBestResult`.
    public let syncedAdmission: LyricsSyncedAdmission
    /// Optional relaxed floor in the conservative unsynced fallback.
    public let unsyncedFallbackRelaxation: LyricsUnsyncedFallbackRelaxation?

    public init(
        tier: LyricsSourceTier,
        bonus: Double,
        canTriggerEarlyReturn: Bool,
        isPreferredHumanCurated: Bool,
        isCJKNativeProvider: Bool,
        isLibraryFallback: Bool,
        isLyricIdentityWitness: Bool,
        appliesRomanizedCJKLyricsCheck: Bool,
        mirrorGroup: LyricsSourceMirrorGroup?,
        hasSelfEvidentCatalogIdentity: Bool,
        trustsWideDurationUnavailableVerdict: Bool,
        syncedAdmission: LyricsSyncedAdmission,
        unsyncedFallbackRelaxation: LyricsUnsyncedFallbackRelaxation?
    ) {
        self.tier = tier
        self.bonus = bonus
        self.canTriggerEarlyReturn = canTriggerEarlyReturn
        self.isPreferredHumanCurated = isPreferredHumanCurated
        self.isCJKNativeProvider = isCJKNativeProvider
        self.isLibraryFallback = isLibraryFallback
        self.isLyricIdentityWitness = isLyricIdentityWitness
        self.appliesRomanizedCJKLyricsCheck = appliesRomanizedCJKLyricsCheck
        self.mirrorGroup = mirrorGroup
        self.hasSelfEvidentCatalogIdentity = hasSelfEvidentCatalogIdentity
        self.trustsWideDurationUnavailableVerdict = trustsWideDurationUnavailableVerdict
        self.syncedAdmission = syncedAdmission
        self.unsyncedFallbackRelaxation = unsyncedFallbackRelaxation
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Declared Profiles (oracle values mirror the legacy hardcoded ladders)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

extension LyricsSource {
    /// Synced-admission ladder shared by every source that had no dedicated
    /// branch in the legacy `switch $0.source` (the old `default:` arm).
    private static let defaultSyncedAdmission = LyricsSyncedAdmission(
        exactRungs: [.init(maxDurationDiff: 1.0, minScore: 10)],
        baseFloor: 35
    )

    /// The declared rule set for this provider. Exhaustive on purpose:
    /// a new case will not compile until it declares a full profile here.
    public var profile: LyricsSourceProfile {
        switch self {
        case .appleMusic:
            return LyricsSourceProfile(
                tier: .official,
                bonus: 12,
                canTriggerEarlyReturn: true,
                isPreferredHumanCurated: true,
                isCJKNativeProvider: false,
                isLibraryFallback: false,
                isLyricIdentityWitness: false,
                appliesRomanizedCJKLyricsCheck: false,
                mirrorGroup: nil,
                hasSelfEvidentCatalogIdentity: true,
                trustsWideDurationUnavailableVerdict: false,
                syncedAdmission: Self.defaultSyncedAdmission,
                unsyncedFallbackRelaxation: nil
            )
        case .amll:
            return LyricsSourceProfile(
                tier: .community,
                bonus: 10,
                canTriggerEarlyReturn: true,
                isPreferredHumanCurated: true,
                isCJKNativeProvider: false,
                isLibraryFallback: false,
                isLyricIdentityWitness: true,
                // Community tier, but the romanized-lyrics rejection is NOT
                // applied here — the check is declared per-profile precisely
                // so AMLL never inherits it from a tier rule.
                appliesRomanizedCJKLyricsCheck: false,
                mirrorGroup: nil,
                hasSelfEvidentCatalogIdentity: true,
                trustsWideDurationUnavailableVerdict: false,
                syncedAdmission: Self.defaultSyncedAdmission,
                unsyncedFallbackRelaxation: nil
            )
        case .netEase:
            return LyricsSourceProfile(
                tier: .curated,
                bonus: 8,
                canTriggerEarlyReturn: true,
                isPreferredHumanCurated: true,
                isCJKNativeProvider: true,
                isLibraryFallback: false,
                isLyricIdentityWitness: false,
                appliesRomanizedCJKLyricsCheck: false,
                mirrorGroup: nil,
                hasSelfEvidentCatalogIdentity: false,
                trustsWideDurationUnavailableVerdict: true,
                syncedAdmission: Self.defaultSyncedAdmission,
                unsyncedFallbackRelaxation: nil
            )
        case .qq:
            return LyricsSourceProfile(
                tier: .curated,
                bonus: 6,
                canTriggerEarlyReturn: true,
                isPreferredHumanCurated: true,
                isCJKNativeProvider: true,
                isLibraryFallback: false,
                isLyricIdentityWitness: false,
                appliesRomanizedCJKLyricsCheck: false,
                mirrorGroup: nil,
                hasSelfEvidentCatalogIdentity: false,
                trustsWideDurationUnavailableVerdict: true,
                syncedAdmission: Self.defaultSyncedAdmission,
                unsyncedFallbackRelaxation: nil
            )
        case .lrclib:
            return LyricsSourceProfile(
                tier: .library,
                bonus: 3,
                canTriggerEarlyReturn: false,
                isPreferredHumanCurated: false,
                isCJKNativeProvider: false,
                isLibraryFallback: true,
                isLyricIdentityWitness: true,
                appliesRomanizedCJKLyricsCheck: true,
                mirrorGroup: .lrclibLibrary,
                hasSelfEvidentCatalogIdentity: true,
                trustsWideDurationUnavailableVerdict: true,
                syncedAdmission: LyricsSyncedAdmission(
                    exactRungs: [
                        .init(maxDurationDiff: 1.0, minScore: 28),
                        .init(maxDurationDiff: 5.0, minScore: 20, minLineCount: 10),
                    ],
                    baseFloor: 45
                ),
                unsyncedFallbackRelaxation: nil
            )
        case .lrclibSearch:
            return LyricsSourceProfile(
                tier: .library,
                bonus: 2,
                canTriggerEarlyReturn: false,
                isPreferredHumanCurated: false,
                isCJKNativeProvider: false,
                isLibraryFallback: true,
                isLyricIdentityWitness: true,
                appliesRomanizedCJKLyricsCheck: true,
                mirrorGroup: .lrclibLibrary,
                hasSelfEvidentCatalogIdentity: true,
                trustsWideDurationUnavailableVerdict: false,
                syncedAdmission: LyricsSyncedAdmission(
                    exactRungs: [
                        .init(maxDurationDiff: 1.0, minScore: 28),
                        .init(maxDurationDiff: 3.0, minScore: 45),
                    ],
                    baseFloor: 50
                ),
                unsyncedFallbackRelaxation: nil
            )
        case .genius:
            return LyricsSourceProfile(
                tier: .textScrape,
                bonus: 1,
                canTriggerEarlyReturn: false,
                isPreferredHumanCurated: false,
                isCJKNativeProvider: false,
                isLibraryFallback: false,
                isLyricIdentityWitness: true,
                appliesRomanizedCJKLyricsCheck: false,
                mirrorGroup: nil,
                hasSelfEvidentCatalogIdentity: false,
                trustsWideDurationUnavailableVerdict: false,
                syncedAdmission: Self.defaultSyncedAdmission,
                unsyncedFallbackRelaxation: .init(minScore: 24)
            )
        case .lyricsOvh:
            return LyricsSourceProfile(
                tier: .textScrape,
                bonus: -2,
                canTriggerEarlyReturn: false,
                isPreferredHumanCurated: false,
                isCJKNativeProvider: false,
                isLibraryFallback: false,
                isLyricIdentityWitness: true,
                appliesRomanizedCJKLyricsCheck: false,
                mirrorGroup: nil,
                hasSelfEvidentCatalogIdentity: false,
                trustsWideDurationUnavailableVerdict: false,
                syncedAdmission: Self.defaultSyncedAdmission,
                unsyncedFallbackRelaxation: .init(minScore: 24, minLineCount: 16)
            )
        }
    }

    /// True when two sources can corroborate each other's lyric identity.
    /// Mirrors of the same library are never independent.
    public static func areIndependentWitnesses(_ lhs: LyricsSource, _ rhs: LyricsSource) -> Bool {
        guard lhs != rhs else { return false }
        if let lhsGroup = lhs.profile.mirrorGroup,
           let rhsGroup = rhs.profile.mirrorGroup,
           lhsGroup == rhsGroup {
            return false
        }
        return true
    }
}
