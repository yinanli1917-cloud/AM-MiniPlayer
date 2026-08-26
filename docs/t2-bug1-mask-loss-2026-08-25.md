# T2 · Bug #1 遮罩丢失 — 代码层复现与根因（2026-08-25）

创始人报：切到下一行后逐字遮罩完全没了、整行呈已高亮态，行进到一半又突然恢复正常。要求：先代码层复现（假时钟+确定性回放），查 handoff 时 mask 状态机与竞态。**本文只出复现+根因+修法代价，不动手改（手感类，终验归创始人）。**

## 结论一句话

**不是切行竞态，是"取词粒度升级"（granularity upgrade）。** 首个结果是整行级（line-level）时，app 先立刻显示行级（活跃行无逐字遮罩、整行均匀点亮＝"遮罩丢失"），~1-2s 后 granularity 重取拿到词级，`applyLyrics` 整份替换歌词，逐字扫掠在**当前播放位置**（本行中段）engage＝"行进到一半又突然恢复"。可见窗口＝重取/backfill 延迟（网络相关，硬上限 9s），非固定时长。

## 复现（确定性，注入时钟，零网络）

两条测试驱真 `NativeLyricsSurfaceView`（T0 时钟缝 debugNowOverride/debugTick/debugPlaybackClockDateProvider）：

**1. 排除切行竞态** — `NativeLyricsMaskHandoffTests`：纯词级、预加载、平滑切行。结果：切到下一行时逐字扫掠**首帧即 engage**，applied 逐帧精确跟 expected（0.001→0.006→…），**0 帧遮罩丢失、0 帧过度揭示**。→ 通用切行路径干净（也印证 T0 的切行手感本就干净）。

**2. 坐实 granularity 升级** — `NativeLyricsGranularityUpgradeTests`：先配行级行、驱到 line 5 中段，再原样替换成词级行（同 id，模拟 applyLyrics 升级），逐帧读活跃行状态：

| 阶段 | perRunSweep | 卡拉OK亮层 | expected | applied |
|---|---|---|---|---|
| 升级前（行级活跃行，中段） | **n（无逐字遮罩）** | **n（无亮层，整行均匀）** | 1.000 | 1.000 |
| 升级后（词级，中段落地） | Y | 有 | 0.589 | 0.589（engage 首帧即跟上） |

即：升级前整行无逐字扫掠（＝用户说的"遮罩丢失/整行已高亮"），升级后逐字扫掠**直接从 0.589（中段）跳出来**（＝"行进到一半恢复"）。engage 后 applied 精确等于 expected，无残留竞态。

## 根因链（代码位）

1. `LyricsService.shouldRefreshCachedLyricsForGranularity`（:348）＝「有缓存、非无歌词、非 unsynced、**且没有任何一行有逐字时间轴**」→ true。
2. 命中缓存时（:666）先 `applyLyrics(cached.lyrics …)`（:702）立即显示**行级**内容 → `displayState=.content`。
3. 因 `cachedNeedsGranularityRefresh` 为真，继续跑 authoritative backfill 找词级（:866/:880，硬上限 `AuthoritativeBackfillBudget.overall = 9s`）。
4. 词级返回 → `applyLyrics(newLyrics …)`（:1327）`self.lyrics = newLyrics` **整份替换** → SwiftUI 重建行 → surface 收到词级行 → 活跃行 `expectsPerRunSweep` 由 false 翻 true → `applyStaticActiveTextPhase`（隐藏亮层、无遮罩）切到 `applyActiveMainPhase`（逐字扫掠，从当前时间的 wavefront 起）。
5. 渲染层无 bug：行级活跃行按设计就是"隐藏 bright 亮层、整行均匀"（`applyStaticActiveTextPhase` :isHidden=true），词级按设计逐字。**丑的是两态之间的硬切**，发生在 backfill 落地那一刻、命中当时正活跃的那一行。

## 与另两症状的关系

- **#3 fetch 提示**：升级期正是 `deepSearching`（"Searching more sources…"）——同一条 backfill 链。若 #1 坐实，#3 大概率同根（见 #3 单独审计）。
- **#2 首字空白**：暂未排查，是否同根待定（可能是词级 engage 首帧的首 run 几何/遮罩边界问题，另查）。
- **288cdf2 不是本 bug**：那条（YRC 实体→words 清空）导致的行级退化**不会自行恢复**；创始人明确说"会恢复"，故本 bug＝granularity 升级，非 288cdf2。但两者叠加：若他跑的构建不含 288cdf2，含缩写的词级行升级后仍会退回行级（不恢复）——那是另一回事，收编 288cdf2 后消失。

## 修法方向与代价（待创始人拍板，不动手）

| 方案 | 做法 | 代价/风险 |
|---|---|---|
| **A. 无缝换装（升级时平滑过渡）** | 检测"行级→词级、同一活跃行"的替换，对该行做 ~0.2s 交叉淡入：整行均匀 → 逐字 wavefront。已扫进度天然保留（engage 首帧 applied 即等于 expected=0.589）。 | 渲染改动中等，新增一个过渡态；手感类需创始人终验；风险＝再多一个易错的动画态。 |
| **B. 词级未到前不降级显示（有界）** | `cachedNeedsGranularityRefresh` 为真时，**先不显示行级**，短暂（≤前台突发窗，如 2-3s）等词级；超时仍未到才回落显示行级。 | 常见情况（创始人说"取 meta 后很快"）几乎无感、且根除翻转；代价＝慢网时首屏多等几秒；需一个超时回落，避免只有行级的歌被无限拖。 |
| **C. 只升级未来行，当前活跃行本行内不换装** | 升级落地时，正在播的活跃行保持行级到本行结束，后续行用词级。 | 最省事、无本行跳变；代价＝该行剩余几秒仍是行级（同屏短暂混粒度）。 |

**建议**：常见路径用 **B（有界等待）**最干净——契合"取 meta 后词级通常很快到"的前提，直接消灭翻转；慢网回落时叠加 **C**（不改已在播的行）避免中段跳。A（交叉淡入）留作若仍要显示行级时的兜底打磨。三者可组合。**但都属手感类改动，需创始人先选方向、改完他亲验。**

## 复现命令

```bash
DEVELOPER_DIR=/Applications/Xcode.app swift test --filter NativeLyricsMaskHandoffTests
```
```bash
DEVELOPER_DIR=/Applications/Xcode.app swift test --filter NativeLyricsGranularityUpgradeTests
```

---

## 更正与收口（2026-08-25 晚）

创始人更正观察：不是"行级→词级一次性升级"，而是**"逐字→逐行→逐字，随时来回振荡"**，并疑为性能问题。本文上半部分的 granularity-一次性升级是一个真实机制、但**不是他看到的主症**。

**真根（代码坐实）**：`applyFetchedLyricsIfCurrent`（LyricsService:~1366）apply 到显示**只守 songID、不比已显示内容质量/粒度**。前台词级显示后，≤9s 的显示 backfill 与**时长校正重取**（MusicController:1252/1299）会**无条件整份替换** self.lyrics 成那一轮竞速结果——某轮 NetEase 超时则 LRCLIB 行级胜出→逐字掉逐行；下轮又逐字。调试日志实证同曲一会话取 2-4 次。这与 >3s 违规同根（发布后那条慢且会改显示的尾巴），详见 [3s 方案页](t2-3s-budget-plan-2026-08-25.md)。

**已修（P1，提交 02eaf3f，创始人经主会话批准）**：① `applyFetchedLyricsIfCurrent` 发布后冻结显示（已有内容则不替换，结果仍缓存供下次）；② 稳定性闸扩展为"内容在屏即不重取同曲"。默认发布后连 line→word 也不升级（零闪）。全测 902/0。手感终验归创始人（新终验构建含 P1）。P2（3s 窗收编 backfill）待诊断数据 + 翻译取舍。
