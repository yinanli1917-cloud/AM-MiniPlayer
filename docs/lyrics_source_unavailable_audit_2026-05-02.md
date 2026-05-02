# Lyrics Source-Unavailable Audit, 2026-05-02

Purpose: preserve evidence for recent-library tracks where the correct product result is **no synced lyrics**. These are not whitelisted lyric substitutions. They are regression fixtures that prevent static-only text from being displayed as if it were synchronized.

Audit command shape:

```text
LyricsVerifier check "<title>" "<artist>" <duration>
LRCLIB /api/get + /api/search
lyrics.ovh /v1/<artist>/<title>
Genius /api/search/song
```

## Findings

| Track | Foreground verifier | LRCLIB | lyrics.ovh | Genius | Product expectation |
| --- | --- | --- | --- | --- | --- |
| Love Is Free - Brenton Wood | no source, 2745ms | `/get` 404; `/search` 3 rows, 0 synced | 404 | no hits | no synced lyrics |
| Fresh Trip - CinCin Lee | no source, 2780ms | `/get` 404; `/search` 0 rows | 404 | no hits | no synced lyrics |
| Oceanside Café - CinCin Lee | no source, 2695ms | `/get` 404; `/search` 0 rows | 404 | no hits | no synced lyrics |
| Tangerine Bossa - Don Tung | no source, 2700ms | `/get` 404; `/search` 0 rows | 404 | no hits | no synced lyrics |
| 圓滑 - Ellen & The Ripples Band | no source, 2516ms | `/get` 404; `/search` 0 rows | 404 | no hits | no synced lyrics |
| Gentle Wave - Jiro Inagaki and His Soul Media | no source, 2763ms | `/get` 404; `/search` 3 rows, 0 synced | 404 | no hits | no synced lyrics |
| Invisible - mei ehara | no source, 2818ms | `/get` 404; `/search` 0 rows | 404 | no hits | no synced lyrics |
| Lisbon Antigua - Nelson Riddle | no source, 2797ms | `/get` 404; `/search` 20 rows, 0 synced | 404 | static-only hits | no synced lyrics |
| With You - Tennyson | no source, 2785ms | `/get` 404; `/search` 4 rows, 0 synced | 404 | static-only hits | no synced lyrics |

## Regression Coverage

These tracks are covered by `docs/lyrics_test_cases.json` as `X10` through `X18` with `shouldFindLyrics: false`. If a provider later adds correct synced lyrics for any of them, the fixture should be re-audited and changed from no-synced coverage to a positive synced fixture with first-line identity proof.
