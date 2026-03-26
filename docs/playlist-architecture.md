# PlaylistView Architecture Reference

> This is a reference document for the "日" structure layout.
> Active rules are in `.claude/rules/banned-patterns.md`.

## Structure Diagram

```
┌─────────────────────────┐  ← History Header (plain text, transparent)
│  ┌───────────────────┐  │
│  │   History 歌单    │  │  ← Fixed-height embedded ScrollView
│  └───────────────────┘  │
├─────────────────────────┤  ← Now Playing Card (default anchor)
│      Now Playing Card   │
│      [Shuffle] [Repeat] │
├─────────────────────────┤
│  Up Next Header         │  ← Plain text, transparent
│  ┌───────────────────┐  │
│  │   Up Next 歌单    │  │  ← Fixed-height embedded ScrollView
│  └───────────────────┘  │
└─────────────────────────┘
```

## Layer Stack

1. **LiquidBackgroundView** — Single unified background
2. **日字 framework** — History + NowPlaying + UpNext in single ScrollView + VStack
3. **SharedBottomControls** — Independent overlay layer

## Interaction

- Default anchor: Now Playing Card at viewport top
- Trackpad down (deltaY > 0) → History (above Now Playing)
- Trackpad up (deltaY < 0) → Up Next (below Now Playing)
- Each song list: fixed-height embedded ScrollView, independent scroll
- Headers: plain text, transparent background, no blur material

## Correct Implementation Pattern

```swift
// Single ScrollView, no snap (free scrolling)
ScrollView {
    VStack(spacing: 0) {
        // History section
        sectionHeader("History")
        ForEach(historyTracks) { ... }

        // Now Playing (anchor)
        NowPlayingCard()

        // Up Next section
        sectionHeader("Up Next")
        ForEach(upNextTracks) { track in
            SongRow(track)
                .modifier(ScrollFadeEffect(headerHeight: stickyHeaderY))
        }
    }
}
.coordinateSpace(name: "scroll")
```

## Sticky Header: Global Overlay + PreferenceKey

```swift
// Track section positions via PreferenceKey
.overlay(alignment: .top) {
    // Pure text header, no material/blur background
    Text(currentSectionTitle)
        .padding()
}
```

## Gemini Per-View Blur

```swift
struct ScrollFadeEffect: ViewModifier {
    let headerHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .visualEffect { content, geometryProxy in
                let frame = geometryProxy.frame(in: .named("scroll"))
                let minY = frame.minY
                let progress = max(0, min(1, 1 - (minY / headerHeight)))
                return content
                    .blur(radius: progress * 10)
                    .opacity(1 - (progress * 0.5))
            }
    }
}
```

Header area is physically transparent — background shows through perfectly.

## Failed Approaches (Historical Record)

All of these were attempted and failed. See `.claude/rules/banned-patterns.md` for the condensed list.

1. Section + LazyVStack + pinnedViews → macOS 26 recursion
2. Nested ScrollView → Scroll conflict
3. VStack + offset + clipped → Pages bleed through
4. ZStack + opacity → No slide, matchedGeometryEffect ghosts
5. Conditional rendering → ScrollView destroyed
6. NSHostingView + alphaValue → Separate render trees
7. Static ZStack layers → Can't scroll
8. Duplicate NowPlayingCard instances
9. Page order/offset reversed
10. Unconstrained two-page container height
11. ZStack alignment: .top with offset pagination
12. controlsReservedHeight spacer → Empty space at bottom
13. Pagination container covering bottom controls hit area
