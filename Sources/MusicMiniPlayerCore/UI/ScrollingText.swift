import SwiftUI

struct ScrollingText: View {
    let text: String
    let font: Font
    let textColor: Color
    let maxWidth: CGFloat

    var alignment: Alignment = .center // Default to center, but can be overridden

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var shouldScroll = false

    var body: some View {
        GeometryReader { geometry in
            if shouldScroll {
                // Scrolling animation for long text
                HStack(spacing: 40) {
                    Text(text)
                        .font(font)
                        .foregroundColor(textColor)
                        .fixedSize()

                    // Duplicate text for seamless loop
                    Text(text)
                        .font(font)
                        .foregroundColor(textColor)
                        .fixedSize()
                }
                .offset(x: offset)
                .onAppear {
                    // Start scrolling after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation(.linear(duration: Double(textWidth) / 30.0).repeatForever(autoreverses: false)) {
                            offset = -(textWidth + 40)
                        }
                    }
                }
            } else {
                // Static text if it fits
                Text(text)
                    .font(font)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxWidth, alignment: alignment)
            }
        }
        .frame(height: 20)
        .clipped()
        .background(
            // Measure text width
            Text(text)
                .font(font)
                .fixedSize()
                .opacity(0)
                .background(GeometryReader { geo in
                    Color.clear.onAppear {
                        textWidth = geo.size.width
                        shouldScroll = textWidth > maxWidth
                    }
                })
        )
    }
}
