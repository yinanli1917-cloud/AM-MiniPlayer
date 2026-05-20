# Lyrics Pipeline

Durable rules for the lyrics fetch, selection, and verifier flow.

## Empty Result Taxonomy

Do not collapse all empty lyric outcomes into "no lyrics".

- `instrumental`: a provider explicitly says the track has no vocal lyric text. The app may display "Instrumental track"; do not cache it as real lyrics.
- `unavailable`: a provider catalog row matches the requested title/artist/duration, but the provider returns no lyric payload. The app should report lyrics unavailable, not no lyrics.
- `none`: no trusted source or catalog identity was resolved. Keep the state unresolved and do not cache it as no lyrics.

## Fallback Selection

- Trust synced lyrics first, but allow conservative static fallback from `lyrics.ovh`/Genius only after synced candidates are missing or rejected by timing/identity gates.
- Low-tier library/text fallbacks belong inside a strict foreground budget.
  If LRCLIB, LRCLIB-Search, Genius, or lyrics.ovh are slow, let
  authoritative background backfill finish and cache them instead of holding
  the visible track switch past the interaction budget.
- When a same-title provider row returns a compressed or wrong-version
  line-timed lyric (for example: first real lyric or catalog marker appears in
  the first few seconds, no word-level timing, and a large tail gap), reject it
  before broad exact-title/duration escapes. Probe sibling catalog rows and rank
  by parsed lyric quality, word-level timing, and timeline fit instead of only
  nearest metadata duration.
- Weak library fallbacks such as low-score LRCLIB/LRCLIB-Search must not end the
  source race while native-provider sibling rescue is still plausible.
- Long sparse songs can legitimately leave a large instrumental tail. Do not
  reject an exact title/duration synced hit only for tail gap when it has
  substantial lyric content and no catalog-credit marker.
- Same-artist CJK duration escapes must require strong romanization/translation evidence; single ambiguous words such as `Hatsukoi` or `Deep` cannot globally bypass title identity.
- English-title to native-title fallbacks belong in the guarded source alias path, not in broad language detection, so short ambiguous English words do not break romanization lookups.
- Romanized Japanese title evidence should be explicit and title-scoped. If a
  known romaji title maps to a native CJK title, treat that as title evidence
  so a closer-duration same-artist song cannot win only because its runtime is
  nearer.
- Provider search rows with multiple artists must preserve the full artist list for matching; alias evidence can belong to a non-first duet artist.
- Native-title alias tiers must not outrank explicit same-artist title evidence unless album evidence or sub-second catalog evidence is present. A short CJK title with a nearby duration is not enough to beat a direct title hit.
- English-title tracks must not use artist-only native-title aliases; require stronger title, album, or Apple catalog evidence to avoid same-English-name artist collisions.
- If an album hint is available, do not accept a loose artist-only native-title alias for an English title. Use album-scoped witness probes or direct title evidence so same-artist duration collisions cannot win.
- Album-scoped provider rows whose artist is a generic compilation bucket
  (`群星`, `Various Artists`, `VA`, soundtrack-style labels, etc.) must not
  satisfy normal artist evidence for a specific requested artist.
- A generic-compilation provider row may be recovered only through the explicit
  compilation-album fallback: exact title match, album-scoped catalog/native
  album match, duration delta under 1.5s, album-backed search provenance, and a
  synced lyric payload. This protects normal artist matching while preserving
  soundtrack/compilation albums where providers credit track rows to `群星`.
- iTunes catalog searches must stay song-scoped (`entity=song`) so storefront bridge lookups do not depend on broad `media=music` behavior, which can be throttled or rejected differently by region.

## Verifier Semantics

- Ad hoc and library runs may pass with `unresolved`, `unavailable`, or `instrumental` classification when no fixture explicitly expects lyrics.
- Fixtures with `shouldFindLyrics: true` must still fail if the pipeline cannot return trusted lyrics.
- Library summaries should report unresolved, unavailable, and instrumental counts separately.

## Lyrics Page UI

- When translation display is enabled, the lyrics page must reserve the
  translation row on first render for translatable lyrics. Source or system
  translations should populate existing space instead of pushing visible lines
  downward after the page transition.
- Lyrics page first-render culling must stay active until enough line heights
  are measured. Do not briefly render the full lyric payload during partial
  measurement; that path causes page-switch frame stalls on translated or
  syllable-synced tracks.
