# POSTM-005: MetadataResolver 多轮优化引发批量回归

**日期**: 2026-03-16
**影响范围**: 功能回归 — 歌词匹配
**严重程度**: P1
**关联 Commit**: cf0850e → 6202991 → f2566f8

---

## 事件摘要
- **症状**: 用户随手测试发现 9 首歌出现歌词丢失或错配（原本能匹配的歌突然搜不到或匹配到完全不同的歌）
- **持续时间**: cf0850e（移除 P4）到 f2566f8（最终修复），跨 4 个 commit
- **影响**: 日文/英文/中文多语种歌曲匹配全面受损

---

## 根因分析

### Five Whys

1. 为什么 9 首歌回归？
   - 因为 cf0850e 过于激进地移除了 P4（仅艺术家匹配）和限制了 P3 翻译匹配
2. 为什么移除 P4 和限制 P3 影响这么大？
   - 因为大量日文/英文歌曲的匹配路径正好依赖这两个优先级
3. **根因**: 匹配管线的安全裕度不够 — 在缺乏大规模回归测试的情况下做了"简化"优化，
   每次修改都只测了少量用例，没有覆盖到各语种的边缘 case

### 根因分类
- [x] **Process** - 缺少大规模自动化回归测试，改一个修一批破一批

---

## 具体问题清单

| # | 歌曲 | 艺术家 | 症状 | 根因 | 修复 commit |
|---|------|--------|------|------|------------|
| 1 | Try to Say (2021 Remaster) | Hitomi Tohyama | 无歌词 | P4 被移除 | 6202991 |
| 2 | Shang-Hide Night | Fujimaru Yoshino | 无歌词 | P4 被移除 | 6202991 |
| 3 | Mayonaka No Shujinkou | 須藤 薫 | 无歌词 | JP romanized 匹配失败 | 6202991 |
| 4 | Hiroshima mon amour | Karen Mok | 无歌词 | CN 翻译匹配被完全禁止 | 6202991 |
| 5 | Karen / Ella Medley | Karen Carpenter | 无歌词 | P4 被移除 | 6202991 |
| 6 | Strange Weather | YELLOW & 9m88 | 无歌词 | 多艺术家拆分后 P4 失效 | 6202991 |
| 7 | Good At Breaking Hearts | Jungle | 错配→Make It Bun Dem | isLikelyEnglishArtist("Jungle")=false → JP 解析 | f2566f8 |
| 8 | Dream Boat ga Deru Yoru ni | Momoko Kikuchi | 无歌词 | JP romanized→CJK 唯一候选限制过严 | f2566f8 |
| 9 | Twelfth Floor | Karen Mok | 无歌词（之前已修过） | artist-only 搜索禁止翻译匹配 | f2566f8 |

---

## 修复方案总结

### cf0850e → 6202991（6 首回归修复）
- **P4 安全加回**: 仅艺术家匹配加时长 < 1s 限制，而非完全移除
- **JP 元信息增强**: romanized→CJK 匹配放宽唯一候选限制
- **艺术家匹配增强**: `isArtistMatch()` 支持 `&` 分隔的多艺术家

### 6202991 → f2566f8（3 首回归修复）
- **isLikelyEnglishArtist**: 单词纯 ASCII 乐队名（如 "Jungle", "Queen"）识别为英文
- **CN 翻译匹配放宽**: artist-only 搜索允许翻译匹配（Δ<0.35s 且唯一候选）
- **JP romanized→CJK**: 同标题候选（如 原版+Remaster）视为安全

---

## 经验教训

### 做得好的地方
- LyricsVerifier CLI 工具在修复过程中发挥了关键作用
- library --recent 50 批量测试帮助发现了更多回归

### 需要改进的地方
- **改之前先跑全量测试**: 每次改匹配逻辑前，先跑 `library --recent 50` 建立基线
- **不要在没有覆盖率的情况下"简化"**: 移除优先级链环节是高危操作
- **Verifier 需要内容验证**: 仅检查"有无歌词"不够，需要检测错配（语言不一致等）

### 运气成分
- 用户手动测试发现了问题，如果没有及时发现可能积累更多回归

---

## 后续行动

| ID | 行动描述 | 性质 | 状态 |
|----|----------|------|------|
| PM-005-1 | 将 9 首问题歌加入 lyrics_test_cases.json 回归用例 | Priority | ✅ 已完成 |
| PM-005-2 | Verifier 增加内容验证（语言一致性、错配检测） | Priority | 🔄 进行中 |
| PM-005-3 | 每次匹配逻辑修改前必须先跑 library --recent 50 基线 | Process | 📋 规范化 |

---

## 标签
#lyrics #matching #regression #metadata-resolver #process
