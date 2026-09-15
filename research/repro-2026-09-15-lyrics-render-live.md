# 歌词渲染缺陷复现（2026-09-15，真机日志 + LOCAL_DEVELOPER_BUILD + git 考古）

范围：创始人肉眼对照 v0.29（277cd5b）与阶段包 3（20878d0/2e72a71）后确认，重影、前奏三点、
滚动后位移三条缺陷 **v0.29 就有**——根因早于 9 月改动，需要往 5-7 月渲染器重写找。本轮追加
两条：手动滚动后点击跳行遮罩丢失（新）、整行全亮无遮罩（复现回归）。另有一条独立的真机紧急
报告：疯狂掉帧+闪屏，CPU 35%（空闲门应 0.5%），本轮已单独给出结论（见文末）。

真机证据来源：
- `research/nanopod_debug_2026-09-14.log`（创始人 20:43–22:58 真机会话原始调试日志，只读，从
  `/tmp/nanopod_debug.log` 复制，16:23:45–23:01:59 全量，7 个 tag 家族 3 万余行）
- 本轮用 `NANOPOD_EXTRA_SWIFT_FLAGS="-Xswiftc -DLOCAL_DEVELOPER_BUILD" ./build_app.sh` 重建的
  LOCAL_DEVELOPER_BUILD 版驱动真实 Music.app + nanoPod.app 做的补充复现（无人值守，静音跑，
  跑完恢复；未用 computer use，未截图/录屏，遵创始人 09-14 裁定）
- git 考古子代理（只读）对 `Sources/MusicMiniPlayerCore/UI/` 223 个 commit（v0.28..HEAD）的
  `git log -S` + `git blame` 追踪

---

## 缺陷 1：强调词重影 —— 09-14 挖空修复本身正确；重影仍在，最新线索是 CALayer shadow

**代码证据（已跑测试，绿）**：`test_emphasisWord_midSweep_brightLayerAlreadyNil_notASecondGhostSource`
（`Tests/MusicMiniPlayerTests/LyricsRenderDefects20260914ReproTests.swift`）证伪了本轮第一个假设
——以为 `mainBrightTextLayer`（`emphasisGlyphLayers` 挂载其上的那层）在 sweep 扫过强调词后仍会
画一份未挖空的静态副本。实测：生产默认臂（`NativeLyricsFeelParity.sweepPathMode == .v28`，
核对过创始人真机 container plist 没有 `nanoPodFeelSweep` 覆盖，走的就是默认值）下，
`applyActiveMainPhase` 在 `geometryReady` 分支无条件把 `mainBrightTextLayer.string` 置 nil——
v2.8 Canvas 模型的亮字完全靠逐词/逐字 tile 画，这条通路上根本没有第二份墨迹。已加只读探针
`debugMainBrightTextLayerIsWordHidden`（镜像已有的 `debugMainTextLayerIsWordHidden`）把这个
证伪钉死，避免下一轮重复踩同一个假设。

**最新线索（git 考古，未验证）**：`applyEmphasisGlyph`（`NativeLyricsRowView.swift:2681` 附近）
在 `expected.glowOpacity > 0` 时设置 `layer.shadowColor/.shadowOpacity/.shadowRadius`——真实
CALayer 阴影/发光，是一条独立于挖空修复的合成器效果。这套发光机制的架构可追溯到 `ef280b5`
「Add native lyrics text render plan」+ `48c2747`「Drive native lyric text sweep with layer
phases」（均 2026-05-30，`NativeLyricsEmphasisPlan` 里 `scale/liftY/floatY/glowOpacity` 同源），
`4bbbc66`「refactor(lyrics): split native row renderer」（2026-07-06）搬进现在的文件形状。
09-14 的挖空修复（`ce19929`/`a1f81b2`）连同它自己的测试套件（`NativeLyricsSweepGhostTests`/
`NativeLyricsEmphasisPartitionTests`）全部只量 Δy（几何位置），从未断言过
`shadowOpacity`/`shadowRadius`——`CALayer.render(in:)`（本仓库所有 headless PNG 用的方法）不保证
真实还原阴影合成（跟 banned-patterns.md 已记录的 CIFilter 模糊盲区同类），所以这条路径目前只能
在真机上核实，headless 测不出来。

**一眼判断问题（给创始人）**：播一首英文逐字歌，唱到一个较长的强调词（比如 "about"）中段时，
那个词周围是不是能看到一圈发光/模糊的光晕，光晕内部隐约有第二层轮廓（不是清晰的双影错位，
而是"发光造成的重叠感"）？如果是，跟之前报的"T 在右下偏移露出"是同一种视觉,还是不同——如果
不同,说明这条线索也不对,需要真机层树 dump 才能继续。

---

## 缺陷 2：前奏三点位置——创始人带截图第三次澄清：不是"不出现"，是钉在面板左上角，没走激活行锚定

创始人最新描述：冷启动进前奏，三点出现在约 `y=25px`（贴顶），而第一句歌词在 `y≈290px`；期望
三点跟激活行一样用 `anchor y=42` 那条线定位、跟歌词同一左边缘。此前两轮的横向居中修复
（`fca3ef2`，已被 `20878d0` 撤回）和"三条入口路径"分析都是围绕 X 轴/相位时钟,没有专门查过
Y 轴锚定这条。

**未完成**：本轮没能在真机日志里直接读到前奏行/三点容器的 `frame.origin.y`——`LineGaps` 探针
（`logLineGapsProbe`）只在 `activeTextLineChanged` 后武装、且只描述 `activeIndex-2...+3` 范围内
"已经在播的"行，冷启动瞬间前套行是否被这条探针覆盖、以及它读到的 y 值是多少，没有直接证据
（同上一轮"This Time"复现里发现的现象一致：冷启动后 17s 才出现第一条 `ActiveBrightness`，索引
直接是 1 不是 0——见下方"关联线索"）。

**关联线索（真机日志，`research/nanopod_debug_2026-09-14.log` 交叉引用 + 本轮 LOCAL_DEVELOPER_BUILD
补充跑）**：`This Time` by Jeff Bernat，`21:11:00` 歌词 Applied（`firstReal="Honestly"`），第一条
`ActiveBrightness`/`LineGaps` 直到 `21:11:17`（17 秒后）才出现，且 `idx=1`——这意味着 idx=0（应为
前奏/prelude 行）从未在这条"进入激活态后 1.0-1.2s 记一次"的探针里被记录到。两种解释：(a) idx=0
真的被激活过,但停留时间 <1s,探针的"下一次 activeTextLineChanged 就重新武装、丢弃前一次挂起
的 log"设计吞掉了它(这样不算 bug,是探针本身的采样盲区);(b) 呈现循环/定位系统在冷启动最初
这段时间根本没有正常驱动到 idx=0,直到 ~17s 后第一次真正落地在 idx=1——这与创始人截图描述的
"整页模糊暗态、没有激活行"完全吻合。本轮无法用现有探针在两者之间判定,需要新埋点(建议:在
`layoutDotContainer`/`updateSurfaceInterludeDots` 里加一行只读日志,记录前奏/间奏三点容器的
`frame.origin.y` 和 `anchorY` 之差,武装方式仿照 `NanoPodMaskTraceEnabled`)。

**git 考古（确认，只读）**：前奏/间奏三点纠缠四套实现，非创始人原话猜测的"浮层/每行/blend/ila"，
而是——`interludeAfterIndex`（`0e777bb`，2026-04-18，旧 SwiftUI 引擎）、`interludeBlend`
（`0ca37a6`，同日）、逐行 `dotContainerLayer`（`18acfe7`，2026-05-31，原生渲染器自己的实现，
落地时没有删掉上面两个旧概念）、浮层 `surfaceInterludeDots`（`abd3c0f`，2026-06-07，"separate
interlude dots from row" ——把点从行里拆出来做独立浮层，但 `18acfe7` 的逐行实现从未真正删除,
只是被部分抑制)。项目 memory（`lyrics_dots_interlude_saga.md`）已经点出：`dotContainerLayer`
本意只服务前奏,但对间奏行也会触发(`isHidden = row.interlude == nil`)且从未针对间奏正确布局
(collapse 到原点),`surfaceInterludeDots` 独立算间隙中心——两套系统按入口路径(冷启动/seek/
手动滚动)决定谁"赢",这正是创始人反复看到"同一个前奏、不同入口不同表现"的结构性原因。三点的
Y 轴锚定问题(本节新增)很可能是这两套里至少一套没有走"跟激活行同一个 accumulatedHeights/anchor
公式"的又一个症状,但本轮没有把 Y 轴这条也钉到具体是哪一套。

**一眼判断问题**：冷启动播一首带明显前奏的歌,三点第一次出现时,是贴着面板顶部(不管歌词滚不
滚动,固定在同一个高处),还是出现在"当前激活行该在的那条横线"上(跟随后第一句歌词落地的位置
基本一致)?

---

## 缺陷 3：手动滚动结束后 1-2px 二次跳变 —— 与缺陷 6(自然切行后像素位移)同源,均未独立复现

见下方缺陷 6 的机制分析(`4ec5596` blur economy / `isSettled` 光栅化)。本轮没有单独针对"手动
滚动刚结束、行从 0.6/0.95 档恢复到 1.0 档"这条路径专门复现——`NativeLyricsDimBaseContinuityTests`
已经钉死手动滚动期间的 0.6 档,但没有测"恢复瞬间之后 1-2 秒"这段。按创始人最新第 4 条澄清,
这条很可能和"播完一行、切到下一行后,上一行又挪 1-2px"是同一机制(行的 opacity/scale
spring 结算后触发的光栅化快照瞬间,产生亚像素级二次调整)——但两条触发路径(用户手动滚动 vs
自然播放切行)不同,不能不加验证就合并成一条。

**一眼判断问题**：手动滚动歌词、松手后等它回弹稳定,盯着某一行看——回弹"停"下来大约 1 秒之后,
这一行是不是又无声地挪了 1-2 像素(不是回弹本身的运动,是回弹已经看起来停了以后的第二次、
更小的移动)?

---

## 缺陷 4（新）：手动滚动后点击跳到前面几行——跳回去的行没有遮罩/不高亮，只剩逐字浮动

**代码级假设（未做 headless 验证，本轮未完成）**：`handleLineTap`（`LyricsLayerRendererView.swift`
约 3480-3508 行）在 `manualScrollState.isActive` 时立刻 `manualScrollState.reset()` +
`semanticSpringRetarget(to: rowIndex, ...)`——这两步只管"视觉上把行springs到新位置"，是同步、
立即生效的。但整行的"是否算激活/是否高亮"读的是另一条独立通路：`nativeHotActiveIndices`/
`nativeBufferedActiveIndices`（由 `synchronizeNativeSemanticIndex` 根据真实播放时钟算出"谁在
唱"）。`onLineTap?(line)` 触发的是外部 seek（经 MusicController → ScriptingBridge/AppleScript），
这条链路有真实、非零的往返延迟——真机日志里同一会话的 `[Timing]` tag 记过 `sbRead=552.5ms`、
`sbRead=1109.4ms` 这类量级。如果 seek 落地前 `nativeHotActiveIndices` 还锁在"点击前音乐正在唱的
那一行"，跳回去的目标行在这段窗口内会呈现"位置对了、但没有被判定为当前激活行"的状态——跟
创始人描述完全吻合。这跟 09-14 报告里"未完全坐实"的那个悬而未决的假设（"我还没有确认
`nativeHotActiveIndices`/`nativeBufferedActiveIndices` 这条通路在手动滚动激活时是否也读了冻结
索引，还是仍然按原始播放时钟计算"）是**同一个缺口**，当时只针对"手动滚动冻结在前奏"验证过，
没有针对"手动滚动后点击跳行"验证。

**未完成**：本轮没能写出 headless 复现（真 surface：播到第 10 行→手动滚→点第 3 行→断言第 3 行
mask/opacity/sweep 进度）——时间不够，留作下一步，方法已经明确。

**一眼判断问题**：手动滚动歌词到前面几行的时候，直接点一行——跳过去以后，那一行是不是只有
文字在轻微浮动（逐字动画在动），但整行看起来还是"没在唱"的暗色，不像正常激活行那样变亮？

---

## 缺陷 5：整行全亮无遮罩 —— 创始人再次真机复现；四层排除法仍未 headless 复现；新增一条机制线索

沿用 09-14 报告的结论（四层排除：锁步假时钟、真 CVDisplayLink+真墙钟播满整曲、针对性零间隔
切行种子点、生产同款 ScriptingBridge 轮询抖动——均 0 次命中）。本轮 git 考古补了机制：

**根因（考古，只读）**：`c4dcd02`「Improve native lyrics UX telemetry and gates」（2026-05-30）
引入 per-run sweep mask 系统本身自带一个静默的整行渐变兜底——当前代码（`NativeLyricsRowView.swift`
~1732-1750）：`updatePerRunSweepMask` 返回 `applied: false`（`NativeLyricsTextSweepLayout.maskLines`
算出空结果，或 `bounds.width/height <= 1`）时，直接退回 `mainBrightTextLayer.mask =
mainSweepMaskLayer`——一整块横跨全行的渐变遮罩，由 `plan.mainSweepProgress` 单值驱动，这正是
"整行一起亮"的外观。`488c0a3`「几何未就绪时藏亮层，避免切行整行高亮」（2026-08-27）已经堵了
一个触发点（`geometryReady == false` 时藏亮层），但那只覆盖"刚挂载/复用的冷几何"这一种；
创始人这次是在快节奏逐字歌上复现——geometry 应该已经 ready，触发点更可能是 `maskLines(...)`
本身在快歌的密集音节/词时间戳下退化返回空（尚未验证）。`488c0a3` 自己的测试
（`NativeLyricsMaskExhaustiveHandoffTests`）枚举了 appear 窗/自然切行/远跳/中段 seek，没有覆盖
"geometry 已就绪但 maskLines 本身退化"这个分支。

**一眼判断问题**：播一首很快的逐字歌（音节间隔很短那种），留意某一行是不是会突然整行一起变亮
（不是从左到右扫过去，是一下子全亮），然后马上恢复正常的逐字扫描？

---

## 缺陷 6：自然切行后，刚变为非激活的那一行又挪 1-2px —— LineGaps 粗粒度探针无法干净隔离；给出机制线索 + 诚实局限

**尝试过的方法（失败，如实报告）**：用 `research/nanopod_debug_2026-09-14.log` 的 `LineGaps`
序列（209 条，20:43-22:58 窗口）做"相邻两次探针里同一物理行 y 的相对位移应当处处一致"检验
（脚本：见下），结果 192/208 次比较都"不一致"——但排查后发现这是**测量方法本身的缺陷**，不是
证据：`LineGaps` 只在每次 `activeTextLineChanged` 后武装、延迟 1.0-1.2s 记一次，而激活行本身
在 `s=` 字段里从 0.95（非激活）跳到 1.00（激活）或反过来——即激活/非激活切换本身就会改变那一
行的"渲染高度"（代码：`scale != 1` 时 `height = frame.height * scale`），所以任何跨越一次行
激活切换的两个探针之间，行间距天然不是刚性平移。这条粗粒度、一次一采样的探针**结构上**无法把
"1-3 秒后的二次跳变"从"激活态切换本身带来的正常间距变化"里分离出来——如实报告为方法局限，
不是"没找到证据"。

**机制线索（git 考古，未做像素级验证）**：`4ec5596`「fix(lyrics): stop presentation loop on
paused panel + renderer batch」（2026-07-10）同一个 diff 里捆了 `applyRasterizationPolicy
(isSettled:isActive:)`/`rasterizationEligible`/`shouldRasterize`（`-S` 全仓库精确一次命中，
即模糊经济光栅化系统的引入点）。行从激活转为非激活时，`isSettled`（弹簧 opacity/scale/blur
同时收敛到很紧的阈值内）翻真的那一刻，`refreshRasterization()` 把该行 `shouldRasterize=true`
并设置 `rasterizationScale`——对该行做一次"从实时合成切到位图快照"的硬切换。banned-patterns.md
已经记录过同类问题的姊妹案例（"STATE-DEPENDENT alpha baked into text while row-layer opacity
spring-animates"）,但那条修复（`NativeLyricsDimBaseContinuityTests`）明确只覆盖**激活**瞬间的
连续性，没有对称的**去激活结算**瞬间（即光栅化快照那一刻）的连续性测试。1-3 秒的时间量级和
"临界阻尼弹簧收敛到 isSettled 的严苛阈值"在数量级上吻合。

**未完成**：没能在本轮把这个假设做成 headless 确定性时钟复现（需要：真 surface、一行从激活到
非激活、逐帧采样 `frame.minY` 覆盖 settle 前后 3 秒、寻找 `shouldRasterize` 翻转帧前后是否有
独立于弹簧运动本身的二次跳变）——方法已经明确，是下一步的第一件事。

**一眼判断问题**：正常播放（不用手动滚动），留意刚唱完、变成上一行的那一句——它已经完成"往上
挪、变暗"这个动作、看起来彻底停下来之后，是不是隔了大概 1-3 秒又无声地挪了 1-2 像素？

---

## 紧急插入：真机报「疯狂掉帧+闪屏、CPU 35%（空闲门应 0.5%）」—— 渲染侧结论

范围限定：本节只管渲染侧（presentation loop/relayout），歌词管线每 6 秒重抓换源那条由另一路
核实,不在这里。

**结论：`b12db38`（"correct accumulatedHeights in the same configure() cycle"，Symptom 3 修复）
是更可能的元凶；`20878d0`（撤回三点水平居中）是纯粹的 position.x 公式替换，读代码确认干净，
不太可能是元凶。**

**b12db38 的机制**（`LyricsLayerRendererView.swift`，`reconcileVisibleRowViews` 内新增块）：
在内容测量循环后，用渲染器自己的 `measuredHeightsByIndex` 重算一份 `accumulatedHeights`，跟
`runtimeConfiguration.accumulatedHeights`（**外部传入、来自 SwiftUI 侧 `LyricsView` 自己的高度
缓存，按设计要经过两跳 `DispatchQueue.main.async` 才能追上**）比较；`heightsActuallyChanged`
为真时，**在 `configure()` 本来就有的一次 `presentationEngine.update(...)` 之外，额外再调一次**
`presentationEngine.update(...)`，其 `onTargetsChanged` 回调无条件 `self?.startPresentationLoop()`
——不经过 `stopPresentationLoopIfIdle` 的任何否决逻辑。`configure()`/`updateNSView` 由 SwiftUI
在 `MusicController` 的播放位置更新（插值、非静态）驱动，正常播放期间调用频率远高于"仅在换行
边界"；而外部 SwiftUI 高度缓存要两跳异步才能追上渲染器自己的即时测量值——这意味着这条比较
在很多个连续的 `configure()` 周期里都可能持续读到"不相等"（不是只触发一次），每次都重新给
presentation engine 的弹簧喂一个（哪怕只有亚像素级差异的）新目标。若目标持续被重新设定，弹簧
永远达不到 `isSettled`，`presentationEngine.hasActiveMotion` 长期为真——这正是空闲门
（`NativeLyricsLoopIdleDecision.shouldKeepPresentationLoopRunning`）唯一会一直判定"不该停"的
输入，与"CPU 常驻高位、空闲门形同虚设"的症状直接对应。`startPresentationLoop()` 本身对已运行
的 loop 是空操作（`guard displayLink == nil else { return }`），所以不是"重复启动"本身费电，
是**弹簧目标被这条新增比较持续重新打乱、永不收敛**这件事本身费电+可能引起可见的亚像素抖动
（"闪屏"的一种可能来源）。

**20878d0 的机制**：纯 `CALayer.position` 赋值公式替换（`frame.midX` → `frame.minX +
totalWidth/2`），发生在已有调用点内，没有新增定时器/每帧钩子/状态机分支；两个改动文件
（`LyricsLayerRendererView.swift`/`NativeLyricsRowView.swift`）的 diff 都是完整对称的撤回，
没有半状态残留。读代码没有找到任何会导致每帧重新布局的路径。

**建议的最小验证/回退方向（未实施，仅供创始人 A/B 参考）**：把 b12db38 新增的
`presentationEngine.update(...)` 调用也套上 `heightsActuallyChanged` 判断之外的第二重门槛——
例如要求 `refreshedAccumulatedHeights` 与`上一次`已经喂给 engine 的高度做比较（而不是跟结构性
必然滞后的外部 SwiftUI 缓存比较），或者给这次额外 update 加一个"同一 configure 周期最多补发一次
弹簧目标"的节流。这只是方向，不是已验证的修法——按"先复现再修"，需要创始人确认要不要现在就动手。

---

## 附：LineGaps 交叉检验脚本（缺陷 6 尝试，方法本身有缺陷，见上文说明）

`analyze_linegaps.py`（scratchpad，未提交到仓库）：解析 `research/nanopod_debug_2026-09-14.log`
里 209 条 `LineGaps` 记录，比较相邻探针中共同出现的行 y 差值是否一致——发现的"不一致"绝大多数
可用激活行 `scale 0.95↔1.00` 变化解释，不能当作缺陷 6 的证据，如上文诚实说明。
