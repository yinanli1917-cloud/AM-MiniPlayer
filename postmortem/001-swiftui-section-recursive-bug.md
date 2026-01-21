# POSTM-001: SwiftUI Section 递归 Bug 导致歌单滚动卡死

**日期**: 2025-01-12
**影响范围**: UI 性能 / 歌单滚动
**严重程度**: P0
**关联 Commit**: 529e3bb, 23e2474

---

## 事件摘要
- **症状**: 歌单页面滚动时出现严重卡顿，CPU 占用飙升，应用进入 NOT RESPONDING 状态
- **持续时间**: ~4 小时（诊断 + 修复）
- **影响**: 歌单页面完全不可用，用户无法浏览和选择歌曲

---

## 时间线
| 时间 (UTC) | 事件 |
|------------|------|
| 14:20 | 开始发现歌单滚动卡顿问题 |
| 14:45 | 初步诊断为 `visualEffect` / `ScrollFadeEffect` 性能问题 |
| 15:30 | 移除模糊效果，问题依然存在 |
| 16:00 | 使用 `sample` 命令分析，发现 `SubgraphList.applyNodes` 被调用 223 次 |
| 16:30 | 确认根因为 SwiftUI `Section` 组件在 macOS 26 Liquid Glass 下的递归 bug |
| 17:00 | 用 `VStack` 替代 `Section`，保留所有视觉效果 |
| 17:30 | 验证修复，问题解决 |

---

## 根因分析

### Five Whys
1. **为什么**歌单滚动会卡顿？
   - 因为 CPU 占用飙升，主线程被阻塞

2. **为什么**主线程会被阻塞？
   - 因为 `SubgraphList.applyNodes` 被递归调用 223 次

3. **为什么**会触发递归调用？
   - 因为 `Section` + `LazyVStack` + `ForEach` 组合在 macOS 26 Liquid Glass 下有 bug
   - `pinnedViews: [.sectionHeaders]` 会加剧问题

4. **为什么**会使用 `Section`？
   - 因为标准 SwiftUI 教程和示例代码都推荐使用 `Section` 来组织列表内容

5. **根因**: SwiftUI 框架在 macOS 26 Liquid Glass 样式下，对 `Section` + `LazyVStack` + `ForEach` + `pinnedViews` 的组合存在未修复的递归 bug，这是一个**架构层面的框架缺陷**，需要在应用层通过组件选择进行规避。

### 根因分类
- [x] **Architecture** - SwiftUI 框架设计与运行条件（macOS 26 Liquid Glass）不匹配
  - 次要：**Bug** - 代码组件选择问题

---

## 影响评估
- **用户影响**: 歌单页面完全不可用，用户无法浏览和选择歌曲
- **技术影响**: 应用进入 NOT RESPONDING 状态，用户体验严重受损
- **影响范围**: 所有使用 macOS 26 Liquid Glass 的用户

---

## 复现步骤
1. 在 macOS 26 Liquid Glass 环境下启动应用
2. 打开歌单页面
3. 快速滚动歌单
4. 观察到应用卡顿，最终进入 NOT RESPONDING 状态

---

## 修复方案

### 已采取行动 (Mitigate)
- [x] 用 `VStack` 替代 `Section`，保留 Header 作为 VStack 的第一个子元素
  - 文件: [PlaylistView.swift](Sources/MusicMiniPlayerCore/UI/PlaylistView.swift)
- [x] 保留 `ScrollFadeEffect` 模糊效果，确认其不是性能瓶颈
- [x] 在 Hover 动画中加 `guard !isScrolling` 优化（辅助措施）

### 后续行动 (Prevent)
| ID | 行动描述 | 性质 | 截止日期 | 状态 |
|----|----------|------|----------|------|
| PM-001-1 | 文档化 macOS SwiftUI 已知 bug 列表，包括 `Section` 递归、`.hudWindow` 过曝 | Priority | 2025-01-15 | ✅ 已完成 |
| PM-001-2 | Code Review 检查清单添加"避免使用 Section + LazyVStack + pinnedViews 组合" | Priority | 2025-01-15 | Pending |
| PM-001-3 | 为关键 UI 流程添加性能监控（使用 `signpost` API） | Improvement | 待定 | Pending |

---

## 经验教训

### 做得好的地方
- ✅ 使用 `sample` 命令进行性能分析，快速定位根因
- ✅ 没有盲目移除视觉效果，而是通过数据驱动决策
- ✅ 保留了所有视觉设计目标，只替换了有问题的组件

### 需要改进的地方
- ❌ 初步诊断时被症状（模糊效果）误导，浪费了约 1 小时
- ❌ 缺少 SwiftUI 已知 bug 的知识库，导致重复踩坑
- ❌ Code Review 流程中没有识别出 `Section` 的潜在问题

### 运气成分
- 🔍 用户反复强调"不是模糊效果的问题"，加速了根因定位
- 🍀 `sample` 命令提供了明确的递归调用证据，避免了盲目排查

---

## 关联资源
- **Fix Commit**: 529e3bb, 23e2474
- **相关文档**: [CLAUDE.md](CLAUDE.md) - 性能陷阱章节
- **技术博客**: [SwiftUI List Performance](https://developer.apple.com/documentation/swiftui/list) (官方文档未提及此 bug)

---

## 标签
#ui #performance #swiftui #macos #liquid-glass #bug
