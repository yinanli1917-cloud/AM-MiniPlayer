# POSTM-003: 封面加载并发阻塞导致 UI 卡顿

**日期**: 2025-12-17
**影响范围**: 性能 / 并发 / 封面加载
**严重程度**: P0
**关联 Commit**: b327f7d

---

## 事件摘要
- **症状**: 歌单页加载时 UI 卡顿，滚动不流畅
- **持续时间**: ~3 小时（诊断 + 修复）
- **影响**: 用户体验严重受损，应用响应缓慢

---

## 时间线
| 时间 (UTC) | 事件 |
|------------|------|
| 14:00 | 发现歌单页封面加载时 UI 卡顿 |
| 14:30 | 初步诊断为并发封面请求导致 ScriptingBridge 阻塞 |
| 15:00 | 确认根因：多个并发 Task.detached 同时调用 ScriptingBridge |
| 15:30 | 设计解决方案：使用串行队列替代并发 Task |
| 16:00 | 实施修复并测试 |
| 16:30 | 验证修复，问题解决 |

---

## 根因分析

### Five Whys
1. **为什么**UI 会卡顿？
   - 因为主线程被阻塞，无法响应 UI 事件

2. **为什么**主线程会被阻塞？
   - 因为多个并发封面请求同时调用 ScriptingBridge，导致系统 Music App 进程阻塞

3. **为什么**会有并发请求？
   - 因为使用了 `Task.detached` 并发加载封面，没有限制并发数

4. **为什么**没有限制并发？
   - 因为设计时优先考虑速度（fire-and-forget），忽略了 ScriptingBridge 的并发限制

5. **根因**: 过早优化（Premature Optimization）- 在不了解系统限制的情况下使用并发，没有考虑正确性保证

### 根因分类
- [x] **Architecture** - 设计与运行条件不匹配（ScriptingBridge 不支持高并发）
- [ ] Bug - 代码缺陷（次要：缺少并发控制）

---

## 影响评估
- **用户影响**: 歌单页加载时 UI 卡顿，滚动不流畅
- **技术影响**: 主线程阻塞，应用响应缓慢
- **影响范围**: 所有加载歌单封面的场景

---

## 复现步骤
1. 打开应用，切换到歌单页
2. 快速滚动歌单，触发大量封面加载请求
3. 观察到 UI 卡顿，滚动不流畅
4. 使用 `sample` 命令分析，发现 ScriptingBridge 调用阻塞主线程

---

## 修复方案

### 已采取行动 (Mitigate)
- [x] 使用串行队列 `artworkFetchQueue` 替代并发 `Task.detached`
  - 文件: [MusicController.swift](Sources/MusicMiniPlayerCore/Services/MusicController.swift)
- [x] 封面搜索限制为前 100 首（每张约 40-50ms）
- [x] 保留 `scriptingBridgeQueue` 用于高优先级操作

### 后续行动 (Prevent)
| ID | 行动描述 | 性质 | 截止日期 | 状态 |
|----|----------|------|----------|------|
| PM-003-1 | Code Review 检查清单添加"ScriptingBridge 调用必须使用串行队列" | Priority | 2026-01-15 | Pending |
| PM-003-2 | 为所有外部 API 调用添加并发限制和重试机制 | Priority | 待定 | Pending |
| PM-003-3 | 封面加载添加进度反馈，避免用户感知卡顿 | Improvement | 待定 | Pending |

---

## 经验教训

### 做得好的地方
- ✅ 使用 `sample` 命令快速定位到 ScriptingBridge 阻塞
- ✅ 设计了双队列策略（高优先级 vs 低优先级）

### 需要改进的地方
- ❌ 没有了解 ScriptingBridge 的并发限制就使用并发
- ❌ 缺少外部 API 调用的最佳实践知识
- ❌ 性能优化时忽略了正确性保证

### 运气成分
- 🔍 问题症状明显（UI 卡顿），易于定位
- 🍀 ScriptingBridge 阻塞可以通过串行队列简单解决

---

## 关联资源
- **Fix Commit**: b327f7d
- **相关文档**: [CLAUDE.md](CLAUDE.md) - 线程安全策略
- **相关 Postmortem**: 无

---

## 标签
#performance #concurrency #scriptingbridge #artwork #optimization
