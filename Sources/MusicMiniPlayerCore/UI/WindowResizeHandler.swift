import AppKit
import SwiftUI

/// 窗口缩放处理器 - 实现整体scale缩放（不是resize）
public class WindowResizeHandler {
    private weak var window: NSWindow?
    private var trackingArea: NSTrackingArea?
    private var isResizing = false
    private var resizeStartPoint: NSPoint = .zero
    private var resizeStartFrame: NSRect = .zero
    private var resizeEdge: ResizeEdge = .none

    private let edgeThreshold: CGFloat = 8.0 // 边缘检测阈值
    private let aspectRatio: CGFloat = 300.0 / 380.0 // 原始宽高比
    private let minSize = NSSize(width: 200, height: 253) // 最小尺寸 (保持宽高比)
    private let maxSize = NSSize(width: 600, height: 760) // 最大尺寸 (保持宽高比)

    enum ResizeEdge {
        case none
        case right
        case bottom
        case bottomRight
        case left
        case top
        case bottomLeft
        case topRight
        case topLeft
    }

    public init(window: NSWindow) {
        self.window = window
        setupTracking()
    }

    private func setupTracking() {
        guard let window = window, let contentView = window.contentView else { return }

        // 创建全窗口跟踪区域
        trackingArea = NSTrackingArea(
            rect: contentView.bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )

        if let trackingArea = trackingArea {
            contentView.addTrackingArea(trackingArea)
        }

        // 创建自定义视图来处理鼠标事件
        let overlayView = ResizeOverlayView(handler: self)
        overlayView.frame = contentView.bounds
        overlayView.autoresizingMask = [.width, .height]
        contentView.addSubview(overlayView, positioned: .above, relativeTo: nil)
    }

    func detectEdge(at point: NSPoint, in view: NSView) -> ResizeEdge {
        let bounds = view.bounds
        let nearRight = point.x >= bounds.maxX - edgeThreshold
        let nearLeft = point.x <= bounds.minX + edgeThreshold
        let nearBottom = point.y <= bounds.minY + edgeThreshold
        let nearTop = point.y >= bounds.maxY - edgeThreshold

        // 角落优先
        if nearBottom && nearRight { return .bottomRight }
        if nearBottom && nearLeft { return .bottomLeft }
        if nearTop && nearRight { return .topRight }
        if nearTop && nearLeft { return .topLeft }

        // 边缘
        if nearRight { return .right }
        if nearLeft { return .left }
        if nearBottom { return .bottom }
        if nearTop { return .top }

        return .none
    }

    func cursor(for edge: ResizeEdge) -> NSCursor {
        switch edge {
        case .right, .left:
            return .resizeLeftRight
        case .bottom, .top:
            return .resizeUpDown
        case .bottomRight, .topLeft:
            return NSCursor.resizeNorthwestSoutheast
        case .bottomLeft, .topRight:
            return NSCursor.resizeNortheastSouthwest
        case .none:
            return .arrow
        }
    }

    func startResize(at point: NSPoint, edge: ResizeEdge) {
        guard let window = window else { return }

        isResizing = true
        resizeEdge = edge
        resizeStartPoint = NSEvent.mouseLocation
        resizeStartFrame = window.frame
    }

    func updateResize(to point: NSPoint) {
        guard isResizing, let window = window else { return }

        let delta = NSPoint(
            x: point.x - resizeStartPoint.x,
            y: point.y - resizeStartPoint.y
        )

        var newFrame = resizeStartFrame

        // 根据拖拽的边缘计算新尺寸
        switch resizeEdge {
        case .right:
            newFrame.size.width = resizeStartFrame.width + delta.x
            newFrame.size.height = newFrame.size.width / aspectRatio
        case .left:
            newFrame.size.width = resizeStartFrame.width - delta.x
            newFrame.size.height = newFrame.size.width / aspectRatio
            newFrame.origin.x = resizeStartFrame.maxX - newFrame.width
        case .bottom:
            newFrame.size.height = resizeStartFrame.height - delta.y
            newFrame.size.width = newFrame.size.height * aspectRatio
            newFrame.origin.y = resizeStartFrame.maxY - newFrame.height
        case .top:
            newFrame.size.height = resizeStartFrame.height + delta.y
            newFrame.size.width = newFrame.size.height * aspectRatio
        case .bottomRight:
            // 使用对角线距离来计算缩放
            let diagonal = sqrt(delta.x * delta.x + delta.y * delta.y)
            let scaleFactor = 1.0 + (diagonal / 300.0) * (delta.x > 0 ? 1 : -1)
            newFrame.size.width = resizeStartFrame.width * scaleFactor
            newFrame.size.height = newFrame.size.width / aspectRatio
            newFrame.origin.y = resizeStartFrame.maxY - newFrame.height
        case .bottomLeft:
            let diagonal = sqrt(delta.x * delta.x + delta.y * delta.y)
            let scaleFactor = 1.0 + (diagonal / 300.0) * (delta.x < 0 ? 1 : -1)
            newFrame.size.width = resizeStartFrame.width * scaleFactor
            newFrame.size.height = newFrame.size.width / aspectRatio
            newFrame.origin.x = resizeStartFrame.maxX - newFrame.width
            newFrame.origin.y = resizeStartFrame.maxY - newFrame.height
        case .topRight:
            let diagonal = sqrt(delta.x * delta.x + delta.y * delta.y)
            let scaleFactor = 1.0 + (diagonal / 300.0) * (delta.x > 0 ? 1 : -1)
            newFrame.size.width = resizeStartFrame.width * scaleFactor
            newFrame.size.height = newFrame.size.width / aspectRatio
        case .topLeft:
            let diagonal = sqrt(delta.x * delta.x + delta.y * delta.y)
            let scaleFactor = 1.0 + (diagonal / 300.0) * (delta.x < 0 ? 1 : -1)
            newFrame.size.width = resizeStartFrame.width * scaleFactor
            newFrame.size.height = newFrame.size.width / aspectRatio
            newFrame.origin.x = resizeStartFrame.maxX - newFrame.width
        case .none:
            return
        }

        // 限制最小/最大尺寸
        newFrame.size.width = max(minSize.width, min(maxSize.width, newFrame.size.width))
        newFrame.size.height = newFrame.size.width / aspectRatio

        // 应用新frame（整体scale效果）
        window.setFrame(newFrame, display: true, animate: false)
    }

    func endResize() {
        isResizing = false
        resizeEdge = .none
    }
}

// MARK: - Resize Overlay View

class ResizeOverlayView: NSView {
    weak var handler: WindowResizeHandler?
    private var currentEdge: WindowResizeHandler.ResizeEdge = .none

    init(handler: WindowResizeHandler) {
        self.handler = handler
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // 移除旧的跟踪区域
        trackingAreas.forEach { removeTrackingArea($0) }

        // 添加新的跟踪区域
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let handler = handler else { return }

        let locationInView = convert(event.locationInWindow, from: nil)
        let edge = handler.detectEdge(at: locationInView, in: self)

        if edge != currentEdge {
            currentEdge = edge
            handler.cursor(for: edge).set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        currentEdge = .none
    }

    override func mouseDown(with event: NSEvent) {
        guard let handler = handler else { return }

        let locationInView = convert(event.locationInWindow, from: nil)
        let edge = handler.detectEdge(at: locationInView, in: self)

        if edge != .none {
            handler.startResize(at: event.locationInWindow, edge: edge)
        } else {
            // 不在边缘，传递给下一个响应者（允许窗口拖动）
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handler = handler else { return }
        handler.updateResize(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard let handler = handler else { return }
        handler.endResize()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 只在边缘区域拦截事件
        guard let handler = handler else { return nil }
        let edge = handler.detectEdge(at: point, in: self)
        return edge != .none ? self : nil
    }
}

// MARK: - NSCursor Extensions

extension NSCursor {
    static var resizeNorthwestSoutheast: NSCursor {
        return NSCursor(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Resize")!,
                       hotSpot: NSPoint(x: 8, y: 8))
    }

    static var resizeNortheastSouthwest: NSCursor {
        return NSCursor(image: NSImage(systemSymbolName: "arrow.up.right.and.arrow.down.left", accessibilityDescription: "Resize")!,
                       hotSpot: NSPoint(x: 8, y: 8))
    }
}
