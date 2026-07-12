# POSTM-010: 歌词别名证据泄漏与批次截止延迟

**日期**: 2026-07-12
**影响范围**: 歌词正确性 / 性能 / 发布隔离
**严重程度**: P1
**关联 Commit**: 6f87f8d

---

## 事件摘要

- **症状**: Karen Mok 的英文 storefront 标题在整批实网回归中偶发返回同专辑兄弟歌曲（`慢慢的流`、`他不爱我`）；后半批次的空结果偶发超过 3 秒；早期 release 边界还曾因 verifier 与诊断类型的编译关系而无法证明开发模式不进包。
- **持续时间**: 从用户报告间歇性“先无歌词、刷新后成功”到 82 条 network-only 批次、全测试和 release 二进制扫描闭环。
- **影响**: LyricsFetcher、candidate selection、metadata resolver、cache policy、verifier 与 release bundle gate。

---

## 时间线

| 时间 (CDT) | 事件 |
|------------|------|
| 14:50 | 用户质疑现有 bundle、10 秒延迟和刷新后恢复的间歇性行为 |
| 15:14 | 82 条 network-only 基线复现 H13/H13B 错词与两条 >3s |
| 15:27 | 定位 native-title witness 将专辑/时长升级为翻译标题证据 |
| 15:34 | 加固候选与 witness 门，并让 song-scoped metadata wave 提前收敛 |
| 15:40 | 定位最外层 foreground sentinel 仍使用 cooperative `Task.sleep` |
| 15:46 | 第二次完整 82 条批次达到 0 条 >3s，Karen 相邻用例均正确 |
| 15:51 | 全套件 798 tests（2 skipped）0 failures |
| 16:00 | release app 产品构建和诊断符号扫描通过 |

---

## 根因分析

### Five Whys

1. 为什么会返回同歌手的另一首歌？
   - 因为 native-title witness 把同专辑、时长接近的 CJK 曲名当作英文标题的本地化别名，再用该错误曲名发起精确查询。
2. 为什么错误结果会得到高分并通过？
   - 因为重新查询后，下游只看到“精确中文标题”，看不到这个标题最初只由弱专辑/时长证据推导出来，证据在层间被无意升级。
3. 为什么三次单跑正确仍会在整批失败？
   - 因为候选返回顺序和 provider 延迟受负载影响，单跑没有覆盖 H13→H13B 相邻执行和长期任务堆积。
4. 为什么外层 2.7 秒预算还能跑到 3.5 秒？
   - 因为内层 hard timeout 已改用 OS timer，但 aggregate task-group sentinel 仍使用 cooperative `Task.sleep`，在 provider 工作饱和 executor 时晚醒。
5. **根因**: 跨层身份契约没有携带“证据来源/强度”，同时验收只关注局部 timeout 与单例重跑，没有把整批负载和最终 release 二进制作为同级门。

### 根因分类

- [ ] **Bug**
- [x] **Architecture** - 弱证据在重新查询边界被升级，deadline 由两种调度机制交付
- [ ] **Scale**
- [ ] **Dependency**
- [x] **Process** - 单跑绿被过早当作修复证据，缺少批次与 bundle 门
- [ ] **Unknown**

---

## 影响评估

- **用户影响**: 某些英文/本地化标题可能先显示无歌词、等待数秒，或更严重地显示同歌手的错误歌词；刷新后因网络顺序变化又可能成功。
- **技术影响**: 模糊 metadata wave 增加无谓请求；cooperative deadline 在压力下漂移；provider `unavailable` 曾可能被上层误解为歌曲无歌词。
- **影响范围**: 英文 storefront 标题映射 CJK 原生标题、同歌手同专辑近时长歌曲、批量/长会话歌词查询及 release 构建。

---

## 复现步骤

1. 用 `LyricsVerifier run --network-only --inter-song-delay 1` 执行完整 fixtures。
2. 观察 H13 后紧接 H13B；修复前 H13B 可返回 `他不爱我`，H13 可返回 `慢慢的流`。
3. 继续到后半批次；修复前 X14/X16/X17 可超过 3 秒，单独重跑却常低于 3 秒。
4. 对 JSON 汇总四项 cache diagnostics；确认 network-only 下实际读写均为 0。

---

## 修复方案

### 已采取行动 (Mitigate)

- [x] English→CJK album-scoped duration witness 必须通过独立 romanized/title corroboration。
- [x] 候选选择不再允许 album match 替代缺失的跨脚本标题证据。
- [x] CN metadata 的组合 title+artist wave 通过证据门后立即停止 fuzzy rescue。
- [x] aggregate foreground sentinel 与 per-source timeout 均改为 OS-backed wall timer；预算设为 2.70 秒并留出交付余量。
- [x] provider `unavailable` 不再持久化为歌曲级负缓存，仅明确 instrumental 可持久化。
- [x] network-only API/CLI/diagnostics 保持 DEBUG-only；release app 与 bundle 均做字符串/符号泄漏扫描。

### 后续行动 (Prevent)

| ID | 行动描述 | 性质 | 截止日期 | 状态 |
|----|----------|------|----------|------|
| PM-010-1 | 每次 alias/deadline 改动必须跑完整 network-only batch，并单独复核所有翻转和 >3s 项 | Priority | - | Done |
| PM-010-2 | 将 release app product 构建、bundle hash parity 和诊断符号扫描保留为 build_app 强制门 | Priority | - | Done |
| PM-010-3 | 将严格 oracle 失败与安全验收分开报告；不得用 hit count 掩盖错词，也不得把诚实 unresolved 报成歌曲无歌词 | Improvement | - | Done |

---

## 经验教训

### 做得好的地方

- network-only 诊断明确证明四项缓存实际 I/O 都为 0。
- H13/H13B 的首行 oracle 把“高分但错歌”暴露为底线违规。
- 第二次完整批次验证了 wall-clock 修复，而不是依赖常量或单跑。

### 需要改进的地方

- 早期验证过度依赖单曲重复，未先证明相邻批次和长期负载。
- release 能编译不等于开发诊断不在二进制；必须扫描最终产物。
- 弱证据经重新查询后会看起来像强证据，设计必须保留或重新验证证据来源。

### 运气成分

- provider 当天仍稳定返回 Karen 两首正确候选，使修复后可以用内容哈希而不只是“未错配”验证。

---

## 关联资源

- **Fix Commit**: 6f87f8d
- **实网证据**: `/tmp/lyrics-audit-network-only-wallclock-20260712.json`
- **相关 Postmortem**: POSTM-005, POSTM-006, POSTM-008

---

## 标签

#architecture #process #lyrics #matching #deadline #release
