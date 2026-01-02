# Apple Music 风格背景效果实现计划

## 目标
在全屏模式下的歌单页和歌词页实现类似 Apple Music 的流体渐变背景效果。

## 当前实现分析

### 现有架构
- `LiquidBackgroundView.swift` - 使用 `NSVisualEffectView` + 纯色叠加层
- 已有 `ProgressiveBlur.metal` shader 实现渐进模糊
- 项目最低支持 macOS 14，但用户系统是 macOS 15

### 现有问题
1. 当前背景是静态的纯色叠加，缺乏 Apple Music 的流动感
2. 没有利用封面图片的色彩信息创建动态效果

## Apple Music 背景效果技术分析

根据 [逆向工程分析](https://www.aadishv.dev/music)：

### 核心技术
1. **多层封面叠加**: 4 层封面副本，分别是视口宽度的 25%、50%、80%、125%
2. **Twist 扭曲 Shader**: 围绕偏移点在一定半径内旋转坐标
3. **Kawase 模糊**: 比高斯模糊更高效的近似算法
4. **动画**: 各层以不同速度旋转和移动

### Twist Shader 核心逻辑
```glsl
vec2 twist(vec2 coord) {
    coord -= offset;
    float dist = length(coord);
    if (dist < radius) {
        float ratioDist = (radius - dist) / radius;
        float angleMod = ratioDist * ratioDist * angle;
        float s = sin(angleMod);
        float c = cos(angleMod);
        coord = vec2(coord.x * c - coord.y * s, coord.x * s + coord.y * c);
    }
    coord += offset;
    return coord;
}
```

## 实现方案对比

### 方案 A: Metal Shader (高性能，复杂度高)
**优点**:
- GPU 加速，性能最优
- 可实现精确的 twist 效果
- 与现有 ProgressiveBlur.metal 架构一致

**缺点**:
- 实现复杂度高
- 调试困难
- 需要处理 SwiftUI 与 Metal 的桥接

**性能**: ⭐⭐⭐⭐⭐ (GPU 渲染，几乎无 CPU 开销)

### 方案 B: CoreAnimation Blob Layer ([Cindori 方案](https://cindori.com/developer/animated-gradient))
**优点**:
- 实现相对简单
- CPU 使用率 < 1%（iPhone 13 基准）
- 跨平台兼容性好

**缺点**:
- 不是真正的 twist 效果，是模糊的 blob
- 视觉效果可能不如 Apple Music 精确

**性能**: ⭐⭐⭐⭐ (CoreAnimation GPU 加速)

### 方案 C: MeshGradient (macOS 15+)
**优点**:
- Apple 官方 API，最简单
- 内置优化

**缺点**:
- 需要 macOS 15+（用户系统支持）
- 不支持 macOS 14 用户
- 有报告称 macOS 15 SwiftUI 存在性能问题

**性能**: ⭐⭐⭐⭐ (官方优化)

### 方案 D: 混合方案 (推荐)
- macOS 15+: 使用 MeshGradient
- macOS 14: 使用简化的 CoreAnimation 方案

## 推荐实现: 方案 D (混合方案)

### 第一阶段: CoreAnimation 基础实现 (兼容 macOS 14+)

1. **创建 `FluidGradientLayer`**
   - 基于 Cindori 的 blob layer 方法
   - 使用 4-6 个 `CAGradientLayer` 作为色块
   - 从封面提取 3-4 个主色调
   - 应用高斯模糊融合

2. **动画系统**
   - 使用 `CADisplayLink` 或 Timer 驱动
   - 目标帧率: 15-30 FPS (节省资源)
   - 平滑的位置/缩放/旋转变化

3. **性能优化**
   - 缓存颜色提取结果
   - 歌曲切换时淡入淡出过渡
   - 背景运行时暂停动画

### 第二阶段: Metal Twist Shader (可选增强)

如果方案 D 第一阶段效果不满意，可以添加:

1. **创建 `TwistShader.metal`**
   - 实现 twist 坐标变换
   - 支持可配置的 radius、angle、offset

2. **Kawase Blur 优化**
   - 替换高斯模糊为 Kawase blur
   - 多 pass 实现 (3-4 次)

### 第三阶段: MeshGradient 升级路径 (macOS 15+)

1. **版本检测**
   ```swift
   if #available(macOS 15.0, *) {
       MeshGradientBackground(artwork: artwork)
   } else {
       FluidGradientBackground(artwork: artwork)
   }
   ```

2. **MeshGradient 实现**
   - 3x3 或 4x4 网格
   - 从封面提取控制点颜色
   - 动画位置变化

## 性能保障措施

1. **帧率限制**: 背景动画限制在 15-30 FPS
2. **懒加载**: 只在可见时渲染
3. **缓存**: 颜色提取结果缓存 (已有 `colorCache`)
4. **降级**: 检测性能问题时自动降级到静态背景
5. **用户设置**: 提供 "简化背景" 选项

## 文件结构

```
Sources/MusicMiniPlayerCore/
├── UI/
│   ├── LiquidBackgroundView.swift     # 现有，保留兼容
│   ├── FluidGradientBackground.swift  # 新增: CoreAnimation 实现
│   └── MeshGradientBackground.swift   # 新增: macOS 15+ MeshGradient
├── Shaders/
│   ├── ProgressiveBlur.metal          # 现有
│   └── TwistShader.metal              # 可选: Twist 效果
└── Services/
    └── NSImage+AverageColor.swift     # 现有，可能需要扩展提取多色
```

## 实现优先级

1. ✅ **P0**: CoreAnimation Blob 基础实现 (第一阶段)
2. ⏳ **P1**: 动画系统和性能优化
3. ⏳ **P2**: MeshGradient macOS 15+ 路径
4. ⏳ **P3**: Metal Twist Shader (可选)

## 风险评估

| 风险 | 可能性 | 影响 | 缓解措施 |
|------|--------|------|----------|
| CoreAnimation 性能不足 | 低 | 中 | 降级到静态背景 |
| macOS 15 SwiftUI 性能问题 | 中 | 中 | 使用 CoreAnimation fallback |
| 颜色提取不准确 | 低 | 低 | 使用现有 dominantColor() |
| 动画卡顿 | 中 | 中 | 降低帧率/简化效果 |

## 参考资料

- [Reverse Engineering Apple Music's Gradient](https://www.aadishv.dev/music)
- [Cindori: Animated Gradient with CoreAnimation](https://cindori.com/developer/animated-gradient)
- [Apple MeshGradient Documentation](https://developer.apple.com/documentation/SwiftUI/MeshGradient)
- [Inferno Metal Shaders](https://github.com/twostraws/Inferno)
