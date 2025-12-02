import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "WindowResize")

/// 窗口缩放边缘枚举
public enum ResizeEdge {
    case none, right, bottom, bottomRight, left, top, bottomLeft, topRight, topLeft

    var cursor: NSCursor {
        switch self {
        case .right, .left:
            return NSCursor.resizeLeftRight
        case .top, .bottom:
            return NSCursor.resizeUpDown
        case .topLeft, .bottomRight:
            // 尝试获取对角线光标
            if let cursor = NSCursor.perform(NSSelectorFromString("_windowResizeNorthWestSouthEastCursor"))?.takeUnretainedValue() as? NSCursor {
                return cursor
            }
            return NSCursor.crosshair
        case .topRight, .bottomLeft:
            if let cursor = NSCursor.perform(NSSelectorFromString("_windowResizeNorthEastSouthWestCursor"))?.takeUnretainedValue() as? NSCursor {
                return cursor
            }
            return NSCursor.crosshair
        case .none:
            return NSCursor.arrow
        }
    }
}

/// 窗口缩放处理器 - 使用全局事件监视器实现边缘缩放
public class WindowResizeHandler: NSObject {
    private weak var window: NSWindow?
    private let edgeSize: CGFloat = 8.0
    private let aspectRatio: CGFloat = 300.0 / 380.0

    private var isResizing = false
    private var initialFrame: NSRect = .zero
    private var initialMouse: NSPoint = .zero
    private var resizeEdge: ResizeEdge = .none
    private var currentEdge: ResizeEdge = .none

    private var mouseMovedMonitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?

    public init(window: NSWindow) {
        self.window = window
        super.init()

        configureWindow()
        setupEventMonitors()

        fputs("[WindowResizeHandler] Initialized with global event monitors\n", stderr)
    }

    deinit {
        removeEventMonitors()
    }

    private func configureWindow() {
        guard let window = window else { return }
        window.minSize = NSSize(width: 200, height: 200 / aspectRatio)
        window.maxSize = NSSize(width: 600, height: 600 / aspectRatio)
    }

    private func setupEventMonitors() {
        // 监听鼠标移动来更新光标
        mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleMouseMoved(event)
            return event
        }

        // 监听鼠标按下
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            if let handled = self?.handleMouseDown(event), handled {
                return nil  // 消费事件
            }
            return event
        }

        // 监听鼠标拖动
        mouseDraggedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            if let handled = self?.handleMouseDragged(event), handled {
                return nil
            }
            return event
        }

        // 监听鼠标松开
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            if let handled = self?.handleMouseUp(event), handled {
                return nil
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let monitor = mouseMovedMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseDraggedMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Event Handlers

    private func handleMouseMoved(_ event: NSEvent) {
        guard let window = window, !isResizing else { return }

        let screenPoint = NSEvent.mouseLocation
        let windowFrame = window.frame

        // 检查鼠标是否在窗口附近
        let expandedFrame = windowFrame.insetBy(dx: -edgeSize, dy: -edgeSize)
        guard expandedFrame.contains(screenPoint) else {
            if currentEdge != .none {
                currentEdge = .none
                NSCursor.arrow.set()
            }
            return
        }

        let edge = detectEdge(screenPoint: screenPoint, windowFrame: windowFrame)

        if edge != currentEdge {
            currentEdge = edge
            edge.cursor.set()
        }
    }

    private func handleMouseDown(_ event: NSEvent) -> Bool {
        guard let window = window else { return false }

        let screenPoint = NSEvent.mouseLocation
        let windowFrame = window.frame
        let edge = detectEdge(screenPoint: screenPoint, windowFrame: windowFrame)

        guard edge != .none else { return false }

        // 开始缩放
        isResizing = true
        resizeEdge = edge
        initialMouse = screenPoint
        initialFrame = windowFrame

        // 临时禁用窗口拖动
        window.isMovableByWindowBackground = false

        fputs("[WindowResizeHandler] Started resize - edge: \(edge)\n", stderr)
        return true
    }

    private func handleMouseDragged(_ event: NSEvent) -> Bool {
        guard isResizing else { return false }
        performResize(currentMouse: NSEvent.mouseLocation)
        return true
    }

    private func handleMouseUp(_ event: NSEvent) -> Bool {
        guard isResizing else { return false }

        isResizing = false
        resizeEdge = .none
        window?.isMovableByWindowBackground = true

        fputs("[WindowResizeHandler] Completed resize\n", stderr)
        return true
    }

    // MARK: - Edge Detection

    private func detectEdge(screenPoint: NSPoint, windowFrame: NSRect) -> ResizeEdge {
        let nearLeft = screenPoint.x <= windowFrame.minX + edgeSize && screenPoint.x >= windowFrame.minX - edgeSize
        let nearRight = screenPoint.x >= windowFrame.maxX - edgeSize && screenPoint.x <= windowFrame.maxX + edgeSize
        let nearBottom = screenPoint.y <= windowFrame.minY + edgeSize && screenPoint.y >= windowFrame.minY - edgeSize
        let nearTop = screenPoint.y >= windowFrame.maxY - edgeSize && screenPoint.y <= windowFrame.maxY + edgeSize

        // 检查是否在窗口内部（允许边缘外一点点）
        let inWindowX = screenPoint.x >= windowFrame.minX - edgeSize && screenPoint.x <= windowFrame.maxX + edgeSize
        let inWindowY = screenPoint.y >= windowFrame.minY - edgeSize && screenPoint.y <= windowFrame.maxY + edgeSize

        guard inWindowX && inWindowY else { return .none }

        if nearBottom && nearRight { return .bottomRight }
        if nearBottom && nearLeft { return .bottomLeft }
        if nearTop && nearRight { return .topRight }
        if nearTop && nearLeft { return .topLeft }
        if nearRight { return .right }
        if nearLeft { return .left }
        if nearBottom { return .bottom }
        if nearTop { return .top }

        return .none
    }

    // MARK: - Resize Logic

    private func performResize(currentMouse: NSPoint) {
        guard let window = window else { return }

        let dx = currentMouse.x - initialMouse.x
        let dy = currentMouse.y - initialMouse.y

        var newWidth = initialFrame.width
        var newOriginX = initialFrame.origin.x
        var newOriginY = initialFrame.origin.y

        // 根据边缘计算新宽度
        switch resizeEdge {
        case .right, .topRight, .bottomRight:
            newWidth = initialFrame.width + dx
        case .left, .topLeft, .bottomLeft:
            newWidth = initialFrame.width - dx
        case .top:
            newWidth = initialFrame.width + (dy * aspectRatio)
        case .bottom:
            newWidth = initialFrame.width - (dy * aspectRatio)
        case .none:
            return
        }

        // 限制宽度范围
        newWidth = max(200, min(600, newWidth))
        let newHeight = newWidth / aspectRatio

        // 计算X坐标
        switch resizeEdge {
        case .left, .topLeft, .bottomLeft:
            newOriginX = initialFrame.maxX - newWidth
        default:
            newOriginX = initialFrame.origin.x
        }

        // 计算Y坐标 (macOS坐标系：原点在左下角)
        switch resizeEdge {
        case .top, .topRight, .topLeft:
            // 从顶部拖动，保持底部不变
            newOriginY = initialFrame.origin.y
        default:
            // 从底部拖动，保持顶部不变
            newOriginY = initialFrame.maxY - newHeight
        }

        let newFrame = NSRect(x: newOriginX, y: newOriginY, width: newWidth, height: newHeight)
        window.setFrame(newFrame, display: true, animate: false)
    }
}
