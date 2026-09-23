> Snapshot for the cache-isolation change (NanoPodCacheLocation). Section 0's "concurrent WIP" is that change itself, taken mid-implementation.

# Real-cache inventory — every non-production path that can touch the founder's real caches

Scope: `~/Library/Application Support/nanoPod/{lyrics_cache.json, metadata_cache.json, translation_cache.json}`.
Worktree: `/Users/yinanli/Documents/MusicMiniPlayer/.claude/worktrees/stoic-jemison-872e9a`.
Snapshot time: **2026-09-22 21:48 PDT**. Read-only investigation; nothing in this worktree was modified to produce this report.

## 0. CRITICAL: the ground shifted mid-investigation — uncommitted WIP already fixes most of this

`git status --short` at snapshot time:

```
 M AGENTS.md
 M Sources/MusicMiniPlayerCore/Services/TranslationDiskCache.swift
 M Sources/MusicMiniPlayerCore/Utils/LyricsDiskCache.swift
 M Sources/MusicMiniPlayerCore/Utils/MetadataDiskCache.swift
 M build_app.sh
?? Sources/MusicMiniPlayerCore/Utils/NanoPodCacheLocation.swift
?? Tests/MusicMiniPlayerTests/NanoPodCacheLocationTests.swift
```

`stat -f %m` on `LyricsDiskCache.swift` / the new `NanoPodCacheLocation.swift` showed mtimes ~15–30s apart and both within the last few minutes of the snapshot — **someone (a concurrent session in this same worktree) is actively landing a fix for exactly this problem class right now.** It is **uncommitted**, not yet built into `nanoPod.app`, and could change again before this report is read.

What it does (`Sources/MusicMiniPlayerCore/Utils/NanoPodCacheLocation.swift`, new file):
- `NanoPodCacheLocation.scope(for:)` resolves one of `.override(path:)` (env `NANOPOD_CACHE_DIR`) > `.testRun` (any process where `NSClassFromString("XCTestCase") != nil` or the `XCTestConfigurationFilePath`/`XCTestSessionIdentifier` env vars are set) > `.production` (bundle id `com.yinanli.nanoPod` with no `NPCacheNamespace` Info.plist key) > `.isolated(namespace:)` (everything else — dev builds, spikes, LyricsVerifier without the production bundle id).
- `.testRun` maps to `<tmp>/nanoPod-xctest-<pid>/`; `.isolated` maps to `~/Library/Application Support/nanoPod-dev/<namespace>/`.
- All three caches' `defaultURL()` now call `NanoPodCacheLocation.versionedFileURL(baseName:, schemaVersion:)` instead of building `~/Library/Application Support/nanoPod/<name>.json` directly (confirmed by reading the current file contents: `Sources/MusicMiniPlayerCore/Utils/LyricsDiskCache.swift:219-221`, `Sources/MusicMiniPlayerCore/Utils/MetadataDiskCache.swift:217-219` (current line numbers, post-edit), `Sources/MusicMiniPlayerCore/Services/TranslationDiskCache.swift:100-102`).
- `build_app.sh:262-285` (current, post-edit) now stamps a `NPCacheNamespace` Info.plist key on any build made from a linked git worktree (this worktree included) unless `NANOPOD_SHARED_CACHE=1` is set — so even the production **app binary**, when built from this worktree, no longer writes the founder's real `~/Library/Application Support/nanoPod/`.
- A companion test file `Tests/MusicMiniPlayerTests/NanoPodCacheLocationTests.swift` (untracked, 288 lines) pins the scope-resolution table.
- The file's own doc comment says this fixes "a spike running lyrics schema 30 wiped the app's schema-31 cache" and "a non-production process using default construction reading/writing the founder's real caches" — i.e. this is the fix for the exact class of incidents documented in `LyricsBlankPageFuzzTests.swift:17-31` and `research/spikes/edge-collapse-spike/run.sh` (both cited below).

**Effect on everything below:** once this lands, `NSClassFromString("XCTestCase") != nil` means *every* `swift test` process — regardless of whether an individual test file swaps `lyricsDiskCache`/constructs a temp `MetadataResolver` — is automatically redirected to a per-PID temp directory. That would make essentially all of Section 1's "does this test swap the cache" analysis moot for `swift test` runs specifically. It does **not** cover:
- `LyricsVerifier` CLI invocations without `--network-only` (not an XCTest process, no production bundle id either, so it actually falls into `.isolated` now too — see Section 3, this also changes if the fix lands)
- the `edge-collapse-spike`'s `probe.sh` (launches the raw `.build` binary directly, not through `run.sh`'s `CFFIXED_USER_HOME`, and is not an XCTest process — but it now gets `.isolated` for free from the resolver as long as it isn't signed with the production bundle id, which it isn't: `com.nanopod.edgecollapsespike`)
- the real, production-signed `com.yinanli.nanoPod` app (still `.production`, unaffected — as intended)

Sections 1–5 below document the state of each path **as the code reads at snapshot time** (i.e. already reflecting the uncommitted fix, since I read the files live) plus the **pre-fix reasoning** each test file's own comments preserve (useful because this fix is uncommitted and could be reverted, and because it explains *why* each test does what it does). Where a finding would only have mattered pre-fix, it's marked "(superseded by §0 if the WIP lands/stays)".

---

## 1. Tests/ — per-class inventory

184 `.swift` files under `Tests/MusicMiniPlayerTests/`. Table covers every file this investigation found referencing a default-path cache, `LyricsFetcher`/`MetadataResolver`/`LyricsService`/`MusicController` singletons, or a literal cache path.

### 1a. Files that call a cache-touching method WITHOUT swapping the instance to a temp file

| File | Class | Cache(s) | R/W | Evidence |
|---|---|---|---|---|
| `LyricsFetcherApplyOnSelectTests.swift` | `LyricsFetcherApplyOnSelectTests` | lyrics_cache (via `LyricsFetcher.shared.lyricsDiskCache`, never swapped in this file) + metadata_cache (via `MetadataResolver.shared`, transitively) | R+W (network miss on a UUID-nonce title → negative/availability verdict candidate) | `Tests/MusicMiniPlayerTests/LyricsFetcherApplyOnSelectTests.swift:207-212` calls `LyricsFetcher.shared.fetchAllSources(title: nonceTitle, artist: "zzqx-nobody", duration: 200, translationEnabled: false)` — no `cachePolicy:` argument, so `LyricsCachePolicyContext.current == .normal` (default) and every source's disk get/set in `Sources/MusicMiniPlayerCore/Services/Lyrics/LyricsFetcher.swift:548-562` runs unbypassed. `grep -c "lyricsDiskCache = "` on this file returns 0. |
| `LyricsKindTests.swift` | `LyricsKindTests` | lyrics_cache + metadata_cache (transitively) | R+W, **env-gated** | `Tests/MusicMiniPlayerTests/LyricsKindTests.swift:185-193` (`testGammaSpeculative_ASCIItoCJK_under2500ms`, real titles "Plastic Love"/"Koibitotachi no Chiheisen"/"Try to Say") and `:208-212` (`testInvisible_byMeiEhara_returnsSynced`, real title "Invisible" by mei ehara) both call `fetcher.fetchAllSources(...)` on `LyricsFetcher.shared` with no cache swap and no `cachePolicy:`. Both are gated behind `guard ProcessInfo.processInfo.environment["NANOPOD_LIVE_TESTS"] == "1" else { throw XCTSkip(...) }` (lines 169, 202) — **inert unless `NANOPOD_LIVE_TESTS=1` is exported**, which `swift test`'s default invocation in CLAUDE.md's Build Commands does not set. |
| `LyricsServiceStateTests.swift` | (top-level test class in file, uses `LyricsService.shared`) | lyrics_cache + metadata_cache (transitively) | R+W | `Tests/MusicMiniPlayerTests/LyricsServiceStateTests.swift:349-361` (`testVisibleLyricsStayContentDuringSameSongMetadataRefresh`) calls `service.fetchLyrics(for: fixture.title, artist: fixture.artist, duration: fixture.duration + 2.0, album: fixture.album)` and `:378-390` (`testDifferentTrackFetchDropsStaleRowsBeforeSearching`) calls `service.fetchLyrics(for: "Different Debug Track", artist: "nanoPod Debug", duration: fixture.duration, album: fixture.album)`. Neither test, nor any `setUp`/`tearDown` in this file, swaps `LyricsFetcher.shared.lyricsDiskCache`, constructs a temp `LyricsService`, or uses `LyricsCachePolicyContext`/`.networkOnly()` — confirmed by `grep -n "lyricsDiskCache\|setUp\|tearDown\|networkOnly\|LyricsCachePolicyContext" LyricsServiceStateTests.swift` returning **zero matches**. This is the one file in the suite with no isolation mechanism of any kind around a real `fetchLyrics` call — **not gated by any env var**, so it runs on every plain `swift test`. Pre-§0-fix this is the most exposed test in the suite; post-fix it is caught by the blanket XCTest redirect. |

### 1b. Known-safe: correctly swap the disk cache to a temp file before any fetch, and the fetch is engineered to hit that temp cache (never falls through to `MetadataResolver.shared`/network)

| File | Mechanism | Evidence |
|---|---|---|
| `ImmediateDiskLyricsPreflightTests.swift` | swaps `LyricsFetcher.shared.lyricsDiskCache` in setUp/tearDown | `:26,30,34` |
| `LyricsBlankPageFuzzTests.swift` | swaps `lyricsDiskCache`; the 2 tests that deliberately construct a cache MISS additionally wrap the call in `LyricsCachePolicyContext.$current.withValue(.networkOnly())` (DEBUG-only production mechanism) | file header `:17-45` documents a **prior real incident** ("an earlier draft of this file was found to have written to the founder's real caches... a 3000-trial fuzzer run took 191s and left `lyrics_cache.json`/`metadata_cache.json` mtimes updated") that this file's current version fixes; swap at `:135,139`; `.networkOnly()` wraps at `:217,233` |
| `LyricsRepeatLoopStressTests.swift` | swaps `lyricsDiskCache` in setUp/tearDown (`:23,27,31`); every `service.fetchLyrics` call is preceded by `tempCache.set(...)` for that exact title, so the disk pre-flight hits the swapped cache and the request never falls through to `MetadataResolver`/network | `:96-118` |
| `LyricsTranslationToggleStressTests.swift` | per-test local swap + `defer` restore (`:152-158`); pre-seeds `temp.set(...)` before `fetchLyrics` | `:150-171` |
| `LyricsLateTranslationInsertTests.swift` | per-test local swap + `defer` restore (`:90-94,138`); pre-seeds `temp.set(...)` before `fetchLyrics` | `:100-106` |
| `LyricsInstrumentalMissStressTests.swift` | constructs a temp `LyricsDiskCache`, swaps in, calls only the synchronous `immediateSyncedDiskLyrics`/`shouldUseImmediateCachedAvailability` (pure lookup that returns nil on an availability row and stops — never triggers `fetchAllSources`) | `:140-178` |
| `LyricsCachePolicyTests.swift` | every cache instance constructed with a `temporaryURL(...)` file | `:5-8,52-53` |
| `MetadataDiskCacheTests.swift`, `MetadataDiskCacheTierTests.swift`, `MetadataNegativeEvidenceTests.swift`, `MetadataNegativeClearOnRefreshTests.swift`, `MetadataArtistOnlyTitleEvidenceTests.swift`, `MetadataEnglishTitleGateTests.swift`, `ResolverSingleFlightTests.swift` | every `MetadataDiskCache`/`MetadataResolver` constructed with an explicit temp `fileURL:` | e.g. `MetadataArtistOnlyTitleEvidenceTests.swift:26`, `ResolverSingleFlightTests.swift:204` |
| `TranslationDiskCacheTests.swift` | every `TranslationDiskCache` constructed with an explicit temp `url` | `:24,43,55,67,82` |
| `LyricsServiceTranslationSessionReuseTests.swift`, `LyricsServiceRealTranslationSessionReuseTests.swift` | swap `LyricsService.shared.translationDiskCache` to a temp file; tests only exercise the translation-session-reuse/executor logic and never call `fetchLyrics`/`fetchAllSources` (confirmed: no such call sites in either file) | swap at `:58` and `:54` respectively |
| `LyricsWordLevelPriorityTests.swift` | uses `service.debugSeedDisplayedLyricsForTesting(...)` / `service.debugApplyFetchedResultForTesting(...)` debug seams that set display state directly, bypassing disk cache entirely | `:219-251` |
| `DiagnosticsServiceTests.swift` | different subsystem (`DiagnosticsService`, not one of the 3 target caches) but same class of risk — fully isolated: `diagnosticsStorageRoot` is rooted at `FileManager.default.temporaryDirectory` and injected via `setStorageBaseDirectoryForTesting` | `:26-32` |
| `NanoPodCacheLocationTests.swift` (new, untracked) | tests the fix itself; uses `tempDir()` (`FileManager.default.temporaryDirectory`-rooted) and a synthetic `ProcessIdentity`, never touches a real path | `:19-23` |

### 1c. Reference `LyricsFetcher.shared`/`LyricsService.shared`/`MusicController.shared` but only call pure functions — no disk I/O at all

Confirmed by grepping each file for the cache-touching method names (`fetchAllSources`, `.fetchLyrics(`, `immediateSyncedDiskLyrics`, `immediateNativeExactDiskLyrics`, `MetadataResolver`, `.candidates(`, `lyricsDiskCache.`) and finding zero hits beyond comments:

- `LyricsSelectionTests.swift` (~90 call sites, all `selectBestCandidate`/`selectBestResult`/`isTitleMatch`/`buildCandidates`/`shouldUseImmediateCachedAvailability` (pure, see `LyricsFetcher.swift:3095-3108`) /`shouldPersistAvailabilityResult` (pure, `:3110-3121`), etc.)
- `LyricsSelectionMemoizationTests.swift` (comment at `:8` mentions `fetchAllSources` but no actual call site)
- `LyricsWordLevelPriorityTests.swift` (pure `LyricsFetcher.LyricsFetchResult` construction + `debugSeed.../debugApplyFetchedResultForTesting`)
- `JapaneseReadingTests.swift` (`fetcher.isTitleMatch` only, `:92`)
- `RadioDurationlessMatchingTests.swift`, `LyricsOriginalDeliverySLATests.swift` (config/deadline constants + pure matching functions)
- `NetworkOutcomeLedgerTests.swift` / nested `QQSearchEnvelopeDecodeTests` (pure envelope decoders + `NetworkOutcomeLedger`, `.shared` used only for `negativeVerdictQuorumMet` which reads `NetworkOutcomeLedger.current`, not disk)
- `RapidSwitchTests.swift` (`MusicController.shared.artworkCacheKey`/`artworkMetadataCacheKey`, pure key-derivation functions, `:195-217`; `MusicController.shared`'s `init()` starts ScriptingBridge/timer plumbing but no track-change notification fires in a headless XCTest process, so `lyricsService` (`MusicController.swift:261`, a lazy computed property returning `LyricsService.shared`) is never invoked in this file)

### 1d. Reads (not writes) the real file, by design, documented

`LyricsWholeLineFlashRealTimeTests.swift:65-89` — `loadCachedSong(hash:label:)` reads `~/Library/Application Support/nanoPod/lyrics_cache.json` directly via `NSString.expandingTildeInPath` + `Data(contentsOf:)`, **read-only**, with an `XCTSkip` fallback if the hash isn't found ("cache may have been pruned/rewritten since prep"). The file's own header (`:1-30`) documents this as intentional: the founder asked for specific real cached tracks (大橋純子's "水玉模様の傘" + 3 fastest-syllable entries) for a real-time (non-lockstep) repro harness. No write path exists in this file.

### 1e. DEBUG-only cache-policy bypass mechanism (used correctly where present)

`Sources/MusicMiniPlayerCore/Utils/LyricsDiskCache.swift:9-51` (`#if DEBUG` block) — `LyricsCachePolicyContext.$current.withValue(policy)` wraps a single call's dynamic extent (including *structured* child tasks it spawns — `async let`/`TaskGroup`; **not** `Task {}`/`Task.detached`, whose task-locals don't inherit, per `NetworkOutcomeLedgerTests.swift:202-209`'s `testDetachedTasksDoNotInheritBinding`). `.allowsReads`/`.allowsWrites` are both `mode == .normal`, so `.networkOnly` short-circuits `LyricsDiskCache.candidates`/`.set`/`.setAvailability` (`:236-241, 266-272, 288-294, 330-336`) and the parallel `MetadataDiskCache` overloads (`Sources/MusicMiniPlayerCore/Utils/MetadataDiskCache.swift:88-113` wrapper + `:233,255,...` effective-policy checks) before any disk touch. `MetadataResolver.swift` itself never references `LyricsCachePolicyContext` directly — it relies entirely on the task-local propagating in from whoever wrapped the call (confirmed by `grep -c "LyricsCachePolicyContext" MetadataResolver.swift` = 0), which is why the LyricsBlankPageFuzzTests.swift header (`:36-44`) is careful to say this only guarantees zero I/O for the wrapped call itself, not for any **unstructured** `Task {}` it spawns that outlives the wrap.

Only two call sites in the whole test suite use `.networkOnly()`: `LyricsBlankPageFuzzTests.swift:217,233`. `LyricsCachePolicyTests.swift` exercises the mechanism itself directly on isolated temp caches (not through a singleton).

---

## 2. research/spikes — every worktree + main checkout

```
find /Users/yinanli/Documents/MusicMiniPlayer -path '*/research/spikes/*/Package.swift' -not -path '*/.build/*'
```
returned exactly **one** result across every worktree and the main checkout:

`/Users/yinanli/Documents/MusicMiniPlayer/.claude/worktrees/compassionate-goldstine-0612ff/research/spikes/edge-collapse-spike/Package.swift`

| Question | Finding | Evidence |
|---|---|---|
| Depends on `MusicMiniPlayerCore`? | Yes | `Package.swift:9-19`: `dependencies: [.package(name: "MusicMiniPlayer", path: "../../..")]`, target depends on `.product(name: "MusicMiniPlayerCore", package: "MusicMiniPlayer")` |
| Uses shared services/caches? | Yes — `MusicController.shared` | `Sources/EdgeCollapseSpike/SpikeAppDelegate.swift:48`, `EdgeCollapseAppModel.swift:53,65,105`, `RootContentView.swift:37,217`. `MusicController.shared` per the task background can start `LyricsService`, which by default (pre-§0-fix) touches all 3 real cache files. |
| Does its run script isolate itself? | **Inconsistently.** `run.sh` (the documented/current entry point) does; `probe.sh` (a second, still-present entry point) does **not**. | `run.sh:38-47`: comment explicitly says *"Isolate from the real app's data: the spike links this worktree's MusicMiniPlayerCore, whose cache schemas can differ from the installed app, and the two would wipe each other's ~/Library/Application Support/nanoPod caches (**2026-09-22: lyrics_cache.json shrank 149 -> 24 entries**)."* — a **confirmed, dated real incident**, same day as this snapshot. Fix: `SPIKE_HOME="$DIR/.build/spike-home"` + `CFFIXED_USER_HOME="$SPIKE_HOME" nohup "$APP/..." &` (`run.sh:44-47`).<br>`probe.sh:29-34` launches the built release binary **directly**, no `CFFIXED_USER_HOME`, no bundle: `EDGECOLLAPSE_PROBE=1 "$BIN" > "$LOG" 2>&1 &`. This binary links the real `MusicMiniPlayerCore` and instantiates `MusicController.shared` the same as `run.sh`'s app, but with zero isolation — **any run of `probe.sh` is still exposed** to the same class of incident `run.sh` was patched for, unless the §0 `NanoPodCacheLocation` fix lands and covers it (it would, since the spike's bundle id `com.nanopod.edgecollapsespike` ≠ `com.yinanli.nanoPod`, so the resolver's `.isolated` branch applies — but `probe.sh` predates and doesn't know about that fix either way). |
| Test target | `Tests/EdgeCollapseSpikeTests/*.swift` (5 files) — none reference `MusicController`/`LyricsFetcher`/`MetadataResolver`/`LyricsService` (confirmed via grep, zero hits) | pure reducer/motion/hit-region unit tests, no risk |

---

## 3. LyricsVerifier CLI (`Sources/LyricsVerifier/`)

Entry point `main.swift:21-42` dispatches 4 subcommands, and **unconditionally** flushes the metadata cache on exit for every one of them:

```swift
// main.swift:39-42 (inside the top-level Task, after the switch)
MetadataResolver.shared.diskCache.flush()
exit(0)
```

| Subcommand | Cache mode default | Touches lyrics_cache | Touches metadata_cache | Evidence |
|---|---|---|---|---|
| `run` (predefined 82 cases) | `.normal` unless `--network-only`/`--cache-mode network-only` | R+W (by design — this is a regression cache, per CLAUDE.md: *"network; provider weather applies"*) | R+W | `main.swift:53-95` `runPredefined` → `parseCacheMode(args)` (`:478`) → `TestRunner.swift:63-74` `fetcher.fetchAllSources(..., cachePolicy: cachePolicy)` |
| `check <song> <artist> [dur]` | `.normal` unless flagged | R+W | R+W | `main.swift:229-279` `runAdHoc` |
| `library --recent N` | `.normal` unless flagged | R+W | R+W | `main.swift:307-334` `runLibrary` |
| `benchmark` (100-song global set) | `.normal` unless flagged | R+W | R+W | `main.swift:378-430` `runBenchmark` |
| any subcommand + `--network-only` | `.networkOnly` | bypassed (0 reads/writes) | bypassed (0 reads/writes) — see §1e mechanism | `main.swift:478` `if args.contains("--network-only") { return .networkOnly }`; wired through `TestRunner.swift:67,70,74,97` |
| `benchmark`'s `--no-local-translation` toggle | n/a | n/a | n/a — `checkLocalTranslation` (`BenchmarkValidator.swift:332-378`) uses a raw `TranslationSession(installedSource:target:)` directly, **never** touches `TranslationDiskCache`/`LyricsService` | confirmed via grep, zero `TranslationDiskCache`/`LyricsService` references in `Sources/LyricsVerifier/*.swift` |

**Confirmed by design, not a bug**: normal `run`/`check`/`library`/`benchmark` invocations read and write the real `lyrics_cache.json`/`metadata_cache.json` — this is the CLI's stated purpose (a regression/warm-cache tool against the founder's real library), matching CLAUDE.md's own description. `--network-only` is the only isolation flag and it is a `#if DEBUG`-only mechanism (`LyricsDiskCache.swift:9` `#if DEBUG` gate) — meaning **the compiled release `nanoPod.app` has no such flag or code path** (confirmed: `build_app.sh:193` calls `assert_binary_excludes_diagnostic_cache_mode` on the release binary).

`TranslationDiskCache`: never referenced anywhere in `Sources/LyricsVerifier/` — the CLI has no translation-cache exposure at all.

Note re §0: `LyricsVerifier` is not an XCTest process and doesn't carry `com.yinanli.nanoPod` as a bundle id, so once the uncommitted `NanoPodCacheLocation` fix is committed, the CLI's *default* (non-`--network-only`) runs would **also** stop touching the real founder cache (they'd fall into `.isolated`) — which would be a behavior change worth flagging to whoever is landing that fix, since CLAUDE.md documents `run`/`check`/`library`/`benchmark` as deliberately warming/reading the real regression cache.

---

## 4. Scripts and other executable targets

### 4a. `Package.swift` executable targets
Only 3: `MusicMiniPlayer`, `MusicMiniPlayerFull` (the two real app products — expected to use the real cache when installed/signed as `com.yinanli.nanoPod`; that's their entire purpose, out of scope as a "problem") and `LyricsVerifier` (§3). No other executable targets exist (`Package.swift:46-90`).

### 4b. `scripts/*.sh`, `scripts/*.py`, `build_app.sh`

All of the following reference `nanoPod`/`Application Support` because they **drive the real, installed app** (launch it, quit it, read its live diagnostics CSVs) as their explicit purpose — this is by design, not an accidental leak, and is out of scope for "should this be isolated":

| Script | What it touches | Evidence |
|---|---|---|
| `scripts/fix_menubar.py` | ControlCenter's `trackedApplications` plist (not one of the 3 caches) | `:30,45,79,81` |
| `scripts/analyze_winter_session.py` | reads `~/Library/Application Support/nanoPod/Diagnostics/Live/lyrics_line_motion_samples.csv` (Diagnostics, not one of the 3 caches) | `:25` |
| `scripts/soak_harness.py`, `scripts/perf_harness.py`, `scripts/lyrics_ux_benchmark.py`, `scripts/lyrics_visual_harness.py`, `scripts/e2e_smoke.py`/`.sh`, `scripts/luxb_dual_monitor.py`, `scripts/luxb_sequential_reference.py`, `scripts/lyrics_motion_evaluator.py` | launch/quit the real signed `nanoPod.app` (`pgrep -x nanoPod`, `osascript ... tell application "nanoPod"`, `defaults write com.yinanli.nanoPod`), read live `Diagnostics/` CSVs — none directly open `lyrics_cache.json`/`metadata_cache.json`/`translation_cache.json` | e.g. `perf_harness.py:87,93,119-122`, `lyrics_ux_benchmark.py:63,69,158,162-177` |
| `scripts/verify_playlist_move_reflects_upnext.sh` | only touches a scratch Music.app playlist named `nanoPod-move-test`, no cache files | `:23` |
| `build_app.sh` | see §0 — the uncommitted `NPCacheNamespace` stamping (`:262-285`) is the one relevant mechanism; also flushes/copies the built binary, no direct cache file I/O of its own | `:262-285` |

None of these scripts open `lyrics_cache.json`/`metadata_cache.json`/`translation_cache.json` directly by path — they act on the app process, which (pre-§0-fix) resolves those files through the default `defaultURL()` chain when its bundle id is `com.yinanli.nanoPod`. Since these scripts are meant to exercise the real production app, this is expected/by-design and is flagged only for completeness, not as a defect.

`scripts/assert_pure_edition.sh`: no cache/nanoPod references at all (confirmed via grep) — purely a binary-symbol check.

---

## 5. Other files under `~/Library/Application Support/nanoPod/` (out of scope, follow-up only)

Current directory listing (read-only `ls -l`, per task instructions):

```
ArtworkCache/                    (dir, 98 entries)
lyrics-backfill-census.jsonl     68,760 bytes
lyrics_cache.json                173,071 bytes   ← in scope (§1-§3)
metadata_cache.json               24,086 bytes   ← in scope (§1-§3)
playback-history.json             10,080 bytes
translation_cache.json            43,572 bytes   ← in scope (§1-§3)
updates/                         (dir)
```

All filenames are still the **unversioned** pre-fix names (`lyrics_cache.json`, not `lyrics_cache.v31.json`) — confirming the uncommitted §0 fix has not yet been built into the installed `nanoPod.app`; the real app on disk right now is still running the old `defaultURL()` logic.

Not analyzed further per task scope (§5 explicitly marked as out-of-scope follow-ups):
- `ArtworkCache/` — separate artwork disk cache, own single-flight/token-bucket system (see recent commits `7fc82b5`/`e714151`/`faaf1e2` in git log), not one of the 3 target caches.
- `playback-history.json` — separate subsystem.
- `lyrics-backfill-census.jsonl` — separate diagnostics log (`DiagnosticsService`, see §1b `DiagnosticsServiceTests.swift`).
- `updates/` — `UpdateService`/`UpdateApplier` staging directory, unrelated.

---

## Final count

| Category | Count |
|---|---|
| Test files scanned for cache-touching patterns | 184 (all of `Tests/MusicMiniPlayerTests/`) |
| Test classes/files that touch a real cache **unswapped, ungated** | **1** — `LyricsServiceStateTests.swift` (2 tests: `testVisibleLyricsStayContentDuringSameSongMetadataRefresh`, `testDifferentTrackFetchDropsStaleRowsBeforeSearching`) |
| Test classes/files that touch a real cache **unswapped, but env-gated (`NANOPOD_LIVE_TESTS=1`, off by default)** | **1** — `LyricsKindTests.swift` (2 tests) |
| Test classes/files that touch a real cache **unswapped, no env gate, deterministic UUID-nonce title** | **1** — `LyricsFetcherApplyOnSelectTests.swift` (1 test) |
| Test classes verified known-safe (temp-file swap, correctly engineered to never fall through) | **16** files (§1b) |
| Test classes verified pure-function-only (no cache I/O despite referencing `.shared`) | **8** files (§1c) |
| Test file that reads the real file read-only, by design, documented | **1** — `LyricsWholeLineFlashRealTimeTests.swift` |
| research/spikes packages found repo-wide | **1** — `edge-collapse-spike`; depends on `MusicMiniPlayerCore` and `MusicController.shared`; `run.sh` isolates via `CFFIXED_USER_HOME`, `probe.sh` does **not** |
| LyricsVerifier subcommands that R+W real caches by default | **4/4** (`run`, `check`, `library`, `benchmark`) — by design; `--network-only` (DEBUG-only) is the sole bypass |
| Scripts/executables with direct real-cache-file I/O (not via the app process) | **0** — all script/cache contact is indirect, through driving the real app process |
| **Uncommitted, in-flight fix found covering nearly all of the above for `swift test` runs** | `NanoPodCacheLocation.swift` (new) + edits to the 3 `defaultURL()`s + `build_app.sh` — **not yet committed** (git status `M`/`??`), being actively worked on in this same worktree during this investigation |
