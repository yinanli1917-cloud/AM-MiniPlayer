# nanoPod 动效实现规格：设置页演示台 + 引导「完成一步」

配套原型：同目录 `prototype.html`（单文件，A、B 两节，深浅色，手机宽度可看）。本文所有数字都能在原型代码里找到对应，原型是这份规格的可运行版本。作者：动效设计会话，2026-09-29。只出原型与规格，未改 `Sources/`、`Tests/`。

## 0. 结论先行

1. 设置页的演示台照系统设置「触控板」页重排：窗口顶部居中一块 **16:9 圆角矩形**演示台（候选 280×158 / **300×169 推荐** / 320×180），自带壁纸式背景；悬停一行，这一行先亮，停满 150 ms 才切演示；离开后演完当前一轮，落在静息帧停。一次只有一段在动。
2. 演示动画的节奏以触控板录屏为准：主运动 **0.9 s 缓入缓出、无过冲**，动作之间停 0.7–1.4 s。
3. 引导「完成一步」做成 **7 状态的状态机**：预备 → 画勾 → 环长 → 火花 → 安定 → 交接（最后一步换成 合圈 → 礼花）。环的进度是一个可重定向的弹簧，被打断时速度不断、不回头。
4. 触觉建议：勾落下那一刻 `.levelChange` 一次，合圈 `.alignment` 一次。声音不加。
5. 「减少动态效果」下：演示台只显示静帧；打勾动画只留线性填充、淡入淡出与触觉。

原型里有两处与 09-25 稿不同，需要创始人知道（详见 §C）：演示台高 120 → 140；演示动画用系统触控板的节奏，不用面板自己的弹簧。

---

## A. 设置页：演示台

### A.1 排版与尺寸

窗口内容仍是 480 × 562（含标题栏 28）。创始人 09-29 定：演示区保留一整块，但不必撑满两边，做成居中、比例规整的圆角矩形。竖向布局（上到下）：

| 部件 | 尺寸 | 备注 |
|---|---|---|
| 上边距 | 24 | 左右、下边距 20 |
| 演示台 stage | **居中**，16:9 圆角矩形，圆角 12；候选 280×158 / 300×169 / 320×180，**默认 300×169** | 圆角取 12 = 下面分组卡片的圆角，两块卡片同一个半径；窗口内边距 20、窗口圆角 14，视觉上外大内小 |
| 间距 | 18 | |
| 分段控件 | 440 × 24，选中段强调色 | 面板 · 通用 · 快捷键 · 关于 |
| 间距 | 18 | |
| 分组行区 | 440 × 剩余高度（300×169 时 289；280×158 时 300；320×180 时 278），下边距 20 | 两行文字的行 53，只有标题的行 44（无说明的开关行、录制框行、按钮行）；标题 13、说明 11 |
| 开关 | 36 × 20，圆钮 16 | 触控板页的开关外观 |

三个候选的取舍：

| 尺寸 | 行区高度 | 「通用」段 6 行（4 行单行 44 + 2 行 53 = 282）能否放下 | 评价 |
|---|---|---|---|
| 280×158 | 300 | 放得下，脚注（约 16）也放得下（298 ≤ 300） | 最紧凑；场景缩到 0.875×，键帽 30、歌词 13 pt，仍可读，但面板显小 |
| **300×169（推荐）** | 289 | 放得下行（282 ≤ 289）；脚注放不下，需把「nanoPod 通过自动化读取…」并进对应行的说明或行区外的一行小字里 | 视觉重量与下面 4 行分组卡片最协调；场景 0.9375×，几乎原尺寸；宽度 300 = 分组卡片宽 440 的 68 %，接近黄金比 |
| 320×180 | 278 | 放不下（282 > 278），「通用」段要滚动 | 最舒展，但把行区压得最紧 |

推荐 300×169 的理由：唯一同时满足「场景不缩小到失真」和「6 行通用段不滚动」的尺寸（脚注挪位是可接受的小代价）。「面板」「快捷键」两段行少，窗口下部留 60–100 的空白，与系统设置里触控板页下方的留白同类，不需要用拉高行距去填。

每段场景都画在一张 **320×180 的底图**上，再整体等比缩放到所选尺寸（缩放 = 台宽 / 320），所以三个尺寸看到的是同一构图；台左下角保留一块 170×24 的安全区放说明胶囊（行名 + 状态），场景元素不进入这块区域。

演示台背景（不是纯色）：`RadialGradient`（左上冷光）+ `RadialGradient`（右下暖光）+ `LinearGradient(160°)`，三层叠成一张安静壁纸。

| 项 | 浅色 | 深色 |
|---|---|---|
| 底色 A → B | `#E2E8F7` → `#F3E4EE` | `#1F2340` → `#2E2040` |
| 左上光 | `#CFDCFF` | `#34427F` |
| 右下光 | `#FFD6E2` | `#5B2C4B` |
| 玻璃（胶囊、菜单栏条） | `rgba(255,255,255,.86)` | `rgba(48,48,54,.86)` |

为什么是壁纸：面板、胶囊、键帽在冷色底上才不会和 Apple Music 粉抢色；粉色只留给「正在发生的那件事」（贴边光、按键光圈、开关）。

### A.2 行与演示台的对应

| 状态 | 表现 |
|---|---|
| 指针进入行 | 行底色立刻变深（`--card-hover`，同触控板页悬停灰），0.12 s；此时演示台不变 |
| 指针停满 150 ms | 演示台切换到这一行的演示（A.4） |
| 指针离开行 | 悬停底色撤掉；这一行保留半档浅色底（`active`），说明台上现在是哪一行 |
| 台左下角 | 11 pt 次要色写行名，后接一个小胶囊写状态（开 / 关 / 当前语言 / 已录快捷键）；随演示交叉淡入淡出 |
| 拨动开关 | 不论有没有悬停：台上回放一次到新状态，然后停在静息帧 |
| 键盘焦点进入行 | 立即切换（无 150 ms 等待） |

### A.3 悬停意图

复用 `SharedControls.swift` 的 `ProgressHoverIntentEngine`：指针停留 **150 ms**，期间移动累计不超过 **4 pt**，才算「停住」；按鼠标事件判定，不定时采样。路过的行不切演示、不启动任何东西。原型里用 `pointerenter / pointermove / pointerleave` 与一个 150 ms 定时器复现，已用合成事件验证三种情形：快速路过（60 ms）不触发；停满触发；停留中移动超过 4 px 则重新计时。

### A.4 切换演示与「同一时间只动一段」

- 台上有前后两层。新演示在后层建好、`opacity 0→1`（0.28 s ease-in-out），前层同时 `1→0`。**淡出的那一层立刻冻结**在当前帧（不再走时钟），淡出结束后销毁。任何时刻最多一个时钟在走。
- 同一行再次悬停：如果它正在循环，什么都不做；如果已停在静息帧，原地从头循环，不做交叉淡入淡出。
- 离开行后的收尾：不硬停。运行器算出下一个「静息帧」的时刻 `stopAt = 下一个满足 t ≡ restT (mod loop) 的时刻`，走到就停，并把画面定在静息帧。静息帧由开关状态决定（开 = 效果完成态，关 = 初始态）。
- 没有悬停、没有开关回放时：演示台是静态视图，**不挂** `TimelineView`、不占合成。窗口 `orderOut` 或被遮挡（`NSWindow.didChangeOcclusionStateNotification`）时暂停时钟。
- 原型的自动轮播（顶栏开关）只用于给人看，不进产品。

### A.5 节奏总则（来自触控板录屏）

出处：`docs/design/2026-09-25-onboarding/research/trackpad-demo-frames.md`。

| 量 | 值 | SwiftUI |
|---|---|---|
| 主运动时长 | 0.9 s（录屏 0.92–1.02） | `.timingCurve(0.42, 0, 0.58, 1, duration: 0.9)` |
| 主运动缓动 | 缓入缓出，无过冲 | 同上；在 `KeyframeTrack` 里用 `CubicKeyframe(_, duration:)`，起止速度都取 0，与该贝塞尔视觉上一致 |
| 出现 / 消失 | 纯 `opacity`，0.28–0.42 s，不缩放 | `.easeOut(duration: 0.3)`（消失用 `.timingCurve(0.2, 0.8, 0.2, 1, duration:)`） |
| 动作之间的停顿 | 0.7–1.4 s | 见各演示时间线 |
| 单次循环 | 5–8.4 s | |
| 装饰 | 无箭头、无残影、无常驻呼吸 | |
| 录屏里的「末帧瞬时贴合」小毛病 | 不复刻 | |

物理弹簧只用于**按键的物理反馈**（键帽 120 ms 下压）与开关旋钮；演示里所有位移都是缓入缓出，才和系统页一个气质。

调色（浅 / 深）：强调色 `#FA4058` / `#FB546C`（`Color("AccentColor")`；用户选了具体强调色时，演示台高亮跟 `Color.accentColor`）。面板 fluid 渐变固定：左上 `#FF9AA8`，右下 `#7D6CFF`，底 `#B9508F`；封面小图：天空 `#FFD58F → #FF7F8F → #6B5BD6` 自上而下，落日 `#FFF1D0`，海面 `#5A4BC4 → #2F2A85`。这些是示意色，不是真实封面。

### A.6 逐段演示

约定：`panelW` 是演示里的面板宽度，`em` 指 `panelW`（面板高 = 1.136 em，比例 250 : 284）；时间 `t` 是这一段的循环时钟，单位秒；`io` = 缓入缓出（A.5），`out` = `cubic-bezier(.2,.8,.2,1)`；`bump(t, t0, d)` = 在 `[t0, t0+d]` 内取 `sin(π·(t−t0)/d)`，其余为 0。每段都实现成一个纯函数 `render(t) -> DemoFrame`（无副作用，可用假时钟逐帧断言）。

#### A.6.1 全屏封面（`cover`，循环 6.2 s）

面板 `panelW = 110`，水平居中（左 105、上 30，底图 320×180 坐标，下同）。状态变量 `s ∈ [0,1]`：

| t (s) | 事件 | 曲线 |
|---|---|---|
| 0 – 0.9 | 静息，`s = 0`（封面留边） | |
| 0.9 – 1.8 | `s: 0 → 1` | io，0.9 s |
| 1.8 – 3.9 | 停，`s = 1`（铺满面板宽） | |
| 3.9 – 4.8 | `s: 1 → 0` | io，0.9 s |
| 4.8 – 6.2 | 停 | |

由 `s` 派生（单位 em）：封面边长 `lerp(0.68, 1.0, s)`；封面左 `(1−边长)/2`；封面上 `lerp(0.075, 0, s)`；封面圆角 `lerp(0.04, 0, s)`；暗渐变（scrim，底部 0.62 em 高）不透明度 `s`；标题条 top `lerp(0.885, 0.79, s)`、艺人条 `lerp(0.94, 0.845, s)`、控制行 `lerp(1.0, 0.915, s)`。铺满时封面阴影去掉。

- 开关回放（once）：开 = 播 `t ∈ [0.7, 2.7]`；关 = 播 `t ∈ [3.7, 5.4]`。
- 静息帧：开 `t = 2.7`，关 `t = 0.3`。
- SwiftUI：一个 `KeyframeAnimator(initialValue: CoverFrame(s: 0), trigger: token)` 两条轨道 `[LinearKeyframe(0, 0.9), CubicKeyframe(1, duration: 0.9), LinearKeyframe(1, 2.1), CubicKeyframe(0, duration: 0.9), LinearKeyframe(0, 1.4)]`；或用统一的 `DemoClock` 调纯函数（推荐，见 A.8）。

#### A.6.2 贴边收起与换歌探出（`peek`，循环 8.4 s）

台 = 一块屏幕；右缘是屏幕边；顶部 10 pt 菜单栏条（右侧三个小图标，最右一个是粉色 ♪ 点）。面板 `panelW = 104`，左 170、上 24。变量：

| 变量 | 事件 |
|---|---|
| `tuck` | 0.7 → 1（io 0.92 s）；6.7 → 0（io 0.92 s） |
| `cp`（胶囊） | 2.4 → 1（io 0.8 s）；5.7 → 0（io 0.8 s）。**探出停留 2.5 s（3.2 → 5.7）= LiquidEdge autoPeek 真实时长** |
| `pulse` | `bump(t, 2.3, 1.0)`：换歌那一刻贴边条亮一下 |

派生：

- 面板 `translateX = tuck × 170`（面板朝右滑出屏幕；170 > 320 − 170，保证滑出后完全在台外），`opacity = 1 − io(clamp((tuck − 0.55)/0.45))`。
- 贴边条：5 × 40，圆角 3，贴右缘、垂直居中（上 70）；`opacity = strip = io(clamp((tuck − 0.5)/0.5))`，`translateX = (1 − strip) × 5`；粉色进度光高度：换歌前 62 %，换歌后重置为 8 % 并以 1.5 %/s 走；`pulse` 时光晕 `shadow(radius: 12·pulse, spread: 3·pulse, color: accent · 0.55·pulse)`。
- 胶囊：156 × 46，圆角 23，右缘留 12，垂直居中；内含 32 × 32 圆角 9 缩略封面 + 两条文字条；`translateX = (1 − cp) × 190`，`opacity = clamp(3·cp)`。
- 关（不探出）：`cp` 恒 0，其余不变，只有贴边条亮一下。
- 开关回放：开 `t ∈ [1.9, 5.9]`（含胶囊探出）；关 `t ∈ [1.9, 3.6]`。静息帧：开 `t = 5.0`（胶囊在），关 `t = 3.4`（只有贴边条）。
- 「贴边隐藏」快捷键行（`hideEdge`，循环 7.0 s）用同一套零件：键帽按下（0.9、3.9，`bump` 0.34 s）→ `tuck` 1.05 → 1（io 0.92），4.05 → 0（io 0.92）；没有胶囊。

#### A.6.3 显示翻译（`trans`，循环 6.0 s）

镜头拉近：面板 `panelW = 214` 居中（左 53）、上 10，高度裁到台底（相当于放大的截图，只露出歌词区）。歌词（自编示例句，非真实歌词）：

- 上一行 `Down by the water`（`opacity .42`，top 6）；当前行 top 30；后两行 top 66 / 94（基准位置，译文出现时再下移 20）
- 当前行 `Let’s go see the sea`（白，semibold，字号 = `0.07 × panelW` ≈ 15）
- 下一行 `Just you, just me`、再下一行 `Let the tide decide`（`.42`）
- 译文 `我们去看海吧`（字号 0.88 ×，`opacity .78`）

变量 `s`：1.1 → 1（out 0.55 s）；4.2 → 0（out 0.5 s）。派生：译文 `opacity = s`、`offsetY = −3·(1−s)`、`blur = 1.6·(1−s)`；后两行整体 `translateY = 20·s`（给译文让位，行距变化用同一条曲线，不另起弹簧）。

- 开关回放：开 `[0.7, 2.6]`，关 `[3.9, 5.4]`。静息帧：开 `2.6`，关 `0.3`。
- 「翻译为」行（`transTo`，循环 6.8 s）：译文常显，每 1.7 s 换一种语言：我们去看海吧 / 海を見に行こう / 바다 보러 가자 / Allons voir la mer；换语言的前 0.3 s（`u = (t mod 1.7)/1.7 ≤ 0.18`）新旧译文交叉淡入淡出（io）。用户在 Picker 里选定某语言时，台上回放一次并停在该语言。

#### A.6.4 显示 / 隐藏面板快捷键（`showhide`，循环 6.6 s）

台 = 屏幕 + 一扇半透明的背景窗口（140 × 100，左 160、上 30，三个红黄绿点 + 几条灰线），用来证明面板是浮在别的窗口之上的。面板 `panelW = 92`，左 184、上 26。键帽三枚 34 × 34、圆角 9、间距 6，左 24、上 76（三枚合宽 126，止于 150，不碰背景窗口），内容取用户录的组合（原型：⌥ ⌘ P；未录则一个虚线空键帽）。

| t (s) | 事件 | 曲线 |
|---|---|---|
| 0 – 0.9 | 面板可见 | |
| 0.9 – 1.24 | 键帽按下：`d = bump(t, 0.9, 0.34)`；键帽 `translateY = 3·d`、`scale = 1 − 0.05·d`、底部阴影 `3 − 2.5·d`、外圈强调色光环 `2·d` pt（`rgba(accent, 0.8·d)`） | 半个正弦，≈120 ms 落 + 220 ms 起 |
| 1.0 – 1.32 | 面板淡出：`opacity 1 → 0`，`scale 1 → 0.955` | out，0.32 s（对应 `MicroInteractionFeel.Tokens.windowFadeOutDuration` 量级） |
| 1.32 – 3.4 | 面板隐藏 | |
| 3.4 – 3.74 | 键帽再按下 | 同上 |
| 3.5 – 3.92 | 面板淡入：`opacity 0 → 1`，`scale 0.955 → 1` | out，0.42 s |
| 3.92 – 6.6 | 面板可见 | |

- 开关回放：无开关（录制框行），悬停 / 焦点触发循环；录制新组合后台上回放 `t ∈ [0.6, 2.5]` 一次。
- 静息帧：`t = 0.3`（面板可见，键帽未按）。

### A.7 SwiftUI 结构

```swift
enum SettingsDemo: CaseIterable { case cover, peek, translation, translateTo, showHide, hideEdge /* + 通用段 */ 
    var loop: Double        // 秒
    var once: (on: ClosedRange<Double>, off: ClosedRange<Double>)
    func restTime(on: Bool) -> Double
    func frame(at t: Double, options: DemoOptions) -> DemoFrame   // 纯函数
}
struct DemoStage: View {          // 默认 300×169；内部画在 320×180 底图上再 scaleEffect(width / 320)
    let demo: SettingsDemo; let mode: DemoMode // .still | .loop | .once(on:)
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        if reduceMotion || mode == .still { DemoCanvas(frame: demo.frame(at: demo.restTime(on:), options:)) }
        else { TimelineView(.animation) { ctx in DemoCanvas(frame: demo.frame(at: clock.time(ctx.date), options:)) } }
    }
}
```

- 每段演示是 `frame(at:)` 纯函数 + 一个只画不算的 `DemoCanvas`（`Canvas` 或 `ZStack`）。推荐用 `TimelineView(.animation)` 驱动纯函数，而不用 `PhaseAnimator`：纯函数可用假时钟逐帧断言，和「switch 回放一段区间」「离开后走到静息帧」这两件事天然吻合。
- 如果一定要用声明式 API：每个 `s` / `tuck` / `cp` 变量对应一个 `KeyframeTrack`，轨道值如 A.6 表；`KeyframeAnimator(initialValue:trigger:)` 的 `trigger` 用递增 token（悬停期间每轮结束 +1）。开关回放要从循环的中间开始，`KeyframeAnimator` 做不到，此时改用把两段区间拆成两个独立 keyframes 的 `enum Phase`。
- 交叉淡入淡出：`ZStack { ForEach(layers) { $0.opacity(...) } }`，前层 `.animation(.easeInOut(duration: 0.28), value: activeID)`；被淡出的层用 `.transaction { $0.animation = nil }` 冻结其内容（`TimelineView(paused: true)`）。
- 全部由 `RoundedRectangle` / `Capsule` / `Text` / `Image(systemName:)` 构成；无位图、无第三方。

### A.8 Reduce Motion

读 `@Environment(\.accessibilityReduceMotion)`（监听 `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`）：

- 不挂 `TimelineView` / `KeyframeAnimator` / `PhaseAnimator`，直接画 `restTime(on:)` 那一帧。
- 悬停只换静帧，无交叉淡入淡出（`Transaction(animation: nil)`）；台左下角的说明文字照样更新。
- 开关切换：静帧直接换成新状态。
- 静帧的选取：开 = 效果完成态（封面铺满 / 胶囊探出 / 译文显示 / 面板可见），关 = 初始态。

### A.9 通用段两行（原型未画，参数留给实现）

沿用同一节奏：登录时启动 = 屏幕从暗到亮（0.4 s）+ 菜单栏 ♪ 点 `scale 0.6 → 1`（io 0.5 s）；在 Dock 显示 = 底部 Dock 胶囊 4 块灰块，nanoPod 块从上方落入并把邻块挤开（io 0.9 s），关时反向。

### A.10 验收（代码层）

1. 假时钟驱动 `ProgressHoverIntentEngine`：停留 149 ms 不切，150 ms 切；期间累计移动 4.1 pt 重新计时。
2. `DemoStage` 任何时刻只有一个活动时钟（计数断言）；淡出层的时钟已停。
3. `frame(at:)` 对每段在 `restTime` 的帧与设计稿数值相等；`t` 与 `t + loop` 帧完全相同（循环无缝）。
4. Reduce Motion 注入为真：`DemoStage` 的 body 不含 `TimelineView`（`Mirror`）。
5. 离开行后：运行器在 `stopAt` 停止；`stopAt` 满足 `(stopAt − restT) mod loop == 0`。
6. 手感（缓动、停顿是否舒服）由创始人亲自终验。

---

## B. 引导里「完成一步」的打勾动画

### B.1 零件与静态规格

| 零件 | 规格 |
|---|---|
| 进度环 | 外径 28、线宽 5.5、连续粗环、圆头；`Circle().trim(from: 0, to: p/7).stroke(style: StrokeStyle(lineWidth: 5.5, lineCap: .round)).rotationEffect(.degrees(-90))`；路径半径 `(28 − 5.5)/2 = 11.25`；轨道 = 强调色 22 %（深色 30 %）；7 步各占 1/7 |
| 环内数字 | 9.5 pt bold，等宽数字，显示「当前是第几步」 |
| 环内勾 | 路径 `M8.6 14.3 L12.2 17.7 L19.2 10`（28 × 28 坐标），线宽 2.6、圆头圆角、强调色；用 `trim(from: 0, to: draw)` 画出 |
| beat 点 | 14 × 14 圆，未完成 = 1.5 pt 描边（`#3C3C43` 30 %）；完成 = 强调色实心 + 白勾（路径 `M4 7.3 L6.3 9.5 L10.2 4.8`，线宽 1.9） |
| 环在不同进度 | 原型下方一排：已完成 0 / 1 / 3 / 5 / 6 步与合圈（实心 + 白勾）。零长度弧用 `opacity 0` 隐藏（否则圆头会画出一个点） |
| 高光彗星 | 环长的过程中，弧头后面拖一小段白色 55 % 弧（描边 3），长度和不透明度随环的速度变化：`len = C/7·0.55·clamp(v/2.4)`、`alpha = clamp(0.32·v, 0, 0.55)`，`v` = 环进度弹簧的速度（步/秒）；停下即消失 |

数值出处：09-25 引导方案 §8 与 `storyboard.html`（环外径 28、线宽 5.5、beat 点 14）。

### B.2 状态机（普通一步）

记 `T0` = 最后一个待勾 beat 的起始时刻（一步里还有 n 个 beat 没勾时，第 i 个 beat 相隔 70 ms 依次勾，`T0 = 70 ms × (n−1)`）；下表时间都是相对 `T0`。总长 ≈ 1.1 s 到下一张卡就位。

| # | 状态 | 起止 (ms) | 哪些属性在变 | 曲线 / 弹簧 | 衔接 |
|---|---|---|---|---|---|
| 0 | `idle` | — | 全部静息 | | 检测到完成（`completeStep()`）→ 1 |
| 1 | `anticipate` 预备 | 0 – 60 | 环整体 `scale 1 → 0.95`；环内数字 `opacity 1 → 0.6`；最后一个 beat 点 `scale 1 → 0.88` | 各 0.06 s，`out` | 60 ms 到 → 2 |
| 2 | `draw` 画勾 | 60 – 320 | 该 beat 点（与状态 1 同时刻起算）：填充圆半径 0 → 6.9（0.14 s，`out`）；勾 `trim 0 → 1`（0.26 s，`out`）；点 `scale 0.88 → 1.22`（0.09 s，`out`）再弹回 1；beat 文字变次要色 0.2 s（勾一落下就开始）。**触觉 `.levelChange` 在 60 ms** | 回弹：`Spring(duration: 0.30, bounce: 0.42)`，在 150 ms 触发 | 与 3 同时开始 |
| 3 | `grow` 环长 | 60 – 660 | 环进度 `p → p+1`（一格 = 1/7 圈）；线宽 `5.5 → 6.5`（0.15 s，`out`）；环整体 `scale → 1.07`（0.18 s，`out`），240 ms 处弹回 1；彗星高光随速度出现 | 进度：`Spring(duration: 0.6, bounce: 0)`（可重定向）；回弹：`Spring(duration: 0.45, bounce: 0.35)` | 340 ms 起并行进入 4 |
| 3a | 数字 → 勾 | 340 – 700 | 数字 `opacity → 0`、`scale → 0.5`（0.14 s，`in`）；环内勾 `trim 0 → 1`（0.28 s，`out`，延迟 80 ms）；勾容器 `scale 0.6 → 1.15`（0.16 s）→ 1 | 回弹：`Spring(duration: 0.32, bounce: 0.45)`，在 260 ms 触发 | |
| 4 | `sparks` 火花 | 380 – 930 | 从**弧头当前位置**喷 16 粒（连击每级 +4，最多 28）+ 一圈冲击波 | 见 B.5 | 不阻塞；寿命到即销毁 |
| 5 | `settle` 安定 | 660 – 860 | 线宽 `6.5 → 5.5`（0.2 s，`out`） | | 660 ms → 6 前的 100 ms 是「让人看清」的停顿 |
| 6 | `handoff` 交接 | 760 – 1100 | 见下 | | 结束 → 回 `idle`，`busy = false` |

`handoff` 展开：

1. 卡内容（标题、正文、beat 列表）`opacity 1 → 0`，0.14 s，`in`（`.easeIn`）。
2. 0.14 s 后换内容；环内勾 `scale → 0.7` 退场、数字换成下一步的数字：`opacity 0 → 1`、`scale 0.8 → 1`、`offsetY 6 → 0`，0.22 s，`out`（`.contentTransition(.numericText())` 的手写等价）。
3. 新内容三块依次 `opacity 0 → 1` + `offsetY 6 → 0`，每块 0.18 s，`out`，错峰 40 ms。
4. 卡的位移（跟随下一个锚点）不在本原型内，规格沿用 09-25 稿：`Spring(response: 0.5, dampingFraction: 0.86)`，速度连续。

只勾 beat（不是整步完成）时只做状态 1–2 中 beat 点的部分与触觉，不长环、不喷火花。

### B.3 最后一步（合圈）

`anticipate`、`draw`、`grow` 与普通步相同（环目标 = 7/7）；差异如下，时间相对 `T0`：

| 状态 | 起止 (ms) | 变化 | 曲线 / 弹簧 |
|---|---|---|---|
| `grow` | 60 – 660 | 数字 → 勾推迟到 500 ms | 同上 |
| `seal` 合圈 | 600 – 950 | **触觉 `.alignment` 在 600 ms**；环整体 `scale 1.08 → 1`；线宽 `5.5 → 7 → 5.5`（0.12 s + 0.22 s）；描边叠一层白色闪光 `opacity 1 → 0`（0.35 s，`out`） | 回弹 `Spring(duration: 0.5, bounce: 0.38)` |
| 填实 | 640 – 1000 | 环心圆盘半径 `0 → 11.25`（强调色实心）；环内勾变白 | `Spring(duration: 0.4, bounce: 0.25)` |
| `confetti` 礼花 | 680 – 2500 | 72 粒（B.5）；两圈冲击波（第二圈延迟 120 ms）；卡整体 `offsetY −4 → 0` | 卡：`Spring(duration: 0.4, bounce: 0.3)` |
| `settle` + 换终页内容 | 1050 – 1500 | 同 `handoff`，内容换成「都认识了」；环保持实心 + 勾 | 同 handoff |

翻译步被延后（09-25 稿 §8.2）时：环停在 6/7，不合圈不填实；礼花照放。这条路径原型未演，规格不变。

### B.4 打断规则（连点、完成中再完成）

原则：**视觉可以合并，进度永远单调，速度不断。**

1. 进度环用一个可重定向的弹簧 `ring: Val`。新的完成到来时只改目标（`target += 1`），弹簧从当前位置、当前速度继续走。SwiftUI 里等价于对同一个 `@State var ringProgress` 再调一次 `withAnimation(.spring(duration: 0.6, bounce: 0)) { ringProgress = new }`（SwiftUI 的弹簧动画在中途被覆盖时保持速度连续）。原型实测三连点：环单调不减，逐帧最大跳变 0.109 步，回退 0 次。
2. 上一次完成里**还没发生的 cue** 立刻快进：
   - 状态类 cue（勾画完、beat 变色、内容交接、进度目标）无动画地执行到位；
   - 装饰类 cue（火花、冲击波、礼花）**丢弃**，不补放；
   - 线宽 / 整体缩放弹簧回到静息值（线宽 0.1 s，缩放 `Spring(duration: 0.3, bounce: 0)`）。
3. 然后按正常流程启动新一次完成。连击计数 `combo`：两次完成间隔 < 4 s 则 `+1`（上限 3），火花 `16 + 4·combo` 粒。
4. 最后一步的合圈序列**不可被打断**（`B.finished` 之前忽略新的完成）。
5. 检测器回退（用户撤销）：忽略。完成是单调的。
6. 卡被关闭 / 用户点「以后再说」/ 窗口被遮挡：立刻快进到终态（同 2 的「状态类 cue」），不放装饰。
7. 中途切换「减少动态效果」：立刻快进当前序列，之后按降级规格走。
8. 慢放 0.25×（原型开关）只缩放时间，不改变任何顺序或参数，用于评审。

### B.5 粒子（Canvas）

绘制：一个 `TimelineView(.animation(minimumInterval: 1/60, paused: particles.isEmpty && halos.isEmpty))` 内放一个 `Canvas`，覆盖在卡片上方的透明子窗口（沿用 09-25 稿的礼花窗口，火花也画在同一个窗口里）。粒子清空即 `paused = true`，窗口 2.2 s 后关闭。

| 项 | 火花 | 礼花 |
|---|---|---|
| 数量 | 16（+4 每级连击，最多 28） | 72 |
| 起点 | 环当前弧头位置 `center + 11.25·(cos θ, sin θ)`，`θ = −90° + 360°·p/7` | 卡上沿，水平在卡宽 ±60 pt 内随机 |
| 初速 | 90–140 pt/s，方向 = 弧头径向 ± 约 85° | 220–320 pt/s，向上，锥角 ±30° |
| 阻尼 | 每帧 ×0.88（`pow(0.88, dt·60)`） | 每帧 ×0.985；重力 360 pt/s² |
| 大小 / 形状 | 圆点，半径 2–3.5 pt，随寿命缩到 50 % | 6 × 9 矩形 / 圆 / 细条三形，自旋 ±2.5 rad/s |
| 颜色 | 强调色 50 %、浅粉 `#FF8FA0` 25 %、金 `#FFB93F`（深色 `#FFC65A`）25 % | 强调色、金、紫 `#7A6BFF`（深 `#8F82FF`）、青 `#7FD6C2`、浅粉、白（09-25 稿建议取封面主色 3 个，无法取色时用这组） |
| 寿命 | 0.55 s，`alpha = 1 − easeIn(age/life)` | 1.8 s，末 0.5 s 线性淡出 |
| 冲击波 | 环心圆描边 1.5 pt，半径 `14 → 30`（out，0.5 s），`alpha 0.5 → 0`；礼花时叠两圈，第二圈延迟 120 ms | |

火花的颜色没有用白：浅色卡片是白底，白火花看不见。

### B.6 SwiftUI 映射

**不要用 `PhaseAnimator` 做主体。** 它在 `trigger` 变化时从头走 phase，不能在中途以当前速度接续，无法满足 B.4。建议：

```swift
@Observable final class CompletionChoreographer {
    enum Phase { case idle, anticipate, draw, grow, sparks, settle, handoff, seal, confetti }
    var ringProgress: Double = 0          // 单位：步；弹簧驱动
    var ringScale = 1.0, ringWidth = 5.5, numberOpacity = 1.0, checkDraw = 0.0, discRadius = 0.0 ...
    private var cues: [Cue] = []          // (fireAt: TimeInterval, essential: Bool, body: () -> Void)
    func complete()  { if busy { flushEssential() }; schedule(for: step) }
    private func flushEssential() { /* 状态类 cue 用 Transaction(animation: nil) 立即执行；装饰类丢弃 */ }
}
```

- `Cue` 由一个注入的 `Clock`（假时钟可推进）驱动；每个 cue 里用 `withAnimation(.spring(duration:bounce:))` 或 `.timingCurve(...)` 改上面的 `@Observable` 属性。这样整套序列是**确定性可回放**的，可以写单元测试。
- 环：`Circle().trim(from: 0, to: min(1, ringProgress/7))`，`.animation` 不加在 view 上，由 `withAnimation` 显式驱动（保证重定向速度连续）。
- 环内勾、beat 勾：`Path` + `.trim(from: 0, to: checkDraw)`；回弹用独立的 `scaleEffect`。
- 一次性的装饰（勾的 pop、环的弹跳）可以各用一个小 `KeyframeAnimator`（`SpringKeyframe(1.07, duration: 0.18, spring: .init(duration: 0.45, bounce: 0.35))` → `SpringKeyframe(1, ...)`），触发时若上一轮未完成就直接丢弃，视觉上不会有跳变，因为装饰类值量级只有 ±7 %。
- 数字变化：`.contentTransition(.numericText())` + `.transition`；交接里的数字上滚也可以直接用它，不必手写。
- 勾的符号如果不想手画：`Image(systemName: "checkmark")` + `.symbolEffect(.drawOn)`（macOS 26 的 SF Symbols 7 才有）；本机最低系统 macOS 14，因此规格按 `Path.trim` 写，这条留作以后升级的选项。

### B.7 Reduce Motion 降级版

读 `accessibilityReduceMotion`（卡内容）与 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`（窗口位移、粒子）。降级序列：

| 时间 (ms) | 变化 |
|---|---|
| 0 | beat 点直接变成实心 + 白勾（无缩放、无 trim，最多 0.12 s 淡入）；触觉 `.levelChange`（**保留**） |
| 0 – 300 | 环进度线性 `p → p+1`（`.linear(duration: 0.3)`），线宽恒 5.5，无弹跳，无彗星 |
| 0 – 160 | 数字 `opacity 1 → 0`，勾 `opacity 0 → 1`（0.16 s 线性） |
| 500 | 卡内容整体 `opacity 1 → 0`（0.12 s），换内容，`opacity 0 → 1`（0.16 s） |
| 无 | 无火花、无冲击波、无礼花、无彗星 |
| 最后一步 | 只做描边白色闪一次（`opacity 1 → 0`，0.35 s 线性）+ 环心圆盘 0.2 s 线性填实 + 触觉 `.alignment`；不放礼花；不做整卡跳动 |

原型里打开顶栏「减少动态效果」即可验证：`scale` 恒 1、线宽恒 5.5、粒子数恒 0（已用脚本逐帧核对）。

### B.8 触觉与声音建议（原型不实现）

| 项 | 建议 | 理由 |
|---|---|---|
| 步完成 / beat 完成 | `NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .drawCompleted)`，落在 `draw` 起点（+60 ms，勾开始画、点撞停的那一帧） | 触觉必须和画面上「第一次有东西撞停」同步（WWDC19 Core Haptics：同步是关键，延迟毫秒级就会破坏整体感）；`.drawCompleted` 让它等这一帧画完再触发 |
| 合圈 | `.alignment`，落在 `seal` 起点（+600 ms） | 「对齐 / 到位」的语义最贴合圆头碰到起点 |
| 火花、礼花 | 不再给触觉 | 一次完成只给一次或两次；HIG：常用会变得烦人，最好的触觉是没开时才发觉少了它 |
| 每次调用 | 重新取 `defaultPerformer`，不缓存 | `NSHapticFeedback.h`：设备可能在应用生命周期里变化 |
| 手不在触控板上（鼠标） | 系统自动吞掉，不用特殊处理 | 同上头文件 |
| 声音 | **不加**。这是音乐 app，短促的提示音会踩在用户正在听的歌上，多邻国靠声音，我们靠触觉 + 画面 | 若日后要加：只在合圈那一次、默认关、音量跟随系统提示音，且要走一个设置开关 |
| 触觉开关 | 跟随系统「触控板触觉反馈」设置；不另设 App 内开关 | HIG「让触觉可关」由系统满足 |

### B.9 从多邻国借了什么、没借什么

借的是**方法**，不是数字：

1. 动画做成**状态机**，工程实现与动画时序分离：多邻国用 Rive 的 State Machine 把动画（状态）和触发逻辑连起来，动画师改时序不动工程。我们对应：`Phase` + `Cue` 表 + 一个纯函数式的时序，设计参数集中在一张表里（就是本文 B.2–B.3），改数字不改流程。
2. 时序靠**多轮粗动画反复试**，节奏与能量是调出来的（多邻国 streak 动画一文）。我们对应：原型的慢放 0.25× 与确定性 `advance()`，评审时逐帧看。
3. **连续答对有升级**：多邻国在连续答对后插入「奖励小动画」。我们对应：连击 `combo`，间隔 < 4 s 的连续完成火花更多。
4. **多感官一起**：画面 + 声音 + 触觉一起讲同一件事。我们对应：画面 + 触觉；声音因音乐 app 的特殊性不加。
5. **成功反馈分层**：小事（beat）小反馈、大事（步）中反馈、终点（合圈）大反馈——小而准、大而少，不每次都放礼花。

没借的：吉祥物与夸张的角色表演（nanoPod 的气质是安静的）；声音。

---

## C. 与已有方案的差异与后续项

| 项 | 已有稿 | 本原型 | 处理建议 |
|---|---|---|---|
| 演示台尺寸 | 440 × 120（menu-settings proposal §4.2） | 居中 16:9 圆角矩形，候选 280×158 / 300×169（推荐）/ 320×180 | 行区随之变为 278–300；通用段 6 行需 282，见 A.1 表；推荐尺寸下脚注要挪位 |
| 演示动画的曲线 | 「演示演的就是真实曲线」：封面用面板自己的弹簧（response 0.5/0.4，damping 0.85） | 全部用触控板录屏的缓入缓出 0.9 s | 我认为演示页要的是「安静」，弹簧的回弹在小台面上显得躁。若创始人更想要真实手感，把 A.6.1 的 `io 0.9` 换成 `Spring(duration: 0.5, bounce: 0.15)` 即可，其余不变 |
| 环的合圈 | 圆头碰起点：脉冲 + 描边闪 + 礼花（引导稿 §8.2） | 同上，再加「环心填实 + 白勾 + 卡跳一下 + 两圈冲击波」 | 属于加码，可按需要回退到只脉冲 |
| 火花起点 | 环心（引导稿 §8.1） | 弧头当前位置 | 因果更清楚：环长到哪、火花就在哪 |
| 火花颜色 | 粉红 60 % / 白 40 % | 粉红 / 浅粉 / 金 | 浅色卡片上白色不可见 |
| Apple Activity rings | — | 本环是**单环 7 段进度**，不用 Apple 的 Move 红 / Exercise 绿 / Stand 青，不叠圈 | HIG「Activity rings」明文：不要为其他用途复制或改造活动圆环、不要用它做装饰。本环形状虽是圆环，但颜色、圈数、语义都不同，合规；合圈动画是我们自己的，没有模仿 Apple 的烟花 |

后续项（本次未做）：通用段两行演示；「关于」段动画；触觉与声音的真实接入；礼花颜色取封面主色；打断规则的 Swift 单元测试。

---

## D. 参考出处

读过并用到的（网页内容为本次调研当天抓取）：

1. Duolingo Blog，《How Duolingo Animates Its World Characters》，Jasmine Vahidsafa、Kevin Lenzo，2022-11-10。https://blog.duolingo.com/world-character-visemes/ 。用到：Duolingo 选 Rive 因为文件小、能接进自家架构；State Machine 是「把动画（状态）连起来的逻辑」，让程序控制状态、触发、过渡与混合；动画师导出单一运行时文件交给工程。**没有**任何时序数字。
2. Duolingo Blog，《Building Character》，Greg Hartman，2020-11-10。https://blog.duolingo.com/building-character/ 。用到：每个角色有一段答对时播放的专属动画；连续答对若干题后有「奖励型插页动画」。**没有**时序数字。
3. Duolingo Blog，《You’re on fire! Or, how we brought the streak milestone to life》，Kurt Hartfelder，2022-01-21。https://blog.duolingo.com/streak-milestone-design-animation/ 。用到：多轮粗动画反复试，再打磨整体节奏与能量；「时序就是一切」。明确**未公开**缓动、粒子、声音、Rive 细节。
4. Rive Blog，《State machines make iteration a breeze for designers and developers》。https://rive.app/blog/state-machines-make-iteration-a-breeze-for-designers-and-developers 。用到：状态机把设计迭代和工程实现解耦（工程绑定输入，设计随时改动画）。
5. 60fps.design，《Duolingo Lesson Complete Head Explode Animation》（第三方收录，非 Duolingo 官方）。https://60fps.design/shots/duolingo-lesson-complete-head-explode-animation 。用到：完成页按阶段编排（入场 → 主体 → 统计卡错峰滑入 + 计数器 + 音效）。
6. Apple HIG「Activity rings」（取自官方 HIG 数据源 `developer.apple.com/tutorials/data/design/human-interface-guidelines/activity-rings.json`）。https://developer.apple.com/design/human-interface-guidelines/activity-rings 。用到：环色不可改、不加渐变阴影特效、不可为其他用途复制或改造。**HIG 没有写合圈动画的时序**；Apple Watch 合圈的动画时序我没有找到公开资料，本文没有引用任何 Apple 的合圈数字，环的弹簧参数是本方案自己的设计。
7. Apple HIG「Playing haptics」（同上数据源）。https://developer.apple.com/design/human-interface-guidelines/playing-haptics 。用到：触觉与视觉、声音协调，强度与锐度对齐动画；避免滥用；短触觉配离散事件；可关闭；macOS 三种模式 alignment / levelChange / generic。
8. WWDC19 Session 223《Expanding the Sensory Experience with Core Haptics》。https://developer.apple.com/videos/play/wwdc2019/223/ 。用到：三条原则 Causality / Harmony / Utility；视觉与触觉同步是关键；锐利瞬态配有清脆起音的声音。
9. Cultured Code，《What’s New in the all-new Things》。https://culturedcode.com/things/features/ 。用到：Things 自称「自研动画工具包」，并引用 Craig Mod「每个动画都有目的」。**没有**勾选框的时序数字。
10. Pratt SI，《Design Critique: Things 3 (iOS App)》，Yi Chen，2020-02-05。https://ixd.prattsi.org/2020/02/design-critique-things-3-ios-app/ 。用到：勾选时设备震动（触觉反馈）；撤销勾选被当作不常见操作加以保护。该文没有讲动画时序。
11. 仓库内：`docs/design/2026-09-25-onboarding/research/trackpad-demo-frames.md`（触控板录屏逐帧规格，本文 A.5 的来源）、`docs/design/2026-09-25-onboarding/proposal.md` §8（引导动效基线）、`docs/design/2026-09-25-onboarding/storyboard.html`（环 28 / 5.5、beat 点）、`docs/design/2026-09-25-menu-settings/proposal.md` §4（设置页演示台）、`docs/design/2026-09-25-onboarding/research/apple-tipkit-haptics-particles.md`（`NSHapticFeedback.h` 原文、`defaultPerformer` 不缓存、`.drawCompleted`）。

**没能确认的：** 多邻国答对 / 完成课程反馈的具体时长与缓动（官方文章均未公开）；Things 3 勾选动画的时序（官方与评论都没写）；Apple Watch 合圈动画的时序。这三处本文的数字都是本方案自己设计并在原型里调出来的，不是从这些产品拷贝的。

## E. 原型自验记录

- 每段演示均在 Browser pane 里用确定性假时钟（`__proto.seek` / `__proto.advance`）取帧检查：全屏封面（留边 / 铺满）、贴边收起与换歌探出（收起中 / 胶囊探出）、显示翻译（关 / 开）、翻译为（循环语言）、显示隐藏快捷键（按下 / 淡出中）、贴边隐藏；B 的普通步（预备、画勾、环长、火花、勾入环、交接）与最后一步（合圈、填实、礼花、终页）。
- 悬停意图、循环收尾、打断、降级、慢放均用脚本验证（数值见 B.4、B.7）。
- 深浅色、手机宽度（390）无横向滚动。
- 手感（缓动是否舒服、火花是否够克制、礼花密度）需要创始人亲自终验；自动检查不能代替。
