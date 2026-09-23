# 贴边收起完整重设计（C1 第二版）2026-09-19

状态：设计稿，待创始人裁决第 10 节各项后开工。取代 `research/c1-edge-morph-design-2026-09-12.md`。
现状盘点：`research/inventory-panel-states-2026-09-19.md`。
参考视频拆解：scratchpad `video-analysis-30fps.md`（黑胶囊↔玻璃卡片，粘连）、`ios-video-analysis-v2.md`（Apple Music 正在播放页收回迷你播放器，封面单飞过冲）。

## 0. 第一版错在哪

- 窗口从不缩小，250×316 整块挪出屏外只露 6pt；胶囊 20pt 宽被切剩圆角，看上去是椭圆（SnappablePanel.swift:13、EdgeMorphHost.swift:185）。
- 只做了「一个形状变另一个形状」，没有颈、没有两滴分离，没有主角单飞，没有材质切换。
- 「收起」被拆成贴角再推两步；实际手势是一个双指横滑，应一气呵成。

## 1. 目标

一次双指横滑完成「卡片 → 黑胶囊 → 缩进屏幕边」，hover 时胶囊从边里粘连浮出，点击展开回原页面。全程像一块液体：形状有颈、有过冲，主角（封面）最后落定，材质在收起时压黑、展开时回 fluid，触碰有玻璃反馈。三个页面（封面、歌词、播放列表）都能收，收到的终态一样，展开回到收起前的页面。

## 2. 状态模型

```
EdgePresentation
  card(page)          完整卡片，可在四角，页面 = album | lyrics | playlist
  collapsing          卡片 → 胶囊 → 缩进边，一个手势一段动画
  tucked              窄杆：贴边只露 8pt，窗口就是窄杆大小
  floating            hover 浮出：28pt 胶囊悬在边旁 12pt
  expanding           胶囊 → 卡片，回到 card(page)
```

事件：`collapseRequested(edge)`、`hoverEntered`、`hoverExited`、`expandRequested`、`settled`、`reduceMotionChanged`。
`SnapEvent` 现有五个事件改名对应，reducer 表保持 5×5 穷举，测试 `EdgePresentationReducerTests` 改表。
贴角（四角吸附）仍是纯几何，不进这个状态机；卡片在哪个角只决定收起时贴哪条边和窄杆在那条边上的纵向位置。

## 3. 几何

| 状态 | 窗口 frame | 说明 |
|---|---|---|
| card | 用户尺寸，默认 250×316，纵横比锁 | 不变 |
| collapsing | 保持卡片 frame 不动，直到 settled 才缩 | 动画全部在卡片 frame 内画，避免中途改窗口尺寸 |
| tucked | 8×96，贴边，纵向对齐卡片原中心并夹在屏幕内 | 窗口真缩到这个尺寸；hover 命中区外扩到 16pt |
| floating | 28×120，离边 12pt | 窗口扩到 40×120 覆盖颈的区域 |
| expanding | 先把窗口扩回卡片 frame，再在里面画展开 | 与 collapsing 对称 |

规则：任何 glass 或黑色形状的宽高比 ≥ 3:1 或显式 RoundedRectangle；禁止默认 Capsule 落在近方框上。纵横比锁在 collapsing/expanding 期间临时解除，settled 后恢复。
只处理左右两条边。上边有菜单栏，下边有 Dock，第一版不做，滑向上下不触发收起。

## 4. 手势与输入映射

| 输入 | card | tucked | floating |
|---|---|---|---|
| 双指横滑向边（封面页任意方向、歌词/列表页仅横向，沿用 ScrollDetector 分流） | collapse 到该边 | 无 | 无 |
| 鼠标拖动 | 移窗 | 沿边上下拖窄杆 | 同左 |
| hover 进入 | 现有 hover 控件 | 浮出 → floating | 保持 |
| hover 离开 | 现有 | 无 | 缩回 → tucked |
| 点击 | 现有 | 浮出并展开 | 展开 → card(page) |
| 快捷键 hideToEdge | collapse 到离中心最近的边 | 展开 | 展开 |
| 快捷键 togglePanel / 菜单栏图标 | 整窗淡出（windowPresent 臂） | 整窗淡出，记住 tucked，再次唤出回 tucked | 同 tucked |
| 拖窄杆离开边超过 40pt | 无 | 展开 | 展开 |

## 5. 页面处理

- 三页共用同一条收起动画和同一个终态，终态不带页面信息。
- 主角封面：封面页飞大封面；歌词页和列表页飞页面里那张小封面（歌词页头部、列表页 Now Playing 行）。三页的封面在 collapsing 开始时先统一 matched 到同一个 hero 身份，再单飞。
- 收起时页面内容（歌词行、列表行）在前 80ms 内淡出并向边略移 8pt，不参与变形。
- 展开回 `card(page)`，page 是收起前的页；歌词页是条件挂载，展开时先挂载再淡入，挂载放在 expanding 的 material 时钟上，避免第一帧空白。
- 窄杆和浮出胶囊内容与页面无关：窄杆 = 进度填充；胶囊 = 封面圆点 + 播放/暂停。歌词页不在胶囊里显示歌词（创始人 09-03 否定菜单栏歌词，同一精神）。

## 6. 材质

- card：fluid 底（现状），C5 对比层不变。
- collapsing：0–100ms 把 fluid 压成纯黑（黑覆盖层 opacity 0→1），之后所有变形都是黑色实心。
- tucked：8pt 窄杆全黑（贴边端）。
- floating：胶囊本体一块 `.glassEffect(.regular.interactive(), in: Capsule())`，上压黑→透明 LinearGradient，方向从屏幕边框指向屏内：贴边端纯黑（边框延伸），远端透出壁纸的玻璃（面板延伸）。参考 iOS 26 Type to Siri 面板从灵动岛长出时的黑到玻璃渐变（创始人 09-20 提供截图）。内容不再套玻璃，避免 glass-on-glass。粘连的颈和吞边都在黑端，Canvas 液滴画黑即可；玻璃在远端不参与变形。
- expanding：黑区先收成边上一条窄带再淡掉，玻璃端退成 fluid 底；内容在 material 时钟末尾淡入。
- Reduce Transparency：玻璃换为深灰实心，渐变保留。
- Reduce Motion：全部替换为交叉淡入 180ms，无变形、无单飞；窗口尺寸直接跳。

## 7. 时序

三时钟（几何 / 内容 / 材质）沿用 `MicroInteractionFeel.Tokens` 的做法，全部新 token，旧 edgeMorph token 删除。

### 7.1 collapsing（双指横滑，总约 460ms）

| 时间 | 几何 | 内容 | 材质 |
|---|---|---|---|
| 0 | 手势结束 | 页面内容开始淡出并向边移 8pt | 黑覆盖开始 |
| 0–80 | 高度先塌（从上下向中心，宽不变） | | |
| 80 | | 封面脱开单飞开始（弹簧 response 0.32，bounce 0.35） | |
| 80–160 | 宽度猛收成竖杆（比终态胶囊高、比卡片细） | | 100ms 黑覆盖到 1 |
| 160–200 | 竖杆变短，落到胶囊上，顶部留颈两帧后吸收，胶囊落定过冲 6% 回弹 | | |
| 200–320 | 胶囊向边平移，与边接触处两体粘连（Canvas 液滴），最后只露 8pt | | |
| ~340 | | 封面落进胶囊封面位，全程最后停下 | |
| 320–460 | 窗口 frame 缩到 8×96，settled | | |

### 7.2 floating（hover 浮出，约 180ms；缩回对称 160ms）

| 时间 | 几何 | 内容 | 材质 |
|---|---|---|---|
| 0 | 窗口扩到 40×120 | | |
| 0–120 | 胶囊从边里浮出，与边之间拉颈，颈在 90ms 最细、120ms 断开 | 封面圆点 40ms 后淡入 | |
| 120–180 | 胶囊落到离边 12pt，过冲 4% 回弹 | 播放/暂停 100ms 后淡入 | |

### 7.3 expanding（点击，约 360ms）

| 时间 | 几何 | 内容 | 材质 |
|---|---|---|---|
| 0 | 窗口扩回卡片 frame | 封面从胶囊位起飞（弹簧同 7.1） | |
| 0–30 | 胶囊先鼓成圆团（宽过冲，比胶囊和卡片都圆） | | |
| 30–170 | 圆团向卡片位拉长，圆角从全圆收到卡片 squircle | | 90ms 起黑覆盖 1→0 |
| 170–260 | 卡片落定，过冲 3% | 页面内容 200ms 起淡入；歌词页在此挂载 | |
| ~300 | | 封面落回页面封面位 | |
| 360 | settled，纵横比锁恢复 | | |

## 8. 实现路径（2026-09-20 改写：系统原生 morph，不自己画形状）

第一版样品（自写 Shape 关键帧 + Canvas 液滴 + 多段 withAnimation 接力 + 落定改窗口尺寸）被创始人否决，根因见 `research/spikes/edge-collapse-spike/AUDIT-2026-09-20.md`。材质证据见 scratchpad `v3-material-analysis.md`。

- 一个 `GlassEffectContainer(spacing:)`、一个 `@Namespace`，常驻。所有形体都是里面带固定 `glassEffectID` 的 `.glassEffect(.regular.interactive(), in: 显式形状)`：`body`（卡片 RoundedRectangle 18 → 窄杆 Capsule 8×96 → 浮出长条/封面滴）、`control`（仅浮出态，用 `.glassEffectTransition(.matchedGeometry)` 插拔，从 body 里滴出/被吸回）。collapsing/expanding 没有自己的布局，只是 body 在两个布局之间飞行。
- 每次过渡只一次 `withAnimation(spring) { presentation = next }`，落定用 completionCriteria 回调喂 reducer。手感只由 token 表里的弹簧决定：收起 `spring(duration 0.32, bounce 0)`（Apple 实测无过冲 ease-out）为默认臂，`bounce 0.28` 为 bouncy 臂。
- 封面 `matchedGeometryEffect(id: "hero")` 在卡片大图与浮出小图之间共享；窄杆态封面移除，用 `.transition(.opacity)` 缩进杆里淡掉。
- 材质：本体是系统 regular 玻璃，边缘高光由系统给；黑→透明 LinearGradient 只作 overlay 压在贴边端，opacity token 0.85；对照臂 gradient | black | none。
- 窗口：一个 320×360 透明非激活 NSPanel 固定贴右边，过渡期间和状态之间都不改尺寸；透明区域点击穿透；hover 用纯函数 `EdgeCollapseLayout.rects(for:)` 算并集外扩 12pt。
- Reduce Motion：Transaction 禁动画 + 180ms 透明度交叉淡入。
- 连续性证明（不看屏）：PROBE 模式每帧枚举 CA 层树记录 body bounds，一次过渡 ≥ 12 个连续步、单步不超总位移 25%，`probe.sh` 判 PASS/FAIL。
- 不碰 PlaylistView.swift（WT-D 所有）。

## 9. 对照臂与验证

对照臂（`MicroInteractionFeel` 新通道，URL `nanopod://debug/feel/<channel>/<arm>`）：

| 通道 | 臂 | 含义 |
|---|---|---|
| edgeCollapse | liquid \| v1 | 新液体收起 \| 第一版 morph |
| edgeHero | fly \| static | 封面单飞过冲 \| 封面随形状缩放 |
| edgeTouch | interactive \| plain | 胶囊玻璃 interactive \| 普通 regular glass |
| edgeTint | gradient \| black | 黑→玻璃渐变胶囊 \| 全黑胶囊 |
| edgeTempo | video \| slow | 7 节时长 \| 整体 ×1.5 |

代码层门禁（不看屏幕）：

- reducer 5×5 表穷举；未知事件不动状态。
- 每个状态每一帧的形状宽高比 ≥ 3:1 或圆角 ≤ 短边一半，用 `CollapseShape` 采样断言。
- settled 时窗口 frame 等于该状态表中 frame，误差 ≤ 0.5pt。
- hero 落定时间晚于形状落定时间（时钟 plan 断言）。
- Canvas 液滴只在规定时间窗挂载，settled 后层树里无 filter（沿用 WindowAnimationCensus）。
- Reduce Motion 下 plan 只含 opacity 通道。
- DEBUG 时间戳日志 `[EdgeCollapse] clock=<geometry|hero|material|goo> t=…`，可确定性回放。
- 门：`swift build -c release --product MusicMiniPlayer` + 相关测试类串行。

## 10. 待创始人裁决（一次一条）

1. 静止窄杆 8pt 宽、杆身做进度填充。
2. 只做左右两边，上下不收。
3. 歌词页、列表页收起飞小封面，胶囊里不显示歌词。
4. 时长按视频（7 节数值）还是整体放慢 1.5 倍（edgeTempo 臂两个都留，默认选哪个）。
5. togglePanel / 菜单栏图标在 tucked 时整窗淡出并记住 tucked，而不是展开。
6. 拖窄杆离边超过 40pt 视为展开。

## 11. 分节提交

1. 状态机 + reducer 表 + 时钟 scheduler（纯逻辑，测试先行）。
2. `CollapseShape` + 液滴 Canvas + 材质覆盖层（EdgeMorphHost 重写）。
3. SnappablePanel 窗口 frame 表 + 纵横比锁开关 + hover 命中区。
4. hero 封面三页接入。
5. 对照臂、URL、Reduce Motion/Transparency、日志。
每节：release 构建 + 相关测试串行 + 提交，报 hash 给主会话。
