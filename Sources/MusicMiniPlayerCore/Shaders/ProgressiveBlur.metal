//
//  ProgressiveBlur.metal
//  MusicMiniPlayer
//
//  自研渐进模糊 Metal Shader
//  原理：使用 mask 纹理控制每个像素的模糊半径
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - 高斯权重计算

/// 计算高斯权重
float gaussianWeight(float offset, float sigma) {
    float coefficient = 1.0 / (sqrt(2.0 * M_PI_F) * sigma);
    float exponent = -(offset * offset) / (2.0 * sigma * sigma);
    return coefficient * exp(exponent);
}

// MARK: - 水平模糊 Pass

/// 水平方向的可变高斯模糊
/// - Parameters:
///   - position: 当前像素位置
///   - layer: SwiftUI layer
///   - maxRadius: 最大模糊半径
///   - maskTexture: 控制模糊强度的 mask（白色=模糊，透明=清晰）
[[ stitchable ]] half4 horizontalProgressiveBlur(
    float2 position,
    SwiftUI::Layer layer,
    float maxRadius,
    float maskStrength
) {
    // 从 mask 强度计算实际模糊半径
    float radius = maxRadius * maskStrength;

    // 如果半径太小，直接返回原像素
    if (radius < 0.5) {
        return layer.sample(position);
    }

    // 计算 sigma（标准差），通常 sigma = radius / 3
    float sigma = max(radius / 3.0, 0.001);

    // 采样数量（奇数）
    int sampleCount = min(int(radius * 2.0) + 1, 31); // 最多 31 个采样
    int halfSamples = sampleCount / 2;

    half4 result = half4(0.0);
    float totalWeight = 0.0;

    // 水平方向采样
    for (int i = -halfSamples; i <= halfSamples; i++) {
        float offset = float(i);
        float weight = gaussianWeight(offset, sigma);

        float2 samplePos = position + float2(offset, 0.0);
        result += layer.sample(samplePos) * weight;
        totalWeight += weight;
    }

    // 归一化
    return result / totalWeight;
}

// MARK: - 垂直模糊 Pass

/// 垂直方向的可变高斯模糊
[[ stitchable ]] half4 verticalProgressiveBlur(
    float2 position,
    SwiftUI::Layer layer,
    float maxRadius,
    float maskStrength
) {
    float radius = maxRadius * maskStrength;

    if (radius < 0.5) {
        return layer.sample(position);
    }

    float sigma = max(radius / 3.0, 0.001);
    int sampleCount = min(int(radius * 2.0) + 1, 31);
    int halfSamples = sampleCount / 2;

    half4 result = half4(0.0);
    float totalWeight = 0.0;

    // 垂直方向采样
    for (int i = -halfSamples; i <= halfSamples; i++) {
        float offset = float(i);
        float weight = gaussianWeight(offset, sigma);

        float2 samplePos = position + float2(0.0, offset);
        result += layer.sample(samplePos) * weight;
        totalWeight += weight;
    }

    return result / totalWeight;
}

// MARK: - 单 Pass 简化版（性能较低但更简单）

/// 单 Pass 渐进模糊（根据 Y 坐标渐变）
/// 从底部到顶部，模糊程度逐渐减小
[[ stitchable ]] half4 progressiveBlurFromBottom(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float maxRadius,
    float blurHeight
) {
    // 计算当前位置的模糊强度（从底部开始）
    float distanceFromBottom = size.y - position.y;
    float maskStrength = clamp(1.0 - (distanceFromBottom / blurHeight), 0.0, 1.0);

    // 平滑过渡
    maskStrength = maskStrength * maskStrength * (3.0 - 2.0 * maskStrength); // smoothstep

    float radius = maxRadius * maskStrength;

    if (radius < 0.5) {
        return layer.sample(position);
    }

    float sigma = max(radius / 3.0, 0.001);
    int sampleCount = min(int(radius * 2.0) + 1, 15); // 限制采样数以保证性能
    int halfSamples = sampleCount / 2;

    half4 result = half4(0.0);
    float totalWeight = 0.0;

    // 两个方向同时采样（box blur 简化版）
    for (int y = -halfSamples; y <= halfSamples; y++) {
        for (int x = -halfSamples; x <= halfSamples; x++) {
            float2 offset = float2(x, y);
            float distance = length(offset);
            float weight = gaussianWeight(distance, sigma);

            float2 samplePos = position + offset;
            result += layer.sample(samplePos) * weight;
            totalWeight += weight;
        }
    }

    return result / totalWeight;
}

// MARK: - 从顶部开始的渐进模糊

[[ stitchable ]] half4 progressiveBlurFromTop(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float maxRadius,
    float blurHeight
) {
    float distanceFromTop = position.y;
    float maskStrength = clamp(1.0 - (distanceFromTop / blurHeight), 0.0, 1.0);
    maskStrength = maskStrength * maskStrength * (3.0 - 2.0 * maskStrength);

    float radius = maxRadius * maskStrength;

    if (radius < 0.5) {
        return layer.sample(position);
    }

    float sigma = max(radius / 3.0, 0.001);
    int sampleCount = min(int(radius * 2.0) + 1, 15);
    int halfSamples = sampleCount / 2;

    half4 result = half4(0.0);
    float totalWeight = 0.0;

    for (int y = -halfSamples; y <= halfSamples; y++) {
        for (int x = -halfSamples; x <= halfSamples; x++) {
            float2 offset = float2(x, y);
            float distance = length(offset);
            float weight = gaussianWeight(distance, sigma);

            float2 samplePos = position + offset;
            result += layer.sample(samplePos) * weight;
            totalWeight += weight;
        }
    }

    return result / totalWeight;
}
