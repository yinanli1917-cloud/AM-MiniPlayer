/**
 * [INPUT]: Foundation only (pure decision logic -- no LyricsService, no
 *          SwiftUI). Takes the same two values LyricsView.swift already
 *          computes at the top of its `.onChange(of: lyricsService.lyrics)`
 *          handler (`newLyrics.count` and
 *          `LyricsService.isTranslationOnlyWriteback(...)`).
 * [OUTPUT]: Exports LyricsTranslationSessionTrigger.shouldScheduleConfigUpdate.
 * [POS]: UI -- called verbatim from LyricsView's `.onChange(of:
 *        lyricsService.lyrics)` handler to decide whether a NEW arrival of
 *        real lyric content should (re-)schedule a translation
 *        session-config resolution attempt
 *        (LyricsView.scheduleTranslationSessionConfigUpdate ->
 *        LyricsService.silentSystemTranslationConfiguration()).
 *
 * 2026-09-23 root-cause fix (founder repro: "Roses"/"Ocean Side"/"Ring
 * Around the Rosie" -- /tmp/nanopod_debug.log shows
 * "tier3Reason=no session (source not resolved yet)" for a song's ENTIRE
 * playback, never re-emitted, with ZERO intervening page switches or
 * language/showTranslation toggles).
 *
 * Before this fix, LyricsView only called
 * `scheduleTranslationSessionConfigUpdate` from FOUR events: the page
 * becoming `.lyrics`, the view's initial `onAppear`, `translationLanguage`
 * changing, and `showTranslation` toggling to true. A plain track change
 * (`onChange(of: musicController.currentTrackTitle)`) and the eventual
 * arrival of that new track's lyrics (`onChange(of: lyricsService.lyrics)`)
 * did NOT re-trigger it. `LyricsService.fetchLyrics` resets
 * `resolvedSongTranslationSourceLanguage` to nil for every genuinely new
 * song (see that file's "A new song's source language must be resolved
 * fresh" comment) -- so once a listener stays on the lyrics page and lets
 * tracks advance normally (the founder's actual listening pattern, proven
 * by the log: 冬至 -> Roses -> Ocean Side -> Ring Around the Rosie with no
 * PageSwitch log lines in between), NOTHING ever asks
 * `silentSystemTranslationConfiguration()` to run again for the new song.
 * The source stays permanently unresolved, and every split piece of every
 * later song falls through `LyricPieceTranslation`'s tier 3 forever.
 *
 * The fix wires a FIFTH trigger: real new lyric content arriving (this is
 * exactly the event a track change eventually produces, whether the lyrics
 * source answers the CURRENT song or a new one) re-schedules the same
 * config-update attempt. A translation-only writeback (system translation
 * text landing on already-displayed lines) must NOT re-trigger this -- the
 * source was necessarily already resolved to produce that translation in
 * the first place, and re-running the whole resolution dance on every
 * translation writeback would be wasted async work with no observable
 * effect (see `LyricsService.isTranslationOnlyWriteback`).
 */

import Foundation

public enum LyricsTranslationSessionTrigger {
    /// Whether a change to `lyricsService.lyrics` should (re-)schedule a
    /// translation session-config resolution attempt
    /// (`LyricsView.scheduleTranslationSessionConfigUpdate`). True exactly
    /// when the change delivers real new line content (a fresh fetch
    /// result, not merely translation text landing on existing lines).
    public static func shouldScheduleConfigUpdate(
        newLineCount: Int,
        isTranslationOnlyWriteback: Bool
    ) -> Bool {
        newLineCount > 0 && !isTranslationOnlyWriteback
    }
}
