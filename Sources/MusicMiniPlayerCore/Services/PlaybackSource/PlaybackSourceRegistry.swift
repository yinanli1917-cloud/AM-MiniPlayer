import Foundation

// =============================================================================
// [INPUT]: PlaybackSource protocol family
// [OUTPUT]: PlaybackSourceRegistry — holds registered sources + persists the
//           preferred one to UserDefaults
// [POS]: E1 first step. Not wired into the app launch path yet; type + tests
//        only. Defaults-key fallback mirrors PanelBackdropStyle.resolve —
//        unknown/absent value always falls back to .appleMusic so a future
//        wiring pass can never change the shipping default source by accident.
//        `PlaybackSourceID` is now a struct (see PlaybackSource.swift), so an
//        "unknown" id is no longer detectable by construction alone — the
//        fallback instead lives in `activeSourceID`: a preferred id with no
//        REGISTERED source behind it (e.g. persisted from a full-edition-only
//        id, then read back in the pure edition where that source was never
//        registered) resolves to Apple Music.
// =============================================================================

@MainActor
public final class PlaybackSourceRegistry: ObservableObject {

    public static let defaultsKey = "playbackSourceID"

    /// The id the user asked for (persisted). May name a source this process
    /// never registered — see `activeSourceID`.
    @Published public private(set) var preferredSourceID: PlaybackSourceID

    private var sources: [PlaybackSourceID: PlaybackSource] = [:]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferredSourceID = Self.resolve(from: defaults.string(forKey: Self.defaultsKey))
    }

    /// Absent defaults value falls back to Apple Music; a present value is
    /// trusted as-is (unknown-to-THIS-process ids are handled downstream by
    /// `activeSourceID`'s registered-source fallback, not here).
    public static func resolve(from raw: String?) -> PlaybackSourceID {
        guard let raw else { return .appleMusic }
        return PlaybackSourceID(rawValue: raw)
    }

    public func register(_ source: PlaybackSource) {
        sources[source.id] = source
    }

    /// The preferred source if it is actually registered; otherwise falls
    /// back to Apple Music. This is what callers should route through.
    public var activeSourceID: PlaybackSourceID {
        sources[preferredSourceID] != nil ? preferredSourceID : .appleMusic
    }

    public var activeSource: PlaybackSource? {
        sources[activeSourceID]
    }

    public func select(_ id: PlaybackSourceID) {
        preferredSourceID = id
        defaults.set(id.rawValue, forKey: Self.defaultsKey)
    }
}
