# Music Queue Parity Setup Blocker

created_utc: 20260531T104026Z
context_attempted: user-playlist-playback
playlist_attempted: New Playlist 1
playlist_track_count: 4
manual_outcome: setup-blocked

## Attempt

The current local Music.app state was stopped with no readable current track.
To create a real active playback context for the required user-playlist parity
row, I attempted to play the existing user playlist `New Playlist 1`.

The playlist contents were:

```text
1 | In My Dreams | LAKEY INSPIRED | In My Dreams | 9D68BA9926C85E88
2 | Happiness Is Now | Jazzinuf | Dazzle | D9FAF594CF26E792
3 | sometimes | Jazzinuf | Dazzle | 7AACC7A34CF3FB31
4 | Nujabes Tribute 2 | Nicholas Cheung | Nujabes Tribute Covers | 1C8DFFC79D26DC16
```

I first tried the public AppleScript path while Music.app volume was muted:

```text
tell application "Music"
    set sound volume to 0
    play track 1 of playlist "New Playlist 1"
end tell
```

Music.app remained stopped and AppleScript still could not read a current track
or current playlist:

```text
player_state=stopped
sound_volume=0
current_track.error=Can't make name of «class pTrk» of application "Music" into type Unicode text.
current_playlist.error=Music got an error: Can't get current playlist.
```

I then opened the playlist in Music.app and used the visible row play button.
Music.app showed this alert:

```text
This computer is not authorised. You must authorise this computer before you
can use Apple Music or iTunes Match on this computer.
```

After dismissing the alert, Music.app remained stopped. I restored Music.app
volume to its original value:

```text
player_state=stopped
sound_volume=100
```

## Interpretation

This is an environment setup blocker for collecting active user-playlist
parity evidence on this Mac. It is not evidence that the user-playlist context
is `unavailable` through public APIs.

Do not add this attempt to `SUMMARY.md` as an `exact` or `unavailable` matrix
row. Once this Mac is authorized for Apple Music/iTunes Match, rerun the
existing matrix flow against an active user playlist:

```bash
bash .codex/workspace/run_music_queue_parity_matrix.sh \
  --run-current \
  --context user-playlist-playback \
  --probe-fixed-indexing
```

Then complete visible notes and validate the matrix before using the result as
implementation evidence.
