# 阶段包 1（2026-09-11）

- 位置：`/Users/yinanli/Documents/MusicMiniPlayer/nanoPod.app`（main e5a70c9，BuildInfo release_sha256=5a853253…，MacOS/nanoPod md5 5bf3bf1d998a8e4375cc7e386aaf5c15）。旧 v0.29 发售包 md5 是 55fa543f…，别拿混。
- 版本号仍显示 0.29（按最新 v0.* tag 生成），以 BuildInfo 的 git=e5a70c9 区分。
- 出包门禁：e2e 冒烟结果见本文末尾。

## 本包包含（按 worktree）

**WT-D 队列伴生**
- 点行跳曲：点下去该行立即变淡并出小转圈，换曲确认、失败或 4s 超时后清除；行上 hover 手形光标。【终验：等待态手感、光标】
- 电台 / Apple Music 流下 Up Next 空态文案「Music 未提供此来源的队列」，其他情况仍「队列为空」；History / Now Playing / Up Next 中英本地化。
- 队列同步：ScriptingBridge 3s 超时不再当空队列写入；Music 退出或无当前曲时清幽灵行。

**WT-A 歌词管线**
- 选中即上屏：前台取词裁决一出就上屏，不再等被取消子任务排水（曾差 0.45s）。日志关键字 `apply-on-select`。
- 内存缓存改按字节治理，20 MiB 约 360 首。
- 英文标题门 + 负证据缓存：纯英文歌不再对 JP/KR/HK/TW 与 CN 做推测查询；查过无果的标题记 24h 负证据。元数据缓存 schema 8→9，**首次启动会冲掉旧元数据缓存并后台预热，前几分钟歌词可能略慢**。若某歌「昨天没词今天该有却没有」，先看 lyrics_cache.json 的 availability 行，再看 metadata_cache.json 的 negative_* 行。

**WT-B 歌词渲染**
- 窗口被遮挡再露出时，歌词呈现状态直达目标，不再从冻结的中途值续动画。
- 切行波浪对照臂（B2）：默认 topdown（上一行先退、入场行晚约 80ms、下方逐行再晚一拍，契约规定的 AMLL 顶→底波浪）。切换：
  ```bash
  open "nanopod://debug/feel/wave/sync"
  ```
  ```bash
  open "nanopod://debug/feel/wave/topdown"
  ```
  ```bash
  open "nanopod://debug/feel/reset"
  ```
- 运行时埋点 ActiveBrightness（B3 亮度封顶）与 LineGaps（B1 行距）：release 包默认不写日志，先执行下面这条并重启 nanoPod，日志在 `/tmp/nanopod_debug.log`，grep `ActiveBrightness` / `LineGaps`。每次切行最多两行、每次滚动手势两行。
  ```bash
  defaults write ~/Library/Preferences/com.yinanli.nanoPod.plist enableDebugFileLog -bool YES
  ```
  （09-12 更正：这台机器上 nanoPod 曾以沙盒运行过，`defaults write com.yinanli.nanoPod …` 域名形式会被 cfprefsd 静默重定向进 ~/Library/Containers/com.yinanli.nanoPod/ 的容器 plist，现在的非沙盒 app 读不到；必须写显式路径。WT-B 已替创始人写入，当前实例已在落盘。）

**WT-E 播放源抽象**：无可见变化。

## 终验清单（创始人）
1. 普通切行看一次：上一行约 0.15s 内不动，然后位移、变暗、亮层同时起；再切 sync 臂比一下，决定波浪方向。
2. 行距：肉眼看激活行前后行距是否跳；同时开着埋点，反馈时把 `/tmp/nanopod_debug.log` 里 LineGaps 行一起给。
3. 亮度：若再见到某激活行发不亮，记歌名与时间，日志里 ActiveBrightness 行一起给。
4. 歌单页：点几次跳曲，感受等待态；电台下看空态文案；再判断这一页的定位。
5. 歌词出词速度：切几首英文歌与中日韩歌，感受是否比 v0.29 快；首启前几分钟预热除外。

## 未包含（分支上或未开始）
WT-C 全部（贴边液态、页面切换、微交互、设置页），等 C1 方案裁决；WT-A A4 埋点采数与 A5 翻译持久化；WT-B B4 间奏点结构统一；WT-D D5 快捷键（等裁决）、D2 挂起；WT-E E3（等版本切分与私有 API 例外裁决）。

## e2e 冒烟（2026-09-12T00:52Z，--skip-build，对本包）
5/5 PASS：cold_start_original_lyrics（原文+翻译 0.759s，从 play 返回算 0.562s）、seek（3.0→61.6s，displayState=content）、consecutive_track_changes（冬天一個遊→尋開心 均 lyrics_applied）、no_lyrics_no_crash（Tangerine Bossa 终态 noLyrics，进程存活）、clean_exit_no_leftover。报告与 events.jsonl 在主会话 scratchpad e2e-stage1-run2/。
