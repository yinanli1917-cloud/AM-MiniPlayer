# 认识 nanoPod：交互式引导设计方案 v3

日期 2026-09-26（v1 09-25，v2/v2.1 09-26 上午）· 状态：按创始人 09-26 下午第二批反馈改稿，待评审 · 本方案不改 Sources/ 与 Tests/ · 配套：同目录 `storyboard.html`（可点的分镜）、`research/` 四份调研报告

## v3 改了什么

1. **口吻**：整套文案重写。立场从「教会用户」改成「陪他走一遍」——没有「学会」「掌握」「恭喜」「试试看你能不能」，没有「甩」；句子短、真诚、克制，像朋友顺手递东西。结束那一屏不总结做了哪几样，只说一句走心的话。中英各自成立，不是互译；§9 有全表，§9.1 有 v2.1 → v3 逐句对照表，方便直接挑。
2. **移到角落的轨迹**：演示改成柔和的弧线——x、y 两轴各走一段弹簧，x 快（0.50 s）y 慢（0.74 s），轨迹自然成弧，不手画路径；弧高随方向变，对角线移动约为位移的 12%、近水平或近竖直约 5–8%，最高点在行程约 1/3 处，两轴落定约 0.6 s（§8.8）。查了真实面板：`SnappablePanel.renderFrame` 两轴共用同一段 `Spring(duration: 0.5, bounce: 0.15)`，各带自己的初速度——零速度或推的方向正对角落时是直线，方向偏一点才自然弯。演示与实机是否一致曾单列为待定问题；v3.2 已定：弧线只在演示里，实机不改（§13）。
3. **进度环**：分段环改成 Apple Watch 活动环那种连续粗环：外径 24pt、线宽 5pt（≈21%）、圆头；前景 浅 `#FA4058` / 深 `#FB546C`；背景轨道是同一色相的低透明度（浅 22%、深 28%），不透明底上等价于 浅 `#FED5DA` / 深 `#5C2D36`。每完成一步弧长 +1/7，0.6 s ease-out；合圈脉冲一次；小火花保留（§4.7、§8.1、§8.2）。翻译被延后时环停在 6/7，不再有虚线段。
4. **不变**：卡片 Liquid Glass 材质；专辑页两个角那一步；双指示意动画的逐帧规格；翻译延后到第一首外文歌再出现；7 步结构。
5. **命名与入口**：这套引导叫「认识 nanoPod / Getting to know nanoPod」。接着走的入口只在设置里：设置 › 通用 的「认识 nanoPod」一行，按钮随状态变——没走完显示「接着认识 nanoPod / Keep getting to know nanoPod」，点了从停下的地方接着走；走完了显示「重新认识 nanoPod / Get to know nanoPod again」，点了从头走（§9.2）。
6. 「几段」的问题改成「几步」：环连续之后，7 步与 6 步的取舍曾等创始人定；v3.2 已定 7 步（§13）。
9. **v3.3（09-27）**：演示轨迹改成固定路径，不再靠两轴弹簧之差生成——二次 Bézier，向屏幕中心一侧鼓出，弧高 = 位移的 9%，最高点在行程 45%，沿路径 0.6 s ease-out，落点仍是右下角 16pt 边距（§8.8）；真实面板不变。
8. **v3.2（09-27，创始人看过 v3.1）**：卡片排版改成标题、正文左对齐，进度环挪到卡片右上角、靠右对齐并放大——外径 24 → 28pt、线宽 5 → 5.5pt（≈20% 不变），环内数字 8.5 → 9.5pt、勾 10 → 12pt（§4.7）。「放到角落」演示改回真实默认位置：右上角推到右下角、从右缘收边；这一段近竖直（x 只差 4pt），两轴弹簧的弧线浅得看不出来——v3.3 改成固定路径弧；左缘镜像只作分支说明（§3.3 S5、§8.8）。§13 两问已定：7 步；弧线只放在引导演示里，真实面板吸附不改、不加开关。
7. **v3.1（09-26 晚，与菜单稿对齐）**：菜单里不再放「接着认识 nanoPod…」这一项——菜单实测它会把菜单撑宽（英文 259×152、中文 182×152，平时 146×128），点「以后再说」的人会长期看到它，与创始人嫌菜单「胖」的判断相撞，且回头接着走引导很少发生。「以后再说」「先到这里」之后菜单栏都不出入口，只留设置里那一个随状态变的按钮；welcome.foot 与所有指向菜单栏的文案改成指向设置。

## 0. 一段话结论

把现有 C6 的三页说明窗口换成一条陪着走的旅程：一张 236pt 宽的 Liquid Glass 卡片贴在要操作的地方、跟着用户走（面板被推到别的角落时卡也跟过去）；一个连续的粗进度环，7 步各占 1/7——第 1 步「和 Music 打招呼」只在权限未授时出现（通常预填，用户从 1/7 起），后面 6 步：鼠标挪过来·播放 → 专辑页的两个角 → 歌词 → 翻译 → 放到角落·收边 → 回来。每步靠真实状态信号自动判定完成，卡上没有「下一步」；beat 完成打勾 + 一次触觉，一步完成才长环 + 16 粒火花；最后一步环合上、放唯一一次礼花，卡上说一句走心的话。卡片自绘（独立 nonactivating NSPanel）不用 TipKit；检测走现有 `@Published` 信号，新增 5 个小钩子；当前歌不能翻译时翻译一步延后到第一首外文歌；引导结束整套对象销毁，只留那一个延后订阅。总时长 75–110 秒。

## 1. 要解决的问题与原则

现状（`Sources/MusicMiniPlayerAppKit/OnboardingView.swift`、`Sources/MusicMiniPlayerCore/Services/OnboardingState.swift`）：C6 是欢迎 / 授权 / 完成三页向导，普通 `NSWindow`，`showOnboardingWindow()` 会 `NSApp.activate(ignoringOtherApps: true)` 抢焦点（`MusicMiniPlayerApp.swift:856-867`）；只有文字说明，看完就忘（NN/g：短时记忆约 20 秒）。创始人的要求：让用户亲手把高频且不直观的操作做一遍，卡片弹在要操作的位置旁边，每步进度环推进 + 小礼花，精致；09-26 下午补充：口吻要真诚克制、不当老师，移动轨迹要柔和弧线，环要粗、轨道带色。

原则：

1. 只带用户做高频且不自明的操作；自明的不带（播放键只作为一个 beat 顺带确认）。
2. 边做边熟：完成 = 检测到真实状态变化。卡上没有「下一步」，只有「这一步先不做」兜底。
3. 一次只有一张卡，一张卡只讲一个地方（HIG Popovers："show one popover at a time"）；一张卡可以有两个 beat，高亮环在 beat 之间跳。
4. 卡片永不盖住要操作的东西，不成为 key window，不抢焦点，不出声音。
5. 铁律：引导自己不触发任何系统弹窗。当前歌不能翻译就把翻译一步延后（不指向设置、不改锚点）；Music 自动化权限的系统询问只在用户点了「连上 Music」之后出现。
6. 随时可以停下、随时可以接着来（设置 › 通用 的「接着认识 nanoPod」按钮；菜单栏不放入口）；已经在做的自动跳过（预勾、预填）。
7. 庆祝分量匹配事情大小：beat 只打勾，一步一次小火花，只有最后放礼花（Intuit 内容规范、庆祝疲劳研究）。
8. 零常驻：结束后无窗口、无玻璃、无每帧工作、无 timer、无 `TimelineView`；`WindowAnimationCensus` 扫不到任何残留。唯一允许的残留是延后步的一个 Combine 订阅（订现有的 `LyricsService.$canTranslate`，事件驱动、零每帧成本），补完或过期即取消。
9. 口吻：真诚、克制、第二人称、短句；不「教」，不评价用户；确认句平实（「到了。」「回来了。」），不喊口号。

## 2. 调研结论摘要

详见 `research/internal-ops-hooks.md`、`research/cleanshot-exemplars-nng.md`、`research/apple-tipkit-haptics-particles.md`、`research/trackpad-demo-frames.md`。只列影响设计的结论。

### 2.1 内部代码事实

- 高频操作与可订阅信号：播放 `MusicController.isPlaying`（`MusicController.swift:174`）；三页 `MusicController.currentPage`（`:205-211`）；翻译 `LyricsService.showTranslation`（`LyricsService.swift:121`，UserDefaults `showTranslation`，默认 false）、`canTranslate`（`:173`）；歌词显示态 `LyricsDisplayState`（`:28-87`）。
- 控件悬停才出现：专辑页 `showOverlayContent` 随 `onContinuousHover` 翻真（`MiniPlayerView.swift:193-206`），歌词页 `showControls`（`LyricsView.swift:1769`）。`fullscreenAlbumCover` 默认 true（`MusicMiniPlayerApp.swift:74-77`）。
- 专辑页两个角（`MiniPlayerView.swift:167-186`，只在 `showControls || isAudioOutputMenuPresented` 且专辑页时挂载）：左上 `MusicButtonView`（`HoverableButtons.swift:194-214`，`↖ Music` 胶囊，padding 10/6，`NSWorkspace.openApplication` 打开 /System/Applications/Music.app）；右上 `AudioOutputSwitcherView`（触发钮 32pt，列表宽 214，`onMenuPresentedChanged` → `isAudioOutputMenuPresented`）。两者各留 12pt 内边距。
- 底部控件几何（`SharedControls.swift:154-176`）：左下歌词按钮 26×26、中间播放簇 3×30 间距 10、右下歌单按钮 26×26，水平 padding 12、底 padding 16；翻译按钮 32×32 在歌词页控件右上（`:131-138`）。
- 移到角落（`SnappablePanel.swift`）：双指在面板上拖动（`handleScrollDrag`，灵敏度 1.5），松手 `handleScrollEnd`（`:344-362`）先判贴边（`checkAndHideToEdgeWithVelocity`，离边 20pt 内且速度 > 50 且横向占优）；否则 `snapToCorners` 为真时 `calculateTargetCorner(velocity:)`（`:721-745`）：按 `projectionFactor = 0.28` 把速度投影成落点，落点中心在可视区哪个象限就弹到哪个角，角边距 `cornerMargin = 16`。鼠标拖拽只移动、不吸角、不贴边（`:291`）。
- **吸附动画的轨迹**（`SnappablePanel.swift:596-667`）：`startSpringAnimation()` 用 `Spring(duration: 0.5, bounce: 0.15)`（注释注明 WWDC23 手势吸附推荐）；`renderFrame()` 里 x、y 两轴用**同一段** `currentSpring`，各自带初速度 `animInitVelX / animInitVelY`（来自松手时的双指速度；快捷键、程序触发的 `moveToEdgeCorner` 等入口把速度置 0）。所以：零速度或速度方向正对位移方向时，两轴按同一条曲线插值，轨迹是**直线**；双指推的方向与角落方向不一致时，两轴的初速度不同，轨迹**自然弯**，弧的形状由那一下的速度决定，每次不一样。弹簧结束时发 `.windowMovementEnded`（`:693-695`）。液态贴边（`LiquidEdge/`）是另一套逐帧 pose 系统，不参与吸角，不受此影响。
- 贴边收起：面板离屏幕边 ≤ 28pt（`edgeProximity`，`:184-191`）时双指横向划过 10pt（`LiquidEdgeGestures.swift:17`）；全局快捷键 `hideToEdge` 无默认键。展开：点小条 / 胶囊，或 hover 停留 0.08s 探出胶囊（`LiquidEdgeController.swift:240-253`）。收边时面板窗口被 `orderOut`（`:221-225`）。`LiquidEdgeController.state` 是 `private(set)`、非 `@Published`。
- 面板窗口：`SnappablePanel: NSPanel`，`[.titled, .resizable, .fullSizeContentView, .nonactivatingPanel]`，`level = .floating`，`canBecomeKey = true`。伴随窗口范式 `LiquidEdgeStageWindow`（`LiquidEdgeStageView.swift:108-130`）。未用过 `addChildWindow`。
- 面板默认位置：`NSScreen.main.visibleFrame` 右上角、各留 20pt（`:360-370`）——在 28pt 贴边判定内。位置与尺寸不持久化。
- 玻璃先例：`PanelBackdrop.swift` 已有 `NSGlassEffectView`（`.regular` / `.clear` 两臂）；`SharedControls.swift:246-249` 用 `GlassEffectContainer` 包播放簇；`Components/VisualEffectView.swift` 是 `NSVisualEffectView` 的 SwiftUI 包装。2026-07-17 A/B（记忆 glass_backdrop_ab）：原生玻璃与不透明 fluid 的 WindowServer 成本打平；2026-06 教训：多个独立 `.glassEffect()` 各自采样会累积过曝，要包进一个 `GlassEffectContainer`；玻璃叠 `NSVisualEffectView` 禁止。
- 屏幕坐标锚定没有先例；托管视图比窗口高 32pt 但同原点（`PanelWindowMetrics.swift:44-60`），SwiftUI `.global` 到窗口坐标不需减 32pt——需实测钉死一次。
- 无 favorite / 音量 UI；无粒子实现；无 `NSHapticFeedbackManager` 使用；L10n 手写字典跟随系统语言。

### 2.2 CleanShot X 的真相与范例

- CleanShot X 没有「控件旁锚定卡片 + 进度 + 礼花」这套引导。它是极简首启向导 + 让设置页本身承担教学：清晰分组、随状态变化的提示文字、误操作保护（Marcin Wichary）。本方案取的是它的品质：精致、文案随状态实时改、不让人踩坑。
- 与创始人描述最接近的现成形态是 Figma 的 10 步走查：锚定控件的卡 + 小动图 + 「5 of 5」进度 + 随时关闭。
- Superhuman：旁支清单完成率 30% → 强制但预填默认值的引导 98%。Linear：「no tour」，一项对应一个动作。Things 3：教程就是一个待办项目。
- NN/g：情境式优于教程式；一次一条、多图少字；引导标注要与真实界面视觉区分；交互式走查 ≈ 练一轮；允许跳过的引导完成率高约 25%。步骤条适合 3–7 步。
- 进度心理学：goal-gradient；endowed progress（Nunes & Drèze 2006：预盖 2 章 2/10 起步完成率 34%，0/8 起步 19%）。
- 庆祝：Intuit——只为用户自己完成的事庆祝，常规动作用平实确认；Apple Fitness 社区教训：多个庆祝同时触发会互相顶掉，要排队。

### 2.3 Apple 平台事实

- TipKit：`.popoverTip` macOS 14+；`TipNSPopover` 能锚 `NSStatusItem.button`；`TipGroup(.ordered)` 要 macOS 15，项目最低 14（`Package.swift:9`）；`TipViewStyle` 能重写泡泡内容但改不了弹出位置算法。
- NSPopover：菜单栏 app 里普遍要 key window / `NSApp.activate` 才正常（与「不抢焦点」相悖）。
- Haptic（`NSHapticFeedback.h`）：`.generic` / `.alignment` / `.levelChange`，`performanceTime: .drawCompleted`；手不在触控板上时系统自动抑制；每次取新的 `defaultPerformer`。
- HIG：Onboarding "brief, enjoyable… people are more likely to complete it"；Launching "postpone nonessential setup"；Motion——Reduce Motion 用 fade 替代缩放 / 位移。
- 粒子：Canvas + `TimelineView(.animation(paused:))` 停止即干净。
- 进度环：`Circle().trim` + `.stroke(lineCap: .round)`；`.contentTransition(.numericText())` 13+；`.symbolEffect(.replace)` 14+。
- 触控板演示（`research/trackpad-demo-frames.md`）：轮廓 188×142、圆角约 16、描边约 3px 无填充；两个 22px 圆点 `#6B9CFD` 中心距约 32；位移 0.92–1.02 s、缓动接近 cubic-bezier(0.42, 0, 0.58, 1)、无过冲；圆点只做透明度不缩放；运动时拖同色渐隐尾巴。

## 3. 旅程

### 3.1 七步：带他做什么、为什么、怎么判完成

| 步 | 名 | 带他做什么 | 为什么值得 | 用户动作（beat） | 完成信号 | 预计耗时 |
|---|---|---|---|---|---|---|
| 1 | 和 Music 打招呼（条件） | 权限询问放在用户点按钮之后 | 铁律 5；HIG Launching 不前置设置。已授时预填，不出卡 | 点「连上 Music」→ 系统询问 → 允许 | `OnboardingState.automationStatus == .authorized` | 5 s |
| 2 | 鼠标挪过来 · 播放 | 面板静止只剩封面，控件悬停才出来 | 「控件在哪」是面板最不直观的一件事 | ① 移到面板上 ② 按一下播放（已在放则预勾） | `controlsRevealed`；`isPlaying == true` | 5–10 s |
| 3 | 专辑页的两个角 | 右上选声音从哪出；左上 ↖ Music 一步到 Music（完整版到对应的原生播放器） | 创始人 09-26 点名；两个按钮只在悬停时出现 | ① 右上角：声音从哪出 ② 左上角：去 Music（任意顺序） | `audioOutputMenuPresented`；`musicButtonTapped` | 10 s |
| 4 | 歌词 | 去歌词页的两条路 | 创始人点名；图标语义不自明 | 点左下小气泡或封面 | `currentPage == .lyrics` | 5 s |
| 5 | 翻译 | 歌词页右下角的翻译按钮 | 创始人点名；悬停才现、可翻译才挂载 | 点翻译按钮（当前歌不能翻 → 延后到第一首外文歌，S4′/S4L） | `showTranslation` 翻真 | 5–10 s |
| 6 | 放到角落 · 收边 | 双指轻推落到最近的角；再往边推一下藏进边里 | 创始人 09-26 点名的移动方式 + 招牌收边动作；两个都是双指手势 | ① 推到一个角落 ② 再往屏幕边上推一下 | `snappedCorner`；`LiquidEdgeState == .tucked` | 15 s |
| 7 | 回来 | 它在哪、怎么探出、怎么回来 | 收了就得让他知道怎么拿回来 | ① 鼠标停上去 ② 点一下 | `.floating`；`.expanding → .card` | 10 s |

流畅用户约 60 秒，一般用户 75–110 秒。

**不带他做什么，理由**：上一首/下一首、shuffle/repeat（自明）；缩放（原生窗口行为，低频）；歌单页（09-12/09-13 创始人对 Up Next 实时性的裁决未闭合）；点歌词行 seek（中频、一句话能说清，放进 §10.5 的情境提示候选）；全屏封面（菜单开关自明）；全局快捷键（没有默认键，是设置任务不是动作——最后一张卡把它作为唯一的「下一步」递出）；MusicKit 授权（等开发者身份认证，留在设置页）；favorite / 音量（没有 UI）。

### 3.2 顺序的理由

打招呼 → 鼠标挪过来·播放 → 两个角 → 歌词 → 翻译 → 放到角落·收边 → 回来。前两步把「有歌在播、控件会出来」建立起来；两个角就在悬停后的专辑页上，紧接着；歌词在翻译前，因为翻译按钮长在歌词页；推到角落与收边连成一步，因为落到角之后面板必然在贴边判定内（角边距 16 ≤ 28），再推一下顺理成章，卡片还会跟着面板过去一次，用户亲眼看到「它跟着我」；回来必须紧跟收边。乱序做也允许（§5.4）。

### 3.3 每步规格

坐标以面板 frame 为基准（默认 250×284，`P`）。文案见 §9。

**S0 见面**
- 时机：首次启动，面板可见且首次播放器状态读取返回（或 2.5 s 超时）之后——避免与系统的 Automation 询问叠在一起。
- 锚：面板朝屏幕中心一侧的边中点，间距 16pt。卡：环（已连接时 1/7 预填 + 「✓ Music 已经连上了」小标签）、标题「你好，很高兴见到你」、正文、「开始」、「以后再说」、脚注。
- 「开始」→ S1（权限未授则 G）；「以后再说」→ `status = skipped`，卡淡出；菜单栏不出任何入口，设置 › 通用 的按钮显示「接着认识 nanoPod」。

**G 和 Music 打招呼（条件：`automationStatus != .authorized`）**
- 「连上 Music」→ 现有 `OnboardingState.requestAutomationAccess()`（`OnboardingState.swift:169-171`），返回后重查：authorized → 环 +1/7、小火花；denied → 卡就地换成「Music 还没答应」+「去看看」（`x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`）+「先往下」。不阻塞后续；S1 的播放 beat 会说明「连上 Music 之后，就能从这里放」。

**S1 鼠标挪过来 · 播放**
- 锚：播放按钮中心 `(P.minX + 125, P.maxY − 31)`；高亮环 40pt 从卡出现起就标出隐藏按钮的位置，悬停时按钮在环里浮现。
- beats：① 「移到面板上」← `controlsRevealed`；② 「按一下播放」← `isPlaying`；已在播放则 ② 预勾并写「已经在放了」。
- 边界：Music 没开 → 按播放拉起 Music，正文随动「正在打开 Music…」；库里没歌 → beat ② 8 秒未完成时「这一步先不做」变明显。确认「有声音了。」

**S2 专辑页的两个角**
- 锚：右上输出钮中心 `(P.maxX − 28, P.minY + 28)`（高亮环 40pt），beat ① 完成后高亮环跳到左上 ↖ Music 胶囊 `(P.minX + 43, P.minY + 23)`（胶囊形 74×34）；卡片位置不变，只换 beat 与环。
- beats：① 「右上角：声音从哪出」← `audioOutputMenuPresented`（新钩子）；② 「左上角：去 Music」← `musicButtonTapped`（新钩子）。任意顺序。
- 边界：点 ↖ Music 会把 Music 带到前台——面板与卡都是浮动窗，仍在最上；正文随动「Music 打开了，回来接着来。」输出设备只有一个：仍以列表打开为准。完整版：↖ 按钮指向当前播放源的原生 app，文案由播放源决定。鼠标离开面板控件隐去 → 高亮环仍在，正文随动「鼠标再回到面板上」。确认「两个角都在这儿。」

**S3 歌词**
- 锚：左下导航按钮中心 `(P.minX + 25, P.maxY − 31)`，高亮环 36pt；卡片位置不变。检测 `currentPage == .lyrics`。无歌词照常完成，S4 走 S4′。确认「到了。」

**S4 翻译**
- 主锚：翻译按钮中心 `(P.maxX − 28, P.maxY − 92)`，高亮环 40pt。检测 `showTranslation` 翻真——检测动作不检测结果。确认「译文来了。」
- **S4′ 延后**（`canTranslate == false`：无歌词、网络不可达、歌词已是目标语言，或 `displayState` 仍在 searching 超过 3 s）：这一步标为 `deferred`，环不长、不庆祝；卡就地换成「这首不用翻 / 等有一首外文歌的时候，我再来告诉你翻译在哪。」，1.1 s 后按 §8.1 的位移走到 S5。为什么不指向设置：设置 › 歌词 里的是总开关，当前歌不能翻时打开它看不到任何结果；引导中途打开设置窗口会把人带离面板。菜单 v2 已按「面板里有的不进菜单」把「显示翻译」移出菜单，所以也不再有菜单栏锚点。
- **S4L 之后**：引导结束（走完或停下）后，只保留一个 `LyricsService.$canTranslate` 订阅。它翻真且面板可见、开播 ≥ 3 s、本次启动还没出过 → 在翻译按钮旁出这一张卡（同 S4 的锚与高亮环）：「这首可以翻译 / 鼠标挪过来，右下角的按钮点一下。」；`showTranslation` 翻真 → 最后一截长满 + 小火花 + haptic `.alignment` → 环安静合上、脉冲一次，不放礼花（礼花在 S7 放过了）→ 取消订阅、销毁。`showTranslation` 在触发时已经是 true（用户早在设置里开了）→ 不出卡，静默补上、取消订阅。这首没做 → 换歌时卡淡出，下一首外文歌再来，最多 3 首；20 次启动都没遇到 → 静默标 skipped、取消订阅。设置「重新认识 nanoPod」随时可以整套重来。

**S5 放到角落 · 收边**
- 演示（分镜页）按真实默认位置：右上角推到右下角、从右缘收边，走一条向屏幕中心鼓出的固定弧线（弧高 9% 位移、最高点 45%、0.6 s ease-out，§8.8）。
- 锚：面板朝屏幕中心一侧的边中点；无高亮环（动作是手势）；卡内触控板手势示意先演「往角落推」（§8.7），目标角亮一团角落光；beat ① 完成后卡片从面板的新位置长出，正文换成「落好了。往右边再推一下，它会藏进屏幕边。」（落在左边角则「往左边」），示意换成「横推」，目标边亮边缘光。
- beats：① 「推到一个角落」← `snappedCorner`（新钩子：弹簧动画结束且 origin 落在四角目标 ±1pt）；② 「再往屏幕边上推一下」← `.collapsing` 一出现卡立刻淡出，`.tucked` settled 记完成。
- 替代路径：「替我收起来」→ `hideToNearestEdge()`（`SnappablePanel.swift:423`），用户没做手势但看到结果、能走完 S6；脚注「用鼠标的话，在 设置 › 快捷键 给「贴边隐藏」录个键就好。」鼠标拖拽不吸角：beat ① 对鼠标用户 8 秒后也显示「这一步先不做」。Stage Manager 开着 → 只用右边的角。
- 用户先推进边（跳过角落）→ ①② 同勾。中途又展开 → 不算完成，卡回面板旁。
- 这一步的环填充与火花在 S6 卡出现时补放（此刻卡片已隐去）。

**S6 回来**
- 锚：贴边小条 6×56（落角那一侧的屏幕边缘，面板中线高度）；卡放在 `hitRegion(for: .floating)` 之外再留 20pt；高亮环 18×72 药丸贴着小条。
- beats：① 「鼠标停上去，它会探出来」← `.floating`；② 「点一下，回来」← `.expanding` 后 settled 回 `.card`。直接双指向内推 → 同勾。确认「回来了。」→ 环合上（§8.2）。

**S7 就这些了**
- 锚同 S0（面板在它落的角）。环整圈 + 勾；标题「就这些了」；正文「往后它就安静地待在一边，想听的时候就在。愿有音乐陪着的时候，都是好时光。」；「录个快捷键」→ `showSettingsWindow(selectedTab:)` 直达快捷键页；「好」；脚注「想再走一遍：设置 › 重新认识 nanoPod」。翻译延后时正文多一句「翻译那一步，等有外文歌的时候我再来。」，环停 6/7。8 秒无操作自动收起；写 `status = completed`、`schema = 2`，整套对象销毁（延后时只留一个订阅）。

### 3.4 步数与总长的取舍

7 步是步骤条建议区间（3–7）的上限：创始人点名的动作有五个（歌词、翻译、收边、两个角、移动），加上必要的前置（鼠标挪过来·播放）与必要的收尾（回来），能合的已经合了——两个角合成一步两个 beat，推到角落与收边合成一步两个 beat。再往下合只剩两种：把歌词与翻译合成「歌词页」一步两个 beat（6 步，省约 15 秒，代价是创始人点名的两个时刻只剩一次长环），或把第 1 步从环里拿掉当成卡外的前置（6 步，代价是失去预填带来的 endowed progress）。都不推荐。创始人 09-27 已定：7 步（§13）。

## 4. 卡片系统

### 4.1 卡片窗口 `TourCardWindow`

抄 `LiquidEdgeStageWindow` 的配置：

```
NSPanel, styleMask [.borderless, .nonactivatingPanel]
canBecomeKey = false, canBecomeMain = false
isFloatingPanel = true
level = card.level（.floating）并 order(.above, relativeTo: panel.windowNumber)
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
isOpaque = false, backgroundColor = .clear, hasShadow = false（玻璃自己带影；NSVisualEffectView 回退臂开 hasShadow）
ignoresMouseEvents = false
```

不用 `addChildWindow`：面板收边时被 `orderOut`，子窗口会一起消失；贴边小条也不在面板窗口里。

### 4.2 锚点来源

`TourAnchor { id, screenRect, screen }`，两类：
1. 面板内控件：新增 `TourAnchorKey: PreferenceKey`，修饰符 `.tourAnchor(.playPause)` 挂在 `PlayPauseControlButton`、`leftNavigationButton`、`TranslationButtonView`、`MusicButtonView`、`AudioOutputSwitcherView` 触发钮与专辑页封面上；`MiniPlayerView` 根部收集 → `TourAnchorRegistry`。未激活时修饰符不发 preference。控件隐藏（未悬停）时用上次已知矩形。
2. 贴边小条：`LiquidEdgeController.tuckedRegionInScreen` / `floatingHitRegionInScreen`。

### 4.3 放置算法（纯函数，可测）

```
place(cardSize, anchor, panelFrame, visibleFrame) -> (origin, beakSide, beakOffset)
面板内控件 / 面板边：side = 面板朝屏幕中心的一侧；x = 面板外 16pt；该侧放不下换另一侧；都放不下放面板上下方
  y = clamp(anchor.midY − h/2, visible.minY + 8, visible.maxY − 8 − h)；beak offset = clamp(anchor.midY − y, 18, h − 18)
贴边小条：x = floatingHitRegion 之外 20pt；y 同上；beak 朝屏幕边
```

### 4.4 跟随、隐藏、恢复

- 只订阅：面板的 `didMove` / `didResize` / `didChangeScreen`、已有的 `.windowMovementBegan` / `.windowMovementEnded`（`SnappablePanel.swift:247, 281, 619, 694`）、`didChangeScreenParametersNotification`、面板可见性。不轮询。
- 拖动 / 推动开始 → 卡 0.14 s 淡出；弹簧落定（`.windowMovementEnded`）→ 重新放置、卡从新位置长出（S5 的 beat ① 就是这条通路）。
- 面板被 `togglePanel` 隐藏 → 卡隐；再出现 → 回。收边 → 按 S5/S6 规则。菜单开 → 隐；关 → 回。显示器参数变化 → 重放置到锚点所在屏。

### 4.5 高亮环 overlay

盖住面板的透明窗口 `TourHaloWindow`：`ignoresMouseEvents = true`、level 同面板并排其上、frame = 面板 frame、随 §4.4 同一套通知移动。内容一个圆环或药丸：1.5pt 粉红描边、外 3pt 轨道色光晕；出现时从 1.25× 落到 1×（spring .9 s，一次），之后静止；beat 之间的跳转用 spring(.42, .85) 位移。只在 S1–S4、S6 与延后的 S4L 存在。

### 4.6 材质：Liquid Glass，回退 `.popover` 材质

| 候选 | 看起来 | 能不能带箭头 | 代价 | 结论 |
|---|---|---|---|---|
| `NSVisualEffectView` `.hudWindow` | 深灰厚磨砂 | 能（maskImage） | 已知在 Liquid Glass 下过曝（CLAUDE.md 性能陷阱） | 不用 |
| `NSVisualEffectView` `.popover` / `.menu` | 经典 vibrancy 轻磨砂，系统 popover / 菜单同款 | 能（`maskImage` 画卡体 + 箭头） | 合成器每帧重算的是它后面的内容变化；卡在面板旁边、后面是桌面，基本静止 | **macOS 14/15 回退臂** |
| `NSGlassEffectView` / SwiftUI `.glassEffect`（macOS 26） | Tahoe 系统菜单、TipKit 气泡同款 Liquid Glass | `NSGlassEffectView` 只有圆角矩形；SwiftUI `.glassEffect(.regular, in: Shape)` 接受任意 Shape，卡体 + 箭头可以是一个形状 | 2026-07-17 A/B：原生玻璃与不透明 fluid 成本打平 | **macOS 26 主臂** |

选 Liquid Glass 的理由：目标系统 macOS 26 的菜单栏菜单、系统 popover、TipKit 都是玻璃，引导卡要和系统一族；成本不是杠杆（A/B 打平），引导期间短暂存在、结束销毁；`.regular` 就是「轻」的那档，无 tint、无额外暗底；`.clear` 更透但给媒体背景用，文字可读性不够，作为 A/B 臂留着。

三条教训的处理：`.hudWindow` 过曝 → 不用它；玻璃叠玻璃累积过曝 → 一张卡只有一个玻璃形状（卡体 + 箭头同一个 `TourBubbleShape`），包在一个 `GlassEffectContainer` 里，卡内按钮是实色胶囊，高亮环与礼花窗口没有材质，放置规则保证卡永不盖住面板；模糊每帧重算 → 卡在面板旁不在歌词上方，面板移动 / 收边期间卡隐去，引导结束卡窗口 `close()`、玻璃视图随之释放，`WindowAnimationCensus` 的 `effectViews` 清单必须回到引导前。

实现：SwiftUI `TourCardView` 根部 `GlassEffectContainer { content.glassEffect(.regular, in: TourBubbleShape(side:offset:)) }`（`#available(macOS 26)`），否则 `VisualEffectView(material: .popover, blendingMode: .behindWindow)` + `maskImage`。Reduce Transparency 由系统自动转不透明底，实现时各实测一次。A/B 通道 `nanopod://debug/feel/tourCard/<glass|clear|vibrancy>`。

### 4.7 视觉规格

| 项 | 规格 |
|---|---|
| 尺寸 | 宽 236pt 固定；高随内容（92–190pt）；圆角 14pt continuous；箭头 12pt 等腰，同一形状 |
| 材质 | §4.6。顶部 1px 内高光（玻璃自带）；外 0.5px 8% 描边 |
| 字 | SF Pro Text：标题 13 semibold；正文 12 regular 次级色；beat 12；脚注 10.5；环内数字 9.5 semibold tabular；标题、正文、beats 一律左对齐 |
| 进度环 | **连续粗环**：外径 28pt、线宽 5.5pt（≈20%）、圆头（`lineCap: .round`），12 点钟起顺时针；放在卡片右上角、右缘与标题顶对齐，标题与正文左对齐（v3.2，创始人：24/5 看着太粗太挤）。前景 Apple Music 粉红：浅色外观 `#FA4058`、深色外观 `#FB546C`（菜单 / 设置 v2 定稿，取自本机 Music.app 图标渐变取样）。背景轨道 = 前景色同色相的低透明度：浅 22%、深 28%，用 `Color("AccentColor").opacity(...)` 叠在玻璃上；不透明底上的等价色 浅 `#FED5DA`（`#FA4058` @22% 叠白）/ 深 `#5C2D36`（`#FB546C` @28% 叠 `#1E1E21`，暗酒红）。每完成一步弧长 +1/7；环内数字 9.5pt 标当前步，做完换 12pt 的勾 |
| 强调色派生 | 文字 ink 档：浅 `#D42640`（同色相压暗到 4.5:1 以上）、深 `#FF8497`（提亮）；柔底 soft：浅 rgba(250,64,88,.12)、深 rgba(251,84,108,.16)；高亮环光晕 用轨道色；火花 60% 主色、40% 白 |
| beat | 14pt 圆点描边 → 实心粉红 + 白勾；完成行文字转次级色 |
| 按钮 | 主按钮胶囊 11pt semibold 反色；次按钮 12% 对比色底；链接 11pt 次级色 |
| 一句确认 | 完成瞬间正文下方 12pt semibold：「有声音了。」「两个角都在这儿。」「到了。」「译文来了。」「收好了。」「回来了。」 |

### 4.8 状态随动文案

正文随当前状态改：Music 是否在开、控件是否隐去、翻译这首为什么延后、落在哪个角、Music 是否已在前台……每个分支一句 ≤ 20 字的直说（§9）。判定源全部是已有的 `@Published` 或钩子。

## 5. 状态机与持久化

### 5.1 类型

```swift
enum TourStep: String, CaseIterable, Codable { case connect, reveal, corners, lyrics, translate, moveTuck, back }
enum TourStepState: String, Codable { case pending, completed, skipped, deferred }
enum TourPhase: Equatable { case idle(deferredArmed: Bool), welcome, step(TourStep, beats: [Bool]),
                            transitioning(from: TourStep?, to: TourStep?), finale, deferredTip(TourStep) }
enum TourEvent { case start, stopTour, skipStep, signal(TourSignal), anchorUnavailable(TourStep), anchorRestored(TourStep),
                 panelHidden, panelShown, panelMoving, panelSettled(corner: Corner?), panelTucked, panelExpanded,
                 canTranslateBecameTrue(secondsIntoSong: Double), songChanged, launch,
                 resume(completed: Set<TourStep>), appWillTerminate, finaleDismiss }
```

`TourMachine` 是纯值类型 reducer：`(phase, event, snapshot) -> (phase, effects)`，与 `LiquidEdgeReducer` 同一写法。

### 5.2 转移要点

- `welcome + start` → 权限未授 `step(.connect)`，否则第一个未完成步。
- `step(s) + signal(完成 s 的最后一个 beat)` → `transitioning(s → next)` → 反馈时长后 `step(next)` 或 `finale`。
- beat 完成不换 phase，只更新 `beats`，效果 `.checkBeat` + `.haptic(.levelChange)`；`corners` 的两个 beat 任意顺序。
- `step(s) + signal(完成 t ≠ s)`（乱序）→ 记 t 完成、环 +1/7、小火花；phase 不变。
- `step(.moveTuck) + panelSettled(corner: some)` → beat ① 勾，效果 `.relocateCard`；`+ panelTucked` → 步完成；`step(any) + panelTucked` → 记 `.moveTuck` 完成 → `step(.back)`。
- `step(.back) + panelExpanded` → 两 beat 同勾 → 完成 → finale。
- `any + stopTour` → skipped → `idle` + teardown；`step(s) + skipStep` → s 标 skipped（环不长）→ 下一步。
- `step(.translate)` 进入时 `snapshot.canTranslate == false` → `.translate` 标 deferred，效果 `.showDeferralNote`（1.1 s）→ `transitioning(.translate → .moveTuck)`。
- `finale + finaleDismiss | 8 s` → completed → 有 deferred 步则 `idle(deferredArmed: true)` + teardown（只留 `$canTranslate` 订阅），否则 `idle(deferredArmed: false)` + 全量 teardown。
- `idle(deferredArmed: true) + canTranslateBecameTrue(≥ 3 s)`，且面板可见、本次启动未出过 → `deferredTip(.translate)`（重建卡窗 + 高亮环）；`+ signal(showTranslation)` → 步完成、安静合圈 → `idle(false)` + 取消订阅；`+ songChanged` → attempts += 1 → `idle(true)`，attempts ≥ 3 → 标 skipped、取消订阅；`+ launch` 累计 20 次未触发 → 标 skipped、取消订阅。触发时 `showTranslation` 已为 true → 静默标 completed、取消订阅。

### 5.3 持久化（UserDefaults，替换 C6 的两个键）

| 键 | 类型 | 含义 |
|---|---|---|
| `nanoPodTourSchema` | Int | 当前 2；C6 的 `nanoPodOnboardingCompleted` / `nanoPodOnboardingSchema`(=1) 读一次迁移 |
| `nanoPodTourStatus` | String | notStarted / inProgress / completed / skipped |
| `nanoPodTourCompletedSteps` | [String] | 已完成（skipStep 的标 `skipped:`） |
| `nanoPodTourResumeCount` | Int | 自动续显次数，≥ 3 不再自动出 |
| `nanoPodTourDeferred` | [String: Int] | 延后步 → 已尝试的歌数；存在即表示要在启动时装上延后订阅 |
| `nanoPodTourDeferredLaunches` | Int | 延后步武装后经过的启动次数，≥ 20 静默标 skipped |
| `nanoPodLaunchCount` | Int | 沿用 |

### 5.4 乱序、提前做过、中途离开

- 激活期间所有剩余步的检测同时武装；先做完的先长环。当前卡不跳，等它那步完成再走到下一个未完成步。
- 开始时就满足的（已在播放、翻译已开、已授权）→ 预勾 / 预填，不出那张卡。
- 停下 → 不再自动出现；设置 › 通用 的「接着认识 nanoPod」从第一个未完成步继续（走完后同一按钮变「重新认识 nanoPod」，从头走）。
- 退出 app → inProgress；下次「欢迎回来」卡（S0 变体：「上次走到这儿，接着来。」），自动续显最多 3 次。

### 5.5 前置条件门

`shouldPresent(status, schema, launchCount, forced)` 沿用 C6 思路；再叠时机门：面板可见 ∧（首次状态读取已返回 ∨ 2.5 s 超时）∧ 没有系统询问在前台。

### 5.6 schema 升级

步骤带 `introducedIn`；老用户已 completed 且 `nanoPodTourSchema < currentSchema` → 只出新增步的迷你旅程，见面卡改「有个新东西」。C6 → v3 首个版本，所有步 `introducedIn = 2`。

## 6. 完成检测钩子清单

| 信号 | 现有 | 位置 | 需要做的 |
|---|---|---|---|
| 播放中 | 是 | `MusicController.$isPlaying` | 无 |
| 当前页 | 是 | `MusicController.$currentPage` | 无 |
| 翻译开关 / 可翻译 | 是 | `LyricsService.$showTranslation` / `$canTranslate` | 无 |
| 歌词显示态 | 是 | `LyricsService.displayState` | 无 |
| Automation 权限 | 是 | `OnboardingState.automationStatus` | 无 |
| 控件出现 | **否** | `MiniPlayerView.swift:200-206`、`LyricsView.swift:1769` | 新增 `.nanoPodControlsRevealed` 通知，翻真时 post 一次 |
| 音频输出列表打开 | **否** | `MiniPlayerView.swift:181`（`onMenuPresentedChanged`） | 新增 `.nanoPodAudioOutputMenuPresented` 通知 |
| ↖ Music 点击 | **否** | `HoverableButtons.swift:200-203`（action） | 新增 `.nanoPodMusicButtonTapped` 通知 |
| 落到角落 | **否** | `SnappablePanel.swift:693-695`（弹簧结束） | 新增 `.nanoPodPanelSnappedToCorner`（userInfo 带角），判定 origin 落在四角目标 ±1pt；暴露 `public func currentCorner() -> Corner?` |
| 贴边状态 | **否** | `LiquidEdgeController.state`（`private(set)`） | 新增 `statePublisher` + `tuckedRegionInScreen` / `floatingHitRegionInScreen` |
| 面板近边 | 否（`private nearEdge`） | `SnappablePanel.swift:184` | 暴露 `tuckableEdge() -> Edge?` |
| 面板移动 / 缩放 / 换屏 / 可见 | 是 | `NSWindow` 通知 + `.windowMovementBegan/Ended` | 无 |
| 控件屏幕矩形 | **否** | — | `TourAnchorKey` + `.tourAnchor(_:)` ×6 + 根部收集 |
| 可翻译（延后步触发） | 是 | `LyricsService.$canTranslate` + `MusicController.$currentTrackTitle`（换歌） | 无新钩子；引导结束后只保留这一个订阅，完成或过期即取消 |
| 菜单开 / 关 | 是（delegate 已设） | `menuWillOpen` / `menuDidClose` | 转发为通知 |
| 设置页直达 | 是 | `showSettingsWindow(selectedTab:)` | 快捷键页需可选中 |

真正的新钩子 5 个：控件出现、输出列表打开、↖ Music 点击、落到角落、贴边状态发布；其余是暴露已有值。

## 7. 前置条件与边界矩阵

| 情形 | 处理 |
|---|---|
| 没在放歌 | S1 beat ② 等用户按播放；8 s 未完成「这一步先不做」变明显 |
| Music.app 没开 | 按播放拉起 Music；文案随动 |
| Automation 权限未授 / 被拒 | G 闸门；拒绝 → 设置深链 + 「先往下」 |
| ↖ Music 把 Music 带到前台 | 面板与卡浮动仍在最上；文案「Music 打开了，回来接着来。」 |
| 只有一个输出设备 | beat 以列表打开为准 |
| 当前歌没歌词 / 网络不可达 / 已是目标语言 | S3 照常；S4 → S4′ 延后，第一首外文歌再出 S4L；绝不弹窗、不指向设置 |
| 从未播放外文歌 | 延后步 20 次启动后静默标 skipped、取消订阅；设置「重新认识 nanoPod」仍可整套重来 |
| 翻译失败 | 算完成（检测动作） |
| 引导开始时窗口已收边 | S0 锚到小条；「开始」后先走 S6，再回第一个未完成步 |
| 中途用户提前收边 | 记 moveTuck 完成，直接进 S6 |
| 只有鼠标 | 拖动不吸角、不能推：S5 8 s 后「这一步先不做」变明显 + 「替我收起来」按钮 + 脚注指向快捷键 |
| 落在右边角 / 左边角 | 文案「往右边 / 往左边再推一下」；Stage Manager 开着 → 只用右边的角 |
| 多显示器 | 卡放在锚点所在 `NSScreen`；面板换屏重放置 |
| 全屏 Space | 卡窗 `collectionBehavior` 同面板 |
| 面板被 togglePanel 隐藏 | 卡随隐随现 |
| 用户拖动 / 推动 / 缩放面板 | 动中卡淡出，落定后从新位置长出 |
| 用户不按顺序 | 全部检测同时武装；先做完先长环 |
| 提前做过 | 预勾 / 预填，不出卡 |
| 中途停下 / 退出 app | skipped / inProgress；菜单栏不出入口，设置 › 通用「接着认识 nanoPod」 |
| Reduce Motion / Reduce Transparency | §8.4；材质由系统转不透明 |
| 多个庆祝同时到 | 庆祝队列，一次只播一个 |
| 老用户 schema 升级 | 只出新增步 |
| 卡片 30 s 无人理（非最后一张） | 正文补一句「不着急，随时可以停下。」 |

## 8. 反馈节奏与动效规格

原则：优雅 = 少而准。每次只动一个东西，位移用速度连续的弹簧，内容错峰 40 ms 淡入；没有呼吸循环、没有常驻动画；只有用户刚做完的动作才允许过冲。

### 8.1 完成一步（≈ 1.0 s 到下一张卡就位）

| t | 发生什么 | 规格 | Reduce Motion |
|---|---|---|---|
| 0 ms | 检测到完成 | haptic `.levelChange`，`.drawCompleted`，每次取新的 `defaultPerformer` | 保留 |
| 0 ms | beat 打勾 | 圆点 → 实心勾，scale 1→1.22→1，spring(response .28, damping .60) | 直接切换 |
| 50 ms | 进度环长一截 | 弧长 +1/7：`trim(to:)` 0.6 s ease-out（cubic-bezier(.2,.8,.2,1)，等价 `.timingCurve`），圆头领着走；线宽 5.5→6.5→5.5 spring(.30, .60) | linear 0.30，线宽不变 |
| 50 ms | 火花 | 16 粒 2–3.5pt 圆点，初速 90–140 pt/s 全向，阻尼 .88/帧，寿命 0.55 s，粉红 60% / 白 40%，起点环心；`Canvas` + `TimelineView(.animation(paused:))`，结束 `paused = true` | 不放 |
| 100 ms | 环内数字 → 勾 | `.contentTransition(.symbolEffect(.replace.downUp))` 0.30 s | `.replace` |
| 750 ms | 卡内容淡出 | opacity 1→0，0.14 s easeIn | 同 |
| 800 ms | 卡位移到下一锚点 | 窗口 frame spring(response .50, damping .86)，速度连续；箭头在中点 0.1 s 交叉淡化换向 | 原地淡出、新位置淡入 0.16 s |
| 860 ms | 新内容淡入 | 标题、正文、beats 依次 40 ms 错峰，各 opacity + 6pt 自锚点方向位移 0.18 s smooth；环内数字 `.numericText` | 整体 opacity 0.16 s |

beat 完成（不是步完成）只做前两行。

### 8.2 最后一步（环合上）

| t | 发生什么 | 规格 | Reduce Motion |
|---|---|---|---|
| 0 ms | 最后一截长满 | 同上 0.6 s；haptic `.alignment`（合圈的语义） | 保留 |
| 600 ms | 圆头碰到起点：合圈脉冲 | scale 1→1.08→1 spring(.50, .62)；线宽 5.5→7→5.5；描边 粉红→白→粉红 0.35 s | 只做描边色闪一次 |
| 650 ms | 礼花 | 72 粒自面板上沿一线缓缓喷出：初速 220–320 pt/s 向上、锥角 ±30°、重力 360 pt/s²、阻力 .985/帧（末段飘落）、自旋 ±2.5 rad/s、6×9pt 矩形/圆/细条三形、色取封面主色 3（`NSImage+AverageColor` 采样，过暗过灰回退粉红/白/金，哑光）+ 白，寿命 1.8 s，末 0.5 s 淡出；独立点击透传窗口（面板宽 + 160 × 320，面板上方），2.2 s 后关闭 | 不放 |
| 1000 ms | 卡长成最后一张 | 高度 spring(.40, .85)，文案与按钮错峰淡入 0.2 s | opacity |
| 8 s | 自动收起 | opacity 0.16 s easeIn，scale 1→.97；teardown | opacity |

翻译被延后时：环停在 6/7，不合圈、不脉冲，礼花照放（庆祝的是这一坐的完成），正文多一句「翻译那一步，等有外文歌的时候我再来。」S4L 完成时：最后一截长满 + 火花 + haptic `.alignment` → 0.6 s 后合圈脉冲（scale 1→1.08→1）→ 不放礼花 → 1.2 s 后卡淡出、销毁。

### 8.3 卡片出现 / 位移 / 消失

| 动作 | 规格 | Reduce Motion |
|---|---|---|
| 出现 | opacity 0→1（前 0.14 s）+ scale .96→1 + 自锚点方向 8pt 位移，spring(response .36, damping .86)，变换原点在箭头 | opacity 0.16 s |
| 位移 | frame spring(.50, .86)，从上一段速度起步 | 淡出淡入 |
| 跟着面板去角落（S5 beat ①） | 面板落定后卡从新位置长出（同「出现」），不追着面板飞（追着飞会和面板弹簧打架） | 同 |
| 消失 | 0.16 s easeIn，opacity → 0，scale → .97 | opacity |
| 高亮环 | 出现 1.25× → 1×，spring .9 s 一次，然后静止；beat 间位移 spring(.42, .85) | 直接出现 |

### 8.4 Reduce Motion 总则

读 SwiftUI `accessibilityReduceMotion`（卡内容）与 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`（窗口位移、粒子），监听 `accessibilityDisplayOptionsDidChangeNotification`。一切位移与缩放 → 淡化；粒子不放；触觉保留；环填充线性；手势示意静止在起点态。纯函数 `TourMotionPolicy.resolve(reduceMotion:) -> TourMotionSpec`。

### 8.5 建议新增到 `MicroInteractionFeel.Tokens` 的数值

```
tourCardPresentResponse = 0.36, tourCardPresentDamping = 0.86
tourCardTravelResponse  = 0.50, tourCardTravelDamping  = 0.86
tourCardDismissDuration = 0.16, tourContentStagger = 0.04
tourRingOuterDiameter = 28, tourRingLineWidth = 5.5
tourRingFillDuration    = 0.60
tourRingPulseResponse   = 0.50, tourRingPulseDamping = 0.62
tourBeatCheckResponse   = 0.28, tourBeatCheckDamping = 0.60
tourHaloSettleDuration  = 0.90
tourSparkCount = 16, tourSparkLifetime = 0.55
tourConfettiCount = 72, tourConfettiLifetime = 1.8, tourConfettiGravity = 360
tourFinaleAutoDismiss   = 8.0
```

feel channels：`tourCelebration: .sparks（默认）| .quiet`；`tourCard: .glass（默认）| .clear | .vibrancy`。

### 8.6 声音与触觉

不出任何声音（音乐 app）。触觉只在 beat / 步完成瞬间给一次 `.levelChange`；合圈一次 `.alignment`。鼠标用户系统自动无感。

### 8.7 触控板手势示意（按逐帧规格）

来源：创始人 09-26 录的系统设置「触控板」页演示，逐帧拆解在 `research/trackpad-demo-frames.md`。源规格（966×488 画面）：轮廓 188×142、圆角约 16、描边约 3px #ACACAC、无填充、无阴影；两个圆点直径 22、色 #6B9CFD、中心距约 32；一次位移 0.92–1.02 s，缓动接近 cubic-bezier(0.42, 0, 0.58, 1)，无过冲；运动时沿运动方向拖同色渐隐尾巴（22 → 34–48px）；圆点的出现与静息只做透明度（1.0 → 0.31 → 0 → 0.31 → 1.0），没有缩放；到位后停约 350 ms。源动画末尾约 6% 位移在一帧内贴合终点，属于系统动画的实现痕迹，不复刻。

等比缩进卡内（源 188 → 96，比例 0.51）：
- 轮廓：96×72pt，圆角 8pt，1.5pt 描边（8% 对比色），无填充；在卡内居中占一行。
- 手指：两个 11pt 圆点，`#6B9CFD`（深浅色外观都用它，与系统一致），中心距 16pt，同时出现。
- 一轮 3.55 s：0–0.45 s 淡入到 1.0 → 停 0.35 s → 0.95 s 位移（cubic-bezier(0.42, 0, 0.58, 1)）→ 停 0.35 s → 0.30 s 暗到 0.31 → 平台 0.58 s → 0.42 s 淡到 0 → 隐 0.15 s。位移量：横推 36pt；往角落推 30×18pt 指向目标角。
- 拖尾：位移中段沿运动方向把一个同色 1.5pt 模糊的副本拉长到 1.8×、透明度 0.45，到位前收回。
- 播两轮后静止在起点、0.31 不透明；卡被 hover 时再播一轮；Reduce Motion 只画起点静止态、无拖尾。
- 三个变体：往角落推（S5 beat ①）、横推向右 / 向左（S5 beat ②，方向随目标边）。分镜页的 `tpNudge` / `tpSwipe` / `tpSwipeL` 与三组拖尾 keyframes 就是这份规格。
- 实现：SwiftUI `TourGestureGlyph`，一个 `TimelineView(.animation(paused:))` 驱动两轮后 `paused = true`，hover 时重新武装一轮；不用 CAAnimation 循环。

### 8.8 面板移到角落的轨迹

创始人 09-26：要柔和的抛物线，带一点小弧度，不要直线。

**演示规格（v3.3，分镜页「移到角落的轨迹」一节）**：弧线只在引导演示里，不绑真实物理，所以直接走一条固定路径：

| 项 | 值 |
|---|---|
| 路径 | 二次 Bézier：起点 = 面板当前位置，终点 = 目标角（边距 16pt） |
| 鼓出方向 | 弦的法向里指向屏幕中心的那一侧（右上 → 右下时向左鼓） |
| 弧高（最大偏离弦） | 位移的 9%（右上 20pt → 右下 16pt 这一下位移 ≈ 96pt，弧高 ≈ 8.6pt） |
| 最高点位置 | 行程 45% 处（控制点放在弦上 45% 处、向鼓出侧偏 2 × 弧高——二次 Bézier 的最大偏离是控制点偏离的一半） |
| 时长与缓动 | 沿路径参数 0.6 s，ease-out cubic-bezier(.2, .8, .2, 1)，等价 `Spring(duration: 0.6, bounce: 0)`；无过冲 |
| Reduce Motion | 直接落到目标 |

实现（引导的演示层，不碰 `SnappablePanel`）：`TourDemoPath.quadratic(from:to:sagittaRatio: 0.09, peak: 0.45, bulgeToward: screenCenter)` 给出路径，`TimelineView` 或 `CADisplayLink` 按 ease-out 采样 `point(at:)` 驱动演示用的面板影子；分镜页的 `arcControl` / `arcPoint` / `movePanelAlongArc` 就是这套算式。

曾试过（v3–v3.2）用 x、y 两轴不同响应的弹簧（x 0.50 s / y 0.74 s）生成弧：对角线 ≈12%、近竖直 (100,300) ≈7.5%，但真实默认位置到右下角近竖直（x 只差 4pt），弧不到 1%，弃用。

**真实面板现在怎么走**（§2.1）：两轴共用同一段 `Spring(duration: 0.5, bounce: 0.15)`，各带松手时的初速度。零速度（快捷键、程序触发）或推的方向正对角落时是直线；推的方向偏一点，两轴初速度不同，轨迹自然弯，弧形取决于那一下的速度，每次不一样。创始人 09-27 已定：弧线只放在引导演示里，真实面板的吸附不改、不加开关（§13）。

## 9. 文案

口吻：真诚、克制，像朋友顺手递东西给你——第二人称、短句、不评价、不比喻堆叠、不抖机灵；确认句平实；不出现「v3 改了什么」第 1 条列出的那几个词，移动面板一律说「推」。中英各自成立，不是互译。英文由系统语言决定（`L10n` 现有机制），key 命名 `tour.<step>.<field>`。

### 9.1 v2.1 → v3 逐句对照表

| key | v2.1 中 | **v3 中** | v2.1 en | **v3 en** |
|---|---|---|---|---|
| tour.name | 引导 | **认识 nanoPod** | Tour | **Getting to know nanoPod** |
| welcome.title | 嗨，来认识一下 nanoPod | **你好，很高兴见到你** | Hi. Let's get you the hang of nanoPod | **Hi, glad you're here** |
| welcome.body | 六个小动作，每个都请真的做一遍。卡片会一路陪着你，两分钟不到。 | **接下来几分钟，我陪你把 nanoPod 走一遍。都是些顺手的小事，不着急。** | Six little moves, each one for real. The card stays with you the whole way. Under two minutes. | **Over the next couple of minutes I'll walk through nanoPod with you. Small, everyday things. No rush.** |
| welcome.start / skip | 走起 / 先不用 | **开始 / 以后再说** | Let's go / Not now | **Begin / Later** |
| welcome.foot | 想重来？菜单栏 ♪ 里有「继续引导」 | **随时可以停下，设置里能接着来** | Want a redo? It's under ♪ › Continue tour | **Stop anytime. You can pick it up again in Settings** |
| welcome.connected | Music 已经连上了 | **Music 已经连上了** | Music's already connected | **Music's connected** |
| resume.title | 欢迎回来 | **欢迎回来** | Welcome back | **Welcome back** |
| resume.body | 上次做到 {n}/7，接着来。 | **上次走到这儿，接着来。** | You were at {n} of 7. Pick it up here. | **We left off here. Let's keep going.** |
| connect.title | 先和 Music 打个招呼 | **先和 Music 打个招呼** | Say hi to Music | **Say hi to Music** |
| connect.body | nanoPod 靠 Music 放歌、读歌词。点一下，系统会问你一次，选「好」就行。 | **nanoPod 靠 Music 放歌、读歌词。点一下，系统会问你一次。** | nanoPod plays and reads lyrics through Music. Click, macOS asks once, and you're in. | **nanoPod plays and reads lyrics through Music. One click, and macOS will ask you once.** |
| connect.allow / later | 好，连上 / 等会儿再说 | **连上 Music / 稍后** | Connect / Maybe later | **Connect Music / Later** |
| connect.denied.title | Music 还没点头 | **Music 还没答应** | Music said no | **Music isn't on yet** |
| connect.denied.body | 到 系统设置 › 隐私与安全性 › 自动化，给 nanoPod 打开 Music。 | **在 系统设置 › 隐私与安全性 › 自动化 里，给 nanoPod 打开 Music 就好。** | Head to System Settings › Privacy & Security › Automation and switch on Music for nanoPod. | **In System Settings › Privacy & Security › Automation, turn on Music for nanoPod.** |
| connect.openSettings / continue | 去打开 / 先往下走 | **去看看 / 先往下** | Take me there / Keep going anyway | **Show me / Go on for now** |
| connect.confirm | 连上了。 | **连上了。** | Connected. | **Connected.** |
| reveal.title | 把鼠标挪过来 | **把鼠标挪过来** | Bring your cursor over | **Bring your cursor over** |
| reveal.body | 面板安静的时候只留封面，控件都藏在下面。 | **面板平时只留封面，控件在你需要的时候才出来。** | When the panel's resting, it's just the cover. The controls are tucked underneath. | **At rest it's just the cover. The controls come out when you need them.** |
| reveal.beat1 / beat2 / beat2done | 移到面板上 / 按一下播放 / 已经在放了 | **移到面板上 / 按一下播放 / 已经在放了** | Hover the panel / Hit play / Already playing | **Hover the panel / Press play / Already playing** |
| reveal.openingMusic | 正在叫醒 Music… | **正在打开 Music…** | Waking Music up… | **Opening Music…** |
| reveal.needAccess | 得先连上 Music 才能从这里放 | **连上 Music 之后，就能从这里放** | Connect Music first to play from here | **Once Music's connected, you can play from here** |
| reveal.confirm | 出声了。 | **有声音了。** | There's your music. | **There's the music.** |
| corners.title | 专辑页的两个角 | **专辑页的两个角** | The two corners | **The two corners** |
| corners.body | 右上换出声的设备，左上一键跳去 Music。 | **右上角选声音从哪里出，左上角一步到 Music。** | Top right picks where the sound goes. Top left jumps you into Music. | **Top right picks where the sound comes out. Top left takes you to Music.** |
| corners.beat1 / beat2 | 点右上，看看现在从哪出声 / 点左上 ↖ Music | **右上角：声音从哪出 / 左上角：去 Music** | Top right: see where it's playing / Top left: ↖ Music | **Top right: where the sound goes / Top left: over to Music** |
| corners.musicOpened | Music 在后面开好了，回来接着来。 | **Music 打开了，回来接着来。** | Music's open behind you. Come on back. | **Music's open. Come back whenever you're ready.** |
| corners.confirm | 两个角都认识了。 | **两个角都在这儿。** | Both corners, done. | **Both corners, right there.** |
| lyrics.title | 看歌词 | **歌词在这儿** | Now the lyrics | **The lyrics** |
| lyrics.body | 左下角的小气泡，或者直接点封面。 | **左下角的小气泡，或者点一下封面。** | The little speech bubble, bottom left. Or just click the cover. | **The little speech bubble at the bottom left, or click the cover.** |
| lyrics.hoverBack | 鼠标再挪回面板上 | **鼠标再回到面板上** | Hover the panel again | **Bring your cursor back over** |
| lyrics.confirm | 到了。 | **到了。** | There you go. | **Here they are.** |
| translate.title | 顺手开翻译 | **翻译** | Turn on translation | **Translation** |
| translate.body | 右下角这个按钮。译文会跟在每一句下面。 | **右下角的按钮。译文会跟在每一句下面。** | The button at the bottom right. Every line gets one underneath. | **The button at the bottom right. Each line gets one underneath.** |
| translate.confirm | 译文来了。 | **译文来了。** | Translated. | **Translated.** |
| translate.deferred.title | 这首不用翻，先跳过 | **这首不用翻** | This one doesn't need it. Skipping for now | **This one doesn't need it** |
| translate.deferred.body | 等到一首外文歌，我再来说翻译在哪。 | **等有一首外文歌的时候，我再来告诉你翻译在哪。** | When a song in another language comes on, I'll show you where translation lives. | **When a song in another language comes along, I'll show you where translation is.** |
| translate.deferred.confirm | 先记着。 | **记下了。** | Noted. | **Noted.** |
| translate.later.title | 这首能翻了 | **这首可以翻译** | This one can be translated | **This one can be translated** |
| translate.later.body | 鼠标挪过来，右下角那个按钮点一下。 | **鼠标挪过来，右下角的按钮点一下。** | Bring your cursor over and hit the button at the bottom right. | **Bring your cursor over and press the button at the bottom right.** |
| translate.later.confirm | 译文来了。 | **译文来了。** | Translated. | **Translated.** |
| move.title | 甩去一个角落 | **放到你喜欢的角落** | Fling it to a corner | **Put it in a corner you like** |
| move.body | 双指按住面板，往哪个角一甩，它就落在哪。 | **双指按住面板，轻轻往一个角推过去，它会自己落好。** | Two fingers on the panel, flick toward any corner. It'll land there. | **Two fingers on the panel, nudge it toward a corner. It settles there on its own.** |
| move.beat1 / beat2 | 甩到任意一个角 / 再往屏幕边上一划 | **推到一个角落 / 再往屏幕边上推一下** | Flick it to a corner / Now swipe it into the edge | **Nudge it to a corner / Now nudge it into the edge** |
| move.bodyTuck | 落好了。现在往右边一划，它会藏进屏幕边。 | **落好了。往右边再推一下，它会藏进屏幕边。** | Landed. Now swipe right and it slips into the edge. | **Settled. Nudge it right once more and it slips into the edge.** |
| move.bodyTuckLeft | 落好了。现在往左边一划，它会藏进屏幕边。 | **落好了。往左边再推一下，它会藏进屏幕边。** | Landed. Now swipe left and it slips into the edge. | **Settled. Nudge it left once more and it slips into the edge.** |
| move.forMe | 替我收起来 | **替我收起来** | Tuck it for me | **Tuck it for me** |
| move.tucking | 正在收… | **正在收…** | Tucking… | **Tucking…** |
| move.mouseNote | 用鼠标？到 设置 › 快捷键 给「贴边隐藏」录个键就行。 | **用鼠标的话，在 设置 › 快捷键 给「贴边隐藏」录个键就好。** | On a mouse? Give Hide to Edge a key in Settings › Shortcuts. | **On a mouse, give Hide to Edge a key in Settings › Shortcuts.** |
| move.confirm | 收好了。 | **收好了。** | Tucked away. | **Tucked in.** |
| back.title | 它就贴在这条边上 | **它就在这条边上** | It's right there on the edge | **It's right here on the edge** |
| back.beat1 / beat2 | 鼠标停上去，它会探出头 / 点一下，回来 | **鼠标停上去，它会探出来 / 点一下，回来** | Rest your cursor on it. It peeks out / Click, and it's back | **Rest your cursor on it. It peeks out / Click, and it's back** |
| back.confirm | 回来了。 | **回来了。** | And it's back. | **It's back.** |
| done.title | 就这些，你都会了 | **就这些了** | That's it. You've got it | **That's all** |
| done.body | 五步都做完了。想更顺手？给「显示 / 隐藏面板」录个快捷键，一个键就能叫它出来。 | **往后它就安静地待在一边，想听的时候就在。愿有音乐陪着的时候，都是好时光。** | All five moves done. Want it faster? Give Show / Hide panel a key and summon it from anywhere. | **From here on it stays quietly to the side, there whenever you want it. I hope the time you spend with music, and with nanoPod, is time you enjoy.** |
| done.deferred.body | 六个做完了，翻译那步等一首外文歌再补。想更顺手？给「显示 / 隐藏面板」录个快捷键。 | **往后它就安静地待在一边，想听的时候就在。翻译那一步，等有外文歌的时候我再来。愿有音乐陪着的时候，都是好时光。** | Six down. Translation waits for a song that needs it. Want it faster? Give Show / Hide panel a key. | **From here on it stays quietly to the side, there whenever you want it. Translation can wait for a song that needs it; I'll come back then. I hope the time you spend with music, and with nanoPod, is time you enjoy.** |
| done.shortcut / ok | 录个快捷键 / 好了 | **录个快捷键 / 好** | Set a shortcut / All done | **Set a shortcut / OK** |
| done.foot | 以后想重看，设置里有「重看引导」 | **想再走一遍：设置 › 重新认识 nanoPod** | Replay anytime under Settings › Replay tour | **To walk through again: Settings › Get to know nanoPod again** |
| stop / skipStep | 跳过引导 / 这步先跳过 | **先到这里 / 这一步先不做** | Skip the tour / Skip this one | **Stop here / Skip this one** |
| idleHint | 不想做也没关系，随时可以跳过。 | **不着急，随时可以停下。** | No pressure. Skip whenever you like. | **No rush. Stop whenever you like.** |
| settings.row | — | **认识 nanoPod**（设置 › 通用 的行标题） | — | **Getting to know nanoPod** |
| settings.continue（没走完时的按钮） | 继续引导（{n}/7）（原为菜单项） | **接着认识 nanoPod** | Continue tour ({n}/7) | **Keep getting to know nanoPod** |
| settings.again（走完后的按钮） | 重看引导 | **重新认识 nanoPod** | Replay tour | **Get to know nanoPod again** |

### 9.2 命名

- 这套引导本身叫 **「认识 nanoPod」/ "Getting to know nanoPod"**——不是教程，不是 Setup，是认识一个东西。
- 接着走的入口只在设置里，菜单栏不放（v3.1，与菜单稿对齐：那一项会把菜单撑宽，点「以后再说」的人会长期看到它，回头接着走很少发生）。设置 › 通用 有一行「认识 nanoPod / Getting to know nanoPod」，右侧一个按钮随状态变：
  - 没走完（inProgress，或 skipped 且有未完成步）：**「接着认识 nanoPod」/ "Keep getting to know nanoPod"**，点了从停下的地方接着走；
  - 走完了（completed）：**「重新认识 nanoPod」/ "Get to know nanoPod again"**，点了从头走。
  理由：与卡片口吻同一句式（「接着来」），不带「继续设置」的任务感，不带「引导 / Tour」的导游感；不带 (n/7)，进度在卡上看。
- 卡上的两个兜底：**「先到这里」/ "Stop here"**（整套停下）、**「这一步先不做」/ "Skip this one"**（跳这一步）。

## 10. 实现路线

### 10.1 TipKit 还是自绘：自绘

| 需求 | TipKit | 自绘卡片窗口 |
|---|---|---|
| 顺序引导 | `TipGroup(.ordered)` 要 macOS 15，项目最低 14 | 自己的状态机，14 起 |
| 锚 nonactivating 面板里的控件、不抢焦点 | `.popoverTip` 走 NSPopover，菜单栏 app 里普遍需要 key window | `canBecomeKey = false` 的 NSPanel，先例 `LiquidEdgeStageWindow` |
| 锚贴边小条 / 被移走的面板 | popover 绑定 positioningView，跨窗口迁移要销毁重建 | 一个窗口换 frame |
| 卡片在锚点间位移引导视线；玻璃形状带箭头 | 无；泡泡形状由系统定 | 有；`glassEffect(in: Shape)` |
| 进度环 / beats / 状态随动文案 / 火花 | `TipViewStyle` 能画内容，弹出方向与位置算法不可控，受 `displayFrequency` 节流 | 全可控 |

TipKit 留给引导之后的情境提示（§10.5）。

### 10.2 模块与文件

```
Sources/MusicMiniPlayerCore/Onboarding/
  TourModel.swift / TourMachine.swift / TourPersistence.swift / TourPlacement.swift / TourMotionPolicy.swift
  TourAnchorRegistry.swift / TourDetectors.swift
  TourDeferredWatcher.swift    引导结束后唯一残留：一个 $canTranslate + 换歌订阅，触发 / 过期 / 取消
Sources/MusicMiniPlayerAppKit/Tour/
  TourController.swift（@MainActor 执行 effects）/ TourCardWindow.swift / TourCardView.swift（GlassEffectContainer + TourBubbleShape；回退 VisualEffectView .popover + mask）
  TourRingView.swift（连续粗环）/ TourHaloWindow.swift / TourCelebrationView.swift（Canvas + TimelineView）/ TourGestureGlyph.swift（§8.7）/ TourStrings.swift
现有改动：
  LiquidEdgeController.swift   + statePublisher / tuckedRegionInScreen / floatingHitRegionInScreen
  SnappablePanel.swift         + tuckableEdge() / currentCorner() / snappedToCorner 通知（吸附弹簧不改，创始人 09-27 已定）
  MiniPlayerView.swift / LyricsView.swift  + controlsRevealed、audioOutputMenuPresented 通知、封面 .tourAnchor(.artwork)
  HoverableButtons.swift       + musicButtonTapped 通知、.tourAnchor(.music / .translate)
  SharedControls.swift / AudioOutputSwitcherView.swift  + .tourAnchor(.playPause / .lyricsNav / .audioOutput)
  MusicMiniPlayerApp.swift     + menuWillOpen/DidClose 转发、启动门（含延后订阅武装）、删除 OnboardingWindow 三个方法（菜单不加任何引导项）
  SettingsView.swift           + 通用页「认识 nanoPod」一行：按钮读 TourPersistence 状态显示「接着认识 nanoPod」/「重新认识 nanoPod」
  OnboardingState.swift        → 迁移到 TourPersistence（保留 automationStatus / requestAutomationAccess）
  OnboardingView.swift         删除
```

### 10.3 分阶段

- P0 逻辑与测试：Model / Machine / Persistence / Placement / MotionPolicy / Detectors + 5 个钩子 + §11 单测。
- P1 卡片：窗口 / 视图 / 锚点 / 放置 / 跟随；先硬切换验证位置与不抢焦点；玻璃与回退臂各实测 Reduce Transparency。
- P2 手感：出现 / 位移 / 环 / beats / 火花 / 礼花 / haptic / RM / 手势示意；接 feel channels；创始人终验。
- P3 收尾：文案两语、设置里的入口按钮、schema 迁移、删除 C6 窗口、`nanopod://debug/tour/<show|reset|step/<id>>`。

### 10.4 对现有 C6 的处置

`OnboardingWindowView` 与三个窗口方法删除；`OnboardingState` 里权限查询与请求保留；`shouldPresent` 扩成 §5.5 的门；旧两个键只读一次做迁移。

### 10.5 与菜单 / 设置会话的对齐（只提需求）

1. 菜单只放次高频操作，**不放任何引导入口**（v3.1：菜单稿里的「继续引导… / Continue Setup…」删掉，不用别的名字替代）。
2. 设置改成系统设置式 sidebar；「通用」页一行 **「认识 nanoPod / Getting to know nanoPod」**，右侧按钮随状态变：没走完 **「接着认识 nanoPod / Keep getting to know nanoPod」**（从停下的地方接着走），走完了 **「重新认识 nanoPod / Get to know nanoPod again」**（从头走）；快捷键页可被 `showSettingsWindow(selectedTab:)` 直达（最后一张卡「录个快捷键」用）。
3. 强调色：Apple Music 粉红，浅色 `#FA4058`、深色 `#FB546C`（菜单 / 设置 v2 定稿）；卡片、进度环、beat、火花全部跟随，派生档见 §4.7。
4. 菜单 v2 已按「面板里有的不进菜单」移除「显示翻译」，本方案不再有任何指向菜单的引导，也不锚定状态栏图标；菜单 `menuWillOpen` / `menuDidClose` 转发通知仍要（面板在右上角时菜单会盖到卡片）。
5. 后续项：引导结束后用 TipKit 做 2–3 条情境提示——点歌词行 seek（进入歌词页第 3 次）、全屏封面开关、给面板录快捷键（第 5 次手动显示隐藏后）。

## 11. 空闲成本与验收（代码层）

创始人禁止截图 / 录屏 / computer use；自验只做代码层，手感由创始人终验。

### 11.1 单元测试清单

| 文件 | 钉住什么 |
|---|---|
| `TourMachineTests` | 顺序完成 → phase 与 effects 表；beat 任意顺序；乱序完成长环不跳卡；提前收边直达 S6；stopTour / skipStep；resume；schema 升级只含新步；`finaleDismiss` 与 8 s 超时都 teardown；假时钟驱动 `transitioning`；延后：进入 S4 时 canTranslate 为假 → deferred 不长环；终局带 deferred → `idle(deferredArmed: true)`；`canTranslateBecameTrue` 3 s 门、面板不可见不出、一次启动只出一次；3 首未做 / 20 次启动 → skipped；触发时 showTranslation 已真 → 静默完成 |
| `TourDetectorTests` | 注入 `PassthroughSubject` 模拟各信号 → 正确 `TourSignal`；`.expanding` 中途不算 tuck；`.floating → .card` 两 beat；snappedCorner 判定表（四角 ±1pt、非角不算）；延后判定表（noLyrics / networkUnreachable / 已是目标语言 / searching > 3 s） |
| `TourPlacementTests` | 面板在 1440×900 可视区四角 × 两类锚点的放置表；两侧都放不下的兜底；小条左右两边；卡不与面板 frame、不与 floating hit region 相交 |
| `TourRingTests` | 环的 trim 值 = 已完成步数 / 7；延后时 6/7 不合圈；S4L 完成后 7/7 合圈一次；Reduce Motion 下无脉冲 |
| `TourPreconditionTests` | `shouldPresent` 表；时机门 |
| `TourMotionPolicyTests` | RM 开 / 关全表；庆祝队列一次一个 |
| `TourAnchorRegistryTests` | 未激活不发 preference；窗口 → 屏幕矩形；真 `NSHostingView` + `NSWindow` 钉死 32pt 托管条不产生偏移 |
| `TourBubbleShapeTests` | 箭头位置 / 边的 path 数学（四边 × offset 夹取） |
| `TourTeardownTests` | 完成 / 停下后：`TourController` weak 为 nil；观察者计数回零；无 display link / timer；`TimelineView` paused 且已移除；`WindowAnimationCensus.sweepAllWindows()` 报告里没有 Tour* 窗口，`effectViews` 清单与引导前一致；带延后步时活着的订阅恰好一个（`TourDeferredWatcher`），补完 / 过期后为零 |
| `TourStringsTests` | 每个 key 中英都有；长度上限；不含禁用词表（「v3 改了什么」第 1 条列出的那几个词，表本身放在测试里）|

### 11.2 零常驻的检测方法

- 引导结束后 `nanopod://debug/animsweep`：窗口清单里不得有 Tour* 窗口；`effectViews`（玻璃 / vibrancy）数量回到引导前；动画数一致。
- 进行中：唯一的每帧工作是火花 / 礼花的 `TimelineView`（0.55 s / 1.8 s）与手势示意（两轮后停）；高亮环落定是一次性动画，`isRemovedOnCompletion = true`。
- 检测器只有 Combine sink 与通知观察者，无轮询；`TourAnchorKey` 只在激活时发值。
- 延后步武装期间：全进程只多一个 `$canTranslate` + 换歌 sink，无窗口、无视图、无每帧工作；S4L 出现时才重建卡窗与高亮环，完成即销毁。

### 11.3 创始人终验清单（手感）

玻璃卡在深浅色桌面上的通透度是否「轻」；卡出现是否从锚点长出来；位移是否把视线带到下一个控件；面板被推走后卡从新位置长出的时机；环长一截与火花是否同一拍、粗环的圆头是否干净；收边时卡淡出早于液态第一帧；小条旁的卡不碍 hover；合圈脉冲与礼花的量；手势示意与系统设置演示的相似度；文案读起来是不是像朋友在说话；Reduce Motion 下完全无位移。

## 12. 开放问题与后续项

- 32pt 托管条与 `.global` 坐标的关系要用真控件实测一次。
- `hideToNearestEdge()` 在面板离边很远时先弹到角再收，约 0.6 s——卡文案「正在收…」。
- 胶囊「换歌自动弹出 2.5 s」落地后 S6 的 hover beat 要区分来源。
- 完整版接入网易云 / QQ 后，「和 Music 打招呼」与 ↖ 按钮按播放源改名与判定。
- 歌单页定位裁定后若保留，第 8 步与 3–7 上限冲突，届时得合并歌词 + 翻译。
- 情境提示（TipKit）属于后续项。

## 13. 已定（创始人 2026-09-27）

1. **7 步**。不合并歌词与翻译；总长按一般用户 75–110 秒。§3.4 的两刀作废。
2. **移到角落的弧线只放在引导演示里**。真实面板的吸附不改（仍是两轴共用一段 `Spring(duration: 0.5, bounce: 0.15)`、各带初速度），也不加开关；演示走固定的二次 Bézier 弧（弧高 9% 位移、最高点 45%、0.6 s ease-out，向屏幕中心鼓出），落点仍是右下角 16pt（§8.8）。

余下由他真机比完再定的都是运行时 feel channel：卡片材质 glass / clear / vibrancy、火花有无。
