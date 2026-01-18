# Models 模块

数据模型定义，供服务层和 UI 层使用。

## 文件清单

| 文件 | 行数 | 职责 |
|------|------|------|
| LyricModels.swift | 90 | 歌词数据结构：LyricWord, LyricLine, CachedLyricsItem |

## 设计原则

- 纯数据结构，无业务逻辑
- 所有类型 `public` 以便跨模块使用
- 实现 `Identifiable`, `Equatable` 支持 SwiftUI

---

[PROTOCOL]: 新增模型文件时更新此文档
