import AppKit
import SwiftUI

/// 窗口缩放处理器 - 实现整体scale缩放（不是resize）
public class WindowResizeHandler {
    private weak var window: NSWindow?
    private var isResizing = false
    private var resizeStartPoint: NSPoint = .zero
    private var resizeStartFrame: NSRect = .zero
    private var resizeEdge: ResizeEdge = .none
    private var currentEdge: ResizeEdge = .none
    private var eventMonitor: Any?

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
        setupEventMonitor()
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupTracking() {
        guard let window = window, let contentView = window.contentView else { return }

        // 创建wrapper view来包含原内容
        let wrapperView = NSView(frame: contentView.bounds)
        wrapperView.autoresizingMask = [.width, .height]
        wrapperView.wantsLayer = true

        // 移动原有内容到wrapper
        let existingSubviews = contentView.subviews
        for subview in existingSubviews {
            subview.removeFromSuperview()
            wrapperView.addSubview(subview)
        }

        // 添加wrapper
        contentView.addSubview(wrapperView)
    }

    private func setupEventMonitor() {
        // 监听本地鼠标事件
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self, let window = self.window else { return event }

            // 只处理我们窗口的事件
            guard event.window == window else { return event }

            switch event.type {
            case .mouseMoved:
                self.handleMouseMoved(event)
                return event

            case .leftMouseDown:
                return self.handleMouseDown(event)

            case .leftMouseDragged:
                self.handleMouseDragged(event)
                return nil // 拖拽时消费事件

            case .leftMouseUp:
                self.handleMouseUp(event)
                return event

            default:
                return event
            }
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        guard let window = window, let contentView = window.contentView else { return }

        let locationInWindow = event.locationInWindow
        let locationInView = contentView.convert(locationInWindow, from: nil)
        let edge = detectEdge(at: locationInView, in: contentView)

        if edge != currentEdge {
            currentEdge = edge
            cursor(for: edge).set()
        }
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window = window, let contentView = window.contentView else { return event }

        let locationInWindow = event.locationInWindow
        let locationInView = contentView.convert(locationInWindow, from: nil)
        let edge = detectEdge(at: locationInView, in: contentView)

        if edge != .none {
            startResize(at: locationInWindow, edge: edge)
            return nil // 消费事件
        }

        return event // 传递事件
    }

    private func handleMouseDragged(_ event: NSEvent) {
        if isResizing {
            updateResize(to: NSEvent.mouseLocation)
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        if isResizing {
            endResize()
        }
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
