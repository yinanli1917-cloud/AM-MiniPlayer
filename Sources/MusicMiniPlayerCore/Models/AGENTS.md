# Codex Project Instructions

_Migrated from Claude Code `/Users/yinanli/Documents/MusicMiniPlayer/Sources/MusicMiniPlayerCore/Models/CLAUDE.md` on 2026-05-03. The source `CLAUDE.md` was left unchanged._

Codex should follow these instructions when working in this project. Claude-specific commands, hooks, and permission syntax should be interpreted as intent and adapted to Codex tools.

# Models 模块

数据模型定义，供服务层和 UI 层使用。

## 文件清单

| 文件 | 行数 | 职责 |
|------|------|------|
| LyricModels.swift | 106 | 歌词数据结构：LyricWord, LyricLine, CachedLyricsItem, kInstrumentalPatterns |

## 设计原则

- 纯数据结构，无业务逻辑
- 所有类型 `public` 以便跨模块使用
- 实现 `Identifiable`, `Equatable` 支持 SwiftUI

---

[PROTOCOL]: 新增模型文件时更新此文档
