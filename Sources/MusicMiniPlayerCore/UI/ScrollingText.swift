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
    @State private var hasScrolled = false

    var body: some View {
        GeometryReader { geometry in
            if shouldScroll && !hasScrolled {
                // Scrolling animation for long text - scroll once then stop
                HStack(spacing: 0) {
                    Text(text)
                        .font(font)
                        .foregroundColor(textColor)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: alignment)
                }
                .offset(x: offset)
                .frame(width: maxWidth, alignment: alignment)
                .onAppear {
                    // Start scrolling after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        // Scroll to show the end, then back to start
                        let scrollDistance = textWidth - maxWidth
                        withAnimation(.linear(duration: Double(scrollDistance) / 20.0)) {
                            offset = -scrollDistance
                        }
                        // After scrolling, pause and reset
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(scrollDistance) / 20.0 + 1.0) {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                offset = 0
                                hasScrolled = true
                            }
                        }
                    }
                }
            } else {
                // Static text if it fits or after scroll is complete
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
                    .onChange(of: text) { _, _ in
                        // Reset scroll state when text changes
                        textWidth = geo.size.width
                        shouldScroll = textWidth > maxWidth
                        hasScrolled = false
                        offset = 0
                    }
                })
        )
    }
}
