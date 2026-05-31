# Liqoria Queue Reference Assessment

Checked on 2026-05-24. Refreshed on 2026-05-31.

## Why It Matters

Liqoria is useful as a competitive signal: a third-party Mac app publicly claims
Apple Music queue handling. It is not proof that a public, App Store-compliant
API exists for exact Music.app Up Next/history parity.

## Sources Checked

- User-provided reference URL:
  `https://www.liqoria.com/blog/liqoria-1.3-adds-animated-art-player-audio-quality-(dolby-atmos-lossless)-and-improve-apple-music-queue-copy-copy`
- Liqoria Apple Music page:
  https://www.liqoria.com/applemusic
- Liqoria changelog 1.2.0:
  https://www.liqoria.com/changelog/1.2.0
- Liqoria changelog:
  https://www.liqoria.com/changelog
- Liqoria home/FAQ:
  https://www.liqoria.com/
- Liqoria Reddit launch/update post:
  https://www.reddit.com/r/AppleMusic/comments/1tbabp2/i_made_player_for_mac_with_apple_music_queue/
- App Store web search for Liqoria:
  no `apps.apple.com` Liqoria listing found in the 2026-05-31 search result.
- AppAddict review:
  https://mb.appaddict.app/

## Findings

- Liqoria's own Apple Music page claims an "Apple Music Queue" feature and says
  the app can handle the user's Apple Music queue.
- Liqoria's 1.2.0 changelog says Apple Music queue support was added, including
  queue actions and search-to-queue behavior.
- Liqoria's 1.3.0 changelog separately says queue support exists in "Liqoria
  Player" and includes moving songs to play next, which reinforces that Liqoria
  may operate as its own player/queue surface rather than a pure Music.app
  assistant.
- Liqoria's home page describes the product as a full music app with independent
  actions and built-in search, not just a lightweight Music.app assistant.
- On 2026-05-31, Liqoria's home page still describes the app as a full music
  app that can perform actions independently, without relying on the original
  music app.
- On 2026-05-31, Liqoria's Apple Music page still says it can handle the Apple
  Music queue, and its changelog still separates Apple Music queue support from
  later Liqoria Player queue support.
- A current Reddit post by the Liqoria developer claims miniplayer queue control
  that can view, reorder, and manage Apple Music queue changes synced with the
  actual Apple Music app. In the same thread, the developer says an animated
  artwork technique uses Apple private frameworks. That statement is about
  artwork, not queue control, but it raises the compliance bar for treating
  Liqoria as App Store-safe precedent.
- The public purchase path is direct download / Lemon Squeezy. I did not find
  evidence that Liqoria is distributed through the Mac App Store, and the
  2026-05-31 App Store web search did not surface a Liqoria listing.
- A third-party AppAddict review says Liqoria uses private frameworks and is not
  on the App Store. Treat this as a report, not primary evidence, but it is
  consistent with the absence of Mac App Store distribution.

## Implication For nanoPod

Liqoria proves that a competitor is willing to claim Apple Music queue control.
It does not prove:

- the queue source is public;
- the queue source is exact across radio, playlists, albums, local files, and
  manual queue edits;
- the implementation is App Store-reviewable;
- the design fits nanoPod's assistant-only product boundary.

For this task, Liqoria should motivate testing, not lower the proof bar. nanoPod
still needs a recorded parity pass against Music.app's visible queue before any
queue source can be labeled exact.
