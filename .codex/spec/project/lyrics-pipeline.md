# Lyrics Pipeline

Durable rules for the lyrics fetch, selection, and verifier flow.

## Empty Result Taxonomy

Do not collapse all empty lyric outcomes into "no lyrics".

- `instrumental`: a provider explicitly says the track has no vocal lyric text. The app may display "Instrumental track"; do not cache it as real lyrics.
- `unavailable`: a provider catalog row matches the requested title/artist/duration, but the provider returns no lyric payload. The app should report lyrics unavailable, not no lyrics.
- `none`: no trusted source or catalog identity was resolved. Keep the state unresolved and do not cache it as no lyrics.

## Fallback Selection

- Trust synced lyrics first, but allow conservative static fallback from `lyrics.ovh`/Genius only after synced candidates are missing or rejected by timing/identity gates.
- Same-artist CJK duration escapes must require strong romanization/translation evidence; single ambiguous words such as `Hatsukoi` or `Deep` cannot globally bypass title identity.
- English-title to native-title fallbacks belong in the guarded source alias path, not in broad language detection, so short ambiguous English words do not break romanization lookups.

## Verifier Semantics

- Ad hoc and library runs may pass with `unresolved`, `unavailable`, or `instrumental` classification when no fixture explicitly expects lyrics.
- Fixtures with `shouldFindLyrics: true` must still fail if the pipeline cannot return trusted lyrics.
- Library summaries should report unresolved, unavailable, and instrumental counts separately.
