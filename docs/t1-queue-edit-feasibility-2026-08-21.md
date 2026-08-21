# T1 · 队列编辑可行性结论（2026-08-21）

一页结论 spike。目标：摸清 nanoPod 能否编辑 Music 的 Up Next（移除/插播下一首/拖拽重排），据此再定最小编辑集。方法：Music.app `sdef` 权威字典 + 真机 AppleScript 实测（scratch 歌单，用后即删，未动用户真实队列/曲库）+ 现有代码路径核查。

## 一句话结论

**真正的 Up Next 瞬态队列在公开 API 里既不可写、也不可寻址**——没有任何脚本对象、没有 `play next`/`enqueue`/重排命令，`up next` 甚至不是 Music 字典里的词。编辑能力只存在于两个都带硬约束的间接路径上，需要创始人在两者间拍板方向。

## 能力矩阵（真机实测 + sdef 权威）

| 操作 | ScriptingBridge / AppleScript（控制系统 Music.app，现行架构） | 证据 |
|---|---|---|
| 读 Up Next | ⚠️ 仅 `current playlist` 的 tracks 切当前曲之后（= 歌单上下文，非真队列）；**电台/流媒体 URL track 下 `current playlist` 直接报错**"Can't get current playlist" | 实测：当前播放 Apple Music URL track 时报错；app 现行 `getUpNextTracksFromApp` 即走此路 |
| 移除队列项 | ❌ 无队列对象。只能 `delete` 掉**用户歌单**里的曲（持久改库，非临时移除；电台/流媒体无歌单可删） | scratch 歌单 `delete track` OK；`current playlist` 只读引用 |
| 插播下一首 | ❌ 无 `play next`/`enqueue` 命令；`add` 只能把**磁盘文件**加到歌单末尾，不能把曲目插到队列 next 位 | sdef：`add` direct-param `type="file"`，无队列动词 |
| 拖拽重排 | ⚠️ `move track to before/after` 在**用户歌单**内可行（尽管 sdef 里 `move` 标注 playlist-only、`track.index` 只读）；对真队列/电台/只读系统歌单不可行 | scratch 歌单 `move (last track) to before (first track)` **OK** |
| 作用于"当前正在播放的队列" | ❌ `current playlist` 是**只读引用**；即便它恰好指向可写用户歌单，改的也是持久库歌单，且 Apple Music 歌单/专辑/电台下它根本不存在 | sdef `current playlist access="r"`；实测电台下报错 |

sdef 权威事实：命令集 `add/delete/move/duplicate/make/...` 全部作用于 playlist/track/file，**无 queue/up-next 类，无重排/插播/入队动词**；`track.index` `access="r"`；`current playlist` `access="r"`。

## 关键架构发现：nanoPod 其实有两个播放器

1. **ScriptingBridge → 系统 Music.app**（主路径）：play/pause/skip/进度/队列读取都走这里，控制的是用户可见的 Music.app。队列编辑受上表全部限制。
2. **MusicKit `ApplicationMusicPlayer.shared`**（已在用）：`MusicController+Playback.swift:248` 点播 Apple Music 单曲时用它，是与系统 Music.app **相互独立**的第二个播放器。它的 `.queue` 是**完全可编辑**的（`insert(_:position: .afterCurrentEntry/.tail)` = 插播下一首、`entries` 可增删可重排）。

→ 队列编辑的可行性完全取决于"谁是播放器"：控制系统 Music.app = 几乎不能编辑队列；nanoPod 自己用 ApplicationMusicPlayer 当播放器 = 队列全可编辑。`SystemMusicPlayer`（MusicKit 里代表系统播放器的那个）**不暴露**队列变更，帮不上忙。

## 两条路线的取舍

**路线 A（留在 ScriptingBridge，编辑最小集）**：仅当当前是**库用户歌单**播放时，可对底层用户歌单做 移除/重排/追加（实测三者皆可）。代价：① 改的是持久库歌单不是临时队列；② Apple Music 歌单/专辑/电台/只读系统歌单**全不支持**（覆盖面小，且正是多数人常用的播放方式）；③ 编辑是否即时反映到当前播放尚未在真机确认（待安静时段非破坏性复测——需短暂起播一个库歌单，本次未做以免打断用户电台）。

**路线 B（改用 MusicKit ApplicationMusicPlayer 当播放器）**：队列 增/删/重排/插播下一首 全部原生可行、语义干净。代价：架构大改（从"遥控系统 Music.app"变成"自己是播放器"）、仅 Apple Music 目录曲、需 MusicKit 授权、与用户可见的 Music.app 分裂成两个播放源（易冲突）。app 现有 `playAppleMusicTrack` 只是它的单曲一次性用法，不是托管队列。

## 建议（待创始人拍板）

- **不要**承诺"编辑系统 Music.app 的 Up Next"——公开 API 做不到，无私有 API 的红线下无解。
- 若要做真·队列编辑且手感对标 Apple 原生，**只有路线 B**能达标，但那是一次播放架构转向的大决策，需单独立项评估（与现有 ScriptingBridge 控制、锁屏/媒体键、双播放器冲突一并权衡）。
- 若只想在现架构下给一点编辑能力，**路线 A 的"库歌单场景下移除/重排"**是唯一低成本可交付项，但要如实标注其只在库歌单播放时可用、且为持久改库；先补一个真机测试确认"改当前播放歌单是否即时生效"再定。
- 一次只推一件：本 spike 只出结论，不写编辑代码。

## 复现

```bash
sdef /System/Applications/Music.app | grep -iE 'queue|up next|<command name'
```
scratch 歌单写能力实测脚本见本次会话记录（create user playlist → duplicate 3 曲 → delete/move 实测 → delete playlist），全部用后即删，未触及用户真实队列或曲库数据。
