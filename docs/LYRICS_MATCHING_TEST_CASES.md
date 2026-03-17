# 歌词匹配回归测试用例

> **目的**: 记录每个典型匹配场景的测试用例，确保修复一个问题不会破坏另一个场景。
> **维护原则**: 每次修改匹配逻辑时，必须验证所有测试用例仍然通过。

---

## 典型场景分类

### 1. 中英文翻译标题 (Translation Relationship)

| ID | 输入标题 | 输入艺术家 | 期望解析 | 期望匹配 | 状态 |
|----|---------|-----------|---------|---------|------|
| T01 | None of Your Business (feat. Kumachan) | Julia Peng | 关你屁事啊 / 彭佳慧 | NetEase/QQ | ✅ |
| T02 | Between Love and You | Naiwen Yang | 在爱和你之间 / 杨乃文 | QQ Music | ✅ |

**匹配策略**: `duration-precise+CN` (P4) - 时长极精确 (<0.5s) + 结果是中文 + 输入是纯英文 ASCII

**关键代码**: `MetadataResolver.swift` Line 126-143

---

### 2. 罗马字艺术家名 (Romanized Artist)

| ID | 输入标题 | 输入艺术家 | 期望解析 | 期望匹配 | 状态 |
|----|---------|-----------|---------|---------|------|
| R01 | PONCHET 泰国歌 | PONCHET | 保持原值 / PONCHET | LRCLIB/SimpMusic | ✅ |
| R02 | 日文歌 | Hiroshi Fujiwara | 藤原ヒロシ | JP 区域 iTunes | ✅ |
| R03 | Koibitotachi no Chiheisen | Momoko Kikuchi | 恋人たちの地平線 / 菊池桃子 | NetEase | ✅ |

**匹配策略**: 纯 ASCII 艺术家名 + 非英语常见名 → 尝试 JP/KR 区域 iTunes

**关键代码**: `MetadataResolver.swift` `inferRegions()` + `isLikelyEnglishArtist()`

---

### 3. 中文歌词搜索 (Chinese Lyrics)

| ID | 输入标题 | 输入艺术家 | 期望匹配源 | 状态 |
|----|---------|-----------|----------|------|
| C01 | 女爵 | 杨乃文 | NetEase/QQ | ✅ |
| C02 | 叶子 (电视剧《蔷薇之恋》原声带版) | 阿桑 | NetEase (清理后搜索 "叶子") | ✅ |
| C03 | 繁简体混合歌名 | 周杰倫 | NetEase (简化搜索) | ✅ |

**匹配策略**:
1. 清理标题括号内容（电视剧原声带版等）
2. 繁体转简体 `LanguageUtils.toSimplifiedChinese()`

**关键代码**: `LyricsFetcher.swift` `searchNetEaseSong()` Line 388-398

---

### 4. 日韩小语种 (Japanese/Korean/SEA)

| ID | 输入标题 | 输入艺术家 | 期望解析 | 期望匹配 | 状态 |
|----|---------|-----------|---------|---------|------|
| J01 | 日文片假名标题 | YOASOBI | 保持原值 | NetEase/AMLL | ✅ |
| K01 | 韩文歌名 | BTS | 保持原值 | NetEase/AMLL | ✅ |
| S01 | ภาษาไทย (泰文) | 泰国艺术家 | TH 区域 iTunes | SimpMusic | ✅ |

**匹配策略**: 语言字符检测 → 查询对应区域 iTunes

**关键代码**: `LanguageUtils.swift` `containsThai()` / `containsVietnamese()` 等

---

### 5. 特殊情况处理

| ID | 场景 | 输入 | 期望行为 | 状态 |
|----|-----|-----|---------|------|
| S01 | QQ Music 艺术家优先匹配 | 在爱和你之间 / 杨乃文 | 匹配原版而非翻唱 | ✅ |
| S02 | 短英文通用标题 | Love / 某艺术家 | 严格时长匹配 (<0.5s) | ✅ |
| S03 | 多艺术家 feat. | XXX (feat. YYY) | 拆分艺术家后匹配 | ✅ |
| S04 | Remaster/Live 后缀 | Song (2020 Remaster) | 移除后缀后搜索 | ✅ |

---

## 问题跟踪

### 当前待修问题

无

### 已修复问题历史

| 问题 ID | 描述 | 修复日期 | 修复 Commit |
|--------|------|---------|------------|
| T01 | Julia Peng 翻译标题不匹配 | 2026-01-25 | e98c34c |
| T02 | 杨乃文《在爱和你之间》无歌词 | 2026-01-25 | 待提交 |
| R03 | Momoko Kikuchi《Koibitotachi no Chiheisen》无歌词 | 2026-01-25 | 待提交 |
| REG-001~009 | MetadataResolver 多轮优化引发 9 首歌批量回归 | 2026-03-16 | cf0850e→f2566f8 |

**REG 批量回归根因** (详见 postmortem/005):
- P4（仅艺术家匹配）被完全移除 → 6 首歌丢失
- `isLikelyEnglishArtist("Jungle")` 返回 false → JP 区域错误解析 → 错配
- CN 翻译匹配在 artist-only 搜索被完全禁止 → Karen Mok 回归
- JP romanized→CJK 唯一候选限制过严 → Momoko Kikuchi 回归

**修复策略**: P4 安全加回（带时长限制）; 单词 ASCII 乐队名启发式; 翻译匹配放宽; 同标题候选视为安全

---

## 验证方法

### 手动验证
1. 清空缓存 `rm ~/Library/Caches/com.nanoPod/*`
2. 启动应用播放测试歌曲
3. 检查 `/tmp/nanopod_debug.log` 日志
4. 确认歌词显示正确

### 关键日志模式
```
🚀 fetchAllSources START: 'XXX' by 'YYY'
🔄 元信息解析: '中文标题' by '中文艺术家'   # MetadataResolver 成功
✅ 匹配P1: '歌名' by '艺术家' (Δ0.00s)     # 歌曲搜索成功
🏆 最终选择: NetEase                       # 歌词获取成功
```

---

## 更新日志

| 日期 | 变更 | 修改人 |
|-----|------|-------|
| 2026-01-25 | 初始创建文档 | Claude |
| 2026-01-25 | 修复 R03 罗马字→日文解析问题 | Claude |
| 2026-03-16 | 批量回归修复: 9 首歌 (P4/JP/CN/英文乐队名) | Claude |

---

[PROTOCOL]: 每次修改匹配逻辑必须更新此文档
