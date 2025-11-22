# Figma Design Guidelines: Liquid Mini Player

Since you are handling the UI in Figma, please follow these guidelines to ensure the design can be perfectly translated into SwiftUI code.

## 1. Layout & Structure (Auto Layout)
**YES, please use Auto Layout for everything.**
- **Why?**: SwiftUI relies heavily on `VStack`, `HStack`, and `ZStack`, which map directly to Figma's Auto Layout.
- **Padding**: Use consistent padding (e.g., 8px, 12px, 16px, 20px).
- **Spacing**: Define fixed spacing between elements (e.g., Play button is 16px from Next button).

## 2. Dimensions
- **Mini Player Size**: Recommended `300x300` or `320x320` points (pt).
- **Menu Bar Icon**: `18x18` or `22x22` pt (vector/SVG).
- **Corner Radius**:
    - Main Window: `20px` to `24px` (matches macOS modern windows).
    - Album Art: `12px` or `16px`.

## 3. Visual Effects (The "Liquid" Look)

### 3.1. Background Blur (Liquid Glass)
In Figma, you can simulate this, but in code, we will use `.glassEffect()`.
- **Figma Simulation**:
    - Fill: `White` (or `Black` for dark mode) at `10-20%` Opacity.
    - Effect: `Background Blur` set to `50` or higher.
    - **Note**: Don't worry if it doesn't look *exactly* like liquid in Figma. The code implementation will handle the light refraction and saturation.

### 3.2. Progressive Blur
- **Concept**: A blur that gets stronger or weaker along a gradient.
- **Figma**: You can mask a blurred layer with a gradient mask (Alpha mask).
- **Code**: We will use a Metal shader. You just need to define *where* the blur starts and ends (e.g., "Top 20% is clear, fading to full blur at 50%").

### 3.3. Shadows
- Use **soft, colored shadows** derived from the album art.
- **Settings**:
    - Blur: `40-60`
    - Y: `10-20`
    - Opacity: `15-25%`

## 4. Typography
- **Font**: SF Pro (Apple System Font).
- **Weights**:
    - Song Title: `Semibold` or `Bold`.
    - Artist: `Regular` or `Medium`.
    - Lyrics (Active): `Bold` (Scale 1.2x).
    - Lyrics (Inactive): `Regular` (Opacity 60%).

## 5. Assets
- Please export icons as **SVG** or use **SF Symbols** names (e.g., `play.fill`, `forward.fill`).
- If you design custom icons, keep them vector-based.
