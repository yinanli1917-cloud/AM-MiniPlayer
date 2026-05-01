# Postmortem 尸检报告索引

> "简化是最高形式的复杂。能消失的分支永远比能写好的分支更优雅。"
> 代码是思想的凝结，架构是哲学的具现。每一行 Bug 代码都是对世界的一次重新误解，每一次 Postmortem 都是对本质的一次逼近。

---

## 什么是 Postmortem？

Postmortem（尸检报告）是对已修复 Bug/问题的系统性复盘，目的是：
1. **理解根因** - 透过症状找到系统/流程层面的真正问题
2. **建立知识库** - 避免在未来重蹈覆辙
3. **指导预防** - 通过可执行的行动减少复发

**核心理念：Blameless Culture** - 我们分析系统为何允许错误发生，而非指责个人。

---

## 使用流程

### 1. 创建 Postmortem
修复 Bug 后，基于 `TEMPLATE.md` 创建新报告：
```bash
cd postmortem
cp TEMPLATE.md $(date +%Y%m%d)-brief-title.md
```

### 2. 填写核心字段
- **Five Whys**: 连续问"为什么"直到找到系统层面的根因
- **根因分类**: Bug/Architecture/Scale/Dependency/Process/Unknown
- **后续行动**: Actionable + Specific + Bounded

### 3. 更新索引
在此文件添加条目，便于模式识别

---

## 报告索引

### 按 ID 排序

| ID | 标题 | 日期 | 根因分类 | 严重程度 | 状态 |
|----|------|------|----------|----------|------|
| POSTM-001 | SwiftUI Section 递归 Bug 导致歌单滚动卡死 | 2025-01-12 | Architecture | P0 | ✅ 已完成 |
| POSTM-002 | 页面切换时 hover 状态未同步导致文字位置错误 | 2026-01-09 | Architecture | P1 | ✅ 已完成 |
| POSTM-003 | 封面加载并发阻塞导致 UI 卡顿 | 2025-12-17 | Architecture | P0 | ✅ 已完成 |
| POSTM-004 | 歌词视图手动滚动和间距问题 | 2025-12-20 | Architecture | P1 | ✅ 已完成 |
| POSTM-005 | MetadataResolver 多轮优化引发 9 首歌批量回归 | 2026-03-16 | Process | P1 | ✅ 已完成 |
| POSTM-006 | romanized→CJK 路径 ASCII→ASCII 错配 | 2026-03-18 | Bug | P1 | ✅ 已完成 |
| POSTM-007 | Chinese Translation Leak — Three Root Causes | 2026-03-22 | Bug | P1 | ✅ 已完成 |
| POSTM-008 | Localized-title lyrics fallback missed synced sources | 2026-05-01 | Bug / Process | P1 | ✅ 已完成 |

---

### 按类别排序

#### 🏗️ Architecture (架构设计问题)
- [POSTM-001](./001-swiftui-section-recursive-bug.md) - SwiftUI Section 递归 Bug
- [POSTM-002](./002-page-switch-hover-desync.md) - 页面切换 hover 状态同步
- [POSTM-003](./003-artwork-concurrent-blocking.md) - 封面加载并发阻塞
- [POSTM-004](./004-lyrics-scroll-spacing.md) - 歌词视图滚动和间距

#### 🐛 Bug (代码缺陷)
- [POSTM-006](./006-romanized-cjk-false-positive.md) - romanized→CJK ASCII→ASCII 错配
- [POSTM-007](./007-chinese-translation-leak-trilogy.md) - Chinese Translation Leak (3 root causes)
- [POSTM-008](./008-lyrics-resolver-localized-title-fallback.md) - localized-title lyrics fallback and artwork weak-match guards

#### 📊 Scale (性能/资源问题)
- 待填充

#### 🔗 Dependency (第三方依赖)
- 待填充

#### 📋 Process (流程问题)
- [POSTM-005](./005-metadata-resolver-regressions.md) - MetadataResolver 多轮优化引发批量回归
- [POSTM-008](./008-lyrics-resolver-localized-title-fallback.md) - localized-title source fallback 未被 fixture 固化

---

## 模式识别

**高发问题区域** (根据 Postmortem 统计，按频率排序):
1. **SwiftUI macOS 差异** (2次) - Liquid Glass 材质过曝、Section 递归
2. **状态同步** (2次) - 页面切换时的 hover 状态残留、动态高度计算
3. **并发竞态** (1次) - 封面预加载与主线程冲突（ScriptingBridge 不支持高并发）
4. **布局设计** (1次) - 固定行高无法支持动态内容

**设计教训**:
- 过早优化（Premature Optimization）- POSTM-003: 并发加载未考虑系统限制
- 过早简化（Premature Simplification）- POSTM-004: 固定行高无法支持动态内容
- 缺少生命周期管理 - POSTM-002: SwiftUI 没有提供视图生命周期钩子
- 无覆盖率简化（Simplification Without Coverage）- POSTM-005: 移除匹配优先级前没有大规模回归测试
- 共享 Unicode 范围需要上下文 - POSTM-007: CJK Unified 不等于"中文"，日文汉字需假名上下文区分
- 安全策略也有副作用 - POSTM-007: "不丢弃任何行"导致翻译泄漏持续存在
- fallback 成功条件必须匹配 source 索引方式 - POSTM-008: localized title 需要 fan-out 到所有 title-keyed synced sources，而不是只补部分平台

---

## 工作流集成

### Release 前检查
```bash
# 检查当前改动是否会触发已知问题
cat postmortem/*.md | grep "根因"
```

### Release 后复盘
```bash
# 分析本次 Release 的 fix commits
git log --grep="fix" --since="1 month ago"
# 为每个 fix commit 创建 Postmortem
```

---

## 参考资源

- [Atlassian Incident Management Handbook](https://www.atlassian.com/incident-management/handbook/postmortems)
- [Google SRE Book - Postmortem Culture](https://sre.google/sre-book/postmortem-culture/)
