import Foundation

// =============================================================================
// [INPUT]: PlaybackSource protocol family
// [OUTPUT]: PlaybackSourceRegistry — holds registered sources + persists the
//           active one to UserDefaults
// [POS]: E1 first step. Not wired into the app launch path yet; type + tests
//        only. Defaults-key fallback mirrors PanelBackdropStyle.resolve —
//        unknown/absent value always falls back to .appleMusic so a future
//        wiring pass can never change the shipping default source by accident.
// =============================================================================

@MainActor
public final class PlaybackSourceRegistry: ObservableObject {

    public static let defaultsKey = "playbackSourceID"

    @Published public private(set) var activeSourceID: PlaybackSourceID

    private var sources: [PlaybackSourceID: PlaybackSource] = [:]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.activeSourceID = Self.resolve(from: defaults.string(forKey: Self.defaultsKey))
    }

    /// Absent or unknown values fall back to Apple Music.
    public static func resolve(from raw: String?) -> PlaybackSourceID {
        guard let raw else { return .appleMusic }
        return PlaybackSourceID(rawValue: raw) ?? .appleMusic
    }

    public func register(_ source: PlaybackSource) {
        sources[source.id] = source
    }

    public var activeSource: PlaybackSource? {
        sources[activeSourceID]
    }

    public func select(_ id: PlaybackSourceID) {
        activeSourceID = id
        defaults.set(id.rawValue, forKey: Self.defaultsKey)
    }
}
