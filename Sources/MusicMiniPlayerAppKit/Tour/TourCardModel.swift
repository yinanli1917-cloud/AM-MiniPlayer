/**
 * [INPUT]: MusicMiniPlayerCore's TourStep/TourCardSide.
 * [OUTPUT]: Exports TourCardModel, TourBeatModel — the plain-data content a
 *           `TourCardView` renders (proposal §3.3/§9). No SwiftUI, no L10n
 *           call inside — `TourController` fills in the localized strings so
 *           this stays a dumb, comparable value type for state-change diffing.
 * [POS]: MusicMiniPlayerAppKit/Tour.
 */

import Foundation
import MusicMiniPlayerCore

struct TourBeatModel: Equatable, Identifiable {
    var id: Int
    var text: String
    var checked: Bool
    /// "这一步先不做" pressed: the unchecked dot turns dashed and dim (C.5.4).
    var skipped = false
    /// The user has done everything but this beat and can do it now (C.5.3).
    var pending = false
}

struct TourCardModel: Equatable {
    enum Kind: Equatable {
        case welcome
        case resume
        case connect
        case connectDenied
        case step(TourStep)
        case deferralNote
        case finale(deferred: Bool)
        case deferredTip
    }

    var kind: Kind
    var title: String
    var body: String
    var beats: [TourBeatModel] = []
    var confirm: String?
    var primaryTitle: String?
    var secondaryTitle: String?
    var footNote: String?
    var chip: String?
    var ringCompleted: Int
    var ringClosed: Bool = false
    var stepLabel: String = ""
    var showStop: Bool = true
    var showSkipStep: Bool = true
    var showFallbackButton: Bool = false
}
