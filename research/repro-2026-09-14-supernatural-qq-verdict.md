# 复现报告：阶段包 3 Supernatural（QQ 48L）是否有缺陷

工作 worktree：`worktree-agent-a04d9e11ec3fe6844`，起初停在 `277cd5b`（旧于 main），
fast-forward 到 main 当前 tip `2e72a71`（`git merge --ff-only`，worktree 分支无独有提
交，安全操作）。含 df2a421（覆盖/空档比例惩罚）与 e13d867（人工标注源 ±12 容忍带在
候选自身有时间轴完整性惩罚时不适用）两个 2026-09-14 修复。

## 背景：两份证据为什么看起来矛盾

- 真机日志 `/tmp/nanopod_debug.log`（20:48 时段，已 cp 到
  `research/nanopod_debug_2026-09-14-2048.log`）第 23650/23657 行：
  ```
  [20:48:15] 🏆 Human-curated source preferred: QQ (72.6) over library fallback LRCLIB (67.7)
  [20:48:15] 📋 Applied: 'supernatural|newjeans|supernatural single|191' 48L, firstReal="Stormy night", unsynced=false
  ```
- 上一位代理（e13d867 提交者）用 `LyricsVerifier check --dump` 复验时 QQ 未命中
  （`found:false`），终态是 LRCLIB 37L，据此在 `docs/stage-bundle-3-2026-09-14.md`
  第 40 行报「修后终态换成 37 行完整版」。

两条证据都真实，不矛盾——同一段代码，QQ 搜索接口本身间歇性空结果（见下），命中与否
决定最终选的是 QQ 还是 LRCLIB。真正要判定的是：**QQ 赢的那次（48L）本身有没有缺陷**，
规则会不会漏判。

## 复现方法

```bash
export DEVELOPER_DIR=/Applications/Xcode.app
swift run LyricsVerifier check "Supernatural" "NewJeans" 191 --dump
```

连续跑 8 次（`NANOPOD_DEBUG_LOG=1` 开调试日志观察 QQ 搜索请求）：5 次 QQ `found:false`，
3 次命中。命中时分数、行数、内容与真机日志逐字段一致（QQ 72.6 / LRCLIB 67.7 /
NetEase 58.1，QQ 47 真实行 + 1 占位行 = 48 行，首句 "Stormy night"）——确认复现的就
是真机同一次决策，不是另一个候选。

### QQ 搜索间歇性空结果（复现，非配置/限流可辨因——记录，不修）

同一进程内，间隔 3 秒、完全相同的查询词 `supernatural NewJeans`：

```
[23:10:05] [QQMusic] 📦 title+artist: 20 个候选   ← 命中
[23:13:33] [QQMusic] 📦 title+artist: 0 个候选    ← 空
[23:13:34] [QQMusic] 📦 title only:    0 个候选
[23:13:34] [QQMusic] ❌ 未找到歌曲
```

没有超时、没有 HTTP 错误、没有限流响应头可辨——`u.y.qq.com/cgi-bin/musicu.fcg`
就是偶尔对合法查询回空列表。这是先前 `repro-2026-09-14-lyrics-pipeline.md`
已经记录过的现象（"QQ 一次有结果一次没有"），本次独立复现，仍判定为上游可用性
波动，非本仓库代码/配置问题。

## 逐行对照：QQ（47 真实行）vs LRCLIB（36 真实行）

真实 `--dump` 输出，未编辑。前 15 行：

| # | QQ 时间戳 | QQ 文本 | # | LRCLIB 时间戳 | LRCLIB 文本 |
|---|---|---|---|---|---|
| 1 | 26.3s | Stormy night | 1 | 8.7s | Come on |
| 2 | 28.5s | Cloudy sky | 2 | 16.8s | (Ah-ah) |
| 3 | 30.0s | In a moment you and I | 3 | 25.8s | Come on (let's go) |
| 4 | 35.1s | One more chance | 4 | 26.2s | Stormy night, cloudy sky |
| 5 | 37.3s | 너와 나 다시 한번 만나게 | 5 | 29.9s | In the moment, you and I |
| 6 | 40.8s | 서로에게 향하게 | 6 | 35.1s | One more chance, 너와 나 |
| 7 | 43.7s | My feeling's getting deeper | 7 | 38.6s | 다시 한번 만나게 서로에게 향하게 |
| 8 | 48.1s | 내 심박수를 믿어 | 8 | 43.7s | My feeling's getting deeper |
| 9 | 52.5s | 우리 인연은 깊어 | 9 | 48.1s | 내 심박수를 믿어 |
| 10 | 56.6s | I gotta see the meaning of it | 10 | 52.6s | 우리 인연은 깊어 |
| 11 | 61.6s | I don't know what we've done | 11 | 56.9s | I gotta see the meaning of it (come on) |
| 12 | 63.8s | 되돌아가긴 싫어 | 12 | 61.9s | I don't know what we've done |
| 13 | 66.4s | もう知っている | 13 | 63.8s | 되돌아가긴 싫어, もう知っている |
| 14 | 70.5s | Don't know what we've been sold | 14 | 70.5s | Don't know what we've been sold |
| 15 | 72.7s | 見つけられるよ | 15 | 72.8s | 見つけられるよ, so it's sure (come on) |

（完整 47/36 行原样保存于 `research/nanopod_debug_2026-09-14-2048.log` 引用的
verifier 输出；下方"真实数字"一节给出全曲统计。）

**两份候选的真实结构差异只有一处**：QQ 从 26.3s（"Stormy night"）开始，缺失
LRCLIB 8.7–25.8s 的三行前奏 hook（"Come on" / "(Ah-ah)" / "Come on (let's go)"，
约 17 秒）。26.3s 之后，QQ 与 LRCLIB 对每一句歌词的时间点几乎逐行对应（同一句歌词
时间差普遍 <1s，例如 [14] Don't know what we've been sold 两边都是 70.5s）——
QQ 行数反而更多（47 vs 36），原因是 QQ 把 LRCLIB 合并的双语句拆成两行
（如 LRCLIB "Stormy night, cloudy sky" 一行 = QQ "Stormy night" + "Cloudy sky"
两行），不是多抓到内容。

## 真实数字（调用真实 `LyricsScorer`/`LyricsResultSelection` 公式逐项验证）

用 verifier dump 出的真实时间戳重建 `LyricLine` 数组，调用真实代码（临时诊断测试，
未提交，验证后已删除）：

| 分量（镜像 `hasTimelineIntegrityPenalty` 的三条阈值，与 `LyricsScorer` 5b/5c/6 同源） | QQ | LRCLIB | 阈值 |
|---|---|---|---|
| 头部偏移（firstLyricStart） | 26.3s | 8.7s | `max(90, 191×0.30)=90s` |
| 尾部空档（191 − lastLyricStart） | 11.3s | 11.4s | `max(140, 191×0.40)=140s` |
| 最大内部空档 | 8.6s（136.9→145.5，两句 "It's supernatural" 之间的间奏，属正常乐句停顿） | 11.4s（125.7→137.1，同一处间奏） | `max(45, 191×0.15)=45s` |

三项全部远低于阈值——`hasTimelineIntegrityPenalty` 对 QQ 与 LRCLIB 都返回
`false`。且 QQ 分数（72.6）本身就高于 LRCLIB（67.7），选择走的是分数直接胜出，
±12 容忍带根本没被触发（`isLibraryFallbackSourceName(top.source)` 分支的存在
只是因为 `top` 取的是 `workingPool.first`——结果数组按抓取完成顺序排列、非按分
数排序，LRCLIB 在这次里先到，所以日志措辞是"human-curated preferred over
library fallback"，但实质是 QQ 分数更高）。

真实 `fetcher.selectBestResult(from: [lrclib, qq], songDuration: 191)`（用上表
两组真实候选数据构造）返回 `.qq`，与真机日志、与本次 verifier 复现完全一致。

对照 LRCLIB 自身的最大内部空档（11.4s）比 QQ（8.6s）还大——如果 QQ 因为"中间
跳行"被判有缺陷，那这条标准下 LRCLIB 同样该被判——但两者都在乐句间奏的正常范围
内，不是丢内容。

## 判定

**阶段包 3 的 Supernatural（QQ 48L 版本）无缺陷。** 规则在这次没有漏判：

1. df2a421 / e13d867 的完整性检查逐项复核为真——QQ 候选头部/尾部/内部空档三项
   都在阈值内，不该被拒，事实上也没有走容忍带（分数直接胜出）。
2. 上一位代理的"已修"结论成立，只是当时验证时 QQ 恰好搜不到，只覆盖了
   LRCLIB 赢的那条路径；这次补上了 QQ 赢的路径，同一套代码在两条路径下都给出
   正确答案。
3. QQ 唯一的真实差异是缺 3 行 17 秒的前奏 hook——这是候选来源之间常见的转写
   颗粒度差异（是否收录 ad-lib 前奏句），不是"从中段起录/丢了一大段"那类错版本
   （那是本轮已修的 NetEase 63.2s 空洞问题，性质不同）。26.3s 的头部偏移远低于
   90s 门槛，门槛本身也不该收紧到这个量级去卡它——收紧会连坐真正的长前奏/长
   间奏歌曲（`build_app.sh` 门禁里 82+100 两套回归已经验证过收紧的连带风险）。

**不需要代码改动。** 未发现需要修的评分/选择逻辑缺口；不跑 82 条/100 首 A/B
（这两套只在有代码改动时才需要重新跑）。

## 未做项

- QQ 搜索接口间歇性空结果的根因（限流阈值、IP 信誉、还是纯随机）未查——不在
  本仓库代码范围内，且现有的多源竞速架构已经能容忍单源间歇失败（另一次请求命中
  即可），暂不判定为需要处理的问题。
- 未验证 QQ 缺失的 3 行前奏 hook 是否应该由回填（backfill）阶段用另一源补全后
  热切换——真机日志里这次没有看到 backfill 覆盖这条候选（QQ 分数已经够高，未触发
  回填的"不满意再找"路径）；如果创始人认为这 17 秒前奏值得为它单独触发回填，
  需要另外定策（这会是一个新的行为要求，不是本次缺陷修复范围）。
