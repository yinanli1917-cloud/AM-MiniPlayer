import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "WindowResize")

/// 窗口缩放边缘枚举
public enum ResizeEdge {
    case none, right, bottom, bottomRight, left, top, bottomLeft, topRight, topLeft
}

/// 可缩放的透明 NSView - 放置在窗口内容上层捕获边缘拖动
/// 使用 NSView.mouseDown + NSWindow.nextEvent 事件循环实现可靠的窗口缩放
public class ResizableEdgeView: NSView {
    private weak var targetWindow: NSWindow?
    private let edgeSize: CGFloat = 12.0
    private let aspectRatio: CGFloat = 300.0 / 380.0

    private var isResizing = false
    private var initialFrame: NSRect = .zero
    private var initialMouse: NSPoint = .zero
    private var resizeEdge: ResizeEdge = .none

    public init(window: NSWindow) {
        self.targetWindow = window
        super.init(frame: .zero)
        setupTrackingArea()
        fputs("[ResizableEdgeView] Initialized for window resize\n", stderr)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        setupTrackingArea()
    }

    // MARK: - Hit Testing

    /// 只有在边缘区域时才接收点击，否则让事件穿透到下层 SwiftUI 内容
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let edge = detectEdge(at: point)
        if edge != .none {
            return self
        }
        return nil  // 让事件穿透
    }

    // MARK: - Mouse Events

    public override func mouseMoved(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let edge = detectEdge(at: localPoint)
        updateCursor(for: edge)
    }

    public override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    public override func mouseDown(with event: NSEvent) {
        guard let window = targetWindow else { return }

        let localPoint = convert(event.locationInWindow, from: nil)
        let edge = detectEdge(at: localPoint)

        guard edge != .none else { return }

        // 开始缩放
        isResizing = true
        resizeEdge = edge
        initialMouse = NSEvent.mouseLocation
        initialFrame = window.frame

        // 临时禁用窗口拖动
        window.isMovableByWindowBackground = false

        fputs("[ResizableEdgeView] Started resize - edge: \(edge)\n", stderr)

        // 🔑 关键：使用事件循环进行连续鼠标追踪
        var trackingEvent: NSEvent? = event

        while isResizing {
            // 获取下一个鼠标事件
            trackingEvent = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date.distantFuture,
                inMode: .eventTracking,
                dequeue: true
            )

            guard let currentEvent = trackingEvent else { break }

            switch currentEvent.type {
            case .leftMouseDragged:
                performResize(currentMouse: NSEvent.mouseLocation)

            case .leftMouseUp:
                isResizing = false
                window.isMovableByWindowBackground = true
                NSCursor.arrow.set()
                fputs("[ResizableEdgeView] Completed resize\n", stderr)

            default:
                break
            }
        }
    }

    // MARK: - Edge Detection

    private func detectEdge(at point: NSPoint) -> ResizeEdge {
        let viewBounds = bounds

        let nearLeft = point.x <= edgeSize
        let nearRight = point.x >= viewBounds.width - edgeSize
        let nearBottom = point.y <= edgeSize
        let nearTop = point.y >= viewBounds.height - edgeSize

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

    // MARK: - Cursor Updates

    private func updateCursor(for edge: ResizeEdge) {
        switch edge {
        case .right, .left:
            NSCursor.resizeLeftRight.set()
        case .top, .bottom:
            NSCursor.resizeUpDown.set()
        case .topLeft, .bottomRight:
            // 使用私有API获取对角线光标
            if let cursor = NSCursor.perform(NSSelectorFromString("_windowResizeNorthWestSouthEastCursor"))?.takeUnretainedValue() as? NSCursor {
                cursor.set()
            } else {
                NSCursor.crosshair.set()
            }
        case .topRight, .bottomLeft:
            if let cursor = NSCursor.perform(NSSelectorFromString("_windowResizeNorthEastSouthWestCursor"))?.takeUnretainedValue() as? NSCursor {
                cursor.set()
            } else {
                NSCursor.crosshair.set()
            }
        case .none:
            NSCursor.arrow.set()
        }
    }

    // MARK: - Resize Logic

    private func performResize(currentMouse: NSPoint) {
        guard let window = targetWindow else { return }

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

/// 窗口缩放处理器 - 管理 ResizableEdgeView 的生命周期
public class WindowResizeHandler: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private var resizeView: ResizableEdgeView?
    private let aspectRatio: CGFloat = 300.0 / 380.0

    public init(window: NSWindow) {
        self.window = window
        super.init()

        configureWindow()
        setupResizeView()

        fputs("[WindowResizeHandler] Initialized with ResizableEdgeView\n", stderr)
    }

    private func configureWindow() {
        guard let window = window else { return }
        window.minSize = NSSize(width: 200, height: 200 / aspectRatio)
        window.maxSize = NSSize(width: 600, height: 600 / aspectRatio)
        window.delegate = self
    }

    private func setupResizeView() {
        guard let window = window, let contentView = window.contentView else { return }

        // 创建透明的边缘检测视图
        let resizeView = ResizableEdgeView(window: window)
        resizeView.translatesAutoresizingMaskIntoConstraints = false
        resizeView.wantsLayer = true
        resizeView.layer?.backgroundColor = NSColor.clear.cgColor

        // 添加到内容视图的最上层
        contentView.addSubview(resizeView, positioned: .above, relativeTo: nil)

        // 约束让它覆盖整个窗口
        NSLayoutConstraint.activate([
            resizeView.topAnchor.constraint(equalTo: contentView.topAnchor),
            resizeView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            resizeView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            resizeView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])

        self.resizeView = resizeView
    }

    // MARK: - NSWindowDelegate

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // 保持宽高比
        let newWidth = frameSize.width
        let newHeight = newWidth / aspectRatio
        return NSSize(width: newWidth, height: newHeight)
    }
}
