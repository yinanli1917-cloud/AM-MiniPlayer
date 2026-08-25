# T2 · Bug #3 「Searching more sources…」提示链审计（2026-08-25）

创始人：直接取 meta info 后不该出现这个提示；>3s 必是竞态或错误路径，审计这条链。

## 结论

提示（`deepSearching` = "Searching more sources…"）**不会在已有内容时出现**（状态机守卫成立），也**不会为同 songID 的内存缓存命中而闪**（命中即同帧 `applyLyrics` 置 `.content`）。它出现＝当时**确实没有可显示内容**、前台突发窗结束、backfill 在跑。是否算"错误路径"分两种：

- **合理慢取**：磁盘缓存 + 快源都真没有这首，只有慢源/backfill 有 → 提示是真实等待（硬上限 9s）。**不是 bug**。
- **可避免的摩擦（真问题）**：这首其实**在磁盘缓存里**，却仍走了异步取词、暴露了 spinner/提示。根因见下。

## 链路时序（代码位）

1. `LyricsService.fetchLyrics`：换歌时**同步**先置 `displayState = .searching`（:584），再取消旧任务、查缓存。
2. **内存缓存**（`lyricsCache`，NSCache，**countLimit 仅 50**，:664）命中 → 同帧 `applyLyrics` → `.content`。**无 spinner**。
3. 未命中 → 启动**异步** fetch 任务（LyricsFetcher）。**磁盘缓存（`lyrics_cache.json`，450 条）只在这个异步任务里查**（LyricsFetcher :607/705/730/1038），不在步骤 1 之前的同步预检里。
4. 异步任务里，`canUseImmediateDiskLyrics = !CJK(title) && !CJK(artist)`（:607）——**即时磁盘快路径只对非 CJK 标题/艺人开放**（CJK 需先经 MetadataResolver 解析别名，不能直接拿原标题命中）。
5. 前台突发窗（≤5s；marker-only 2.2-2.95s）无果 → `enteringDeepSearch()`（:1084）→ 提示出现。

## 为什么创始人常看到（两个结构性暴露）

1. **内存缓存只有 50 条**。大曲库下绝大多数歌不在内存缓存里 → 几乎每首都进异步取词（至少 spinner 一闪；磁盘/快源都miss 时升到 >3s 提示）。本会话实测 44 次 fetch 仅 1 次内存命中——命中率极低，佐证。
2. **即时磁盘快路径非 CJK 才走**。创始人曲库大量中日文——这些歌即便在磁盘缓存里，也拿不到即时同步返回，更易见 spinner/提示。

## 与 #1 的收敛修法（关键）

磁盘缓存是**内存字典支撑的、`get()` 同步且快**（init 时把 JSON 解进 `memory` 字典，:362）。因此可在 `fetchLyrics` 的**同步预检**里（置 `.searching` 之前）加一次**全语言的磁盘缓存直查**：
- 命中 → 直接 `applyLyrics(disk.lyrics)` → `.content`，**根除**已缓存歌的 spinner/提示（#3）。
- 且若磁盘缓存存的是**词级**，直接就是词级显示，**顺带消除 #1 的"行级→词级中段翻转"**（不再先显示行级再升级）。
- CJK 的别名问题：预检直查可先用 `stableSongID`/原标题尝试；未命中再回落异步解析路径（保持现有正确性）。

一处代价/风险：同步直查若键不匹配（duration/album 漂移、CJK 别名）会 miss → 回落异步（即现状），无倒退。需确认同步读 6MB 字典的首次加载时机不落在换歌热路径（init 预热即可）。

## 未决：需要生产数据

「>3s 到底多频繁、backfill 延迟 p50/p95 是多少」——只有创始人的**真实诊断导出**（`nanopod-diagnostics-<stamp>` 或长窗口 `/tmp/nanopod_debug.log`）能定。本会话日志只是我几分钟的操作（44 fetch / 1 内存命中 / 1 次 backfill HIT@4.5s / 12 次 MISS），**样本不足以给分布，不编造**。若他导出诊断，我据此出 p50/p95 + >3s 命中率，既答 #3 的"多频繁"，也为 #1 修法 B 的"有界等待"定界值。

## 复现/证据命令

```bash
grep -c "fetchLyrics START" /tmp/nanopod_debug.log; grep -c "Cache hit" /tmp/nanopod_debug.log
```
（本会话：44 次 fetch，1 次内存命中——命中率暴露。deepSearch 本会话未触发，因多在封面页/播已缓存歌。）
