# C1 贴边形变设计：card ↔ pill Liquid Glass morph（2026-09-12）

裁定范围：创始人已选选项 (a)——`SnappablePanel` 的吸附引擎与 frame 弹簧原样保留，只在 CONTENT 层加 Liquid Glass card↔pill morph + 材质淡入淡出。否决方向不在本文档内讨论：灵动岛式多形态贴附、菜单栏歌词。

---

## 1. 状态模型：`EdgePresentation`

```swift
public enum EdgePresentation: Equatable {
    case card            // 正常/贴边前
    case hidingToPill     // hideToEdge 触发 → 恢复前的过渡态
    case pill            // isEdgeHidden == true 且未 peek
    case peeking         // isEdgePeeking == true
    case restoringToCard // restoreFromEdge 触发 → card 落定前
}
```

推导源：`SnappablePanel.isEdgeHidden`（`SnappablePanel.swift:45`，`private(set) public var`，已经是 public 只读）与私有 `isEdgePeeking`（`SnappablePanel.swift:400`，当前完全私有，SwiftUI 侧不可见）。`hidingToPill`/`restoringToCard` 是新增的「过渡中」态，跨越 frame 弹簧的 settling 窗口（`Spring(duration:0.5, bounce:0.15)`，见 `SnappablePanel.swift:466-470`）。

发布位置：**不新增 ObservableObject**，理由是 `SnappablePanel` 是 `NSPanel` 子类而非 SwiftUI 视图模型，现有跨层桥接方式已经是闭包回调（`onEdgeHiddenChanged`，`SnappablePanel.swift:18`），不是 Combine/Observation。沿用同一模式：`MusicController`（已是 `@EnvironmentObject`，见 `MiniPlayerView.swift:7`）新增一个 `@Published var edgePresentation: EdgePresentation`，由 AppKit 侧的窗口 delegate/管理代码（`MusicMiniPlayerApp.swift`，创建 `SnappablePanel` 处）把新增回调接到这个 `@Published` 字段上。SwiftUI 通过已经在用的 `@EnvironmentObject var musicController` 观察它，零轮询——这与 `currentPage`（同文件同一个 `MusicController` 上的 `@Published`，`MiniPlayerView.swift:75,82` 已经在读）是完全同构的机制，不引入新的观察路径。

## 2. Pill 内容与分层（避免 glass-on-glass）

6pt 常驻露边（`edgeHiddenVisibleWidth = 6`，`SnappablePanel.swift:13`）、30pt hover 探出（`peekAmount = 30`，`SnappablePanel.swift:401`）。Pill 内容：一个贴合露边宽度的竖直胶囊，内容为**封面缩略图 + 一条细的播放进度竖线**；`peeking` 态胶囊变宽，露出 play/pause 按钮。内容必须够「轻」才配得上玻璃——缩略图+进度线+一个按钮，不塞文字。

分层规则（同一时刻只允许一种材质）：`PanelBackdrop` 的 `.base` 角色（`PanelBackdrop.swift:33,55-59`）在 `.pill`/`.peeking`/`.hidingToPill`/`.restoringToCard` 期间渲染 `Color.clear`（仿照现有 `.pageOverlay` 在 glass 臂下渲染 `Color.clear` 让出材质的先例，`PanelBackdrop.swift:58-59`），玻璃材质改由 pill 自己的 `glassEffect` 承载；`.card` 态下 `.base` 照常渲染（fluid 或 glass 由 `PanelBackdropStyle` 决定，`PanelBackdrop.swift:16-26`，与 edgeMorph 臂正交）。card 本体保持不透明 fluid，不套 `glassEffect`——只有 pill 允许玻璃，这样任意时刻至多一层材质。

## 3. 视图层级：`GlassEffectContainer` + `glassEffectID`

新增 `EdgeMorphHost` 视图，挂在 `MiniPlayerView.mainBody` 的 `ZStack` 内（`MiniPlayerView.swift:60` 起的 `ZStack`，与 `PanelBackdrop`/`WindowDraggableView` 同级）。

```swift
GlassEffectContainer(spacing: 40) {
    if showsCardGlass { cardGlassContent.glassEffectID("panelBody", in: morphNS) }
    if showsPillGlass { pillContent.glassEffectID("panelBody", in: morphNS) }
}
```

单一 `Namespace` `morphNS`（新增，独立于 `MiniPlayerView` 已有的 `animation` 命名空间——那个是给 `matchedGeometryEffect` 用的跨页 hero image，不应混用）。增删发生在 `withAnimation` 内，由 `edgePresentation` 变化驱动（`onChange(of: musicController.edgePresentation)`，写法同现有 `onChange(of: musicController.currentPage)`，`MiniPlayerView.swift:245`）。`GlassEffectTransition`：默认 `.matchedGeometry`（官方文档默认过渡，`research/liquid-glass-animation-map-2026-09.md:9`）——两个视图共享同一个 `glassEffectID` 时容器内本就是身份延续而非独立淡入淡出，不需要 `.materialize`。

## 4. 三时钟映射与 Tokens

现状只有几何通道（`NSPanel.setFrameOrigin` 弹簧，`SnappablePanel.swift:466-470,521-535`），SwiftUI 内容层完全不知道这个动画在跑。需要新增一个 hook 把 AppKit 帧动画的**开始时刻**通知给 SwiftUI，而不改动弹簧数学本身：

- **发现的 hook**：`onEdgeHiddenChanged`（`SnappablePanel.swift:18`，`hideToEdge`/`restoreFromEdge` 调用处 `SnappablePanel.swift:374,395`）已在动画启动后同步触发，可以作为「几何动画已经开始」的信号，但它是在 `startSpringAnimation()`（`:371`）之后才 fire，且不带时间戳。
- **需要新增的最小 hook**：一个 `public var onGeometryMorphWillStart: ((EdgePresentation, CFTimeInterval) -> Void)?`，在 `launchAnimation()`（`SnappablePanel.swift:477`）设置 `animStartTime = CACurrentMediaTime()`（`:481`）**之前**调用一次，把即将开始的目标态（hidingToPill/restoringToCard/peeking 对应态）和 `CACurrentMediaTime()` 传出去。不改 `renderFrame()`/`currentSpring` 任何数学。

三个时钟用独立 `withAnimation` 调度，起点相对 `onGeometryMorphWillStart` 回调的时刻 t0：

| 时钟 | 起点（相对 t0） | 时长/曲线 | Token 名（`MicroInteractionFeel.Tokens` 新增） | 值 |
|---|---|---|---|---|
| 几何（AppKit frame 弹簧，不变） | t0（回调即时） | 现有 `Spring(duration:0.5, bounce:0.15)`，不改 | — | — |
| 内容 pre-seed（pill 缩略图淡入） | t0 − 20ms（提前量，需要在 `onGeometryMorphWillStart` fire 前预调度，见下） | `withAnimation(.easeOut(duration: edgeMorphContentLagMax))` | `edgeMorphPreSeedLead` | `0.02`（20ms） |
| 内容主体（card↔pill 身份切换） | t0 + 20~80ms 之间取值 | `withAnimation(.smooth(duration: ...))` | `edgeMorphContentLagMin` / `edgeMorphContentLagMax` | `0.02` / `0.08` |
| 材质（`glassEffect` 透明度收敛） | t0 + `edgeMorphContentLagMin` | `withAnimation(.smooth(duration: edgeMorphMaterialSettle))` | `edgeMorphMaterialSettle` | `0.31`（270–350ms 区间取中值） |

pre-seed 提前 20ms 这件事在纯回调模型下无法真正「提前」于 t0（回调本身就是 t0），可行做法是把 pre-seed 调度成「hover/手势判定出隐藏意图那一刻」就起播、而不是等 `startSpringAnimation()`——即在 `checkAndHideToEdgeWithVelocity` 判定为 true 之后立即回调（比 `hideToEdge` 内部真正调用 `startSpringAnimation()` 早一步），这样自然拿到 ~20ms 的提前量而不需要编造时间戳倒退。三个数值全部写进 `MicroInteractionFeel.Tokens`（`MicroInteractionFeel.swift:185-200` 已有的同一个 enum 里追加，不新建结构），使用处只读 token 不复述数值，遵守文件头注释「不在调用点复述数值」的约定（`MicroInteractionFeel.swift:182-184`）。

## 5. 圆角连续性

card 圆角与 pill 胶囊圆角共享同一条连续曲线：card 用 `.clipShape(.rect(cornerRadius: 16, style: .continuous))`（现状 `MiniPlayerView.swift:122` 已是 `RoundedRectangle(cornerRadius: 16, style: .continuous)`，等价 API，二者均在 official.md 已见列表——`RoundedRectangle(cornerRadius:style:)` 是标准 SwiftUI Shape API，非 Liquid Glass 专属，不需要标注 [未验证]）；pill 用同一个 `.continuous` 曲线家族的 `Capsule(style: .continuous)`。two shapes 的连续性靠 morph 期间半径插值——`glassEffectID` 身份延续动画下，`GlassEffectTransition` 的 `.matchedGeometry` 负责形状插值本身（官方端点原文，`research/liquid-glass-animation-map-2026-09.md:9`），设计侧只需保证两端形状声明都用 `.continuous` corner style，不需要手写插值器覆盖这条路径；仅当验证发现容器不插值圆角（需 Xcode 26 实机截图确认，[未验证]）时才退回手写 `NativeLyricsRowScale`-类型的纯函数插值器。

## 6. Reduce Motion

AppKit 侧现状**零读取**（`research/liquid-glass-animation-map-2026-09.md:13,178` 已确认 `SnappablePanel.swift` 未见任何 `NSWorkspace.accessibilityDisplayShouldReduceMotion`）。新增：`SnappablePanel` 在 `hideToEdge`/`restoreFromEdge`/`peekFromEdge`/`hideBackToEdge`（`:354,377,422,436`）四处调用前查一次 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`，为真时跳过弹簧插值，直接 `setFrameOrigin(animationTarget)`（等价于 `renderFrame()` 里 `t >= settlingDuration` 分支，`:531-534`）——geometry 通道瞬切。SwiftUI 侧内容层用现有的 `@Environment(\.accessibilityReduceMotion)`（`MiniPlayerView.swift:8` 已声明）：HIG 允许 reduce motion 时仍做交叉淡入（reduce motion ≠ 无过渡），所以内容/材质两个通道保留 crossfade，只是把三个 `withAnimation` 换成 `.linear(duration: 0.1)`（与本文件其余各处 reduceMotion 三元式完全一致的写法，例如 `MiniPlayerView.swift:86,93,159-160`），不是砍成硬切。

## 7. 对照臂 `.v0`

`v0` 臂：`showsCardGlass`/`showsPillGlass` 逻辑短路为「pill 内容永不挂载 `GlassEffectContainer`」，`EdgeMorphHost` 整体不渲染，`PanelBackdrop.base` 照常渲染（不切 `Color.clear`）——即今天的行为，字节级不变，因为 `EdgeMorphHost` 是新增视图、v0 分支直接跳过它的 body，不触碰任何现有 `PanelBackdrop`/`SnappablePanel` 调用路径。仿照 `NativeLyricsFeelParity.appearWindowMode`/`MicroInteractionFeel.windowPresent` 同一套 `resolve(from:)` fallback 模式（`NativeLyricsFeelParity.swift:23-31`、`MicroInteractionFeel.swift:62-70`）：新增 `EdgeMorphMode { case v0, morph }`，`resolve(from raw:)` 缺省/未知值一律回落 `.morph`（因为这是「默认新行为」型 channel，与 `NativeLyricsFeelParity` 里 `current` 默认的惯例一致，而不是 `MicroInteractionFeel` 里各别 legacy 默认的惯例——这里选 `.morph` 默认是遵照任务给定的「default `.morph`, legacy `.v0`」）。

## 8. 验证：提取的纯函数与测试

- `EdgeMorphClockScheduler`：纯函数，输入 `t0: CFTimeInterval`，输出三元组 `(preSeedStart, contentStart, materialStart, materialDuration)`；测试镜像 `NativeLyricsFeelParityTests` 的量化表写法——给定 t0 断言三个绝对时间戳与 token 值一致。
- `EdgePresentationReducer`：纯函数 `reduce(current: EdgePresentation, event: SnapEvent) -> EdgePresentation`（`SnapEvent` = hideRequested/restoreRequested/peekEntered/peekExited/settled），测试覆盖表格式穷举所有 `(current, event)` 合法与非法组合，仿照 `NativeLyricsMaskExhaustiveHandoffTests` 的穷举风格。
- `EdgeMorphReduceMotionTable`：纯函数 `shouldAnimateGeometry(reduceMotion:) -> Bool` / `contentAnimation(reduceMotion:) -> Animation`，测试仿照 `WindowPresentPolicyTests`（若存在；否则新建，镜像 `WindowPresentPolicy.resolve` 的测试写法，`MicroInteractionFeel.swift:206-212`）。
- `EdgeMorphMode.resolve` 钳制表：仿照 `PanelBackdropStyleTests`（未知/缺省值必须回落）——未知 raw string 必须回落 `.morph`。
- 圆角插值器：仅在第 5 节验证发现容器不自动插值时才需要，暂不预先写。
- DEBUG 日志：每个时钟起点打一行 `[EdgeMorph] t=<CACurrentMediaTime> clock=<geometry|preSeed|content|material> state=<EdgePresentation> token=<name=value>`，格式对齐现有 `DebugLogger` 用法（其余渲染器时间戳日志同一格式家族），供创始人手感终验留证据。

## 9. 文件改动与三次提交拆分

1. **hook + state**（可独立编译验证）：`SnappablePanel.swift`（新增 `onGeometryMorphWillStart` 闭包 + 四处 reduce-motion 判断 + `checkAndHideToEdgeWithVelocity`/`peekFromEdge` 等处提前触发点）、`MusicController`（新增 `@Published var edgePresentation`）、`MusicMiniPlayerApp.swift`（接线回调到 `edgePresentation`）、新文件 `EdgePresentationReducer.swift`（纯函数 + `EdgePresentation` 定义）。
2. **pill + container + 对照臂**（依赖 1）：新文件 `EdgeMorphHost.swift`（pill 内容视图、`GlassEffectContainer`/`glassEffectID`）、`PanelBackdrop.swift`（pill 态下 `.base` 让位 `Color.clear` 的分支）、`MiniPlayerView.swift`（挂载 `EdgeMorphHost`）、新文件 `EdgeMorphFeel.swift`（`EdgeMorphMode` 注册表，模式仿 `NativeLyricsFeelParity.swift`）。
3. **时钟 + 测试**（依赖 1、2）：`MicroInteractionFeel.swift`（新增 4 个 token）、新文件 `EdgeMorphClockScheduler.swift`（纯调度函数）、DEBUG 日志埋点、新测试文件 `EdgeMorphClockSchedulerTests.swift`/`EdgePresentationReducerTests.swift`/`EdgeMorphFeelTests.swift`。

## 10. 未决风险

- **性能**：`CLAUDE.md` 模糊经济教训——静态玻璃层每帧被合成器重求值代价高于 app 自身 CPU；pill 常驻在 frame 弹簧移动期间若玻璃层未 settle 就一直重算，需要复用「settled 行光栅化」同款思路（`applyRasterizationPolicy` 模式，见 `Sources/MusicMiniPlayerCore/UI/NativeLyricsRowView.swift` 现有实现）评估是否也要给 pill 的 `NSGlassEffectView` 做类似阶跃处理；未做验证前不能假设代价可忽略。
- **`PanelBackdrop` 玻璃臂交互**：pill 态下 `.base` 让位 `Color.clear` 这条新分支只覆盖 glass 臂；fluid 臂（默认）下 `.base` 本来就不是玻璃，pill 玻璃与 fluid card 不构成 glass-on-glass，但需要确认 fluid 臂下 card↔pill 交界处是否有视觉割裂（两种材质家族拼接），未做视觉验证。
- **hover 探测在 morph 过程中**：`handleMouseMoved`（`SnappablePanel.swift:403-420`）用 `frame.contains(NSEvent.mouseLocation)` 判定 peek 进出，frame 在几何动画中连续变化，如果 pill 内容层的可点击区域与不断变化的 window frame 不同步，可能出现 hover 判定与视觉胶囊位置脱节的一帧；需要在实现阶段用确定性时钟测试覆盖「几何动画进行中收到 mouseMoved」这一交叉场景，本设计只标出风险点，不预先给出修复方案。
