# POSTM-008: Localized-title lyrics fallback missed synced sources

**日期**: 2026-05-01
**影响范围**: 功能回归 / UI 同步 / 封面匹配
**严重程度**: P1
**关联 Commit**: ec4b77b, ea607e1

---

## 事件摘要
- **症状**: `Invisible` - mei ehara 显示无歌词，但独立查询确认 LRCLIB 存在日文标题 `不確か` 的真实同步歌词；部分歌词首行混入制作/版权信息，封面 fallback 也可能接受同名不同艺人结果。
- **持续时间**: 从本轮完整审查发现到修复验证。
- **影响**: Lyrics metadata resolver, source fan-out, timestamp scoring, metadata stripping, artwork fallback matching。

---

## 时间线
| 时间 (UTC) | 事件 |
|------------|------|
| 09:00 | 基线验证发现 `Invisible` 无歌词，48 例回归中 47/48 通过 |
| 09:15 | 独立查询确认 LRCLIB 有 `不確か` / mei ehara / 326s 的同步歌词 |
| 09:35 | 实施 resolved-title source fan-out、YRC offset、metadata strip 和 scorer/source 优先级修复 |
| 10:10 | 加固 MetadataResolver 的 title-only CJK fallback 和 artwork candidate score |
| 10:25 | `LyricsVerifier run` 通过 48/48，`swift test --skip UpdateApplierTests` 通过 130 tests |

---

## 根因分析

### Five Whys
1. 为什么 `Invisible` 会显示无歌词？
   - 因为原始英文标题查不到歌词，而解析出的日文标题没有被送到所有同步源。
2. 为什么解析标题没有覆盖所有同步源？
   - Branch 2/3 过去主要补 NetEase/QQ，LRCLIB/AMLL/Apple Music 这类 title-keyed source 没有得到同等 fallback。
3. 为什么 UI 同步和封面也会受影响？
   - 歌词源选择和封面源选择都允许弱匹配路径保留过久：歌词端有 title/artist CJK fallback 的上下文不够精确，封面端有 title-only fallback，metadata strip 也没有覆盖短信用行。
4. **根因**: resolver/fallback 的覆盖面和输出校验没有按“源索引方式”建模；title-keyed source、word-level source、artwork source 共用了过于宽松的成功条件。

### 根因分类
- [x] **Bug** - 代码缺陷（需要测试/金丝雀/灰度）
- [ ] **Architecture** - 设计与运行条件不匹配
- [ ] **Scale** - 资源约束/容量规划问题
- [ ] **Dependency** - 第三方依赖故障
- [x] **Process** - 回归用例未覆盖 localized-title-only source fallback
- [ ] **Unknown** - 需要增强可观测性

---

## 影响评估
- **用户影响**: 某些歌曲会显示无歌词或延迟显示歌词；少数歌曲首行可能显示制作/版权信息；封面可能使用同名不同艺人的结果。
- **技术影响**: fallback 分支做了不必要的重复 regional lookup，降低速度；lyrics/artwork source selection 的可信度边界不一致。
- **影响范围**: romanized/English display title 对应 CJK/localized catalog title 的歌曲，以及 fallback artwork source。

---

## 复现步骤
1. 查询 `Invisible` / `mei ehara` / `326s`。
2. 观察原始标题 source miss 后没有使用 `不確か` 命中 LRCLIB。
3. 对比独立 LRCLIB 查询，可发现真实同步歌词首行 `幽霊 ほどけていたんだ`。

---

## 修复方案

### 已采取行动 (Mitigate)
- [x] Branch 2/3 resolved tuple fan-out 覆盖 Apple Music、AMLL、LRCLIB、LRCLIB-Search、NetEase、QQ，并避免每个 source 重复 regional lookup。
- [x] Apple Music TTML 进入高优先级 early-return 和 scorer source bonus。
- [x] NetEase YRC word-level 歌词统一应用已验证的 0.7s source offset。
- [x] MetadataResolver artist+CJK fallback 改为要求 result title 含 CJK，避免 CJK artist 导致 ASCII title 替换。
- [x] stripMetadataLines 增加鼓/乐器/Publisher/SP/OP 等短信用行过滤。
- [x] artwork fallback 改为 title/artist/album 评分，拒绝 title-only wrong artist/album。

### 后续行动 (Prevent)
| ID | 行动描述 | 性质 | 截止日期 | 状态 |
|----|----------|------|----------|------|
| PM-008-1 | Add a fixture that requires localized-title LRCLIB fallback for `Invisible` without relying only on live tests | Priority | - | Pending |
| PM-008-2 | Add source-level timing telemetry for selected lyrics offsets so future offset changes are measurable | Improvement | - | Pending |

---

## 经验教训

### 做得好的地方
- Live verifier exposed the exact no-lyrics case and confirmed the independent LRCLIB result.
- Existing romanized regression cases caught source-selection changes after resolver hardening.

### 需要改进的地方
- Resolved metadata fallback should be treated as a shared source candidate, not as a NetEase/QQ-only rescue path.
- Artwork fallback needs the same “weak matches cannot win alone” rule as lyrics.

### 运气成分
- LRCLIB had a complete synced timeline for the missing song, so the fix could be validated independently.

---

## 关联资源
- **Fix Commit**: ec4b77b, ea607e1
- **Related Issue**: user-reported lyrics/artwork sync and matching review
- **相关 Postmortem**: POSTM-005, POSTM-006, POSTM-008

---

## 标签
#bug #lyrics #metadata-resolver #artwork #matching
