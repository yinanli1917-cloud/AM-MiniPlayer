# Progress-bar hover-intent — 2026-09-25

## 创始人报告

播放进度条鼠标 hover 上去会变粗（7pt → 12pt）；鼠标快速掠过它也会变粗一下，太容易误触。问业界有没有成熟解法。

## 结论：hover-intent 模式（dwell + low velocity gate），不是 CSS 式固定延迟

进入判定不能只是「鼠标进入命中区就变粗」，也不该是「进入后固定延迟 N 毫秒就变粗而不管这段时间内鼠标在干什么」——后者会让一次跨越式掠过（正好卡在延迟窗口末尾）也触发。业界的标准解法（hover intent）是把「鼠标是否已经慢下来 / 停住」也计入判定，不是单纯计时器。

## 调研来源（均已直接抓取原文/源码，非转述）

1. **Brian Cherne, hoverIntent jQuery 插件**（业界这个问题最经典的参考实现，被大量下拉菜单/mega menu 沿用十余年）
   源码：https://raw.githubusercontent.com/briancherne/jquery-hoverIntent/master/jquery.hoverIntent.js
   项目页：https://briancherne.github.io/jquery-hoverIntent/
   默认参数（源码 `_cfg` 对象实测）：`interval: 100`（轮询间隔，毫秒）、`sensitivity: 6`（像素）、`timeout: 0`（离开延迟，默认关闭）。
   算法：`track()` 记录每次 mousemove 的坐标；`compare()` 每隔 `interval` 轮询一次，算本次与上次坐标的欧氏距离 `√((pX−cX)²+(pY−cY)²)`；小于 `sensitivity` 判定「已经慢下来」→ 触发 `over`；否则更新基准坐标、再等一个 `interval` 继续比。核心思想：**用「移动距离/单位时间」判定意图，不是单纯的入场计时器**。

2. **NN/g, "Timing Guidelines for Exposing Hidden Content"**
   https://www.nngroup.com/articles/timing-exposing-content/
   原文实测抓取要点：显示前建议等待 **0.3–0.5 秒**（鼠标停留/暂停后）再展开隐藏内容——「Revealing hidden content too quickly on mouseover can result in accidental activations」；已展开的内容在鼠标离开后应再保留约 **0.5 秒**才收起，避免误判为「不想要了」；可交互的视觉反馈（如 hover 高亮）应在 **0.1 秒**内出现，以保持响应感。

3. **Jakob Nielsen, "Response Times: The 3 Important Limits"**
   https://www.nngroup.com/articles/response-times-3-important-limits/
   三档阈值：**0.1 秒**——用户感觉「系统瞬时响应」的上限，2014 年补充版特别举例「直接操纵（direct manipulation）UI 对象」（如表格列选中即刻高亮）就是卡在这一档；**1.0 秒**——思路不被打断的上限；**10 秒**——注意力极限。

4. **CSS Working Group，"Add hover/focus/long-press triggering delays to CSS" 讨论（2024）**
   https://lists.w3.org/Archives/Public/public-css-archive/2024Aug/0537.html
   说明这仍是 CSS 平台原生缺失的能力（"tooltips are typically implemented with delays to avoid very noisy UI"），业界目前只能靠 JS/宿主层自己实现 hover-intent，讨论也明确「focus 应该即时触发，hover 才需要延迟」——与本次方案对「直接操作 vs 被动 hover」区别对待的取舍一致。

5. 二手信息，未独立核实原文（不作为参数依据，仅作背景）：Baymard 的调研称约六成站点缺少下拉菜单的 hover 延迟（数值同样落在 300–500ms）；Apple Finder 的 spring-loading（拖拽悬停展开文件夹）延迟可在系统设置里调 0–1 秒（`defaults write -g com.apple.springing.delay`），是苹果自己产品里「悬停停留判定意图」的先例，但屏蔽的是「拖拽悬停」而非「纯 hover」，不直接取数;YouTube/Spotify 桌面端的进度条 hover 变粗时机未找到官方公开规格，仅有零散社区讨论，不作为数据来源。Apple HIG 搜索工具对 "hover"/"pointer"/"feedback" 关键词均无命中——HIG 在这个粒度上没有公开的精确数值指引。

## 算法选型：为什么不是 hoverIntent 原版的轮询

hoverIntent 用固定 `interval` 轮询（哪怕鼠标不动也每 100ms 比对一次，直到判定或离开），本质是「只要 hover 着就有一个常驻定时器链」。创始人明确要求零空闲成本、禁止常驻轮询定时器，只许「进入命中区后挂一个一次性 DispatchWorkItem/Timer，离开即取消」。

改用事件驱动的等价实现：
- 进入命中区：以当前指针为锚点，武装一个一次性定时器，到期即视为「已停留够久」。
- 命中区内移动（`.mouseMoved`）：只有当离锚点的距离超过容差（`movementTolerance`）才判定为「仍在移动」，取消旧定时器、以新位置/新到期时间重新武装；容差内的小抖动（手部微颤、高轮询率鼠标噪声）不重置。
- 这与轮询版在语义上等价（都是「移动量低于阈值才算意图」），但定时器只在真正需要「等待意图确认」的时段存在，命中区外、已确认（committed）、已放弃（idle）时都没有定时器——满足零空闲成本。

## 参数取值与理由

| 参数 | 值 | 理由 |
|---|---|---|
| `progressHoverIntentDwellDuration`（停留才判定为意图） | **150ms** | 必须明显盖过掠过耗时（测试基准约 30ms 穿越整条 14pt 高的命中区），同时明显低于 NN/g 揭示型内容的 300–500ms——进度条变粗是原地小反馈（更接近按钮 hover 高亮），不是揭示新内容，应该更快。定在 Nielsen「0.1 秒瞬时」阈值之上一点，让「真的停顿了」读成一次刻意、快速的确认，而不是彻底无感的即时反应（即时就无法过滤掠过）。 |
| `progressHoverIntentMovementTolerance`（容差，不重置计时） | **4pt** | 参照 hoverIntent 默认 sensitivity 6–7px，但本实现按「每次超阈值移动」而非「固定 100ms 采样窗口」判定，且目标是一条 14pt 高的窄带，收紧到 4pt。 |
| `progressHoverIntentExitGrace`（已变粗后，离开命中区到真正变细的宽限） | **80ms** | 只保护「已经可见变粗」的状态，不保护「还没显示任何东西」的 pending 态（后者没有可见变化可言，退出应立即复位）。定在 Nielsen ~100ms「瞬时感」阈值之下，因此收起在感知上仍然是「立即」的；远小于 NN/g 隐藏内容的 ~500ms 建议，因为那条建议是给「鼠标需要跨越空白区域才能到达展开面板」的场景（如 mega menu）用的，本场景不存在这个「跨越」——只是命中区边缘的普通抖动缓冲。 |

## 直接操作永不延迟

`mouseDown`（拖动 seek）无论在哪个状态下都立即变粗、绕过整个意图判定——这对应 Nielsen 「direct manipulation 应落在 0.1 秒瞬时档」的原则：按下即所见即所得，不能有感知延迟。

## 实现 / 测试

见 `Sources/MusicMiniPlayerCore/UI/Components/SharedControls.swift`（`ProgressHoverIntentEngine`，纯 reducer：`(state, event, now, config) -> (state, effect)`）与 `Sources/MusicMiniPlayerCore/UI/MicroInteractionFeel.swift`（`progressHoverIntent` A/B 臂 + `Tokens.progressHoverIntent*`）。测试：`Tests/MusicMiniPlayerTests/ProgressHoverIntentEngineTests.swift`（纯状态机全分支）、`Tests/MusicMiniPlayerTests/ProgressHoverIntentViewTests.swift`（真实 NSView + 合成 NSEvent 集成层）。

### 开发过程中抓到的一个真 bug

集成测试 `test_subToleranceJitter_stillThickensOnSchedule` 最初失败：容差内的小幅移动本该「什么都不做」，但视图层的 `applyHoverIntent` 无条件地在每次调用开头 `cancel()` 已排定的定时器，导致「什么都不做」的抖动事件把刚刚进入时武装的停留定时器取消掉，停留判定永远等不到。根因是把两种不同语义的「没有可见变化」混成了同一个 `Effect.none`：一种是「什么都别碰，包括定时器」（抖动），另一种是「必须取消定时器，只是没有可见变化」（从 pending 状态直接离开命中区）。修复：拆成 `.none` 与 `.cancelTimer` 两个独立 effect，逐条重新核对每个状态转移该用哪一个。过程见对应 commit。
