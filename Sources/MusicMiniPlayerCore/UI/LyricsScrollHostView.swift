/**
 * [INPUT]: LyricsScrollEngine offsets, row SwiftUI content as NSHostingView children
 * [OUTPUT]: Per-frame row Y via AppKit layout — no SwiftUI body invalidation per frame
 * [POS]: Host layer for lyrics scroll stack (display link drives engine.tick)
 */

import SwiftUI
import AppKit
import QuartzCore

struct LyricsScrollRowConfiguration: Identifiable {
    let id: String
    let index: Int
    let content: AnyView
}

struct LyricsScrollHostConfiguration: Equatable {
    var rows: [LyricsScrollRowConfiguration]
    var anchorY: CGFloat
    var accumulatedHeights: [Int: CGFloat]
    var manualScrollOffset: CGFloat
    var displayIndex: Int
    var isManualScrolling: Bool
    var frozenTargetIndex: Int?
    var contentWidth: CGFloat
    var reduceMotion: Bool
    var suppressInitialMotion: Bool
    /// Bumps when row SwiftUI content (highlight / translation) must refresh without row-id churn.
    var contentGeneration: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows.map(\.id) == rhs.rows.map(\.id)
            && lhs.anchorY == rhs.anchorY
            && lhs.accumulatedHeights == rhs.accumulatedHeights
            && lhs.manualScrollOffset == rhs.manualScrollOffset
            && lhs.displayIndex == rhs.displayIndex
            && lhs.isManualScrolling == rhs.isManualScrolling
            && lhs.frozenTargetIndex == rhs.frozenTargetIndex
            && lhs.contentWidth == rhs.contentWidth
            && lhs.reduceMotion == rhs.reduceMotion
            && lhs.suppressInitialMotion == rhs.suppressInitialMotion
            && lhs.contentGeneration == rhs.contentGeneration
    }
}

@MainActor
final class LyricsScrollContainerView: NSView {
    weak var engine: LyricsScrollEngine?
    var onPresentationFrame: ((TimeInterval) -> Void)?
    var onRowHeightChange: ((Int, CGFloat) -> Void)?

    private var configuration = LyricsScrollHostConfiguration(
        rows: [],
        anchorY: 0,
        accumulatedHeights: [:],
        manualScrollOffset: 0,
        displayIndex: 0,
        isManualScrolling: false,
        frozenTargetIndex: nil,
        contentWidth: 400,
        reduceMotion: false,
        suppressInitialMotion: false,
        contentGeneration: 0
    )

    private var rowHosts: [Int: NSHostingView<AnyView>] = [:]
    private var rowBaseY: [Int: CGFloat] = [:]
    private var rowHeights: [Int: CGFloat] = [:]
    private var displayLink: AnyObject?
    private var animationTimer: Timer?

    override var isFlipped: Bool { true }

    func apply(configuration: LyricsScrollHostConfiguration) {
        let rowIDsChanged = self.configuration.rows.map(\.id) != configuration.rows.map(\.id)
        let layoutChanged = self.configuration.accumulatedHeights != configuration.accumulatedHeights
            || self.configuration.anchorY != configuration.anchorY
        let contentChanged = rowIDsChanged
            || self.configuration.contentGeneration != configuration.contentGeneration
        let scrollStateChanged = self.configuration.manualScrollOffset != configuration.manualScrollOffset
            || self.configuration.isManualScrolling != configuration.isManualScrolling
            || self.configuration.frozenTargetIndex != configuration.frozenTargetIndex
            || self.configuration.displayIndex != configuration.displayIndex

        self.configuration = configuration

        engine?.setLayout(LyricsScrollEngine.LayoutSnapshot(
            anchorY: configuration.anchorY,
            accumulatedHeights: configuration.accumulatedHeights
        ))
        engine?.setReduceMotion(configuration.reduceMotion)

        if contentChanged {
            syncRowHosts()
        } else if layoutChanged || scrollStateChanged {
            repositionAllRows()
        }

        updateDisplayLinkState()
    }

    func syncRowHosts() {
        let desired = Set(configuration.rows.map(\.index))
        for index in rowHosts.keys where !desired.contains(index) {
            rowHosts[index]?.removeFromSuperview()
            rowHosts.removeValue(forKey: index)
            rowBaseY.removeValue(forKey: index)
            rowHeights.removeValue(forKey: index)
        }

        let contentWidth = max(1, configuration.contentWidth)
        for row in configuration.rows {
            let hosting: NSHostingView<AnyView>
            if let existing = rowHosts[row.index] {
                hosting = existing
                hosting.rootView = row.content
            } else {
                hosting = NSHostingView(rootView: row.content)
                hosting.translatesAutoresizingMaskIntoConstraints = true
                hosting.layerContentsRedrawPolicy = .onSetNeedsDisplay
                addSubview(hosting)
                rowHosts[row.index] = hosting
            }
            hosting.frame.size.width = contentWidth
            let height = measureRowHeight(hosting)
            rowHeights[row.index] = height
            if height > 1 {
                onRowHeightChange?(row.index, height)
            }
        }
        repositionAllRows()
    }

    private func measureRowHeight(_ hosting: NSHostingView<AnyView>) -> CGFloat {
        let fitting = hosting.fittingSize.height
        if fitting > 1 { return fitting }
        hosting.layoutSubtreeIfNeeded()
        return max(hosting.fittingSize.height, hosting.frame.height, 1)
    }

    private func repositionAllRows() {
        guard let engine else { return }
        let frozen = configuration.isManualScrolling ? configuration.frozenTargetIndex : nil
        let contentWidth = max(1, configuration.contentWidth)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in configuration.rows {
            guard let hosting = rowHosts[row.index] else { continue }
            let y = engine.fullOffsetY(
                forRow: row.index,
                displayIndex: configuration.displayIndex,
                manualScrollFrozenTarget: frozen
            ) + configuration.manualScrollOffset
            let height = rowHeights[row.index] ?? measureRowHeight(hosting)

            if let previousY = rowBaseY[row.index], abs(previousY - y) < 0.25,
               abs(hosting.frame.height - height) < 0.25 {
                continue
            }
            rowBaseY[row.index] = y
            hosting.frame = NSRect(x: 0, y: y, width: contentWidth, height: height)
        }
        CATransaction.commit()
    }

    private func updateDisplayLinkState() {
        if engine?.isWaveActive == true {
            startDisplayLinkIfNeeded()
        } else {
            stopDisplayLink()
        }
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil && animationTimer == nil else { return }

        if #available(macOS 14.0, *) {
            let link = displayLink(
                target: self,
                selector: #selector(displayLinkFired(_:))
            )
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30, maximum: 60, preferred: 60
            )
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickFrame() }
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        }
    }

    private func stopDisplayLink() {
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
        displayLink = nil
        animationTimer?.invalidate()
        animationTimer = nil
    }

    @available(macOS 14.0, *)
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        tickFrame()
    }

    private func tickFrame() {
        engine?.onPresentationFrame = onPresentationFrame
        engine?.tick()
        repositionAllRows()

        if engine?.isWaveActive != true {
            stopDisplayLink()
        }
    }

    override func layout() {
        super.layout()
        repositionAllRows()
    }

    deinit {
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
        animationTimer?.invalidate()
    }
}

struct LyricsScrollHostRepresentable: NSViewRepresentable {
    let engine: LyricsScrollEngine
    let configuration: LyricsScrollHostConfiguration
    var onPresentationFrame: ((TimeInterval) -> Void)?
    var onRowHeightChange: ((Int, CGFloat) -> Void)?

    func makeNSView(context: Context) -> LyricsScrollContainerView {
        let view = LyricsScrollContainerView()
        view.engine = engine
        view.onPresentationFrame = onPresentationFrame
        view.onRowHeightChange = onRowHeightChange
        view.apply(configuration: configuration)
        return view
    }

    func updateNSView(_ nsView: LyricsScrollContainerView, context: Context) {
        nsView.engine = engine
        nsView.onPresentationFrame = onPresentationFrame
        nsView.onRowHeightChange = onRowHeightChange
        nsView.apply(configuration: configuration)
    }
}
