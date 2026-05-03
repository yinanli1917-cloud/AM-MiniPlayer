---
name: liquid-glass
description: |
  iOS/macOS 26 Liquid Glass 设计系统专项参考。材质属性（lensing、morphing、
  adaptivity）、玻璃层级规则、GlassEffectContainer 用法、导航栏/Tab Bar 适配。
  仅在需要实现或调试 Liquid Glass 效果时使用。不涉及通用 SwiftUI 模式。
allowed-tools: Read
source: https://github.com/conorluddy/LiquidGlassReference
update: curl -sL https://raw.githubusercontent.com/conorluddy/LiquidGlassReference/main/SKILL.md -o "$HOME/Library/Mobile Documents/com~apple~CloudDocs/claude-skills/liquid-glass/SKILL.md"
installed: 2026-03-15
---

# Liquid Glass 设计系统参考

## 使用场景

当开发者需要：
- 为 iOS/macOS 26 应用添加 Liquid Glass 效果
- 调试 Liquid Glass 材质渲染问题（过曝、层级错误）
- 理解 Glass 材质的设计规则（何时用、何时不用）

## 核心规则速查

1. **玻璃仅用于导航层**，不用于内容层
2. **GlassEffectContainer** 必须包裹使用玻璃效果的视图层级
3. `.glassEffect()` 放在布局/外观修饰符之后
4. 避免在 `.sheet()` 或 `.popover()` 内嵌套玻璃效果
5. macOS: 使用 `.underWindowBackground` 替代 `.hudWindow` 避免过曝

## 详细参考

完整指南请参阅 `references/liquid-glass-guide.md`，涵盖：
- Part 1: Foundation & Basics
- Part 2: Intermediate Techniques
- 完整代码示例
