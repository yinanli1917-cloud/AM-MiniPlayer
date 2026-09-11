# 第三方播放器支持调研（WT-E 阶段 1，2026-09-10）

状态：调研完成，等创始人裁决范围（见第 6 节）。E1 协议草案见第 5 节。

调研方式：五个 Sonnet 子代理分头做 WebSearch / WebFetch / 仓库源码 clone + grep / 本机 `sdef` 与 Info.plist 检查。凡未核实的一律标「未核实」并写明查过什么。原始分稿在本会话 scratchpad（part1 通用 now-playing、part2 网易云/QQ、part2b 三个网易云第三方客户端源码、part3 YouTube、part4 nanoPod 内部消费面与本机检查）。

铁律前提：禁私有 API。MediaRemote 私有框架、私有 entitlement 绕过、代码注入、逆向私有数据库、Accessibility 读别的 app 窗口（沙盒下本就不可用）全部归入「私有/不可上架」一栏，只记录不采用。

---

## 1. 先讲结论

1. **系统级「读别的 app 在放什么」没有公开 API。** `MPNowPlayingInfoCenter` 只能写自己的信息（Apple 文档原话：An object for setting the Now Playing information for media that your app plays）。唯一能读的是 MediaRemote 私有框架，且 macOS 15.4 起 `mediaremoted` 只放行 `com.apple.` 前缀 bundle id 的进程，社区工具（nowplaying-cli #28、LyricFever #94、boring.notch）集体失效。社区绕过（mediaremote-adapter 借 `/usr/bin/perl` 的 `com.apple.perl5` 身份代跑）仍是私有框架 + 利用未公开系统行为，作者自述可能过不了 App Store。**这条路对 nanoPod 关死。**
2. **所以第三方播放器支持只能「一个播放器一个公开接口」逐个接。** 每个播放器能不能接，取决于它自己有没有公开的脚本字典或本地 HTTP 接口。业界做得好的第三方工具正是这么做的：LyricsX / Sleeve 开源版 / Tuneful 都是 AppleScript 字典；网易云第三方客户端与 YouTube Music 桌面客户端都是自带本地 HTTP。
3. **能接的：** Spotify（AppleScript 字典，读控全）、网易云第三方开源客户端 YesPlayMusic / AlgerMusicPlayer / VutronMusic（本地 HTTP）、YouTube Music 桌面客户端 YTMDesktop / pear-desktop（本地 HTTP + 授权）、浏览器里的 YouTube（AppleScript 注入 JS，或 Safari Web Extension）。
4. **接不了的：** 网易云、QQ 音乐**官方** macOS 客户端。本机实测两者都没有 AppleScript 字典（`sdef` 报 -192），没有公开 IPC，Info.plist 无 URL scheme 声明；LyricsX 2017 年就把「支持网易云播放器」标成 wontfix。唯一能做的是 System Events 模拟按键（单向、拿不到曲目、沙盒下不可用），不算支持。
5. **App Store 角度：** 向第三方 app 发 Apple Events 用公开的 `com.apple.security.automation.apple-events` entitlement + `NSAppleEventsUsageDescription`，可过审（现有 Music.app 路径已经这么做）。连 localhost HTTP 只需已有的 network client entitlement。Safari Web Extension 是 Apple 官方支持的 App Store 分发形态。这三类机制都不碰沙盒红线。

---

## 2. 能力矩阵

图例：读 = now-playing 元数据（标题/艺人/专辑/时长）；位 = 播放位置；控 = play/pause/next/prev；seek；队 = 队列读；封 = 封面；ID = 持久身份。公开 = 是否纯公开 API。店 = nanoPod 依赖它能否上 App Store。

| 播放器 | 机制 | 读 | 位 | 控 | seek | 队 | 封 | ID | 公开 | 店 | macOS 26 | 备注 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Apple Music（现状） | ScriptingBridge + MusicKit | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | persistentID | ✓ | ✓ | ✓ | 现有实现 |
| Spotify 桌面 | AppleScript 字典（app 自带 `Spotify.sdef`） | ✓ | ✓（秒） | ✓ | ✓ | ✗（未见 queue 类，推断不支持） | `artwork url` | `spotify url`（URI） | ✓ | ✓ | 未核实（字典多年稳定） | `duration` 毫秒 vs `player position` 秒；`get properties of current track` 会报错要逐属性取；本机未装 |
| 网易云官方 mac | 无 | ✗ | ✗ | 仅 System Events 按键 | ✗ | ✗ | ✗ | ✗ | — | ✗ | — | 本机 `sdef` -192；无 IPC/URL scheme |
| QQ 音乐官方 mac | 无 | ✗ | ✗ | 同上 | ✗ | ✗ | ✗ | ✗ | — | ✗ | — | 本机 `sdef` -192；第三方开源生态几乎为零 |
| YesPlayMusic | 本地 HTTP Express :27232（仅 127.0.0.1，启动即开，无鉴权） | ✓ `/player` | ✓ | ✗（无写接口） | ✗ | ✗ | 经曲目对象 | 网易云 song id | ✓ | ✓ | 未核实 | 维护模式（最近提交 2026-06-14）；MIT |
| AlgerMusicPlayer | 本地 HTTP Express :31888（默认关，IP 白名单默认空=不限） | ✓ `/api/status` | 未核实（status 只见 isPlaying+currentSong） | ✓ toggle/prev/next/音量/收藏 | ✗ | ✗ | 经曲目对象 | 网易云 song id | ✓ | ✓ | 未核实 | 活跃（2026-08-31）；MIT；标准 `navigator.mediaSession` |
| VutronMusic | 本地 HTTP Fastify :9863「Amuse」协议（默认关，无鉴权） | ✓ `/query` | ✓ | ✗（纯只读） | ✗ | ✗ | `track.cover` | `track.id` | ✓ | ✓ | 未核实 | 活跃（2026-08-07）；MIT；端口与 YTMDesktop 撞 |
| YTMDesktop | 本地 REST + Socket.IO :9863，requestcode→用户确认→token | ✓ | ✓ | ✓ | ✓ | ✓（含 index/repeat/shuffle） | ✓ 缩略图 | videoId | ✓ | ✓ | 未核实 | 文档最全；license 未核实（疑 GPL-3） |
| pear-desktop（原 th-ch/youtube-music） | API Server 插件，本地 HTTP，`/auth/*` token，`/api/v1/song` `/queue` | ✓ | 未核实 | 未核实 | 未核实 | ✓ | 未核实 | 未核实 | ✓ | ✓ | 未核实 | 33k★ 极活跃；MIT；插件 README 路径 404 |
| 浏览器 YouTube（Chrome 系 / Safari） | AppleScript `execute javascript` / `do JavaScript` 注入读 `<video>` + MediaSession | ✓ | ✓ | ✓（模拟） | ✓ | ✗ | 页面抓 | videoId（URL） | ✓ | ✓（Apple Events 自动化 entitlement） | ✓ | 用户须手动开一次「Allow JavaScript from Apple Events」；不开只能读 tab 标题/URL；站点改版易碎 |
| 浏览器 YouTube（Safari Web Extension） | content script + native messaging 到容器 app | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | videoId | ✓ | ✓（官方分发形态） | ✓ | 要自研并维护扩展；只覆盖 Safari |
| WebNowPlaying 浏览器扩展 | 扩展 + 本地 adapter 协议 | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | 站点相关 | ✓ | ✓ | 未核实 | 无 macOS 官方 adapter，协议端口/站点清单未核实；要 nanoPod 自己实现 adapter 端 |
| 系统 Now Playing（任何播放器） | MediaRemote 私有框架 | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | 无稳定 ID | **✗** | **✗** | 15.4+ 需绕过 | 见第 3 节，禁用 |

---

## 3. 依赖私有 API 的方案（单列，只记录）

| 方案 | 私有点 | 现状 | 公开替代 | 代价 |
|---|---|---|---|---|
| MediaRemote 直连（nowplaying-cli、media-remote、MediaRemote-rs、LyricsX 的 MusicPlayer SystemMedia） | `MRMediaRemoteGetNowPlayingInfo` 等私有符号 | macOS 15.4 起被 `mediaremoted` entitlement 校验拒绝 | 逐播放器公开接口（第 2 节） | 覆盖面从「所有播放器」缩到「有公开接口的播放器」 |
| mediaremote-adapter（ungive，BSD-3；boring.notch 采用） | 借 `/usr/bin/perl` 的 `com.apple.perl5` 身份 spawn 子进程加载私有框架 | 作者自述 2026-09-04 仍可用，声称到 macOS 27；无独立复测 | 同上 | 同上；且随时可能被 Apple 封 |
| MediaRemoteWizard | 向 `mediaremoted` 注入代码 | 需关 SIP | 同上 | 不可分发 |
| Accessibility（AXUIElement）读播放器窗口 | 非私有 API，但沙盒 app 不可用（temporary-exception 基本批不下来） | — | 同上 | 只能非 App Store 分发 |

LyricsX 的定位澄清：它「支持网易云」只是歌词源（抓词），播放器侧从未支持网易云客户端（issue #73 wontfix）。与 nanoPod 现状一致：我们的网易云/QQ 也只是歌词源。

---

## 4. 建议路线

**原则：** 一个协议，三类适配器；先做「公开接口最完整、用户设置最少」的。

| 优先 | 目标 | 适配器类型 | 用户要做什么 | 工作量 |
|---|---|---|---|---|
| 1 | Spotify 桌面 | AppleScript/ScriptingBridge（与 Apple Music 同族） | 装 Spotify；首次授权自动化 | 小。字典成熟；坑只有单位与逐属性读 |
| 2 | YouTube Music 桌面（YTMDesktop） | 本地 HTTP 轮询 + Socket.IO 推送 | 装 YTMDesktop，一次性在其内确认授权 | 中。要写 Swift REST + Socket.IO 客户端（Socket.IO 握手可退化为纯 REST 轮询起步） |
| 3 | 网易云（第三方客户端） | 本地 HTTP 轮询 | 用 YesPlayMusic / AlgerMusicPlayer / VutronMusic 替代官方客户端；Alger/Vutron 要手动开开关 | 小。三者都是无鉴权 GET；但只有 Alger 能控，且无 seek |
| 4 | 浏览器里的 YouTube | AppleScript JS 注入（Chrome 系 + Safari） | 手动开一次「Allow JavaScript from Apple Events」 | 中。站点 DOM 易碎；不开权限退化为只显示标题 |
| 后置 | Safari Web Extension | 扩展 + native messaging | 启用扩展 | 大。独立 target，长期维护 |
| 不做 | 网易云/QQ 官方客户端、系统 Now Playing | — | — | 无公开路径 |

**歌词管线的红利（转 WT-A 知会，不在 E 范围内做）：** 网易云第三方客户端与 YTMDesktop 都给出源站原生 ID（网易云 song id / videoId）。网易云 song id 可直接命中我们现有 NetEase 歌词源，跳过整个 MetadataResolver。协议里把 native ID 带上，WT-A 之后可以按 source 走捷径。

**风险：** 本地 HTTP 类适配器依赖第三方项目的接口稳定性与存活（YesPlayMusic 已维护模式）。协议层必须把「源不可用」当一等状态，UI 退化为「未连接」而不是空白。

---

## 5. E1 播放源协议草案

设计约束：
- 不重写 ScriptingBridge 实现。MusicController 现有 `@Published` 与 `togglePlayPause / nextTrack / previousTrack / seek / playTrack(persistentID:) / fetchUpNextQueue / toggleStar / setVolume` 等公开签名不变，UI 与 WT-D 继续调它们。
- 第一步只加协议 + Apple Music 适配器 + 路由器，MusicController 变成「当前源的发布中枢」：它持有 `activeSource`，把源事件写进现有 `@Published`。ScriptingBridge 代码原地不动，由 `AppleMusicPlaybackSource` 调用。
- 线程纪律不变：ScriptingBridge 只在 `scriptingBridgeQueue`；每个适配器自管自己的 queue/Task，对外只经 `AsyncStream` 与 `async` 方法。

```swift
// Sources/MusicMiniPlayerCore/Services/PlaybackSource/PlaybackSource.swift（草案）

public enum PlaybackSourceID: String, Codable, CaseIterable {
    case appleMusic, spotify, neteaseThirdParty, youtubeMusicDesktop, browserYouTube
}

/// 持久身份：跨轮询、跨重启稳定。歌词管线的 PID 权威改吃 stableKey。
public struct PlaybackTrackIdentity: Hashable, Codable {
    public let source: PlaybackSourceID
    public let nativeID: String?        // Music persistentID / Spotify URI / 网易云 song id / videoId；缺失时为 nil
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval   // 0 = 未知（电台语义沿用）
    public var stableKey: String { nativeID.map { "\(source.rawValue):\($0)" } ?? "\(source.rawValue):meta:\(title)|\(artist)|\(album)" }
}

public enum ArtworkHint: Equatable {
    case none
    case image(NSImage)                  // Apple Music SB 直出
    case url(URL)                        // Spotify artwork url / 网易云 cover / YTM thumbnail
    case lookupByMetadata                // 交给现有 RowArtworkStore 走 iTunes/NetEase/Deezer 回退
}

public struct PlaybackCapabilities: OptionSet {
    public let rawValue: Int
    public static let play = Self(rawValue: 1 << 0)
    public static let seek = Self(rawValue: 1 << 1)
    public static let shuffle = Self(rawValue: 1 << 2)
    public static let repeatMode = Self(rawValue: 1 << 3)
    public static let volume = Self(rawValue: 1 << 4)
    public static let favorite = Self(rawValue: 1 << 5)
    public static let queueRead = Self(rawValue: 1 << 6)
    public static let playByID = Self(rawValue: 1 << 7)
    public static let addToLibrary = Self(rawValue: 1 << 8)
    public static let share = Self(rawValue: 1 << 9)
}

public struct NowPlayingSnapshot: Equatable {
    public let identity: PlaybackTrackIdentity?   // nil = 无曲目 / 未连接
    public let isPlaying: Bool
    public let position: TimeInterval
    public let measuredAt: Date                   // 读取前的时间戳（沿用 measurementTime 纪律）
    public let artwork: ArtworkHint
    public let shuffle: Bool?
    public let repeatMode: Int?                   // 0 off / 1 one / 2 all，沿用现有编码
    public let volume: Int?
}

public struct QueueSnapshot: Equatable {
    public struct Item: Equatable { public let identity: PlaybackTrackIdentity; public let artwork: ArtworkHint }
    public let upNext: [Item]
    public let recent: [Item]
}

public enum PlaybackSourceEvent {
    case snapshot(NowPlayingSnapshot)             // 状态/曲目变化（含 track change）
    case positionResync(TimeInterval, Date)       // 只校时，不触发曲目管线
    case queueChanged
    case availability(PlaybackSourceAvailability)
}

public enum PlaybackSourceAvailability: Equatable {
    case available
    case appNotRunning
    case needsUserSetup(String)                   // 例如「在 AlgerMusicPlayer 设置里打开远程控制」
    case unauthorized                             // Apple Events / token 被拒
    case unreachable(String)
}

public protocol PlaybackSource: AnyObject {
    var id: PlaybackSourceID { get }
    var capabilities: PlaybackCapabilities { get }
    var events: AsyncStream<PlaybackSourceEvent> { get }
    func start()
    func stop()
    func readSnapshot() async -> NowPlayingSnapshot?
    func readQueue() async -> QueueSnapshot?
    func togglePlayPause() async
    func next() async
    func previous() async
    func seek(to position: TimeInterval) async
    func setShuffle(_ on: Bool) async
    func setRepeatMode(_ mode: Int) async
    func setVolume(_ level: Int) async
    func toggleFavorite() async
    func play(itemID: String) async
}
```

映射到现状：
- `AppleMusicPlaybackSource`：包现有 SB 代码；`nativeID = persistentID`；artwork `.image`；capabilities 全开。
- `SpotifyPlaybackSource`：ScriptingBridge 生成 Spotify 头文件；`nativeID = spotify url`；artwork `.url`；无 queueRead / playByID / addToLibrary。
- `LocalHTTPPlaybackSource`（一套轮询壳，按 profile 区分 YesPlayMusic / Alger / Vutron / YTMDesktop 的端点、字段、鉴权）；`nativeID` 为源站 id；artwork `.url`；capabilities 按 profile 声明。
- 歌词侧（WT-A 2026-09-10 裁定）：`LyricsService.fetchLyrics(... persistentID:)` 的 persistentID **保持裸值不动**，源信息另开参数（如 `source: PlaybackSourceID`）；`stableKey` 的源前缀只在协议层拼，不下渗到歌词管线与磁盘缓存键。

---

## 6. 需创始人裁决的三件事（按顺序单独发主会话）

1. 网易云与 QQ 音乐官方客户端没有公开路径。是否接受「网易云只支持第三方开源客户端（YesPlayMusic / AlgerMusicPlayer / VutronMusic）、QQ 音乐不做」？
2. Spotify 本机未装。是否把 Spotify 列为 E3 第一实现（需要创始人装 Spotify 做 spike 与终验）？
3. YouTube 先做 YTMDesktop 桌面客户端（本地 HTTP，文档最全），浏览器 YouTube 走 AppleScript JS 注入后置，Safari Web Extension 暂不做。是否同意这个顺序？

---

## 7. 未核实事项（后续 spike 逐条实测）

- Spotify.sdef 原文逐条核对（本机未装）；队列是否真无接口。
- YTMDesktop license；pear-desktop API Server 插件当前源码路径与字段。
- AlgerMusicPlayer `/api/status` 里 `currentSong` 的完整字段与是否含进度。
- VutronMusic 是否发布 mediaSession（与 nanoPod 无关，仅备注）。
- WebNowPlaying 协议端口、站点清单、license。
- 各本地 HTTP 客户端在 macOS 26 下的实机可用性。
- Tuneful / Sleeve 3 / NotchNook 闭源机制。

## 8. 来源

- Apple `MPNowPlayingInfoCenter` 文档：https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter
- Apple Developer Forums 809554（Now Playing 无读 API）：https://developer.apple.com/forums/thread/809554
- Safari Web Extension native messaging：https://developer.apple.com/documentation/SafariServices/messaging-a-web-extension-s-native-app
- Chromium AppleScript：https://www.chromium.org/developers/applescript/
- nowplaying-cli #28（15.4 失效）：https://github.com/kirtan-shah/nowplaying-cli/issues/28
- mediaremote-adapter：https://github.com/ungive/mediaremote-adapter
- boring.notch：https://github.com/TheBoredTeam/boring.notch
- LyricsX：https://github.com/ddddxxx/LyricsX ；MusicPlayer：https://github.com/ddddxxx/MusicPlayer ；issue #73 wontfix
- Sleeve 开源版：https://github.com/jnptzl/sleeve ；Tuneful：https://github.com/martinfekete10/Tuneful
- YesPlayMusic `src/background.js`：https://github.com/qier222/YesPlayMusic
- AlgerMusicPlayer `src/main/modules/remoteControl.ts`：https://github.com/algerkong/AlgerMusicPlayer/blob/main/src/main/modules/remoteControl.ts
- VutronMusic `src/main/appServer/6kLabsAmuse.ts`：https://github.com/stark81/VutronMusic
- YTMDesktop Companion Server：https://github.com/ytmdesktop/ytmdesktop/wiki/v2-%E2%80%90-Companion-Server-API-v1 ；https://ytmdesktop.github.io/developer/companion-server/getting-started.html
- pear-desktop：https://github.com/th-ch/youtube-music
- WebNowPlaying：https://github.com/keifufu/WebNowPlaying
