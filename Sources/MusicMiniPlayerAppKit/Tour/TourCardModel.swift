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
        case finale
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
    /// The stop button's label when it is not the tour's own "Stop here" (the translation tip's way out).
    var stopTitle: String?
    var showSkipStep: Bool = true
    var showFallbackButton: Bool = false
}

/// Everything about a model that changes how tall the card is. A beat turning solid, the ring growing, the step
/// number changing or a beat going pending change none of it, so the card is NOT re-measured (a measure builds a
/// whole hosting view and lays it out: ~35 ms in a debug build, right on the frame the check lands).
struct TourCardLayoutKey: Equatable {
    var kind: TourCardModel.Kind
    var title: String
    var body: String
    var beatTexts: [String]
    var confirm: String?
    var primaryTitle: String?
    var secondaryTitle: String?
    var footNote: String?
    var chip: String?
    var showStop: Bool
    var stopTitle: String?
    var showSkipStep: Bool
    var showFallbackButton: Bool
}

extension TourCardModel {
    var layoutKey: TourCardLayoutKey {
        TourCardLayoutKey(kind: kind, title: title, body: body, beatTexts: beats.map(\.text), confirm: confirm,
                          primaryTitle: primaryTitle, secondaryTitle: secondaryTitle, footNote: footNote, chip: chip,
                          showStop: showStop, stopTitle: stopTitle, showSkipStep: showSkipStep, showFallbackButton: showFallbackButton)
    }
}
