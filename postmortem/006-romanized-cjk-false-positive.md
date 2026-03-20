# POSTM-006: romanized→CJK 路径 ASCII→ASCII 错配

**日期**: 2026-03-18
**影响范围**: 功能回归 — 歌词错配
**严重程度**: P1
**关联文件**: MetadataResolver.swift, LanguageUtils.swift

---

## 事件摘要
- **症状**: Moon Style Love (Leo1Bee, 华语 Mandopop) 显示日文歌词 "Milk Tea" by 清水翔太
- **影响**: 所有纯 ASCII 标题+艺术家、非已知英文的歌曲都可能被 JP/KR 区域搜索污染
- **持续时间**: 从 POSTM-005 修复（f2566f8）到本次修复

---

## 根因分析

### 攻击链（完整 5 步）

```
1. inferRegions("Leo1Bee") → 纯 ASCII + 非已知英文 → 加 JP/KR
2. JP iTunes 搜 "Moon Style Love" → 返回 33 条随机结果
3. romanized→CJK 检查 resultHasCJK → "milk tea" 标题是 ASCII，
   但 artist "清水 翔太" 有 CJK → resultHasCJK = true → 候选通过
4. 唯一候选 + Δ0.19s → isSafe = true → MetadataResolver 返回错误元数据
5. LyricsFetcher 搜 "milk tea 清水翔太" → QQ 58pts 命中 → 错误歌词
```

### Five Whys

1. 为什么显示日文歌词？
   - LyricsFetcher 用了 MetadataResolver 返回的 "milk tea" by "清水 翔太"
2. 为什么 MetadataResolver 返回错误元数据？
   - `romanized→CJK` 路径接受了 ASCII 标题的候选
3. 为什么 ASCII 标题通过了 CJK 检查？
   - `resultHasCJK` 检查的是 trackName + artistName，artist 有 CJK 就够了
4. **根因**: `romanized→CJK` 的 CJK 验证粒度不够——本意是把罗马字标题解析为 CJK 标题，
   但 CJK 检查包含了 artist，导致 ASCII→ASCII 标题替换被放行

### 附带问题

- `isLikelyEnglishArtist` 的"单词=英文"启发式也有问题：
  EPO、JADOES（日文艺术家）被误判为英文 → 跳过 JP 区域搜索 → 无歌词
- 该启发式是 POSTM-005 为了修 Jungle 错配加的，但制造了新的问题

---

## 修复方案

### 1. romanized→CJK 路径：要求结果标题是 CJK

```swift
// Before: resultHasCJK 包含 artist → "milk tea" by "清水翔太" 通过
resultHasCJK && (searchIncludesTitle || titleIsSpecific)

// After: 只检查标题 → "milk tea" 被拒，"夢の続き" 通过
let resultTitleHasCJK = containsChinese(trackName) ||
                        containsJapanese(trackName) ||
                        containsKorean(trackName)
if resultTitleHasCJK { ... }
```

**原理**: romanized→CJK 的目的是把罗马字标题解析为 CJK 标题。
如果结果标题仍然是 ASCII，说明不是真正的 CJK 解析，是噪声。

### 2. resolveRomanizedInput fallback：拒绝 ASCII→不同ASCII 替换

```swift
// Before: 无条件接受
if let cn = cnResult { return (cn.title, cn.artist) }

// After: 标题不变或变成 CJK 才接受
if let cn = cnResult,
   cn.title.lowercased() == title.lowercased() || !isPureASCII(cn.title) { ... }
```

### 3. isLikelyEnglishArtist：去掉"单词=英文"启发式

```swift
// Before: 单词纯 ASCII → 判定英文（误杀 EPO/JADOES）
if words.count == 1 && !knownNonEnglishSingleWord.contains(lowercased) {
    if isPureASCII(artist) { return true }
}

// After: 只用高置信度信号（已知列表 + 英文词缀）
// 单词名无法区分，安全性靠 resultTitleHasCJK 保障
```

---

## 验证结果

| 歌曲 | 修复前 | 修复后 |
|------|--------|--------|
| Moon Style Love - Leo1Bee | ✗ 日文 "Milk Tea" | ✓ NetEase 60pts 中文 |
| Escape - EPO | ✗ 无歌词 | ✓ QQ 37pts (エポ) |
| Stardust Night - JADOES | ✓ | ✓ NetEase 67pts |
| Yume No Tsuzuki - Mariya Takeuchi | ✗ 无歌词 | ✓ lyrics.ovh 68pts |
| Good At Breaking Hearts - Jungle | ✓ | ✓ NetEase 59pts |
| Between Love and You - Naiwen Yang | ✓ | ✓ NetEase 60pts |
| 12 条回归用例 | 11/12 | **12/12** |

---

## 经验教训

### 关键洞察
- **`resultHasCJK` 的粒度问题**: artist 有 CJK ≠ 标题被解析为 CJK。
  检查粒度必须与操作目标一致——romanized→CJK 解析的是标题，就应该检查标题。
- **白名单不是解法**: 用 knownNonEnglishSingleWord 列表补丁只能覆盖已知的，
  无法泛化。正确做法是找到更精确的验证条件（resultTitleHasCJK）。
- **Debug 日志价值**: 完整追踪 MetadataResolver → LyricsFetcher → QQ 的链路
  才能定位根因在哪一步。

### 防御性检查清单
修改 MetadataResolver 的 romanized→CJK 路径时，必须验证：
- [ ] 纯英文歌不被 JP/KR 区域搜索污染（Moon Style Love, Jungle）
- [ ] 纯罗马字日文歌能解析（Yume No Tsuzuki, Escape）
- [ ] 拼音中文歌能解析（Between Love and You）
- [ ] 单词名艺术家不被误判（EPO, JADOES, Jungle, Queen）

---

## 标签
#lyrics #matching #metadata-resolver #false-positive #romanized-cjk
