#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Progressive Blur Shader
// Applies variable blur intensity based on vertical position
[[ stitchable ]] half4 progressiveBlur(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float blurStart,      // Where blur begins (0.0 - 1.0, vertical position)
    float blurEnd,        // Where blur reaches maximum (0.0 - 1.0)
    float maxRadius       // Maximum blur radius
) {
    // Normalize vertical position (0.0 = top, 1.0 = bottom)
    float normalizedY = position.y / size.y;

    // Calculate blur intensity based on position
    float blurIntensity = 0.0;
    if (normalizedY < blurStart) {
        // Above blur start: no blur
        blurIntensity = 0.0;
    } else if (normalizedY >= blurStart && normalizedY < blurEnd) {
        // Transition zone: progressive blur
        blurIntensity = (normalizedY - blurStart) / (blurEnd - blurStart);
    } else {
        // Below blur end: maximum blur
        blurIntensity = 1.0;
    }

    // Calculate actual blur radius for this pixel
    float radius = blurIntensity * maxRadius;

    // Sample surrounding pixels for blur effect
    half4 color = half4(0.0);
    float totalWeight = 0.0;

    // Simple box blur with variable radius
    int samples = int(ceil(radius)) * 2 + 1;
    float step = radius / float(samples / 2);

    for (int y = -samples/2; y <= samples/2; y++) {
        for (int x = -samples/2; x <= samples/2; x++) {
            float2 offset = float2(float(x) * step, float(y) * step);
            float2 samplePos = position + offset;

            // Gaussian-like weight
            float distance = length(offset);
            float weight = exp(-distance * distance / (2.0 * radius * radius));

            color += layer.sample(samplePos) * weight;
            totalWeight += weight;
        }
    }

    return color / totalWeight;
}
