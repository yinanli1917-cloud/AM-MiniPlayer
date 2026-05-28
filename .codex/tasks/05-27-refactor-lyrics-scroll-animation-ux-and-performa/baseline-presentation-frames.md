# Presentation frame baseline (pre-rebuild reference)

Captured against `origin/main` behavior before `feat/lyrics-scroll-rebuild` integration.

## Metrics

| Metric | Source | Notes |
|--------|--------|-------|
| `lyrics.presentationFrame.delta.ms` | `recordLyricsPresentationFrame` | Display link during wave only (new stack) |
| `frame.delta.ms` | `recordFrameTick` | Playback timer (~10 Hz), not scroll |
| Line motion CSV | `recordLyricsLineMotionSamples` | 0.25s sampling; boundary windows 0.85s |

## Harness

```bash
swift test --filter LyricsScrollEngineTests
swift test --filter LyricWaveTiming
./build_app.sh
```

## Targets (full rebuild)

- Presentation stalls during wave ≤ legacy perceived smoothness
- No SwiftUI body driver at 60 Hz for row offsets
- CPU 16s lyrics harness: not worse than baseline; goal per `lyrics-renderer-performance.md` (~27% avg)
