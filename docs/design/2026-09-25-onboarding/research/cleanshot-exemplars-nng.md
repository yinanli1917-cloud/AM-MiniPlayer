# 调研报告 2：CleanShot X 引导、边做边学范例、庆祝时刻、NN/g 结论、进度环规格

调研代理：Sonnet 5（research），2026-09-25。方法论说明：部分页面对自动抓取有拦截（pageflows.com 多数详情页、uxdesign.cc、uxplanet.org、podfeet.com、部分 Medium 文章返回 403），这些条目标注为「仅搜索摘要，未直接读取全文」，可信度低于直接抓取到的来源，使用前建议自行打开链接复核。

## 1. CleanShot X 的 onboarding 具体怎么做

结论：没有找到证据支持「控件旁边锚定浮动卡片 + 进度指示 + 完成礼花」这套范式在 CleanShot X 里存在。能查到的最具体的一篇设计分析（Marcin Wichary 的博客）明确说 CleanShot 的引导方式反而是反其道而行——不用教程气泡，而是把首次启动的极简向导做完之后，让设计精良的「设置」面板本身承担教学功能。

- 首次启动流程：询问是否将其设为默认截图工具；若同意，引导用户去系统设置的键盘快捷键里关掉系统自带截图快捷键，同一组快捷键随即转由 CleanShot X 接管；截屏/录屏权限通过系统设置的隐私与安全性单独申请。来源：https://www.podfeet.com/blog/2022/04/cleanshot-x/ 、 https://how-to-take-screenshot.com/cleanshotx/ （均为搜索摘要，未直接抓取全文）
- 唯一一条与「welcome 引导」直接相关的更新日志记录是 2019-06-05 的 2.5.2 版本，内容为「改进了欢迎页说明文字」，此后官方 changelog 再无 onboarding/welcome/tutorial 相关条目。来源：https://cleanshot.com/changelog
- 核心设计分析文章认为，CleanShot 的「引导」发生在设置面板里，而不是浮动教程：面板有清晰的分组与说明、随状态变化的动态提示文字（"hints swapping to reflect the current status"）、可视化的快捷键自定义与实时预览、以及误操作前的二次确认（"molly guard" 式保护）。文章原话大意是「了解这个工具能力的最好方式就是逛一遍设置」。来源：https://unsung.aresluna.org/cleanshots-onboarding-via-settings/
- 没有找到证据表明存在锚定在菜单栏图标/具体控件旁边、带箭头的浮动气泡卡片；没有找到步骤点/进度条/"1 of 5" 式进度表达；没有找到完成礼花或声音反馈；没有找到「重新打开引导」的菜单入口。以上均为未找到，不代表确定不存在。
- PageFlows 收录了 CleanShot X 的产品页，但具体截图与分步说明在付费墙后。来源：https://pageflows.com/cleanshot/
- 未在 Mobbin、SaaSFrame、onboarding.study 上找到 CleanShot X 的专门收录条目（未找到）。
- 官方 YouTube 有两条相关视频《First steps with CleanShot X》与《Getting started with CleanShot X》，内容无法转写抓取。来源：https://www.youtube.com/watch?v=F4DMNp-Vt3A 、 https://www.youtube.com/watch?v=GWKqnmr95VA

## 2. 其他产品的「边做边学」引导范例

结论：Figma 是目前查到的、与创始人描述最接近的现成范例——锚定 tooltip + 动图 + 「第几步/共几步」进度 + 关闭按钮 + 「了解更多」分层入口。Superhuman 和 Linear/Notion 提供了更硬的证据：把「看教程」换成「在真实或沙盒环境里做一次真动作」，转化率和留存都有实测提升。Slack 走的是对话式路线。TipKit 是 Apple 官方在 macOS 14/iOS 17 起提供的现成框架，最贴近「控件旁边的箭头气泡」这一具体形态。

**Raycast**
- 首次启动是设置向导而非锚定卡片：设置呼出快捷键 → 可选订阅邮件列表 → 点击 Launch Raycast → 授予辅助功能等系统权限；进入主界面后有一个可双击展开的功能说明条目，不是强制播放的分步教程。来源：https://manual.raycast.com/the-basics
- PageFlows 记录该流程共 37 屏、约 4 分 41 秒。来源：https://pageflows.com/post/desktop-web/onboarding/raycast/
- 未找到 Raycast 引导完成时的庆祝反馈相关描述。

**Arc browser**
- 账号创建阶段会在窗口右侧实时预览 Space 概念，让用户在真正创建前先看到效果；随后依次走导入书签、选默认搜索引擎、是否设为默认浏览器。来源：https://www.saasui.design/pattern/onboarding/arc-browser （仅摘要级）
- 早期版本里 profile 功能很难找到，后来官方把它整合进了 onboarding 流程本身。来源：https://beeps.website/blog/2023-12-10-initial-experiences-using-arc-browser/
- PageFlows 记录 Arc 引导共 28 屏。来源：https://pageflows.com/post/mac-os/onboarding/arc/

**Things 3（Mac）**
- 首次启动会自动创建一个名为 "Meet Things Mac" 的教程项目——本质就是一份待办事项列表，用户通过勾掉清单里的条目来学会用法。之后可通过菜单栏 Help → Create Tutorial Project 重新生成。来源：https://culturedcode.com/things/support/articles/2803553/

**Superhuman**
- 早期做法是一个「藏起来」的旁支任务清单，完成率只有 30%，对激活率没有提升。之后改为强制的全屏引导面板（不可跳过，但预填了智能默认值以便快速过），完成率从 30% 直接跳到 98%，功能开启率从 45% 提到近 80%。核心环节是一个完全可交互的「仿真收件箱」沙盒，用户在里面真的清空邮件、做到 Inbox Zero。来源：https://review.firstround.com/superhuman-onboarding-playbook/

**Linear**
- 官方定位是「没有 tour」：让用户直接做事。顺序：邮箱注册 → 创建工作区 → 选主题 → 命令菜单（Cmd+K）介绍（刻意安排在用户还没做任何操作之前，用来先声明「这是一个键盘优先的产品」）→ 可选接入 GitHub → 可选邀请队友 → 进入已填充内容的工作区后，靠一份任务清单继续学，每个任务只对应一个具体动作，做完一个才解锁下一个。真正的「激活」节点是解决第一个 issue。来源：https://supademo.com/user-flow-examples/linear 、 https://linear.app/docs/start-guide

**Notion**
- 注册时根据用户填写的信息挑 5 个个性化模板；Getting Started 页上是一份可以真实操作的功能清单，靠动手做来学；界面元素上 hover 会出现高对比度的提示气泡作为补充说明。来源：https://goodux.appcues.com/blog/notions-lightweight-onboarding

**Figma**
- 引导是可选择开启的一段 10 步走查，在用户点击「开始设计」后触发。每一步是一张锚定在具体控件上的提示卡：简短文案 + 一段演示该功能效果的小动画/动图，并带有形如 "5 of 5" 的进度计数；每步都能点关闭随时退出，复杂的步骤额外提供「了解更多」链接。来源：https://www.chameleon.io/inspiration/figmas-onboarding-tour 、 https://useronboarding.academy/user-onboarding-inspirations/figma-product-walkthrough

**Slack**
- 对话式引导：由 Slackbot 主动发消息，引导新用户「边发消息边学」，而不是弹窗卡片；允许在任意时刻中止引导；「首次发消息」这个动作本身会触发一轮更贴近核心操作的迷你产品导览。来源：https://goodux.appcues.com/blog/slacks-new-user-onboarding

**macOS 系统自带 Tips app 与 TipKit**
- TipKit 是 Apple 在 WWDC23 发布、WWDC24 补充的官方框架（iOS 17/macOS 14 及以上），提供两种视觉形态：内嵌式 TipView（Apple 建议优先用这种，不遮挡内容）与弹出式 popoverTip（带箭头指向具体控件的小气泡，官方建议少用、只用在真正需要打断注意力的场景）；框架自带出现频率控制、资格规则、以及给多个 tip 排序分组以控制被发现的先后顺序。来源：https://developer.apple.com/videos/play/wwdc2023/10229/ 、 https://developer.apple.com/videos/play/wwdc2024/10070/ 、 https://bendodson.com/weblog/2023/07/26/tipkit-tutorial/

## 3. 庆祝时刻的设计

结论：庆祝强度要匹配成就本身的分量，而且「不是每次都庆祝」往往比「每次都庆祝」更有效。Duolingo 选择在里程碑时刻张扬地庆祝，Asana 选择随机 + 可关闭的克制路线，两者方向相反但都经过验证，取决于产品调性。

- Duolingo 无失误完成一课时，吉祥物 Duo 的头部会像放烟花一样「炸开」，随后数据卡片依次错落滑入、数字带滚动计数效果、配合音效。streak 里程碑时火焰图标点燃并放大、彩色粒子迸发，数字用带弹性的弹簧效果滚动计数。来源：https://60fps.design/apps/duolingo
- 在 7/30/100/365 天等重要节点，Duo 会变身「不死鸟」庆祝；设计团队内部明确说这类里程碑动画是「多轮粗剪反复打磨节奏和能量感」才定下来的，并且选择在这些节点上主动放大庆祝感。来源：https://blog.duolingo.com/streak-milestone-design-animation
- Asana 有 5 种「庆祝生物」；默认是完成任务后随机出现，而不是每次都出现——借用的是变比率强化（variable ratio reward）；用户可以在设置里整体关闭。来源：https://zapier.com/blog/asana-celebrations/ 、 https://asana.com/inside-asana/new-celebrations
- 没有找到 GitHub 官方在合并 PR 时内建礼花动效的证据；只有第三方浏览器插件。来源：https://github.com/Antonio072/merge-confetti-extension
- Apple Fitness/Watch 合圆环时的完成动效被普遍称为 "fireworks"，但 Apple 没有公开具体时长、缓动参数。社区讨论里有一个值得注意的副作用：当多个成就在同一时刻触发时，后到的通知可能互相顶掉、导致烟花动效没有显示——「多个庆祝叠在一起触发」是需要主动处理的边界情况。来源：https://discussions.apple.com/thread/252009834 、 https://discussions.apple.com/thread/254968835
- 关于「庆祝疲劳」的设计批评类文章普遍认为：礼花被滥用到近乎廉价；核心问题是「庆祝的分量要匹配用户完成的事有多大」。来源：https://uxdesign.cc/the-over-confetti-ing-of-digital-experiences-af523745db19 、 https://uxplanet.org/why-confetti-celebrations-backfire-and-how-to-make-them-work-be838a6e7b8b （均为摘要级）
- Intuit 官方内容设计规范（可直接抓取全文）：只该为用户自己达成的目标庆祝，不该为系统常规动作庆祝；如果庆祝太频繁、或者为很小的事庆祝，会显得多余甚至有点居高临下——用户测试里有受访者直接质疑「只做了一件事，为什么要庆祝」；常规操作应该用平实的确认提示。来源：https://contentdesign.intuit.com/talking-to-customers/celebrations/

## 4. NN/g 与其他 UX 研究结论

结论：NN/g 不推荐一次性、打断式的教程，推荐「边用边给」的情境化帮助，理由是短时记忆容量有限、教程内容学完就忘，而且用户天生会想跳过教程直接用产品。Coach marks 本身不是不能用，但要一次只出一条、卡在用户真正需要那个功能的当下。goal-gradient effect 和 endowed progress effect 两个经典实验给了可以直接套到进度环设计上的具体数字。

- NN/g《Onboarding Tutorials vs. Contextual Help》：把引导分为 push revelation（教程式）和 pull revelation（情境式）。教程式引导会打断用户、且不会带来更好的任务表现，用户会本能地想跳过（active user 悖论）；脱离实际操作场景的教程内容对短期工作记忆负担重，学完等真正要用的时候已经忘了。建议：容易关掉但事后还能找回来、渐进式披露、帮助贴着对应步骤出现、常规操作不需要额外指引。来源：https://www.nngroup.com/articles/onboarding-tutorials/
- NN/g《Instructional Overlays and Coach Marks for Mobile Apps》：人的短时记忆大约只能保持约 20 秒，多步骤的引导标注根本记不住；频繁弹出提示会训练用户养成「不管有没有用都想赶紧关掉」的条件反射；Wimbledon 平板 app 测试里用户会真的伸手去点教程覆盖层上的图形，把纯装饰性的引导标注当成可交互界面。建议：一次只给一条提示、卡在真正需要的那一刻；多用图少用字；引导标注要在视觉上明显区别于真实界面。来源：https://www.nngroup.com/articles/mobile-instructional-overlay/
- NN/g《Mobile-App Onboarding: An Analysis of Components and Techniques》：引导卡片数量尽量少、每张卡只讲一个概念；coach marks 最适合用在用户第一次碰到某个具体功能的那个时间点；交互式走查比被动教程更有效，理由是它更像「练习一轮」而不是「上一堂课」；这种方式对「这个 app 特有、用户从没见过」的操作尤其有效，对已经是行业惯例的操作则没必要。来源：https://www.nngroup.com/articles/mobile-app-onboarding/
- NN/g 进度指示两篇：呈现进度时应该把当前所在位置放最显眼的位置，同时把已完成的部分也展示出来，文案要用大白话。来源：https://www.nngroup.com/articles/progress-indicators/ 、 https://www.nngroup.com/articles/status-tracker-progress-update/
- goal-gradient effect（目标趋近效应）：Kivetz 2006 咖啡店集章卡实验，顾客从第 9 个章到第 10 个章平均只用 5 天，而从第 1 个章到第 2 个章要 12 天。来源：https://iq.opengenus.org/goal-gradient-effect-in-ux-design/ 、 https://learningloop.io/plays/psychology/goal-gradient-effect
- endowed progress effect（赋予进度效应）：Nunes & Drèze 2006 洗车店集章卡实验，A 组 0/8 起步完成率 19%，B 组预盖 2 章 2/10 起步完成率 34%，两组实际都要洗满 8 次。进度环起步时如果不是完全清空，完成率会更高。来源：https://siliconcanals.com/t-car-wash-loyalty-cards-endowed-progress/
- 行业数据（口径不一，仅供参考）：移动端约 70% 用户会跳过 onboarding；允许跳过的引导流程完成率反而高出约 25%；74% 的用户更喜欢能感知自己已会的内容、自动跳过对应步骤的引导。来源：https://userguiding.com/blog/user-onboarding-statistics
- 步骤追踪器经验法则：适合 3–7 步的流程；少于 3 步用不上，多于 7 步该拆分或合并。来源：https://www.uxpin.com/studio/blog/design-progress-trackers/ 、 https://lollypop.design/blog/2026/february/beyond-the-progress-bar-the-art-of-stepper-ui-design/

## 5. 进度环（progress ring）动效规格

结论：Apple 官方没有公开 Activity Ring 完成动效的具体时长/缓动参数。能查到的是开发者社区公认的实现套路和经验参数值。一条可直接落地的通用原则：过冲（overshoot）适合用在用户刚完成的直接操作上（比如某一步刚打勾、圆环刚合拢），不适合用在被动淡入的元素上。

- SwiftUI 环形进度实现套路：`Circle().trim(from:to:)` 配合 `.stroke(style: StrokeStyle(lineWidth:, lineCap: .round))`，整体旋转 -90 度让起点在 12 点钟方向，再对 trim 的终点值做动画。来源：https://sarunw.com/posts/how-to-create-activity-ring-in-swiftui/ 、 https://cindori.com/developer/swiftui-animation-rings
- 弹簧参数经验值：`.spring(response:dampingFraction:)` 里 dampingFraction 越低过冲越明显，1.0 时几乎不过冲；iOS 17 之后的 duration/bounce API 里 bounce 从 0（不过冲）到 1 可以直接控制「合拢时要不要弹一下、弹多大」。来源：https://www.hackingwithswift.com/quick-start/swiftui/how-to-create-a-spring-animation 、 WWDC23 Animate with springs：https://developer.apple.com/videos/play/wwdc2023/10158/
- 过冲动效的通用设计原则：过冲适合用在用户刚做出的直接动作上，用在被动淡入的元素上会显得不自然。来源：https://uxdesign.cc/how-to-use-overshoot-to-upgrade-your-ui-animations-afe5526fdeac （仅摘要级）
- Duolingo 的技能进度圆圈据描述会刻意让视觉上「看起来快完成了」，借用蔡格尼克效应（Zeigarnik effect）制造「就差一点」的心理驱动（二手信息）。来源：https://medium.com/@assenavseolb/dissecting-duolingos-design-f1113a1db8cd （仅摘要级）
