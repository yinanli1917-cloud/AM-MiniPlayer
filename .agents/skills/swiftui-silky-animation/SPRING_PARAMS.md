# Spring 参数完整参考

## 参数含义

| 参数 | 含义 | 数值影响 |
|------|------|----------|
| mass | 弹簧质量 | 越大移动越慢，惯性越强 |
| stiffness | 弹簧刚度 | 越大弹力越强，回弹越快 |
| damping | 阻尼系数 | 越大衰减越快，弹性越弱 |
| initialVelocity | 初始速度 | 通常为 0，手势拖拽时可传入速度 |

## AMLL 参数 (Apple Music Lyrics-Like)

### 位置动画 (PosY)
```swift
.interpolatingSpring(mass: 1, stiffness: 100, damping: 16.5, initialVelocity: 0)
```
- 用于: 歌词滚动、元素位移、页面切换
- 特点: 流畅自然，有轻微过冲

### 缩放动画 (Scale)
```swift
.interpolatingSpring(mass: 1, stiffness: 100, damping: 16.5, initialVelocity: 0)
```
- 用于: hover 放大、焦点高亮
- 特点: 与位置动画一致，保持协调

### 视觉属性动画 (Blur/Opacity)
```swift
.interpolatingSpring(mass: 1, stiffness: 100, damping: 20, initialVelocity: 0)
```
- 用于: 模糊过渡、透明度变化、颜色变化
- 特点: damping 稍高 (20)，更快稳定，避免视觉闪烁

## Apple 原生预设

```swift
// 弹性 (有明显回弹)
.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0)

// 平滑 (几乎无回弹)
.spring(response: 0.5, dampingFraction: 0.9, blendDuration: 0)

// 快速响应
.spring(response: 0.3, dampingFraction: 0.7, blendDuration: 0)

// 交互式 (跟手)
.interactiveSpring(response: 0.15, dampingFraction: 0.86, blendDuration: 0.25)
```

## 场景推荐

| 场景 | 推荐参数 |
|------|----------|
| 歌词滚动 | AMLL PosY |
| 封面缩放 | AMLL Scale |
| 模糊/透明度 | AMLL Blur/Opacity |
| 窗口吸附 | stiffness: 280, damping: 22 |
| 按钮点击 | Apple 快速响应 |
| 拖拽跟手 | Apple 交互式 |
| 页面过渡 | AMLL PosY + Blur/Opacity 组合 |

## response/dampingFraction 与 mass/stiffness/damping 转换

```swift
// response ≈ 2π / sqrt(stiffness / mass)
// dampingFraction = damping / (2 * sqrt(stiffness * mass))

// 例: AMLL PosY (mass:1, stiffness:100, damping:16.5)
// response ≈ 0.628
// dampingFraction ≈ 0.825
```

## 调试技巧

1. **先确定 response**: 动画总时长感觉
2. **再调 dampingFraction**: 0.5-0.7 弹性，0.8-1.0 平滑
3. **微调 stiffness**: 更精细的"弹力"控制
