# POSTM-002: 页面切换时 hover 状态未同步导致文字位置错误

**日期**: 2026-01-09
**影响范围**: 状态同步 / 页面切换
**严重程度**: P1
**关联 Commit**: e869de8

---

## 事件摘要
- **症状**: 从歌单页切换到专辑页时，播放器文字位置显示不正确
- **持续时间**: ~2 小时（诊断 + 修复）
- **影响**: 页面切换后 UI 状态不一致，用户体验受损

---

## 时间线
| 时间 (UTC) | 事件 |
|------------|------|
| 12:00 | 用户报告页面切换时文字位置错误 |
| 12:20 | 定位到 PlaylistView 的 onHover 状态覆盖问题 |
| 12:40 | 设计解决方案：添加 hoverLocked 锁定机制 |
| 13:00 | 实施修复并测试 |
| 13:20 | 验证修复，问题解决 |

---

## 根因分析

### Five Whys
1. **为什么**文字位置会错误？
   - 因为 `isHovering` 状态在页面切换后被错误设置为 `true`

2. **为什么**状态会被错误设置？
   - 因为 PlaylistView 的 `onHover` 在页面切换时仍然触发并修改了共享状态

3. **为什么**onHover 会在页面切换时触发？
   - 因为页面切换时鼠标恰好位于原 PlaylistView 区域，触发了 hover 事件
   - 没有检查当前页面是否是 PlaylistView

4. **为什么**没有页面检查？
   - 因为 hover 状态是跨页面共享的，但没有设计相应的生命周期管理

5. **根因**: SwiftUI 的跨页面状态管理缺少生命周期钩子（如 `viewDidAppear`/`viewDidDisappear`），导致自定义页面切换实现时状态未正确重置

### 根因分类
- [x] **Architecture** - 设计与运行条件不匹配（SwiftUI 没有提供视图生命周期钩子）
- [ ] Bug - 代码缺陷（次要：缺少边界检查）

---

## 影响评估
- **用户影响**: 页面切换后 UI 状态不一致，文字位置错误
- **技术影响**: 状态管理复杂度增加，需要手动管理生命周期
- **影响范围**: 所有使用自定义页面切换的场景

---

## 复现步骤
1. 打开应用，切换到歌单页
2. 将鼠标悬停在歌单项上（触发 hover 效果，文字上移）
3. 保持鼠标位置不变，切换到专辑页
4. 观察到文字位置依然在上移状态（错误）

---

## 修复方案

### 已采取行动 (Mitigate)
- [x] 添加 `hoverLocked` 状态标记，页面切换时锁定 hover 状态
  - 文件: [MiniPlayerView.swift](Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift)
- [x] PlaylistView 的 `onHover` 添加 `guard currentPage == .playlist` 条件
  - 文件: [PlaylistView.swift](Sources/MusicMiniPlayerCore/UI/PlaylistView.swift)
- [x] 传递 `showOverlayContent` binding 到 PlaylistView

### 后续行动 (Prevent)
| ID | 行动描述 | 性质 | 截止日期 | 状态 |
|----|----------|------|----------|------|
| PM-002-1 | Code Review 检查清单添加"跨页面状态必须添加生命周期检查" | Priority | 2026-01-15 | Pending |
| PM-002-2 | 评估是否需要引入状态管理库（如 TCA）解决复杂状态问题 | Improvement | 待定 | Pending |
| PM-002-3 | 为所有跨页面共享状态添加页面上下文检查 | Priority | 2026-01-15 | Pending |

---

## 经验教训

### 做得好的地方
- ✅ 快速定位到状态同步问题
- ✅ 设计了通用的解决方案（`hoverLocked` 可复用到其他状态）

### 需要改进的地方
- ❌ 缺少 SwiftUI 跨页面状态管理的最佳实践知识
- ❌ Code Review 没有识别出缺少边界检查
- ❌ 没有为跨页面状态设计统一的生命周期管理模式

### 运气成分
- 🔍 问题症状明显（文字位置错误），易于定位
- 🍀 PlaylistView 是唯一有 hover 的页面，问题范围有限

---

## 关联资源
- **Fix Commit**: e869de8
- **相关文档**: [CLAUDE.md](CLAUDE.md) - 已知问题模式
- **相关 Postmortem**: 无

---

## 标签
#state-management #swiftui #page-switch #lifecycle
