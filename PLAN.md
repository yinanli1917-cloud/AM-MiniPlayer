# 歌词搜索匹配优化计划

## 问题分析

### 当前架构
LyricsService 当前使用 **并行请求所有歌词源 + 质量评分选择最佳** 的策略：

**现有歌词源**（5个）：
1. **AMLL-TTML-DB** - 逐字时间轴，最高质量，支持 NCM/Apple Music/QQ/Spotify 多平台索引
2. **NetEase (网易云)** - 中文歌首选，支持 LRC + 翻译，有 YRC 逐字歌词
3. **QQ Music** - 中文歌第二选择，支持 LRC + 翻译
4. **LRCLIB** - 开源歌词库，英文歌较全
5. **lyrics.ovh** - 最后备选，仅纯文本无时间轴

### 核心问题
**"Between Love and You" 错配案例分析**：

1. **元信息源**：系统语言英文 → Apple Music 返回英文元信息
2. **搜索策略缺陷**：
   - 当标题是英文但实际是日文/韩文/小语种歌曲时，中国歌词库（NetEase/QQ）无法正确匹配
   - `fetchChineseMetadata` 只查 iTunes CN，无法处理日文/韩文歌曲
   - 英文通用歌名（如 "Singer", "Love", "Between Love and You"）容易误匹配其他歌曲

3. **匹配逻辑漏洞**：
   - 仅靠 **标题+艺术家+时长** 三要素匹配，对通用歌名不够精确
   - 缺少 **ISRC / Apple Music Track ID** 精确匹配路径
   - 对小语种（日/韩/泰/越等）支持不足

---

## 优化方案

### Phase 1: 增强元信息获取策略

**1.1 多语言元信息获取**

当前只有 `fetchChineseMetadata`（查 iTunes CN），需要扩展为多区域策略：

```
Input: title="Between Love and You", artist="PONCHET"
→ iTunes TH (泰国) → 找到本地化元信息
→ iTunes JP (日本) → 日文歌曲
→ iTunes KR (韩国) → 韩文歌曲
```

**实现**：
- 新增 `fetchLocalizedMetadata(title:artist:duration:)` 函数
- 根据艺术家名推断可能的语言区域（启发式规则）
- 并行查询多个 iTunes 区域 API

**启发式规则**：
- 艺术家名包含日文假名 → 查 JP
- 艺术家名包含韩文 → 查 KR
- 艺术家名包含泰文 → 查 TH
- 艺术家名全是 ASCII 但不在英文艺术家数据库 → 尝试 JP/KR/TH

**1.2 ISRC 精确匹配路径**

ISRC (International Standard Recording Code) 是唱片的全球唯一标识符。

**获取途径**：
- Apple Music API（需要 MusicKit entitlement）
- ScriptingBridge 从 Music.app 获取（如果有）

**应用场景**：
- AMLL-TTML-DB 索引支持 ISRC 查询
- LRCLIB 支持 ISRC 精确匹配
- Musixmatch API 支持 ISRC 查询

---

### Phase 2: 新增全球化歌词源

**2.1 LRCLIB 增强** ⭐ 优先级高

LRCLIB 是最开放的歌词库，完全免费无需认证：

```
GET https://lrclib.net/api/search
?q={关键词}
&track_name={歌名}
&artist_name={艺术家}
&album_name={专辑}
&duration={时长秒}

GET https://lrclib.net/api/get
?track_name={歌名}
&artist_name={艺术家}
&duration={时长秒}
```

**当前问题**：只使用 `get` 端点（精确匹配），没有使用 `search` 端点（模糊搜索）

**优化**：
1. 先尝试 `get` 精确匹配
2. 失败后使用 `search` 模糊搜索
3. 对搜索结果进行标题+艺术家+时长评分

**2.2 Musixmatch** ⭐ 优先级高

全球最大歌词数据库，支持 50+ 语言，14M+ 歌词：

```
GET https://api.musixmatch.com/ws/1.1/track.search
?q_track={歌名}
&q_artist={艺术家}
&apikey={API_KEY}

GET https://api.musixmatch.com/ws/1.1/track.lyrics.get
?track_id={track_id}
&apikey={API_KEY}
```

**要求**：需要注册获取免费 API Key

**优势**：
- 覆盖全球小语种（泰语、越南语、印尼语等）
- 官方数据源，质量可靠
- 支持同步歌词

**2.3 Genius** ⭐ 优先级中

全球第二大歌词库，社区贡献：

```
GET https://api.genius.com/search?q={搜索词}
Authorization: Bearer {ACCESS_TOKEN}

GET https://api.genius.com/songs/{song_id}
→ 返回歌词页面 URL → 需要爬取 HTML
```

**限制**：
- API 不直接返回歌词文本，只返回歌词页面 URL
- 需要额外的 HTML 解析步骤
- 无时间轴（纯文本）

**适用场景**：作为最后的纯文本备选

**2.4 酷狗 KRC** ⭐ 优先级中

酷狗音乐 API，中文歌另一个选择：

```
GET http://mobilecdn.kugou.com/api/v3/search/song
?keyword={关键词}
&page=1
&pagesize=20

GET http://lyrics.kugou.com/search
?keyword={关键词}
&duration={毫秒}
&client=pc
&ver=1
&man=yes
```

**优势**：
- KRC 格式支持逐字歌词
- 与 NetEase/QQ 互补
- 某些歌曲在酷狗有但其他平台没有

**2.5 Spotify 非官方 API** ⭐ 优先级低

需要 SP_DC Cookie，可能违反 TOS，暂不实现：

```
# 需要从浏览器获取 sp_dc cookie
# 不推荐在正式版本中使用
```

---

### Phase 3: 搜索匹配算法优化

**3.1 精确匹配层级**

```
Level 0: ISRC 完全匹配（最可靠）
Level 1: Track ID 匹配（Apple Music ID / Spotify ID / NetEase ID）
Level 2: 标题 + 艺术家 + 时长（±1秒）精确匹配
Level 3: 标题 + 艺术家 + 时长（±3秒）模糊匹配
Level 4: 艺术家 + 时长（±1秒）+ 歌词内容关键词匹配
```

**3.2 歌名规范化**

处理常见的歌名变体：

```swift
func normalizeTrackName(_ name: String) -> String {
    var normalized = name.lowercased()

    // 移除常见后缀
    let suffixPatterns = [
        "\\s*\\(feat\\..*\\)",           // (feat. xxx)
        "\\s*\\[feat\\..*\\]",           // [feat. xxx]
        "\\s*-\\s*remaster.*",           // - Remaster
        "\\s*\\(\\d{4}\\s*remaster\\)",  // (2020 Remaster)
        "\\s*\\(official.*\\)",          // (Official Video)
        "\\s*\\(live.*\\)",              // (Live)
        "\\s*\\(acoustic.*\\)",          // (Acoustic)
    ]

    for pattern in suffixPatterns {
        normalized = normalized.replacingOccurrences(
            of: pattern, with: "", options: .regularExpression
        )
    }

    return normalized.trimmingCharacters(in: .whitespaces)
}
```

**3.3 艺术家名规范化**

```swift
func normalizeArtistName(_ name: String) -> [String] {
    // 拆分多艺术家
    let separators = [" & ", ", ", " feat. ", " ft. ", " x ", " vs ", " vs. "]
    var artists = [name]

    for sep in separators {
        artists = artists.flatMap { $0.components(separatedBy: sep) }
    }

    return artists.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
}
```

**3.4 相似度评分算法**

```swift
func calculateMatchScore(
    inputTitle: String, inputArtist: String, inputDuration: TimeInterval,
    resultTitle: String, resultArtist: String, resultDuration: TimeInterval
) -> Double {
    var score = 0.0

    // 时长匹配（权重 40%）
    let durationDiff = abs(inputDuration - resultDuration)
    if durationDiff < 1 { score += 40 }
    else if durationDiff < 2 { score += 30 }
    else if durationDiff < 3 { score += 20 }
    else if durationDiff < 5 { score += 10 }
    else { return 0 }  // 时长差太大，直接拒绝

    // 标题匹配（权重 35%）
    let titleSimilarity = stringSimilarity(
        normalizeTrackName(inputTitle),
        normalizeTrackName(resultTitle)
    )
    score += titleSimilarity * 35

    // 艺术家匹配（权重 25%）
    let inputArtists = normalizeArtistName(inputArtist)
    let resultArtists = normalizeArtistName(resultArtist)
    let artistMatched = inputArtists.contains { input in
        resultArtists.contains { result in
            input.contains(result) || result.contains(input)
        }
    }
    if artistMatched { score += 25 }

    return score
}
```

---

### Phase 4: 歌词源优先级重构

**当前优先级**（并行请求后评分选择）：
```
AMLL(10) > NetEase(8) > QQ(6) > LRCLIB(3) > lyrics.ovh(0)
```

**新优先级策略**：

根据歌曲语言类型动态调整：

```swift
enum SongLanguage {
    case chinese      // 中文（简/繁）
    case japanese     // 日文
    case korean       // 韩文
    case english      // 英文
    case other        // 其他小语种
}

func getSourcePriorities(for language: SongLanguage) -> [LyricsSource] {
    switch language {
    case .chinese:
        return [.amll, .netease, .qqMusic, .kugou, .lrclib, .musixmatch]
    case .japanese:
        return [.amll, .lrclib, .musixmatch, .netease]
    case .korean:
        return [.amll, .lrclib, .musixmatch, .netease]
    case .english:
        return [.amll, .lrclib, .musixmatch, .genius]
    case .other:
        return [.musixmatch, .lrclib, .amll, .genius]  // 小语种 Musixmatch 最强
    }
}
```

---

## 实现优先级

| 优先级 | 任务 | 预期效果 | 状态 |
|-------|------|---------|------|
| P0 | LRCLIB `search` 端点 | 提升模糊匹配能力 | ✅ 已完成 |
| P0 | 多区域元信息获取 | 解决 "Between Love and You" 类问题 | ✅ 已完成 |
| P0 | SimpMusic Lyrics 集成 | 全球化歌词覆盖（YouTube Music） | ✅ 已完成 |
| P0 | 匹配算法优化 | 减少误匹配 | ✅ 已完成 |
| P1 | Musixmatch 集成 | 覆盖 50+ 语言 | ❌ 需要 API Key |
| P2 | 酷狗 KRC 集成 | 增加中文歌词覆盖 | 待定 |
| P2 | Genius 集成 | 纯文本备选 | 待定 |
| P3 | ISRC 精确匹配 | 终极精确度 | 待定 |

---

## 已完成的文件变更

1. **LyricsService.swift** - 核心逻辑修改
   - ✅ 新增 `fetchLocalizedMetadata` 多区域元信息获取（JP/KR/TH/VN）
   - ✅ 新增 `fetchFromSimpMusic` 全球化歌词源
   - ✅ 新增 `fetchFromLRCLIBSearch` 模糊搜索端点
   - ✅ 更新 `parallelFetchAndSelectBest` 增加新歌词源
   - ✅ 新增 `normalizeTrackName` / `normalizeArtistName` 工具函数
   - ✅ 新增 `stringSimilarity` 字符串相似度评分
   - ✅ 新增语言检测：`containsThaiCharacters`, `containsVietnameseCharacters`, `isPureASCII`
   - ✅ 新增 `inferRegions` 区域推断 + `isLikelyEnglishArtist` 启发式规则

2. **CLAUDE.md** - ✅ 更新歌词源文档

---

## 参考资源

- [LRCLIB API](https://lrclib.net/docs)
- [Musixmatch API](https://developer.musixmatch.com/)
- [Genius API](https://docs.genius.com/)
- [Lyricify-Lyrics-Helper](https://github.com/WXRIW/Lyricify-Lyrics-Helper)
- [Kugou API](https://github.com/keyule/KuGou-API)

---

[PROTOCOL]: 此计划用于歌词搜索匹配优化实现
