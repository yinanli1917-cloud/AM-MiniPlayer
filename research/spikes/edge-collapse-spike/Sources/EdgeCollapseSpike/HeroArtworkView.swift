/**
 * [INPUT]: size (pt), cornerRadius (pt)
 * [OUTPUT]: HeroArtworkView — placeholder "hero" artwork (gradient-filled
 *           rounded rect + system image "music.note"), no real album art.
 * [POS]: Standalone spike content placeholder, top-level task instruction #4/#5.
 * [PROTOCOL]: Placeholder only — never wire real MusicController/artwork into
 *             a spike (design doc explicitly keeps this decoupled from the app).
 */

import SwiftUI

struct HeroArtworkView: View {
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.96, green: 0.58, blue: 0.36), Color(red: 0.55, green: 0.24, blue: 0.62)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: max(8, size * 0.4), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
            )
            .frame(width: size, height: size)
    }
}
