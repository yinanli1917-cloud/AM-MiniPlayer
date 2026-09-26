# nanoPod 交互式引导（Guided Tour）设计方案 v2

日期 2026-09-26（v1 2026-09-25）· 状态：按创始人 09-26 六条反馈改稿，待评审 · 本方案不改 Sources/ 与 Tests/ · 配套：同目录 `storyboard.html`（可点的分镜）、`research/` 三份调研报告

v2 相对 v1 的改动：卡片材质改 Liquid Glass（§4.6 给出选择理由与三条教训的处理）；新增「专辑页的两个角」与「甩到角落」两个动作，重新分组为 7 段（§3）；文案全部改成亲切口吻，中英两套（§9）；触控板手势示意按创始人录的系统设置「触控板」页演示逐帧规格重做（§8.7，`research/trackpad-demo-frames.md`）；强调色换成 Apple Music 粉红（浅 `#FA4058` / 深 `#FB546C`，取自本机 Music.app 图标渐变取样，出处 `docs/design/2026-09-25-menu-settings/proposal.md` 开头）；与菜单 / 设置 v2 对齐（§10.5）。v2.1（同日）：菜单 v2 移除了「显示翻译」项，当前歌不能翻译时的分支改为延后到第一首能翻的歌再教（§3.3 S4′/S4L），不再有状态栏锚点。

## 0. 一段话结论

把现有 C6 的三页说明窗口换成一条「边做边学」的旅程：一张 236pt 宽的 Liquid Glass 引导卡贴在要操作的控件旁边、跟着用户走（面板被甩到别的角落时卡也跟过去）；7 段进度环 = 1 个只在权限未授时出现的「和 Music 打招呼」闸门（通常预填，用户从 1/7 起步）+ 6 个练习步：悬停·播放 → 专辑页的两个角 → 歌词 → 翻译 → 甩到角落再划进边 → 拿回来。每步靠真实状态信号自动判定完成，卡上没有「下一步」；beat 完成打勾 + 一次触觉，一段完成才填环 + 16 粒火花；最后一段七段缝合成整圈、放唯一一次礼花。卡片自绘（独立 nonactivating NSPanel）不用 TipKit；检测走现有 `@Published` 信号，新增 5 个小钩子；当前歌不能翻译时，翻译一步延后到第一首能翻的歌再教；引导结束整套对象销毁，只留那一个延后订阅。总时长 75–110 秒。

## 1. 要解决的问题与原则

现状（`Sources/MusicMiniPlayerAppKit/OnboardingView.swift`、`Sources/MusicMiniPlayerCore/Services/OnboardingState.swift`）：C6 是欢迎 / 授权 / 完成三页向导，普通 `NSWindow`，`showOnboardingWindow()` 会 `NSApp.activate(ignoringOtherApps: true)` 抢焦点（`MusicMiniPlayerApp.swift:856-867`）；只有文字说明，看完就忘（NN/g：短时记忆约 20 秒）。创始人 09-25 的要求：让用户亲手把高频且不直观的操作做一遍，卡片弹在要点的位置旁边，每步进度环推进 + 小礼花，精致。09-26 补充：玻璃卡、两个漏掉的动作、亲切口吻、优雅动效、对齐菜单 / 设置会话。

原则：

1. 只教高频且不自明的操作；自明的不教（播放键只作为一个 beat 顺带确认）。
2. 边做边学：完成 = 检测到真实状态变化。卡上没有「下一步」，只有「这步先跳过」兜底。
3. 一次只有一张卡，一张卡只讲一个地方（HIG Popovers："show one popover at a time"）；一张卡可以有两个 beat，高亮环在 beat 之间跳。
4. 卡片永不盖住要操作的东西，不成为 key window，不抢焦点，不出声音。
5. 铁律：引导自己不触发任何系统弹窗。当前歌不能翻译就把翻译一步延后（不指向设置、不改锚点）；Music 自动化权限的系统询问只在用户点了「好，连上」之后出现。
6. 随时可跳、随时可回来（菜单栏「继续引导」）；已会的自动跳过（预勾、预填）。
7. 庆祝分量匹配事情大小：beat 只打勾，一段一次小火花，只有终局放礼花（Intuit 内容规范、庆祝疲劳研究）。
8. 零常驻：结束后无窗口、无玻璃、无每帧工作、无 timer、无 `TimelineView`；`WindowAnimationCensus` 扫不到任何残留。唯一允许的残留是延后步的一个 Combine 订阅（订现有的 `LyricsService.$canTranslate`，事件驱动、零每帧成本），补完或过期即取消。

## 2. 调研结论摘要

详见 `research/internal-ops-hooks.md`、`research/cleanshot-exemplars-nng.md`、`research/apple-tipkit-haptics-particles.md`。只列影响设计的结论。

### 2.1 内部代码事实

- 高频操作与可订阅信号：播放 `MusicController.isPlaying`（`MusicController.swift:174`）；三页 `MusicController.currentPage`（`:205-211`）；翻译 `LyricsService.showTranslation`（`LyricsService.swift:121`，UserDefaults `showTranslation`，默认 false）、`canTranslate`（`:173`）；歌词显示态 `LyricsDisplayState`（`:28-87`）。
- 控件悬停才出现：专辑页 `showOverlayContent` 随 `onContinuousHover` 翻真（`MiniPlayerView.swift:193-206`），歌词页 `showControls`（`LyricsView.swift:1769`）。`fullscreenAlbumCover` 默认 true（`MusicMiniPlayerApp.swift:74-77`）。
- 专辑页两个角（`MiniPlayerView.swift:167-186`，只在 `showControls || isAudioOutputMenuPresented` 且专辑页时挂载）：左上 `MusicButtonView`（`HoverableButtons.swift:194-214`，`↖ Music` 胶囊，padding 10/6，`NSWorkspace.openApplication` 打开 /System/Applications/Music.app）；右上 `AudioOutputSwitcherView`（`AudioOutputSwitcherView.swift`，触发钮 32pt，列表宽 214，`onMenuPresentedChanged` → `isAudioOutputMenuPresented`）。两者各留 12pt 内边距。
- 底部控件几何（`SharedControls.swift:154-176`）：左下歌词按钮 26×26、中间播放簇 3×30 间距 10、右下歌单按钮 26×26，水平 padding 12、底 padding 16；翻译按钮 32×32 在歌词页控件右上（`:131-138`）。
- 甩到角落（`SnappablePanel.swift`）：双指在面板上拖动（`handleScrollDrag`，灵敏度 1.5），松手 `handleScrollEnd`（`:344-362`）先判贴边（`checkAndHideToEdgeWithVelocity`，离边 20pt 内且速度 > 50 且横向占优）；否则 `snapToCorners` 为真时 `calculateTargetCorner(velocity:)`（`:721-745`）：按 `projectionFactor = 0.28` 把速度投影成落点，落点中心在可视区哪个象限就弹到哪个角，角边距 `cornerMargin = 16`。鼠标拖拽只移动、不吸角、不贴边（`:291`）。弹簧结束时发 `.windowMovementEnded`（`:693-695`）。
- 贴边收起：面板离屏幕边 ≤ 28pt（`edgeProximity`，`:184-191`）时双指横向划过 10pt（`LiquidEdgeGestures.swift:17`）；全局快捷键 `hideToEdge` 无默认键。展开：点小条 / 胶囊，或 hover 停留 0.08s 探出胶囊（`LiquidEdgeController.swift:240-253`）。收边时面板窗口被 `orderOut`（`:221-225`）。`LiquidEdgeController.state` 是 `private(set)`、非 `@Published`。
- 面板窗口：`SnappablePanel: NSPanel`，`[.titled, .resizable, .fullSizeContentView, .nonactivatingPanel]`，`level = .floating`，`canBecomeKey = true`。伴随窗口范式 `LiquidEdgeStageWindow`（`LiquidEdgeStageView.swift:108-130`）。未用过 `addChildWindow`。
- 面板默认位置：`NSScreen.main.visibleFrame` 右上角、各留 20pt（`:360-370`）——在 28pt 贴边判定内。位置与尺寸不持久化。
- 玻璃先例：`PanelBackdrop.swift` 已有 `NSGlassEffectView`（`.regular` / `.clear` 两臂，`cornerRadius = 16`，tint alpha 可调）；`SharedControls.swift:246-249` 用 `GlassEffectContainer` 包播放簇；`Components/VisualEffectView.swift` 是 `NSVisualEffectView` 的 SwiftUI 包装。2026-07-17 A/B（记忆 glass_backdrop_ab）：原生玻璃与不透明 fluid 的 WindowServer 成本打平；2026-06 教训（feedback_glass_effect_container）：多个独立 `.glassEffect()` 各自采样会累积过曝，要包进一个 `GlassEffectContainer`；玻璃叠 `NSVisualEffectView` 禁止。
- 屏幕坐标锚定没有先例；托管视图比窗口高 32pt 但同原点（`PanelWindowMetrics.swift:44-60`），SwiftUI `.global` 到窗口坐标不需减 32pt——需实测钉死一次。
- 状态栏：`statusItem`（`MusicMiniPlayerApp.swift:25`），点击直接弹菜单（`:311-329`），菜单 delegate 已设（`:323`）。
- 无 favorite / 音量 UI；无粒子实现；无 `NSHapticFeedbackManager` 使用；L10n 手写字典跟随系统语言。

### 2.2 CleanShot X 的真相与范例

- CleanShot X **没有**「控件旁锚定卡片 + 进度 + 礼花」这套引导。它是极简首启向导 + 让设置页本身承担教学：清晰分组、随状态变化的提示文字（"hints swapping to reflect the current status"）、误操作保护（Marcin Wichary）。本方案取的是它的品质：精致、文案随状态实时改、不让人踩坑。
- 与创始人描述最接近的现成形态是 Figma 的 10 步走查：锚定控件的卡 + 小动图 + 「5 of 5」进度 + 随时关闭。
- Superhuman：旁支清单完成率 30% → 强制但预填默认值的引导 98%。Linear：「no tour」，一项对应一个动作，做完解锁下一项。Things 3：教程就是一个待办项目。
- NN/g：情境式优于教程式；一次一条、多图少字；引导标注要与真实界面视觉区分；交互式走查 ≈ 练一轮；对「这个 app 特有」的操作最有效。允许跳过的引导完成率高约 25%。步骤条适合 3–7 步。
- 进度心理学：goal-gradient；endowed progress（Nunes & Drèze 2006：预盖 2 章 2/10 起步完成率 34%，0/8 起步 19%）。
- 庆祝：Intuit——只为用户自己完成的事庆祝，常规动作用平实确认；Apple Fitness 社区教训：多个庆祝同时触发会互相顶掉，要排队。

### 2.3 Apple 平台事实

- TipKit：`.popoverTip` macOS 14+；`TipNSPopover` 能锚 `NSStatusItem.button`；`TipGroup(.ordered)` 要 macOS 15，项目最低 14（`Package.swift:9`）；`TipViewStyle` 能重写泡泡内容但改不了弹出位置算法。
- NSPopover：菜单栏 app 里普遍要 key window / `NSApp.activate` 才正常（与「不抢焦点」相悖）。
- 窗口层级（`CGWindowLevel.h`）：`.floating` = 3，菜单栏 `.mainMenu` = 24，`.statusBar` = 25。
- Haptic（`NSHapticFeedback.h`）：`.generic` / `.alignment` / `.levelChange`，`performanceTime: .drawCompleted`；手不在触控板上时系统自动抑制；每次取新的 `defaultPerformer`。
- HIG：Onboarding "brief, enjoyable… people are more likely to complete it"；Launching "postpone nonessential setup"；Motion——Reduce Motion 用 fade 替代缩放 / 位移；The menu bar "When necessary, the system hides menu bar extras"。
- 粒子：Canvas + `TimelineView(.animation(paused:))` 停止即干净；`CAEmitterLayer` 置 `birthRate = 0` 后的开销查不到权威数据，必须 `removeFromSuperlayer`。
- 进度环：`Circle().trim` + `.stroke(lineCap: .round)`；`.contentTransition(.numericText())` 13+；`.symbolEffect(.replace)` 14+。

## 3. 旅程

### 3.1 七段：教哪些、为什么、怎么判完成

| 段 | 名 | 教什么 | 为什么值得教 | 用户动作（beat） | 完成信号 | 预计耗时 |
|---|---|---|---|---|---|---|
| 1 | 和 Music 打招呼（条件） | 权限询问放在用户点按钮之后 | 铁律 5；HIG Launching 不前置设置。已授时预填，不出卡 | 点「好，连上」→ 系统询问 → 好 | `OnboardingState.automationStatus == .authorized` | 5 s |
| 2 | 悬停 · 播放 | 面板静止只剩封面，控件悬停才出现 | 「控件在哪」是面板最不直观的一件事 | ① 移到面板上 ② 按播放（已在放则预勾） | `controlsRevealed`；`isPlaying == true` | 5–10 s |
| 3 | 专辑页的两个角 | 右上换音频输出设备；左上 ↖ Music 跳去 Apple Music（完整版跳对应的原生播放器） | 创始人 09-26 点名；两个按钮只在悬停时出现 | ① 点右上，看看现在从哪出声 ② 点左上 ↖ Music（任意顺序） | `audioOutputMenuPresented`；`musicButtonTapped` | 10 s |
| 4 | 歌词 | 去歌词页的两条路 | 创始人点名；图标语义不自明 | 点左下小气泡或封面 | `currentPage == .lyrics` | 5 s |
| 5 | 翻译 | 歌词页右下角的翻译按钮 | 创始人点名；悬停才现、可翻译才挂载 | 点翻译按钮（当前歌不能翻 → 延后到第一首能翻的歌，S4′/S4L） | `showTranslation` 翻真 | 5–10 s |
| 6 | 甩到角落，再划进边 | 双指一甩落到最近的角；双指往边一划藏进边里 | 创始人 09-26 点名的移动方式 + 招牌收边动作；两个都是双指手势 | ① 甩到任意一个角 ② 再往屏幕边上一划 | `snappedCorner`；`LiquidEdgeState == .tucked` | 15 s |
| 7 | 拿回来 | 它在哪、怎么探出、怎么回来 | 教了收必须教放 | ① 鼠标停上去 ② 点一下 | `.floating`；`.expanding → .card` | 10 s |

流畅用户约 60 秒，一般用户 75–110 秒。7 段是 3–7 建议区间的上限（§3.4）。

**不教什么，理由**：上一首/下一首、shuffle/repeat（自明）；缩放（原生窗口行为，低频）；歌单页（09-12/09-13 创始人对 Up Next 实时性的裁决未闭合）；点歌词行 seek（中频、一句话能说清，放进 §10.5 的情境提示候选）；全屏封面（菜单开关自明）；全局快捷键（没有默认键，是设置任务不是练习动作——终卡把它作为唯一的「下一步」递出）；MusicKit 授权（09-25 记录：等开发者身份认证，留在设置页）；favorite / 音量（没有 UI）。

### 3.2 顺序的理由

打招呼 → 悬停·播放 → 两个角 → 歌词 → 翻译 → 甩·收 → 拿回来。前两段把「有歌在播、控件会出现」建立起来；两个角就在悬停后的专辑页上，紧接着教；歌词在翻译前，因为翻译按钮长在歌词页；甩与收连成一步，因为甩到角之后面板必然在贴边判定内（角边距 16 ≤ 28），划入顺理成章，卡片还会跟着面板跑一次，用户亲眼看到「它跟着我」；拿回来必须紧跟收边。乱序做也允许（§5.4）。

### 3.3 每步规格

坐标以面板 frame 为基准（默认 250×284，`P`）。

**S0 欢迎**
- 时机：首次启动，面板可见且首次播放器状态读取返回（或 2.5 s 超时）之后——避免与系统的 Automation 询问叠在一起。
- 锚：面板朝屏幕中心一侧的边中点，间距 16pt。卡：环（已连接时 1/7 预填 + 「✓ Music 已经连上了」小标签）、标题、正文、「走起」、「先不用」、脚注。
- 「走起」→ S1（权限未授则 G）；「先不用」→ `status = skipped`，卡淡出，菜单栏出现「继续引导」。

**G 和 Music 打招呼（条件：`automationStatus != .authorized`）**
- 「好，连上」→ 现有 `OnboardingState.requestAutomationAccess()`（`OnboardingState.swift:169-171`），返回后重查：authorized → 第 1 段填、小火花；denied → 卡就地换成「Music 还没点头」+「去打开」（`x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`）+「先往下走」。不阻塞后续；S1 的播放 beat 会说明「得先连上 Music 才能从这里放」。

**S1 悬停 · 播放**
- 锚：播放按钮中心 `(P.minX + 125, P.maxY − 31)`；高亮环 40pt 从卡出现起就标出隐藏按钮的位置，悬停时按钮在环里浮现。
- beats：① 「移到面板上」← `controlsRevealed`；② 「按一下播放」← `isPlaying`；已在播放则 ② 预勾并写「已经在放了」。
- 边界：Music 没开 → 按播放拉起 Music，正文随动「正在叫醒 Music…」；库里没歌 → beat ② 8 秒未完成时「这步先跳过」变明显。确认「出声了。」

**S2 专辑页的两个角**
- 锚：右上输出钮中心 `(P.maxX − 28, P.minY + 28)`（高亮环 40pt），beat ① 完成后高亮环跳到左上 ↖ Music 胶囊 `(P.minX + 43, P.minY + 23)`（胶囊形 74×34）；卡片位置不变，只换 beat 与环。
- beats：① 「点右上，看看现在从哪出声」← `audioOutputMenuPresented`（新钩子，`onMenuPresentedChanged(true)`）；② 「点左上 ↖ Music」← `musicButtonTapped`（新钩子，action 内 post）。任意顺序。
- 边界：点 ↖ Music 会把 Music 带到前台——面板与卡都是浮动窗，仍在最上；正文随动「Music 在后面开好了，回来接着来。」输出设备只有一个：仍以列表打开为准。完整版：↖ 按钮指向当前播放源的原生 app，文案由播放源决定。用户鼠标离开面板控件隐去 → 高亮环仍在，正文随动「鼠标再挪回面板上」。确认「两个角都认识了。」

**S3 歌词**
- 锚：左下导航按钮中心 `(P.minX + 25, P.maxY − 31)`，高亮环 36pt；卡片位置不变。检测 `currentPage == .lyrics`。无歌词照常完成，S4 走 S4′。确认「到了。」

**S4 翻译**
- 主锚：翻译按钮中心 `(P.maxX − 28, P.maxY − 92)`，高亮环 40pt。检测 `showTranslation` 翻真——检测动作不检测结果。
- 确认「译文来了。」
- **S4′ 延后分支**（`canTranslate == false`：无歌词、网络不可达、歌词已是目标语言，或 `displayState` 仍在 searching 超过 3 s）：这一步标为 `deferred`，不填段、不庆祝；卡就地换成「这首不用翻，先跳过」+「等到一首外文歌，我再来说翻译在哪。」，第 5 段变成粉红虚线轨道，1.1 s 后按 §8.1 的位移走到 S5。为什么不指向设置：设置 › 歌词 里的是总开关，当前歌不能翻时打开它看不到任何结果，用户学到的是一个开关的位置而不是面板上那个按钮；而且引导中途打开设置窗口会把人带离面板。菜单 v2 已按「面板里有的不进菜单」把「显示翻译」移出菜单，所以也不再有菜单栏锚点。
- **S4L 补课卡**：引导结束（完成或跳过）后，只保留一个 `LyricsService.$canTranslate` 订阅。它翻真且面板可见、开播 ≥ 3 s、本次启动还没出过 → 在翻译按钮旁出这一张卡（同 S4 的锚与高亮环）：「这首能翻了 / 鼠标挪过来，右下角那个按钮点一下。」；`showTranslation` 翻真 → 第 5 段填充 + 小火花 + haptic `.alignment` → 七段安静缝合成整圈、脉冲一次，不放礼花（礼花在终局放过了）→ 取消订阅、销毁。`showTranslation` 在触发时已经是 true（用户早在设置里开了）→ 不出卡，静默补段、取消订阅。这首没做 → 换歌时卡淡出，下一首能翻的歌再来，最多 3 首；20 次启动都没遇到能翻的歌 → 静默标 skipped、取消订阅。设置「重看引导」随时可以整套重来。

**S5 甩到角落，再划进边**
- 锚：面板朝屏幕中心一侧的边中点；无高亮环（动作是手势）；卡内触控板手势示意先演「斜甩」（§8.7），目标角亮一团角落光；beat ① 完成后卡片跟着面板飞到新位置，正文换成「落好了。现在往右边一划，它会藏进屏幕边。」示意换成「横划」，目标边亮边缘光。
- beats：① 「甩到任意一个角」← `snappedCorner`（新钩子：弹簧动画结束且 origin 落在四角目标 ±1pt）；② 「再往屏幕边上一划」← `.collapsing` 一出现卡立刻淡出，`.tucked` settled 记完成。
- 目标边由落的角决定：右边角 → 「往右边一划」；左边角 → 「往左边一划」（Stage Manager 开着时只教右边的角，左边落定也让用户先甩到右边）。
- 替代路径：「替我收起来」→ `hideToNearestEdge()`（`SnappablePanel.swift:423`），用户没做手势但看到结果、能学 S6；脚注「用鼠标？到 设置 › 快捷键 给「贴边隐藏」录个键就行。」鼠标拖拽不吸角：beat ① 对鼠标用户 8 秒后也显示「这步先跳过」。
- 用户先划入边（跳过甩）→ ①② 同勾。中途又展开 → 不算完成，卡回面板旁。
- 第 6 段的填充与火花在 S6 卡出现时补放（此刻卡片已隐去）。

**S6 拿回来**
- 锚：贴边小条 6×56（面板中线高度）；卡放在 `hitRegion(for: .floating)` 之外再留 20pt；高亮环 18×72 药丸贴着小条。
- beats：① 「鼠标停上去，它会探出头」← `.floating`；② 「点一下，回来」← `.expanding` 后 settled 回 `.card`。直接双指向内划 → 同勾。确认「回来了。」→ 终局（§8.2）。

**S7 终卡**
- 锚同 S0（面板在它落的角）。环整圈 + 勾；「就这些，你都会了」；「录个快捷键」→ `showSettingsWindow(selectedTab:)` 直达快捷键页；「好了」；脚注「以后想重看，设置里有「重看引导」」。8 秒无操作自动收起；写 `status = completed`、`schema = 2`，整套对象销毁。

### 3.4 步数与总长的取舍

7 段是步骤条建议区间（3–7）的上限，理由：创始人点名的动作有五个（歌词、翻译、收边、两个角、甩动），加上必要的前置（悬停·播放）与必要的收尾（拿回来），已经把能合的合了——两个角合成一步两个 beat，甩与收合成一步两个 beat。再往下合只剩两种：把歌词与翻译合成「歌词页」一步两个 beat（6 段，省约 15 秒，代价是创始人点名的两个时刻只剩一个环填充），或把第 1 段从环里拿掉当成卡外的前置（6 段，代价是失去预填带来的 endowed progress）。都不推荐；创始人若要更短，第一刀是合并歌词与翻译。

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

`TourAnchor { id, screenRect, screen }`，三类：
1. 面板内控件：新增 `TourAnchorKey: PreferenceKey`，修饰符 `.tourAnchor(.playPause)` 挂在 `PlayPauseControlButton`、`leftNavigationButton`、`TranslationButtonView`、`MusicButtonView`、`AudioOutputSwitcherView` 触发钮与专辑页封面上；`MiniPlayerView` 根部收集 → `TourAnchorRegistry`。未激活时修饰符不发 preference。控件隐藏（未悬停）时用上次已知矩形。
2. 贴边小条：`LiquidEdgeController.tuckedRegionInScreen` / `floatingHitRegionInScreen`。
（v2.1 起不再有状态栏锚点。）

### 4.3 放置算法（纯函数，可测）

```
place(cardSize, anchor, panelFrame, visibleFrame) -> (origin, beakSide, beakOffset)
面板内控件 / 面板边：side = 面板朝屏幕中心的一侧；x = 面板外 16pt；该侧放不下换另一侧；都放不下放面板上下方
  y = clamp(anchor.midY − h/2, visible.minY + 8, visible.maxY − 8 − h)；beak offset = clamp(anchor.midY − y, 18, h − 18)
贴边小条：x = floatingHitRegion 之外 20pt；y 同上；beak 朝屏幕边
```

### 4.4 跟随、隐藏、恢复

- 只订阅：面板的 `didMove` / `didResize` / `didChangeScreen`、已有的 `.windowMovementBegan` / `.windowMovementEnded`（`SnappablePanel.swift:247, 281, 619, 694`）、`didChangeScreenParametersNotification`、面板可见性。不轮询。
- 拖动 / 甩动开始 → 卡 0.14 s 淡出；弹簧落定（`.windowMovementEnded`）→ 重新放置、卡从新位置长出（S5 的 beat ① 就是这条通路）。
- 面板被 `togglePanel` 隐藏 → 卡隐；再出现 → 回。收边 → 按 S5/S6 规则。菜单开 → 隐；关 → 回。显示器参数变化 → 重放置到锚点所在屏。

### 4.5 高亮环 overlay

盖住面板的透明窗口 `TourHaloWindow`：`ignoresMouseEvents = true`、level 同面板并排其上、frame = 面板 frame、随 §4.4 同一套通知移动。内容一个圆环或药丸：1.5pt 粉红描边、外 3pt 12% 光晕；出现时从 1.25× 落到 1×（spring .9 s，一次），之后静止（不再呼吸）；beat 之间的跳转用 spring(.42, .85) 位移。只在 S1–S4、S6 与延后的 S4L 存在。

### 4.6 材质：Liquid Glass，回退 `.popover` 材质

创始人 09-26：玻璃、轻一点、走原生。三条候选与结论：

| 候选 | 看起来 | 能不能带箭头 | 代价 | 结论 |
|---|---|---|---|---|
| `NSVisualEffectView` `.hudWindow` | 深灰厚磨砂 | 能（maskImage） | 已知在 Liquid Glass 下过曝（CLAUDE.md 性能陷阱） | 不用 |
| `NSVisualEffectView` `.popover` / `.menu` | 经典 vibrancy 轻磨砂，系统 popover / 菜单同款 | 能（`maskImage` 画卡体 + 箭头，系统 popover 就是这么画的） | 合成器每帧重算的是它后面的内容变化；卡在面板旁边、后面是桌面，基本静止 | **macOS 14/15 回退臂** |
| `NSGlassEffectView` / SwiftUI `.glassEffect`（macOS 26） | Tahoe 系统菜单、TipKit 气泡同款 Liquid Glass，有折射与边缘高光 | `NSGlassEffectView` 只有圆角矩形；SwiftUI `.glassEffect(.regular, in: Shape)` 接受任意 Shape，卡体 + 箭头可以是一个形状 | 2026-07-17 A/B：原生玻璃与不透明 fluid 成本打平；同样是后面静止就不重算 | **macOS 26 主臂** |

选 Liquid Glass 的理由：（1）目标系统 macOS 26 的菜单栏菜单、系统 popover、TipKit 都是玻璃，引导卡是「系统在教你」的语气，材质要和系统一族；创始人 09-12 也要求提高 Liquid Glass 原生度。（2）成本不是杠杆（A/B 打平），而且引导期间短暂存在、结束销毁（§11）。（3）`.regular` 就是「轻」的那档：无 tint、无额外暗底；`.clear` 更透但是给媒体背景用的，文字可读性不够，作为 A/B 臂留着。

三条教训的处理：
- `.hudWindow` 过曝 → 不用它；回退臂用 `.popover`。
- 玻璃叠玻璃累积过曝 → 一张卡只有一个玻璃形状（卡体 + 箭头同一个 `TourBubbleShape`），包在一个 `GlassEffectContainer` 里；卡内按钮是实色胶囊，不做玻璃按钮；高亮环 overlay 与礼花窗口没有材质；放置规则保证卡永不盖住面板（面板底材可能是 fluid 也可能是玻璃臂）。
- 模糊每帧重算 → 卡在面板旁边、后面是桌面或其他窗口，不在歌词上方；面板拖动 / 甩动 / 收边期间卡隐去（后面在动的时候它不在）；引导结束卡窗口 `close()`、玻璃视图随之释放，`WindowAnimationCensus` 的 `effectViews` 清单必须回到引导前。

实现：SwiftUI `TourCardView` 根部 `GlassEffectContainer { content.glassEffect(.regular, in: TourBubbleShape(side:offset:)) }`（`#available(macOS 26)`），否则 `VisualEffectView(material: .popover, blendingMode: .behindWindow)` + `maskImage`。Reduce Transparency：Liquid Glass 与 vibrancy 材质都由系统自动转成不透明底，实现时各实测一次。A/B 通道 `nanopod://debug/feel/tourCard/<glass|clear|vibrancy>` 让创始人现场比。

### 4.7 视觉规格

| 项 | 规格 |
|---|---|
| 尺寸 | 宽 236pt 固定；高随内容（92–186pt）；圆角 14pt continuous；箭头 12pt 等腰，同一形状 |
| 材质 | §4.6。顶部 1px 内高光（玻璃自带）；外 0.5px 8% 描边；深色下 hasShadow 交给玻璃 |
| 字 | SF Pro Text：标题 13 semibold；正文 12 regular 次级色；beat 12；脚注 10.5；环内数字 9 semibold tabular |
| 进度环 | 22pt，线宽 2.5，7 段、段间 7°、12 点钟起；轨道 12% 对比色，填充 Apple Music 粉红：浅色外观 `#FA4058`、深色外观 `#FB546C`（取自本机 Music.app 图标渐变取样，出处 `docs/design/2026-09-25-menu-settings/proposal.md` 开头）；延后的段画成粉红 50% 虚线轨道 |
| 强调色派生 | 文字用的 ink 档：浅 `#D42640`（同色相压暗到 4.5:1 以上）、深 `#FF8497`（提亮）；柔底 soft：浅 rgba(250,64,88,.12)、深 rgba(251,84,108,.16)；高亮环光晕 rgba(250,64,88,.35)；火花 60% 用主色、40% 白 |
| beat | 14pt 圆点描边 → 实心粉红 + 白勾；完成行文字转次级色 |
| 按钮 | 主按钮胶囊 11pt semibold 反色；次按钮 12% 对比色底；链接 11pt 次级色 |
| 一句确认 | 完成瞬间正文下方 12pt semibold：「出声了。」「两个角都认识了。」「到了。」「译文来了。」「收好了。」「回来了。」 |

### 4.8 状态随动文案

正文随当前状态改：Music 是否在开、控件是否隐去、翻译这首为什么延后、落在哪个角、Music 是否已在前台……每个分支一句 ≤ 20 字的直说（§9）。判定源全部是已有的 `@Published` 或钩子。

## 5. 状态机与持久化

### 5.1 类型

```swift
enum TourStep: String, CaseIterable, Codable { case connect, reveal, corners, lyrics, translate, moveTuck, back }
// 每步 introducedIn: Int（schema）
enum TourStepState: String, Codable { case pending, completed, skipped, deferred }
enum TourPhase: Equatable { case idle(deferredArmed: Bool), welcome, step(TourStep, beats: [Bool]),
                            transitioning(from: TourStep?, to: TourStep?), finale, deferredTip(TourStep) }
enum TourEvent { case start, skipTour, skipStep, signal(TourSignal), anchorUnavailable(TourStep), anchorRestored(TourStep),
                 panelHidden, panelShown, panelMoving, panelSettled(corner: Corner?), panelTucked, panelExpanded,
                 canTranslateBecameTrue(secondsIntoSong: Double), songChanged, launch,
                 resume(completed: Set<TourStep>), appWillTerminate, finaleDismiss }
```

`TourMachine` 是纯值类型 reducer：`(phase, event, snapshot) -> (phase, effects)`，与 `LiquidEdgeReducer` 同一写法。

### 5.2 转移要点

- `welcome + start` → 权限未授 `step(.connect)`，否则第一个未完成步。
- `step(s) + signal(完成 s 的最后一个 beat)` → `transitioning(s → next)` → 反馈时长后 `step(next)` 或 `finale`。
- beat 完成不换 phase，只更新 `beats`，效果 `.checkBeat` + `.haptic(.levelChange)`；`corners` 的两个 beat 任意顺序。
- `step(s) + signal(完成 t ≠ s)`（乱序）→ 记 t 完成、填 t 段、小火花；phase 不变。
- `step(.moveTuck) + panelSettled(corner: some)` → beat ① 勾，效果 `.relocateCard`；`+ panelTucked` → 段完成；`step(any) + panelTucked` → 记 `.moveTuck` 完成 → `step(.back)`。
- `step(.back) + panelExpanded` → 两 beat 同勾 → 完成 → finale。
- `any + skipTour` → skipped → `idle` + teardown；`step(s) + skipStep` → s 标 skipped（不填段）→ 下一步。
- `step(.translate)` 进入时 `snapshot.canTranslate == false` → `.translate` 标 deferred，效果 `.showDeferralNote`（1.1 s）→ `transitioning(.translate → .moveTuck)`。
- `finale + finaleDismiss | 8 s` → completed → 有 deferred 步则 `idle(deferredArmed: true)` + teardown（只留 `$canTranslate` 订阅），否则 `idle(deferredArmed: false)` + 全量 teardown。
- `idle(deferredArmed: true) + canTranslateBecameTrue(≥ 3 s)`，且面板可见、本次启动未出过 → `deferredTip(.translate)`（重建卡窗 + 高亮环）；`+ signal(showTranslation)` → 段完成、安静合圈 → `idle(false)` + 取消订阅；`+ songChanged` → attempts += 1 → `idle(true)`，attempts ≥ 3 → 标 skipped、取消订阅；`+ launch` 累计 20 次未触发 → 标 skipped、取消订阅。触发时 `showTranslation` 已为 true → 静默标 completed、取消订阅。

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

- 激活期间所有剩余步的检测同时武装；先做完的先填段。当前卡不跳，等它那步完成再走到下一个未完成步。
- 开始时就满足的（已在播放、翻译已开、已授权）→ 预勾 / 预填，不出那张卡。
- 跳过 → 不再自动出现；菜单栏「继续引导」从第一个未完成步继续。
- 退出 app → inProgress；下次「欢迎回来」卡（S0 变体：「上次做到 {n}/7，接着来。」），自动续显最多 3 次。

### 5.5 前置条件门

`shouldPresent(status, schema, launchCount, forced)` 沿用 C6 思路；再叠时机门：面板可见 ∧（首次状态读取已返回 ∨ 2.5 s 超时）∧ 没有系统询问在前台。

### 5.6 schema 升级

步骤带 `introducedIn`；老用户已 completed 且 `nanoPodTourSchema < currentSchema` → 只出新增步的迷你旅程，欢迎卡改「有个新东西」。C6 → v2 首个版本，所有步 `introducedIn = 2`。

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
| 甩到角落 | **否** | `SnappablePanel.swift:693-695`（弹簧结束） | 新增 `.nanoPodPanelSnappedToCorner`（userInfo 带角），判定 origin 落在四角目标 ±1pt；暴露 `public func currentCorner() -> Corner?` |
| 贴边状态 | **否** | `LiquidEdgeController.state`（`private(set)`） | 新增 `statePublisher` + `tuckedRegionInScreen` / `floatingHitRegionInScreen` |
| 面板近边 | 否（`private nearEdge`） | `SnappablePanel.swift:184` | 暴露 `tuckableEdge() -> Edge?` |
| 面板移动 / 缩放 / 换屏 / 可见 | 是 | `NSWindow` 通知 + `.windowMovementBegan/Ended` | 无 |
| 控件屏幕矩形 | **否** | — | `TourAnchorKey` + `.tourAnchor(_:)` ×6 + 根部收集 |
| 可翻译（延后步触发） | 是 | `LyricsService.$canTranslate`（`:173`）+ `MusicController.$currentTrackTitle`（换歌） | 无新钩子；引导结束后只保留这一个订阅，完成或过期即取消 |
| 菜单开 / 关 | 是（delegate 已设） | `menuWillOpen` / `menuDidClose` | 转发为通知 |
| 设置页直达 | 是 | `showSettingsWindow(selectedTab:)` | 快捷键页需可选中 |

真正的新钩子 5 个：控件出现、输出列表打开、↖ Music 点击、甩到角落、贴边状态发布；其余是暴露已有值。

## 7. 前置条件与边界矩阵

| 情形 | 处理 |
|---|---|
| 没在放歌 | S1 beat ② 等用户按播放；8 s 未完成「这步先跳过」变明显 |
| Music.app 没开 | 按播放拉起 Music；文案随动 |
| Automation 权限未授 / 被拒 | G 闸门；拒绝 → 设置深链 + 「先往下走」 |
| ↖ Music 把 Music 带到前台 | 面板与卡浮动仍在最上；文案「Music 在后面开好了，回来接着来。」 |
| 只有一个输出设备 | beat 以列表打开为准 |
| 当前歌没歌词 / 网络不可达 / 已是目标语言 | S3 照常；S4 → S4′ 延后（第 5 段虚线），第一首能翻的歌再出 S4L；绝不弹窗、不指向设置 |
| 从未播放能翻译的歌 | 延后步 20 次启动后静默标 skipped、取消订阅；设置「重看引导」仍可整套重来 |
| 翻译失败 | 算完成（检测动作） |
| 引导开始时窗口已收边 | S0 锚到小条；「走起」后先走 S6，再回第一个未完成步 |
| 中途用户提前收边 | 记 moveTuck 完成，直接进 S6 |
| 只有鼠标 | 拖动不吸角、不能划：S5 8 s 后「这步先跳过」变明显 + 「替我收起来」按钮 + 脚注指向快捷键 |
| 落在左边角 | 文案「往左边一划」；Stage Manager 开着 → 只教右边 |
| 多显示器 | 卡放在锚点所在 `NSScreen`；面板换屏重放置 |
| 全屏 Space | 卡窗 `collectionBehavior` 同面板 |
| 面板被 togglePanel 隐藏 | 卡随隐随现 |
| 用户拖动 / 甩动 / 缩放面板 | 动中卡淡出，落定后从新位置长出 |
| 用户不按顺序 | 全部检测同时武装；先做完先填段 |
| 提前做过 | 预勾 / 预填，不出卡 |
| 中途跳过 / 退出 app | skipped / inProgress；菜单栏「继续引导」 |
| Reduce Motion / Reduce Transparency | §8.4；材质由系统转不透明 |
| 多个庆祝同时到 | 庆祝队列，一次只播一个 |
| 老用户 schema 升级 | 只出新增步 |
| 卡片 30 s 无人理（非终卡） | 正文补一句「不想做也没关系，随时可以跳过。」 |

## 8. 反馈节奏与动效规格

原则：优雅 = 少而准。每次只动一个东西，位移用速度连续的弹簧，内容错峰 40 ms 淡入；没有呼吸循环、没有常驻动画；只有用户刚做完的动作才允许过冲。

### 8.1 完成一步（≈ 1.0 s 到下一张卡就位）

| t | 发生什么 | 规格 | Reduce Motion |
|---|---|---|---|
| 0 ms | 检测到完成 | haptic `.levelChange`，`.drawCompleted`，每次取新的 `defaultPerformer` | 保留 |
| 0 ms | beat 打勾 | 圆点 → 实心勾，scale 1→1.22→1，spring(response .28, damping .60) | 直接切换 |
| 50 ms | 环当前段填充 | trim `.smooth(0.45)`（不过冲）；线宽 2.5→3.5→2.5 spring(.30, .60) | linear 0.30 |
| 50 ms | 火花 | 16 粒 2–3.5pt 圆点，初速 90–140 pt/s 全向，阻尼 .88/帧，寿命 0.55 s，粉红 60% / 白 40%，起点环心；`Canvas` + `TimelineView(.animation(paused:))`，结束 `paused = true` | 不放 |
| 100 ms | 环内数字 → 勾 | `.contentTransition(.symbolEffect(.replace.downUp))` 0.30 s | `.replace` |
| 750 ms | 卡内容淡出 | opacity 1→0，0.14 s easeIn | 同 |
| 800 ms | 卡位移到下一锚点 | 窗口 frame spring(response .50, damping .86)，速度连续；箭头在中点 0.1 s 交叉淡化换向 | 原地淡出、新位置淡入 0.16 s |
| 860 ms | 新内容淡入 | 标题、正文、beats 依次 40 ms 错峰，各 opacity + 6pt 自锚点方向位移 0.18 s smooth；环内数字 `.numericText` | 整体 opacity 0.16 s |

beat 完成（不是段完成）只做前两行。

### 8.2 终局（第 7 段完成）

| t | 发生什么 | 规格 | Reduce Motion |
|---|---|---|---|
| 0 ms | 最后一段填充 | 同上；haptic `.alignment` | 保留 |
| 450 ms | 七段缝合 | 段间 7° → 0°，0.30 s smooth | 交叉淡化 |
| 500 ms | 整圈脉冲 | scale 1→1.10→1 spring(.50, .62)；线宽 2.5→4→2.5；描边 粉红→白→粉红 0.4 s | 只闪描边色 |
| 550 ms | 礼花 | 72 粒自面板上沿一线缓缓喷出：初速 220–320 pt/s 向上、锥角 ±30°、重力 360 pt/s²、阻力 .985/帧（末段飘落）、自旋 ±2.5 rad/s、6×9pt 矩形/圆/细条三形、色取封面主色 3（`NSImage+AverageColor` 采样，过暗过灰回退粉红/白/金，哑光）+ 白，寿命 1.8 s，末 0.5 s 淡出；独立点击透传窗口（面板宽 + 160 × 320，面板上方），2.2 s 后关闭 | 不放 |
| 900 ms | 卡长成终卡 | 高度 spring(.40, .85)，文案与按钮错峰淡入 0.2 s | opacity |
| 8 s | 自动收起 | opacity 0.16 s easeIn，scale 1→.97；teardown | opacity |

翻译被延后时的终局：环停在 6/7（第 5 段虚线），不缝合、不脉冲，礼花照放（庆祝的是这一坐的完成），终卡正文改「六个做完了，翻译那步等一首外文歌再补。」补课卡（S4L）完成时：第 5 段填充 + 火花 + haptic `.alignment` → 0.45 s 后七段缝合 + 脉冲（scale 1→1.08→1）→ 不放礼花 → 1.2 s 后卡淡出、销毁。

### 8.3 卡片出现 / 位移 / 消失

| 动作 | 规格 | Reduce Motion |
|---|---|---|
| 出现 | opacity 0→1（前 0.14 s）+ scale .96→1 + 自锚点方向 8pt 位移，spring(response .36, damping .86)，变换原点在箭头 | opacity 0.16 s |
| 位移 | frame spring(.50, .86)，从上一段速度起步 | 淡出淡入 |
| 跟着面板飞（S5 beat ①） | 面板落定后卡从新位置长出（同「出现」），不追着面板飞（追着飞会和液态弹簧打架） | 同 |
| 消失 | 0.16 s easeIn，opacity → 0，scale → .97 | opacity |
| 高亮环 | 出现 1.25× → 1×，spring .9 s 一次，然后静止；beat 间位移 spring(.42, .85) | 直接出现 |

### 8.4 Reduce Motion 总则

读 SwiftUI `accessibilityReduceMotion`（卡内容）与 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`（窗口位移、粒子），监听 `accessibilityDisplayOptionsDidChangeNotification`。一切位移与缩放 → 淡化；粒子不放；触觉保留；环填充线性；手势示意静止在终态。纯函数 `TourMotionPolicy.resolve(reduceMotion:) -> TourMotionSpec`。

### 8.5 建议新增到 `MicroInteractionFeel.Tokens` 的数值

```
tourCardPresentResponse = 0.36, tourCardPresentDamping = 0.86
tourCardTravelResponse  = 0.50, tourCardTravelDamping  = 0.86
tourCardDismissDuration = 0.16, tourContentStagger = 0.04
tourRingFillDuration    = 0.45
tourRingPulseResponse   = 0.30, tourRingPulseDamping = 0.60
tourBeatCheckResponse   = 0.28, tourBeatCheckDamping = 0.60
tourHaloSettleDuration  = 0.90
tourSparkCount = 16, tourSparkLifetime = 0.55
tourConfettiCount = 72, tourConfettiLifetime = 1.8, tourConfettiGravity = 360
tourFinaleAutoDismiss   = 8.0
```

feel channels：`tourCelebration: .sparks（默认）| .quiet`；`tourCard: .glass（默认）| .clear | .vibrancy`。

### 8.6 声音与触觉

不出任何声音（音乐 app）。触觉只在 beat / 段完成瞬间给一次 `.levelChange`；终局一次 `.alignment`。鼠标用户系统自动无感。

### 8.7 触控板手势示意（按逐帧规格）

来源：创始人 09-26 录的系统设置「触控板」页演示（`/Users/yinanli/Movies/Omi Screen Recorder/Screen-2026-09-26-113134.mp4`），Sonnet 子代理用 perceive-animation 逐帧拆解，报告在 `research/trackpad-demo-frames.md`。源规格（966×488 画面）：轮廓 188×142、圆角约 16、描边约 3px #ACACAC、无填充、无阴影；两个圆点直径 22、色 #6B9CFD、中心距约 32；一次位移 0.92–1.02 s，缓动接近 cubic-bezier(0.42, 0, 0.58, 1)，无过冲；运动时沿运动方向拖同色渐隐尾巴（22 → 34–48px）；圆点的出现与静息只做透明度（1.0 → 0.31 → 0 → 0.31 → 1.0），没有缩放；到位后停约 350 ms。源动画末尾约 6% 位移在一帧内贴合终点，属于系统动画的实现痕迹，不复刻。

等比缩进卡内（源 188 → 96，比例 0.51）：
- 轮廓：96×72pt，圆角 8pt，1.5pt 描边（8% 对比色），无填充；在卡内居中占一行。
- 手指：两个 11pt 圆点，`#6B9CFD`（深浅色外观都用它，与系统一致），中心距 16pt，同时出现（源里两点同步，不错峰）。
- 一轮 3.55 s：0–0.45 s 淡入到 1.0 → 停 0.35 s → 0.95 s 位移（cubic-bezier(0.42, 0, 0.58, 1)）→ 停 0.35 s → 0.30 s 暗到 0.31 → 平台 0.58 s → 0.42 s 淡到 0 → 隐 0.15 s。位移量：横划 36pt（源 63/142 的比例落在卡内轮廓上）；斜甩 26×18pt 指向目标角。
- 拖尾：位移中段沿运动方向把一个同色 1.5pt 模糊的副本拉长到 1.8×、透明度 0.45，到位前收回。
- 播两轮后静止在起点、0.31 不透明；卡被 hover 时再播一轮；Reduce Motion 只画起点静止态、无拖尾。
- 两个变体：斜甩（S5 beat ①）、横划（S5 beat ②，方向随目标边）。分镜页的 `tpFling` / `tpSwipe` / `tpTrailD` / `tpTrailH` 四组 keyframes 就是这份规格。
- 实现：SwiftUI `TourGestureGlyph`，一个 `TimelineView(.animation(paused:))` 驱动两轮后 `paused = true`，hover 时重新武装一轮；不用 CAAnimation 循环。

## 9. 文案总表

口吻：像 The Browser Company 那样和人说话——第二人称、短句、口语、偶尔一点俏皮，确认句平实不喊口号。中英各自成立，不是互译。英文由系统语言决定（`L10n` 现有机制），key 命名 `tour.<step>.<field>`。

| key | 中 | 英 |
|---|---|---|
| tour.welcome.title | 嗨，来认识一下 nanoPod | Hi. Let's get you the hang of nanoPod |
| tour.welcome.body | 六个小动作，每个都请真的做一遍。卡片会一路陪着你，两分钟不到。 | Six little moves, each one for real. The card stays with you the whole way. Under two minutes. |
| tour.welcome.start / skip | 走起 / 先不用 | Let's go / Not now |
| tour.welcome.foot | 想重来？菜单栏 ♪ 里有「继续引导」 | Want a redo? It's under ♪ › Continue tour |
| tour.welcome.connected | Music 已经连上了 | Music's already connected |
| tour.resume.title | 欢迎回来 | Welcome back |
| tour.resume.body | 上次做到 {n}/7，接着来。 | You were at {n} of 7. Pick it up here. |
| tour.connect.title | 先和 Music 打个招呼 | Say hi to Music |
| tour.connect.body | nanoPod 靠 Music 放歌、读歌词。点一下，系统会问你一次，选「好」就行。 | nanoPod plays and reads lyrics through Music. Click, macOS asks once, and you're in. |
| tour.connect.allow / later | 好，连上 / 等会儿再说 | Connect / Maybe later |
| tour.connect.denied.title | Music 还没点头 | Music said no |
| tour.connect.denied.body | 到 系统设置 › 隐私与安全性 › 自动化，给 nanoPod 打开 Music。 | Head to System Settings › Privacy & Security › Automation and switch on Music for nanoPod. |
| tour.connect.openSettings / continue | 去打开 / 先往下走 | Take me there / Keep going anyway |
| tour.connect.confirm | 连上了。 | Connected. |
| tour.reveal.title | 把鼠标挪过来 | Bring your cursor over |
| tour.reveal.body | 面板安静的时候只留封面，控件都藏在下面。 | When the panel's resting, it's just the cover. The controls are tucked underneath. |
| tour.reveal.beat1 / beat2 / beat2done | 移到面板上 / 按一下播放 / 已经在放了 | Hover the panel / Hit play / Already playing |
| tour.reveal.openingMusic | 正在叫醒 Music… | Waking Music up… |
| tour.reveal.needAccess | 得先连上 Music 才能从这里放 | Connect Music first to play from here |
| tour.reveal.confirm | 出声了。 | There's your music. |
| tour.corners.title | 专辑页的两个角 | The two corners |
| tour.corners.body | 右上换出声的设备，左上一键跳去 Music。 | Top right picks where the sound goes. Top left jumps you into Music. |
| tour.corners.beat1 / beat2 | 点右上，看看现在从哪出声 / 点左上 ↖ Music | Top right: see where it's playing / Top left: ↖ Music |
| tour.corners.musicOpened | Music 在后面开好了，回来接着来。 | Music's open behind you. Come on back. |
| tour.corners.confirm | 两个角都认识了。 | Both corners, done. |
| tour.lyrics.title | 看歌词 | Now the lyrics |
| tour.lyrics.body | 左下角的小气泡，或者直接点封面。 | The little speech bubble, bottom left. Or just click the cover. |
| tour.lyrics.hoverBack | 鼠标再挪回面板上 | Hover the panel again |
| tour.lyrics.confirm | 到了。 | There you go. |
| tour.translate.title | 顺手开翻译 | Turn on translation |
| tour.translate.body | 右下角这个按钮。译文会跟在每一句下面。 | The button at the bottom right. Every line gets one underneath. |
| tour.translate.confirm | 译文来了。 | Translated. |
| tour.translate.deferred.title | 这首不用翻，先跳过 | This one doesn't need it. Skipping for now |
| tour.translate.deferred.body | 等到一首外文歌，我再来说翻译在哪。 | When a song in another language comes on, I'll show you where translation lives. |
| tour.translate.deferred.confirm | 先记着。 | Noted. |
| tour.translate.later.title | 这首能翻了 | This one can be translated |
| tour.translate.later.body | 鼠标挪过来，右下角那个按钮点一下。 | Bring your cursor over and hit the button at the bottom right. |
| tour.translate.later.confirm | 译文来了。 | Translated. |
| tour.done.deferred.body | 六个做完了，翻译那步等一首外文歌再补。想更顺手？给「显示 / 隐藏面板」录个快捷键。 | Six down. Translation waits for a song that needs it. Want it faster? Give Show / Hide panel a key. |
| tour.move.title | 甩去一个角落 | Fling it to a corner |
| tour.move.body | 双指按住面板，往哪个角一甩，它就落在哪。 | Two fingers on the panel, flick toward any corner. It'll land there. |
| tour.move.beat1 / beat2 | 甩到任意一个角 / 再往屏幕边上一划 | Flick it to a corner / Now swipe it into the edge |
| tour.move.bodyTuck | 落好了。现在往右边一划，它会藏进屏幕边。 | Landed. Now swipe right and it slips into the edge. |
| tour.move.bodyTuckLeft | 落好了。现在往左边一划，它会藏进屏幕边。 | Landed. Now swipe left and it slips into the edge. |
| tour.move.forMe | 替我收起来 | Tuck it for me |
| tour.move.tucking | 正在收… | Tucking… |
| tour.move.mouseNote | 用鼠标？到 设置 › 快捷键 给「贴边隐藏」录个键就行。 | On a mouse? Give Hide to Edge a key in Settings › Shortcuts. |
| tour.move.confirm | 收好了。 | Tucked away. |
| tour.back.title | 它就贴在这条边上 | It's right there on the edge |
| tour.back.beat1 / beat2 | 鼠标停上去，它会探出头 / 点一下，回来 | Rest your cursor on it. It peeks out / Click, and it's back |
| tour.back.confirm | 回来了。 | And it's back. |
| tour.done.title | 就这些，你都会了 | That's it. You've got it |
| tour.done.body | 想更顺手？给「显示 / 隐藏面板」录个快捷键，一个键就能叫它出来。 | Want it even faster? Give Show / Hide panel a key and summon it from anywhere. |
| tour.done.shortcut / done | 录个快捷键 / 好了 | Set a shortcut / All done |
| tour.done.foot | 以后想重看，设置里有「重看引导」 | Replay anytime under Settings › Replay tour |
| tour.skip / skipStep | 跳过引导 / 这步先跳过 | Skip the tour / Skip this one |
| tour.idleHint | 不想做也没关系，随时可以跳过。 | No pressure. Skip whenever you like. |
| menu.tourContinue | 继续引导（{n}/7） | Continue tour ({n}/7) |
| settings.replayTour | 重看引导 | Replay tour |

## 10. 实现路线

### 10.1 TipKit 还是自绘：自绘

| 需求 | TipKit | 自绘卡片窗口 |
|---|---|---|
| 顺序引导 | `TipGroup(.ordered)` 要 macOS 15，项目最低 14 | 自己的状态机，14 起 |
| 锚 nonactivating 面板里的控件、不抢焦点 | `.popoverTip` 走 NSPopover，菜单栏 app 里普遍需要 key window | `canBecomeKey = false` 的 NSPanel，先例 `LiquidEdgeStageWindow` |
| 锚状态栏图标 / 贴边小条 / 被甩走的面板 | popover 绑定 positioningView，跨窗口迁移要销毁重建 | 一个窗口换 frame |
| 卡片在锚点间位移引导视线；玻璃形状带箭头 | 无；泡泡形状由系统定 | 有；`glassEffect(in: Shape)` |
| 进度环 / beats / 状态随动文案 / 火花 | `TipViewStyle` 能画内容，弹出方向与位置算法不可控，受 `displayFrequency` 节流 | 全可控 |

TipKit 留给引导之后的情境提示（§10.5）。

### 10.2 模块与文件

```
Sources/MusicMiniPlayerCore/Onboarding/
  TourModel.swift / TourMachine.swift / TourPersistence.swift / TourPlacement.swift / TourMotionPolicy.swift
  TourAnchorRegistry.swift / TourDetectors.swift
Sources/MusicMiniPlayerAppKit/Tour/
  TourController.swift（@MainActor 执行 effects）/ TourCardWindow.swift / TourCardView.swift（GlassEffectContainer + TourBubbleShape；回退 VisualEffectView .popover + mask）
  TourHaloWindow.swift / TourCelebrationView.swift（Canvas + TimelineView）/ TourGestureGlyph.swift（§8.7）/ TourStrings.swift
现有改动：
  LiquidEdgeController.swift   + statePublisher / tuckedRegionInScreen / floatingHitRegionInScreen
  SnappablePanel.swift         + tuckableEdge() / currentCorner() / snappedToCorner 通知
  MiniPlayerView.swift / LyricsView.swift  + controlsRevealed、audioOutputMenuPresented 通知、封面 .tourAnchor(.artwork)
  HoverableButtons.swift       + musicButtonTapped 通知、.tourAnchor(.music / .translate)
  SharedControls.swift / AudioOutputSwitcherView.swift  + .tourAnchor(.playPause / .lyricsNav / .audioOutput)
  TourDeferredWatcher.swift（Core）  引导结束后唯一残留：一个 $canTranslate + 换歌订阅，触发 / 过期 / 取消
  MusicMiniPlayerApp.swift     + menuWillOpen/DidClose 转发、启动门（含延后订阅武装）、「继续引导」菜单项（按菜单会话的规范）、删除 OnboardingWindow 三个方法
  OnboardingState.swift        → 迁移到 TourPersistence（保留 automationStatus / requestAutomationAccess）
  OnboardingView.swift         删除
```

### 10.3 分阶段

- P0 逻辑与测试：Model / Machine / Persistence / Placement / MotionPolicy / Detectors + 5 个钩子 + §11 单测。
- P1 卡片：窗口 / 视图 / 锚点 / 放置 / 跟随；先硬切换验证位置与不抢焦点；玻璃与回退臂各实测 Reduce Transparency。
- P2 手感：出现 / 位移 / 环 / beats / 火花 / 礼花 / haptic / RM / 手势示意（用逐帧规格）；接 feel channels；创始人终验。
- P3 收尾：文案两语、菜单与设置入口、schema 迁移、删除 C6 窗口、`nanopod://debug/tour/<show|reset|step/<id>>`。

### 10.4 对现有 C6 的处置

`OnboardingWindowView` 与三个窗口方法删除；`OnboardingState` 里权限查询与请求保留；`shouldPresent` 扩成 §5.5 的门；旧两个键只读一次做迁移。

### 10.5 与菜单 / 设置会话的对齐（只提需求）

1. 菜单只放次高频操作；引导未完成（inProgress 或 skipped 且有未完成步）时临时多一项「继续引导（n/7）」，完成后消失。
2. 设置改成系统设置式 sidebar；「通用」页一行「重看引导」按钮；快捷键页可被 `showSettingsWindow(selectedTab:)` 直达（终卡「录个快捷键」用）。
3. 强调色：Apple Music 粉红，浅色 `#FA4058`、深色 `#FB546C`（菜单 / 设置 v2 定稿，取自本机 Music.app 图标渐变取样）；卡片、进度环、beat、火花全部跟随，派生档见 §4.7。
4. 菜单 v2 已按「面板里有的不进菜单」移除「显示翻译」，本方案不再有任何指向菜单的教学，也不再锚定状态栏图标；菜单 `menuWillOpen` / `menuDidClose` 转发通知仍要（面板在右上角时菜单会盖到卡片）。
5. 后续项：引导结束后用 TipKit 做 2–3 条情境提示——点歌词行 seek（进入歌词页第 3 次）、全屏封面开关、给面板录快捷键（第 5 次手动显示隐藏后）。

## 11. 空闲成本与验收（代码层）

创始人禁止截图 / 录屏 / computer use；自验只做代码层，手感由创始人终验。

### 11.1 单元测试清单

| 文件 | 钉住什么 |
|---|---|
| `TourMachineTests` | 顺序完成 → phase 与 effects 表；beat 任意顺序；乱序完成填段不跳卡；提前收边直达 S6；skipTour / skipStep；resume；schema 升级只含新步；`finaleDismiss` 与 8 s 超时都 teardown；假时钟驱动 `transitioning`；延后：进入 S4 时 canTranslate 为假 → deferred 不填段；终局带 deferred → `idle(deferredArmed: true)`；`canTranslateBecameTrue` 3 s 门、面板不可见不出、一次启动只出一次；3 首未做 / 20 次启动 → skipped；触发时 showTranslation 已真 → 静默完成 |
| `TourDetectorTests` | 注入 `PassthroughSubject` 模拟各信号 → 正确 `TourSignal`；`.expanding` 中途不算 tuck；`.floating → .card` 两 beat；snappedCorner 判定表（四角 ±1pt、非角不算）；延后判定表（noLyrics / networkUnreachable / 已是目标语言 / searching > 3 s） |
| `TourPlacementTests` | 面板在 1440×900 可视区四角 × 两类锚点的放置表；两侧都放不下的兜底；小条左右两边；卡不与面板 frame、不与 floating hit region 相交 |
| `TourPreconditionTests` | `shouldPresent` 表；时机门 |
| `TourMotionPolicyTests` | RM 开 / 关全表；庆祝队列一次一个 |
| `TourAnchorRegistryTests` | 未激活不发 preference；窗口 → 屏幕矩形；真 `NSHostingView` + `NSWindow` 钉死 32pt 托管条不产生偏移 |
| `TourBubbleShapeTests` | 箭头位置 / 边的 path 数学（四边 × offset 夹取） |
| `TourTeardownTests` | 完成 / 跳过后：`TourController` weak 为 nil；观察者计数回零；无 display link / timer；`TimelineView` paused 且已移除；`WindowAnimationCensus.sweepAllWindows()` 报告里没有 Tour* 窗口，`effectViews` 清单与引导前一致；带延后步时活着的订阅恰好一个（`TourDeferredWatcher`），补完 / 过期后为零 |
| `TourStringsTests` | 每个 key 中英都有；长度上限；`{n}` 占位符两边一致 |

### 11.2 零常驻的检测方法

- 引导结束后 `nanopod://debug/animsweep`：窗口清单里不得有 Tour* 窗口；`effectViews`（玻璃 / vibrancy）数量回到引导前；动画数一致。
- 进行中：唯一的每帧工作是火花 / 礼花的 `TimelineView`（0.55 s / 1.8 s）与手势示意（两遍后停）；高亮环落定是一次性动画，`isRemovedOnCompletion = true`。
- 检测器只有 Combine sink 与通知观察者，无轮询；`TourAnchorKey` 只在激活时发值。
- 延后步武装期间：全进程只多一个 `$canTranslate` + 换歌 sink，无窗口、无视图、无每帧工作；补课卡出现时才重建卡窗与高亮环，完成即销毁。

### 11.3 创始人终验清单（手感）

玻璃卡在深浅色桌面上的通透度是否「轻」；卡出现是否从锚点长出来；位移是否把视线带到下一个控件；面板被甩走后卡从新位置长出的时机；环填充与火花是否同一拍；收边时卡淡出早于液态第一帧；小条旁的卡不碍 hover；终局礼花的量与时长；手势示意与系统设置演示的相似度；Reduce Motion 下完全无位移。

## 12. 开放问题与后续项

- 32pt 托管条与 `.global` 坐标的关系要用真控件实测一次。
- `hideToNearestEdge()` 在面板离边很远时先弹到角再收，约 0.6 s——卡文案「正在收…」。
- 胶囊「换歌自动弹出 2.5 s」落地后 S6 的 hover beat 要区分来源。
- 完整版接入网易云 / QQ 后，「和 Music 打招呼」与 ↖ 按钮按播放源改名与判定。
- 歌单页定位裁定后若保留，第 8 段与 3–7 上限冲突，届时得合并歌词 + 翻译。
- 情境提示（TipKit）属于后续项。

## 13. 需要创始人拍板的决定

**只剩一个：总长。** 7 段、一般用户 75–110 秒（推荐，创始人点名的五个动作各自都有环填充），还是合并「歌词 + 翻译」为一步两个 beat，做成 6 段、约 60–90 秒。其余（材质 glass / clear / vibrancy、火花有无）都做成运行时 feel channel，他在真机上比完再定，不需要现在拍。
