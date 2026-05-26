# Lyrics Pipeline

Durable rules for the lyrics fetch, selection, and verifier flow.

## Empty Result Taxonomy

Do not collapse all empty lyric outcomes into "no lyrics".

- `instrumental`: a provider explicitly says the track has no vocal lyric text. The app may display "Instrumental track"; do not cache it as real lyrics.
- `unavailable`: a provider catalog row matches the requested title/artist/duration, but the provider returns no lyric payload. The app should report lyrics unavailable, not no lyrics.
- `none`: no trusted source or catalog identity was resolved. Keep the state unresolved and do not cache it as no lyrics.

## System Translation Fill

- Local ML translation is a supplemental lyrics feature, not a blocking fetch
  dependency. It must not show Apple's language selection or download UI during
  normal lyric rendering.
- Before mounting SwiftUI `.translationTask`, detect a stable source language
  from the current eligible lyric sample and preflight that explicit source /
  target pair with `LanguageAvailability`. Start the task only when the pair is
  already `installed`; treat `supported`, `unsupported`, or unidentified samples
  as a silent skip for that song/language until the user explicitly retries.
- Partial source translations should preserve provider translations and sample
  only the missing eligible visible lyric lines for the local fill.

## Fallback Selection

- Trust synced lyrics first, but allow conservative static fallback from `lyrics.ovh`/Genius only after synced candidates are missing or rejected by timing/identity gates.
- Low-tier library/text fallbacks belong inside a strict foreground budget.
  If LRCLIB, LRCLIB-Search, Genius, or lyrics.ovh are slow, let
  authoritative background backfill finish and cache them instead of holding
  the visible track switch past the interaction budget.
- Album hints should not automatically delay exact library fallbacks for
  ordinary English-title tracks. Preserve the native-provider holdback for
  romanized/non-English alias paths, but let likely-English visible titles race
  exact LRCLIB/LRCLIB-Search work immediately so correct foreground lyrics do
  not miss the latency budget.
- When a same-title provider row returns a compressed or wrong-version
  line-timed lyric (for example: first real lyric or catalog marker appears in
  the first few seconds, no word-level timing, and a large tail gap), reject it
  before broad exact-title/duration escapes. Probe sibling catalog rows and rank
  by parsed lyric quality, word-level timing, and timeline fit instead of only
  nearest metadata duration.
- Weak library fallbacks such as low-score LRCLIB/LRCLIB-Search must not end the
  source race while native-provider sibling rescue is still plausible.
- Exact LRCLIB/LRCLIB-Search synced hits may end the foreground race only when
  structured title identity, duration delta, score, and a lightweight timeline
  sanity check all pass. Do not run the full selector repeatedly inside the
  source-race hot path; it adds latency after the correct result has already
  landed.
- Long sparse songs can legitimately leave a large instrumental tail. Do not
  reject an exact title/duration synced hit only for tail gap when it has
  substantial lyric content and no catalog-credit marker.
- Long intros can legitimately push the first real vocal slightly past 90s.
  Keep the normal late-first-vocal rejection, but allow bounded exact-catalog
  synced hits when title/duration evidence is tight, lyric content is
  substantial, internal gaps are sane, tail gap is bounded, and there is no
  catalog-credit marker.
- Same-artist CJK duration escapes must require strong romanization/translation evidence; single ambiguous words such as `Hatsukoi` or `Deep` cannot globally bypass title identity.
- English-title to native-title fallbacks belong in the guarded source alias path, not in broad language detection, so short ambiguous English words do not break romanization lookups.
- English-title detection must include structural English evidence such as
  internal consonant clusters (`gentle`) so ordinary English unresolved tracks
  exit inside the foreground budget. Preserve the ambiguous single-word guard
  (`Escape`, `Deep`) so romanized/native alias lookups still work.
- Romanized Japanese title evidence should be explicit and title-scoped. If a
  known romaji title maps to a native CJK title, treat that as title evidence
  so a closer-duration same-artist song cannot win only because its runtime is
  nearer.
- Short kana native titles can be valid romanized Japanese aliases even when the
  ASCII input is one word. Accept that alias only when the kana title and ASCII
  title share the same Latin key and the native title is compact; do not let it
  become a broad artist-only duration escape.
- For non-English ASCII/romanized titles with a confirmed CJK artist alias, a
  foreground provider branch may fetch the exact native-artist catalog row
  directly when the provider title matches the ASCII title by the same
  romanization key and duration is tight. This is a latency optimization only:
  it must preserve the same title/duration/native-script gates as normal
  candidate selection and must not apply to ordinary English titles.
- Pinyin/native Chinese title evidence is also title-scoped. When an ASCII
  title and a CJK provider title normalize to the same Latin key, use that only
  as alias evidence and re-query with a confirmed CJK artist alias; do not
  directly accept the unrelated catalog row that exposed the alias.
- If the confirmed CJK artist alias is Traditional Chinese, probe the
  Traditional title variant before the Simplified variant. TW/HK catalogs often
  return lyrics only for the Traditional title even when another provider row
  exposed the Simplified alias.
- Provider search rows with multiple artists must preserve the full artist list for matching; alias evidence can belong to a non-first duet artist.
- Native-title alias tiers must not outrank explicit same-artist title evidence unless album evidence or sub-second catalog evidence is present. A short CJK title with a nearby duration is not enough to beat a direct title hit.
- When an album hint is present for a romanized Japanese title, alias+title or
  alias+album searches must not accept a different CJK title only because the
  artist and duration are close. Require native title evidence, an actual album
  match, or a tight artist-only probe so same-album covers cannot select a
  neighboring song.
- QQ title-only native matches for long romanized Japanese titles are not enough
  identity evidence by themselves. Require artist-scoped, album-scoped, or other
  corroborated source evidence; otherwise leave the result unresolved instead of
  showing a plausible same-artist wrong lyric payload.
- English-title tracks must not use artist-only native-title aliases; require stronger title, album, or Apple catalog evidence to avoid same-English-name artist collisions.
- If an album hint is available, do not accept a loose artist-only native-title alias for an English title. Use album-scoped witness probes or direct title evidence so same-artist duration collisions cannot win.
- If title+artist metadata is likely ordinary English and no resolved native
  artist alias exists, do not pay a late provider probe only to discover a CJK
  alias. That probe belongs to romanized/non-English alias paths or to cases
  where earlier metadata already exposed a native alias.
- English storefront title tracks whose title and album are the same normalized
  phrase may use a confirmed CJK artist alias plus an exact native
  title==album catalog row as a native-title bridge. The bridge must require a
  tight duration match, CJK artist match, no live/remix/backing markers, and
  must fetch the provider row directly instead of relying on loose artist-only
  selection.
- That album-title echo bridge must still respect the foreground interaction
  budget when every foreground source returns no usable candidate. Keep the
  guarded bridge/background authoritative lookup available, but cut off the
  empty foreground path before 3s so source-unavailable tracks do not feel
  stuck.
- Album-title echo native bridges must not be bypassed by an immediate
  library-native-title cache preflight. Cached native metadata is evidence for
  the bridge, but the foreground race still needs the album-echo native
  provider window so higher-quality NetEase syllable results can beat a faster
  same-lyric QQ row.
- LRCLIB catalog-native-title bridges for English storefront titles should be
  reserved for long/explicit localized-title evidence. Short generic English
  titles should keep the ordinary empty-result deadline; otherwise source-miss
  tracks spend the interaction budget on a native-title bridge that is unlikely
  to be valid.
- Decorated English titles with cached CJK metadata may use a guarded preflight
  before the full source race. If the cached artist is stale or non-Chinese,
  repair it through the confirmed CJK artist-alias path first, then query with
  the cached native title. This keeps collaboration-credit cache hits fast
  without trusting stale transliteration artists.
- Foreground lyrics resolution and app-side authoritative backfill are separate
  latency budgets. The foreground source race must stay bounded for the visible
  track switch, while authoritative rescue probes for English-title
  CJK/native-title cases must run as concurrent, cancellable probes instead of
  serially stacking album-title echo, album-scoped metadata, resolved metadata,
  native-alias witness, and secondary library retries. Accept the first trusted
  title/duration/persistent-identity result and cancel the remaining rescue
  work; do not hold visible UX for a slow miss.
- A foreground verifier pass under 3s is not proof that the app feels fast.
  App backfill can still create a 7-10s tail if rescue probes are serialized.
  Keep the accurate native-title probes, but parallelize and diagnose them
  rather than removing alias evidence or weakening selection thresholds.
- Exact synced foreground results may shorten the source race only when the
  selected candidate has exact title evidence, tight duration evidence, and
  passes normal result selection, and the visible metadata is not in a
  CJK/native/romanized-protected path. CJK titles, CJK artists/albums, and
  ASCII native-alias probes must still preserve the landing window for native
  provider evidence. This keeps English-title CJK tracks fast when a trusted
  library or provider result is already decisive without regressing native
  alias accuracy.
- When an album hint exists but direct album-catalog identity is unavailable,
  English-title/native-title alias selection may accept an unscoped provider
  alternate CJK title only with confirmed CJK artist identity, tight duration,
  alias-title search provenance, and conservative semantic title evidence.
  Generic English token overlap is not enough.
- Provider-ranked native-title rows may also prove a short ASCII storefront
  title when the provider itself returns a top-ranked CJK title with confirmed
  CJK artist evidence, tight duration, safe query provenance, and no competing
  same-artist title evidence. This is a generalized evidence rule for cases
  where `title+artist`, `title+album+artist`, or a top QQ `title only` row
  exposes the native title; it must not become a song whitelist or a broad
  artist-only escape.
- Search normalization and search evidence are different things. Strip noisy
  media/version descriptors for title identity, but preserve discriminating CJK
  work titles inside descriptors such as `(...电视剧《作品名》原声带版)` as a
  bounded search keyword. This lets provider search find soundtrack rows without
  making the descriptor part of title matching.
- Featured collaborators in the visible title are identity evidence. When an
  ASCII title contains `feat`/`ft`/`featuring`/`with`, build a collaboration
  search phrase from the primary title plus collaborator tokens, and pass the
  original title into candidate selection so that a same-title wrong artist does
  not beat a native-title row whose artist list contains the collaborator.
- A full provider `title+artist` query may bridge an ordinary English title to
  a provider alternate CJK catalog title only when the provider artist is the
  same non-compilation ASCII identity, the row is ranked at the top of the
  query, the duration differs by less than 0.35s, no direct same-artist title
  row exists, and the row is not live/remix/backing material. This is direct
  provider alias evidence, not a loose artist-only escape.
- Provider catalog exact-title foreground discovery is a generalized identity
  path, not a whitelist. It may run for any distinctive exact title with a
  specific requested artist, an album hint, tight duration/rank bounds, and a
  provider compilation/grouping artist; it must reject live/remix/backing rows
  and must not contain song, artist, or source-ID exceptions.
- Exact-title compilation discovery may include provider compilation-artist
  search hints such as `华语群星` / `群星` when the provider no longer ranks the
  guarded compilation row under the bare storefront title. The result still
  needs the same exact title, tight duration, CJK compilation album, and
  backing-track rejection gates before fetching lyrics.
- Same-artist provider discography rescue may run in the foreground for short
  ASCII titles only through general title-shape evidence, not a fixed title
  list. It still requires a specific ASCII artist, no album hint, a confirmed
  CJK provider artist alias, a CJK alternate catalog title by that same artist,
  tight duration evidence, a non-backing synced lyric payload, and normal
  selection scoring before it can win.
- If an English storefront album name has no direct provider album match but
  the provider has an exact-title, exact-duration row under a catalog
  compilation album, use it only as an orphan exact-title fallback when the
  provider artist is a compilation identity, the title is distinctive, and the
  duration/result-rank bounds are tight. Do not let generic compilation artists
  become normal specific-artist evidence.
- Natural English title/artist metadata must not let a high-scoring provider
  row with CJK-dominant lyric text beat a lower-scored synced English library
  row unless the provider result has native-alias evidence. Mark such provider
  rows as script-mismatch suspects and remove them from selection.
- Verified disk-cache hits may bypass network for romanized/native-alias
  tracks. CJK cached lyrics are allowed for pure-ASCII metadata only when the
  visible title is not likely English; ordinary English titles must still block
  immediate CJK cache reuse so stale wrong-script rows cannot reappear.
- Parser changes that affect persisted line text, metadata stripping, source
  translation alignment, or translation eligibility must bump the lyrics
  disk-cache schema. Old merged lines do not contain enough raw source context
  to be safely repaired on read.
- Provider catalog rows such as `专辑：...`, `Album: ...`, `Title: ...`, release
  date, label, or copyright fields can arrive as timed lyric rows. Strip these
  as metadata before source-translation merging so they do not render, shift
  lyric timing, or create partial-translation diagnostics.
- Timed provider credit rows with compact CJK labels such as `出品：...`,
  `发行：...`, `版权：...`, and traditional variants are metadata, not lyrics.
  Strip them using label semantics instead of fixed source IDs, so they cannot
  appear as the first rendered lyric or suppress a real first line.
- If several nearby-duration cache keys exist for the same metadata, read them
  as candidates and use the first result that passes current script/identity
  guards. A stale wrong-script cache row must not block a later verified
  correct cache row for the same track.
- Provider-confirmed terminal availability is reusable evidence. Cache
  instrumental rows with their kind and source identity; cache unavailable
  rows only with a short TTL so repeated visits do not re-run slow provider
  checks or refill fallback-churn diagnostics, while still allowing sources to
  recover later.
- Terminal `instrumental`/`unavailable` rows are authoritative only when their
  identity evidence is authoritative. If an album/catalog native rescue branch
  fired and the only terminal row is not album-matched, suppress that weak
  terminal result so it cannot block a correct synced fallback or turn an
  unresolved native-alias miss into a false no-lyrics state.
- A terminal availability cache row saved without album evidence must not
  short-circuit a later request that has an album hint. Re-check the
  album-scoped/native paths for that request; only album-matched terminal cache
  rows may bypass the foreground resolver when an album is known.
- Terminal availability rows must not be persisted under an album-scoped cache
  key unless the provider result itself matched that album. A title/duration
  terminal result without album evidence may be returned for the current
  no-lyrics state, but it must not become an album-authoritative cache entry.
- Album-scoped provider rows whose artist is a generic compilation bucket
  (`群星`, `Various Artists`, `VA`, soundtrack-style labels, etc.) must not
  satisfy normal artist evidence for a specific requested artist.
- A generic-compilation provider row may be recovered only through the explicit
  compilation-album fallback: distinctive exact title match, album-scoped
  catalog/native album evidence, duration delta under 1.5s, bounded result
  rank, album-backed search provenance, and a synced lyric payload. This
  protects normal artist matching while preserving soundtrack/compilation
  albums where providers credit track rows to `群星`.
- iTunes catalog searches must stay song-scoped (`entity=song`) so storefront bridge lookups do not depend on broad `media=music` behavior, which can be throttled or rejected differently by region.

## Verifier Semantics

- Ad hoc and library runs may pass with `unresolved`, `unavailable`, or `instrumental` classification when no fixture explicitly expects lyrics.
- Fixtures with `shouldFindLyrics: true` must still fail if the pipeline cannot return trusted lyrics.
- Library summaries should report unresolved, unavailable, and instrumental counts separately.
- The verifier must not launch authoritative backfill when the foreground pass
  already returned a trusted terminal classification (`instrumental` or
  `unavailable`). That wastes automation time and can make fixed terminal
  cases look slow even though the app foreground path is done.
- App-side authoritative backfill must be cancellable and generation-gated by
  current song ID. A slow miss from an old track must not apply `No Lyrics`,
  record unavailable diagnostics, or keep background provider work alive after
  the user has switched to a different song.

## Lyrics Page UI

- When translation display is enabled, the lyrics page must reserve the
  translation row on first render for translatable lyrics. Source or system
  translations should populate existing space instead of pushing visible lines
  downward after the page transition.
- Source translations may be sparse on repeated chorus lines. After metadata
  and vocable filtering, fill missing translations only when the same normalized
  lyric text has exactly one unambiguous source translation elsewhere in the
  same track.
- Standalone performer/speaker rows such as `Snoh Aalegra:`, `Choir:`, and
  `Choir/Snoh Aalegra:` are visible context markers, not translatable lyric
  content. Keep them displayable, but strip any source translation attached to
  those rows and exclude them from partial-translation coverage. Do the same
  for ad-lib/vocable rows such as `Ooh ooh`, `Yeah`, `Uh huh`, and sustained
  `Oh I` fragments so diagnostics do not treat non-lyric sounds as missing
  translations.
- Timed source-editor credits such as `edit <name>` are metadata, not visible
  lyrics. Strip them only when they appear in the opening or trailing metadata
  boundary of a lyric payload so a real mid-song lyric containing `edit` is not
  removed.
- Some provider translation tracks can be structurally delayed by one lyric row:
  the first original timestamp has an empty translation and every non-empty
  translation timestamp then matches the next original line. Correct this only
  when timestamp structure and repeated-lyric consistency both support the
  shift; otherwise keep timestamp matching to avoid moving a legitimately
  untranslated first line.
- Source translations may also be sparse for unique visible lines. Do not treat
  "some source translation exists" as "the whole song is translated"; when the
  target language is Chinese, preserve existing source translations and use
  system translation only to fill missing eligible lyric rows.
- Diagnostics must keep source-translation gaps actionable without letting
  fixed gaps stay stale. A partial source translation may create an incident at
  fetch time; when system translation fills the missing eligible rows for the
  same track, clear the matching `lyricsPartialTranslation` incident and record
  a fill event instead of leaving the monitor dirty.
- System translation gaps need the same lifecycle even when the selected lyrics
  source has no provider translation at all. If translation display is
  requested and the local translation preflight/task cannot fill eligible
  lines, record the reason and target language as diagnostics evidence; when
  the system translation later fills the rows, clear the incident and emit a
  `lyrics.translation.filledSystem` event. Use a concrete Chinese target such
  as `zh-Hans` for bare `zh`, and let the Translation session auto-detect the
  source language after the silent availability preflight.
- Lyrics page first-render culling must stay active until enough line heights
  are measured. Do not briefly render the full lyric payload during partial
  measurement; that path causes page-switch frame stalls on translated or
  syllable-synced tracks.
