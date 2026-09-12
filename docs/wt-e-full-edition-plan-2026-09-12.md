# WT-E E3 方案：完整版 SystemNowPlayingSource（2026-09-12，待主会话审）

依据：创始人 09-12 定稿——纯净版上 App Store；完整版为 GitHub 开源版，豁免「不用私有 API」与沙盒约束，按构建 target 隔离，纯净版 target 不含任何私有 API 代码。事实基础见 research/third-party-player-survey-2026-09.md 第 9 节与 scratchpad part9（adapter 字段、命令、集成形态）。本文只是方案，未写码。

## 1. 结论先行

| 问题 | 方案 | 一句话理由 |
|---|---|---|
| target 切分 | SwiftPM 结构切分：新库 target `NanoPodFullEdition`，两个可执行产品 `MusicMiniPlayer`（纯净）与 `MusicMiniPlayerFull`（完整），app 源码下沉为库 `MusicMiniPlayerAppKit` 共用 | 纯净产品的依赖图里根本没有那个 target，链接不到，比编译条件强 |
| adapter 引入 | vendored 上游发布产物（`mediaremote-adapter.pl` + `MediaRemoteAdapter.framework` + `MediaRemoteAdapterTestClient`），钉版本 v0.7.7 记 SHA256，作为 `NanoPodFullEdition` 的资源 | 私有符号只存在于 vendored 二进制里，我们自己的源码零 MediaRemote 符号；ejbills 的 SwiftPM fork 是 branch 追踪、把 ObjC 源码编进我们包图，反而弄脏纯净证明 |
| 自检失败退化 | 启动跑 `test`（5s 超时）；非 0 → 源标 `.unavailable`，路由回落 Apple Music，设置页一行状态，30s→60s→5min 退避重试 + 唤醒重试 | 上游 README 就是这么建议的（test 失败回退 AppleScript） |
| 纯净版证明 | 三道门：① 包图断言（`swift package dump-package` 检查 `MusicMiniPlayer` 依赖不含 FullEdition）② 纯净 release 二进制 `strings`/`nm` 断言无 `MediaRemote` / `mediaremote-adapter` / `MRMediaRemote` / `SystemNowPlayingSource`③ 纯净 .app 内无 `MediaRemoteAdapter.framework` / `.pl` | 复用 build_app.sh 已有的 `assert_binary_excludes_diagnostic_cache_mode` 模式 |

## 2. target 切分细节

```
Sources/
├── MusicMiniPlayerCore/        （不变；PlaybackSource 协议在这）
├── MusicMiniPlayerAppKit/      （原 Sources/MusicMiniPlayerApp 的 .swift 整体 git mv 过来，变库；入口改成 public func nanoPodMain(extraSources: [PlaybackSource])）
├── MusicMiniPlayerApp/         （只剩 main.swift 一行调用 nanoPodMain(extraSources: []) + Info.plist/entitlements）
├── MusicMiniPlayerFullApp/     （main.swift：nanoPodMain(extraSources: [SystemNowPlayingSource()])；同一份 Info.plist 经 sectcreate）
└── NanoPodFullEdition/         （SystemNowPlayingSource + AdapterProcessRunner + StreamPayloadParser；Vendor/ 下三件 adapter 产物 + LICENSE-BSD-3 + VERSION）
```

- `PlaybackSourceID` 从 enum 改为 `struct PlaybackSourceID: RawRepresentable, Hashable, Codable`，Core 只定义 `.appleMusic`；`.systemNowPlaying` 由 FullEdition 用 extension 加。这样 Core 与纯净版对完整版零知识，注册表未知值仍回落 Apple Music（现有测试已钉）。
- `PlaybackTrackIdentity` 加 `originBundleID: String?`（Apple Music 源填 `com.apple.Music`）。
- 代价：`git mv` app 源码目录一次。**这会碰 WT-C 正在改的 SettingsView.swift / MusicMiniPlayerApp.swift 的路径**，需要主会话安排在一个收编同步点做（我出一个只含 mv + `public` 可见性的独立 commit，WT-C 合回后再 rebase 一次）。
- 备选 B（不重构）：单 app target 加 `-DNANOPOD_FULL_EDITION` 编译条件 + 同样的二进制断言。缺点：私有代码仍在纯净 target 的源码树里，只靠条件编译排除，证明弱一档。我不推荐，除非创始人不想动目录。

## 3. 运行时设计（NanoPodFullEdition）

- `AdapterProcessRunner`（协议 + 真实现）：封装 `/usr/bin/perl <pl> <framework> [<testclient>] <cmd>`；`test`（exit 0 判活）、`stream --micros --debounce=100`（长驻子进程，逐行 JSON）、`get --no-artwork`（按需）、`send N` / `seek` / `shuffle` / `repeat`。全部在自有 `DispatchQueue`，不碰 scriptingBridgeQueue。
- `StreamPayloadParser`：处理 `diff=true` 增量合并与 `null` 删键；封面 base64 解码一次并按 `contentItemIdentifier` 缓存；封面迟到时再发一次 `.snapshot`。
- `SystemNowPlayingSource: PlaybackSource`
  - 快照映射：`title/artist/album/duration`；位置 = `elapsedTime + (now − timestamp) × playbackRate`，`measuredAt = timestamp`（沿用现有「读取前时间戳」纪律）；`playing`→isPlaying；`shuffleMode/repeatMode` 1/2/3 映射到现有 0/1/2 编码；`nativeID = contentItemIdentifier ?? uniqueIdentifier`；`originBundleID = bundleIdentifier`。
  - capabilities：play / seek / shuffle / repeatMode。**无** volume、favorite、queueRead、playByID、addToLibrary、share（adapter 不提供）。
  - 控制：toggle=`send 2`，next=`send 4`，previous=`send 5`，seek=`seek micros`，shuffle/repeat=`shuffle`/`repeat` 命令。
  - 可用性状态机：`.available` ⇄ `.unavailable(reason)`；stream 子进程意外退出 → 退避重启；`NSWorkspace.didWakeNotification` → 立即重试。
- 路由规则（Core 的 `PlaybackSourceRegistry` 加「自动」模式）：系统源报告的 `originBundleID == com.apple.Music` 时选 Apple Music 源（保留 persistentID、队列、收藏全能力）；其他 bundle 时选系统源；用户可在设置里固定某一源。
- 歌词管线：非 Apple Music 源调 `fetchLyrics` 时 `persistentID` 传 nil（`contentItemIdentifier` 语义未核实，不冒充 PID），走 title/artist/duration 元数据路径。已与 WT-A 对齐「persistentID 裸值不动」。

## 4. 构建与打包

- `build_app.sh` 加 `NANOPOD_EDITION=pure|full`（默认 full，因为 GitHub 版就是完整版）；纯净版走 `--product MusicMiniPlayer`，完整版 `--product MusicMiniPlayerFull`；BuildInfo.txt 加 `edition=`。
- 完整版：沙盒 false（现状已如此），`codesign --deep` 覆盖 vendored framework；纯净版：沙盒 true + 现有 Apple Events entitlement，不含 FullEdition 资源。
- 纯净版三道门写成 `scripts/assert_pure_edition.sh`，build_app.sh 在 pure 模式下必跑，失败即拒绝交付（同 icns 缺失的处理方式）。

## 5. 测试（全部零网络、零 perl）

- `StreamPayloadParserTests`：diff 合并、null 删键、封面复用、`--micros` 单位。
- `SystemNowPlayingSourceTests`：假 runner 注入（协议缝），假时钟钉位置插值；test 失败→unavailable→退避重试→恢复；stream 退出→重启；命令映射表；shuffle/repeat 编码往返。
- `PlaybackSourceRouterTests`：`com.apple.Music` 自动切回 Apple Music；固定源覆盖自动。
- `PureEditionIsolationTests`：解析 `swift package dump-package` JSON 断言依赖图。
- 一条 opt-in 集成测试（`NANOPOD_ADAPTER_LIVE=1` 才跑）：真跑 `test` 命令，供创始人机器上手动确认。

## 6. 里程碑

| # | 内容 | 验证 |
|---|---|---|
| M1 | 目录重构 + `PlaybackSourceID` 改 struct + 两个可执行产品（功能不变） | 全量 swift test；两个产品都能 build；纯净三道门通过 |
| M2 | vendored adapter + runner + parser + 测试 | 单测 |
| M3 | SystemNowPlayingSource + 路由自动模式 + 设置页状态行 | 单测 + 创始人实机：放网易云 / QQ，面板出曲目与封面、能切歌与 seek |
| M4 | build_app.sh 双版本 + assert_pure_edition.sh | 两版各出一次包，纯净版断言通过 |

## 7. 需主会话/创始人确认的点

1. 切分走方案 A（目录重构，碰 WT-C 路径）还是 B（编译条件）。我推荐 A。
2. M1 的 `git mv` 安排在哪个收编同步点。
