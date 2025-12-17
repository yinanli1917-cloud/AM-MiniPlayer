import AppKit
import SwiftUI

/// 带物理惯性的可吸附窗口面板 - 复刻 iOS PiP 体验
public class SnappablePanel: NSPanel {
    
    // MARK: - Configuration
    
    public var cornerMargin: CGFloat = 16
    public var projectionFactor: CGFloat = 0.12
    public var snapToCorners: Bool = true
    public var edgeHiddenVisibleWidth: CGFloat = 20
    
    // MARK: - Callbacks
    
    public var onDragStateChanged: ((Bool) -> Void)?
    public var onEdgeHiddenChanged: ((Bool) -> Void)?
    /// 获取当前页面状态（用于判断是否允许双指拖拽）
    public var currentPageProvider: (() -> PlayerPage)?
    
    // MARK: - Drag State
    
    private var dragStartLocation: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var isDragging = false
    
    // 速度追踪
    private var positionHistory: [(pos: NSPoint, time: CFTimeInterval)] = []
    private let historySize = 5
    
    // 动画状态
    private var isAnimating = false
    private var animationTarget: NSPoint = .zero
    private var animationTimer: Timer?
    
    // 弹簧动画参数
    private var springVelocityX: CGFloat = 0
    private var springVelocityY: CGFloat = 0
    
    // 贴边隐藏状态
    private(set) public var isEdgeHidden = false
    private var hiddenEdge: Edge = .none
    
    private enum Edge {
        case none, left, right
    }
    
    // MARK: - Init
    
    public override init(contentRect: NSRect,
                         styleMask style: NSWindow.StyleMask,
                         backing: NSWindow.BackingStoreType,
                         defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        self.isMovableByWindowBackground = false
    }
    
    deinit {
        animationTimer?.invalidate()
    }
    
    // MARK: - Stage Manager Detection
    
    private func isStageManagerEnabled() -> Bool {
        let defaults = UserDefaults(suiteName: "com.apple.WindowManager")
        return defaults?.bool(forKey: "GloballyEnabled") ?? false
    }
    
    // MARK: - Event Override
    
    public override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            handleMouseDown(event)
        case .leftMouseDragged:
            handleMouseDragged(event)
        case .leftMouseUp:
            handleMouseUp(event)
        // 双指拖拽支持（仅专辑页面）
        case .scrollWheel:
            // 🔑 非专辑页面：所有滚动事件直接传递给 ScrollView（包括惯性）
            if let provider = currentPageProvider, provider() != .album {
                super.sendEvent(event)
                return
            }
            
            // 专辑页面：用于窗口拖拽
            if event.phase == .began || event.phase == .changed {
                handleScrollDrag(event)
            } else if event.phase == .ended {
                handleScrollEnd(event)
            } else {
                // 惯性阶段等其他情况
                super.sendEvent(event)
            }
        default:
            super.sendEvent(event)
        }
    }
    
    // MARK: - Mouse Drag
    
    private func handleMouseDown(_ event: NSEvent) {
        // 🔑 检查是否点击在交互式视图或底部控件区域
        if let hitView = contentView?.hitTest(event.locationInWindow),
           isInteractiveView(hitView) {
            super.sendEvent(event)
            return
        }
        
        // 🔑 底部控件区域（进度条等）不触发窗口拖拽
        if isInBottomControlsArea(event: event) {
            super.sendEvent(event)
            return
        }
        
        if isEdgeHidden {
            restoreFromEdge()
            super.sendEvent(event)
            return
        }
        
        stopAllAnimations()
        // 🔑 拖拽开始时立即通知UI恢复非hover状态
        onDragStateChanged?(false)
        
        let mousePos = NSEvent.mouseLocation
        dragStartLocation = mousePos
        dragStartOrigin = frame.origin
        isDragging = true
        
        positionHistory.removeAll()
        positionHistory.append((pos: mousePos, time: CACurrentMediaTime()))
        
        super.sendEvent(event)
    }
    
    private func handleMouseDragged(_ event: NSEvent) {
        guard isDragging else {
            super.sendEvent(event)
            return
        }
        
        let mousePos = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        
        positionHistory.append((pos: mousePos, time: now))
        if positionHistory.count > historySize {
            positionHistory.removeFirst()
        }
        
        let dx = mousePos.x - dragStartLocation.x
        let dy = mousePos.y - dragStartLocation.y
        setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }
    
    private func handleMouseUp(_ event: NSEvent) {
        guard isDragging else {
            super.sendEvent(event)
            return
        }
        
        isDragging = false
        
        let mousePos = NSEvent.mouseLocation
        let distance = hypot(mousePos.x - dragStartLocation.x, mousePos.y - dragStartLocation.y)
        
        if distance < 3 {
            super.sendEvent(event)
            return
        }
        
        let velocity = calculateReleaseVelocity()
        
        if checkAndHideToEdgeWithVelocity(velocity) {
            super.sendEvent(event)
            return
        }
        
        if snapToCorners {
            animationTarget = calculateTargetCorner(velocity: velocity)
            springVelocityX = velocity.x * 0.3
            springVelocityY = velocity.y * 0.3
            startSpringAnimation()
        }
        
        super.sendEvent(event)
    }
    
    // MARK: - Scroll (双指) Drag
    
    private var scrollDragOrigin: NSPoint = .zero
    private var isScrollDragging = false
    private var scrollVelocityX: CGFloat = 0
    private var scrollVelocityY: CGFloat = 0
    
    private func handleScrollDrag(_ event: NSEvent) {
        // 检查是否是双指手势（触控板）
        guard abs(event.scrollingDeltaX) > 0 || abs(event.scrollingDeltaY) > 0 else {
            super.sendEvent(event)
            return
        }
        
        if !isScrollDragging {
            // 开始双指拖拽
            if isEdgeHidden {
                restoreFromEdge()
                return
            }
            
            stopAllAnimations()
            // 🔑 拖拽开始时立即通知UI恢复非hover状态
            onDragStateChanged?(false)
            
            scrollDragOrigin = frame.origin
            isScrollDragging = true
            positionHistory.removeAll()
        }
        
        // 移动窗口 - 直接使用 scrollingDelta
        let sensitivity: CGFloat = 1.5
        let newX = frame.origin.x + event.scrollingDeltaX * sensitivity
        let newY = frame.origin.y - event.scrollingDeltaY * sensitivity  // Y 轴反向
        setFrameOrigin(NSPoint(x: newX, y: newY))
        
        // 记录速度
        scrollVelocityX = event.scrollingDeltaX * sensitivity * 60  // 转换为 px/s
        scrollVelocityY = -event.scrollingDeltaY * sensitivity * 60
        
        let now = CACurrentMediaTime()
        positionHistory.append((pos: frame.origin, time: now))
        if positionHistory.count > historySize {
            positionHistory.removeFirst()
        }
    }
    
    private func handleScrollEnd(_ event: NSEvent) {
        guard isScrollDragging else { return }
        isScrollDragging = false
        
        let velocity = CGPoint(x: scrollVelocityX, y: scrollVelocityY)
        
        if checkAndHideToEdgeWithVelocity(velocity) {
            return
        }
        
        if snapToCorners {
            animationTarget = calculateTargetCorner(velocity: velocity)
            springVelocityX = velocity.x * 0.3
            springVelocityY = velocity.y * 0.3
            startSpringAnimation()
        }
    }
    
    // MARK: - Edge Hiding
    
    private func checkAndHideToEdgeWithVelocity(_ velocity: CGPoint) -> Bool {
        guard let screen = screen ?? NSScreen.main else { return false }
        let visible = screen.visibleFrame
        
        let threshold: CGFloat = 20
        let stageManagerOn = isStageManagerEnabled()
        
        let nearLeftEdge = frame.origin.x < visible.minX + threshold
        let nearRightEdge = frame.origin.x + frame.width > visible.maxX - threshold
        let horizontalDominant = abs(velocity.x) > abs(velocity.y) * 0.8
        
        if !stageManagerOn && nearLeftEdge && velocity.x < -50 && horizontalDominant {
            hideToEdge(.left)
            return true
        }
        
        if nearRightEdge && velocity.x > 50 && horizontalDominant {
            hideToEdge(.right)
            return true
        }
        
        return false
    }
    
    private func hideToEdge(_ edge: Edge) {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        
        hiddenEdge = edge
        
        let targetX: CGFloat = edge == .left
            ? visible.minX - frame.width + edgeHiddenVisibleWidth
            : visible.maxX - edgeHiddenVisibleWidth
        
        let isTop = frame.origin.y + frame.height / 2 > visible.midY
        let targetY = isTop ? visible.maxY - frame.height - cornerMargin : visible.minY + cornerMargin
        
        animationTarget = NSPoint(x: targetX, y: targetY)
        springVelocityX = 0
        springVelocityY = 0
        startSpringAnimation()
        
        isEdgeHidden = true
        onEdgeHiddenChanged?(true)
    }
    
    private func restoreFromEdge() {
        guard isEdgeHidden, let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        
        let isTop = frame.origin.y + frame.height / 2 > visible.midY
        let wasLeft = hiddenEdge == .left
        
        let targetX = wasLeft ? visible.minX + cornerMargin : visible.maxX - frame.width - cornerMargin
        let targetY = isTop ? visible.maxY - frame.height - cornerMargin : visible.minY + cornerMargin
        
        animationTarget = NSPoint(x: targetX, y: targetY)
        springVelocityX = 0
        springVelocityY = 0
        startSpringAnimation()
        
        isEdgeHidden = false
        hiddenEdge = .none
        onEdgeHiddenChanged?(false)
    }
    
    // MARK: - Spring Animation
    
    private func stopAllAnimations() {
        isAnimating = false
        animationTimer?.invalidate()
        animationTimer = nil
    }
    
    private func startSpringAnimation() {
        stopAllAnimations()
        isAnimating = true
        
        // 使用高频 Timer (120Hz) 实现流畅动画
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { [weak self] _ in
            self?.updateSpringAnimation()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }
    
    private func updateSpringAnimation() {
        guard isAnimating else { return }
        
        let current = frame.origin
        let target = animationTarget
        
        // 弹簧参数 - 调快速度
        // stiffness: 刚度，越大越快
        // damping: 阻尼，越大回弹越小
        let stiffness: CGFloat = 280    // 从 120 提高到 280，更快
        let damping: CGFloat = 24       // 减少回弹，更干脆
        let mass: CGFloat = 1.0
        let dt: CGFloat = 1.0 / 120.0
        
        let dx = target.x - current.x
        let dy = target.y - current.y
        
        let forceX = stiffness * dx - damping * springVelocityX
        let forceY = stiffness * dy - damping * springVelocityY
        
        springVelocityX += (forceX / mass) * dt
        springVelocityY += (forceY / mass) * dt
        
        let newX = current.x + springVelocityX * dt
        let newY = current.y + springVelocityY * dt
        
        setFrameOrigin(NSPoint(x: newX, y: newY))
        
        let distance = hypot(dx, dy)
        let speed = hypot(springVelocityX, springVelocityY)
        
        if distance < 0.3 && speed < 2 {
            setFrameOrigin(target)
            isAnimating = false
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }
    
    // MARK: - Velocity Calculation
    
    private func calculateReleaseVelocity() -> CGPoint {
        guard positionHistory.count >= 2 else { return .zero }
        
        let recent = positionHistory.suffix(3)
        guard recent.count >= 2 else { return .zero }
        
        let samples = Array(recent)
        let p1 = samples.first!
        let p2 = samples.last!
        
        let dt = p2.time - p1.time
        guard dt > 0.001 else { return .zero }
        
        return CGPoint(
            x: (p2.pos.x - p1.pos.x) / CGFloat(dt),
            y: (p2.pos.y - p1.pos.y) / CGFloat(dt)
        )
    }
    
    // MARK: - Corner Calculation
    
    private func calculateTargetCorner(velocity: CGPoint) -> NSPoint {
        guard let screen = screen ?? NSScreen.main else { return frame.origin }
        let visible = screen.visibleFrame
        
        let projectedX = frame.origin.x + velocity.x * projectionFactor
        let projectedY = frame.origin.y + velocity.y * projectionFactor
        
        let centerX = projectedX + frame.width / 2
        let centerY = projectedY + frame.height / 2
        
        let isRight = centerX > visible.midX
        let isTop = centerY > visible.midY
        
        let margin = cornerMargin
        
        if isTop && isRight {
            return NSPoint(x: visible.maxX - frame.width - margin, y: visible.maxY - frame.height - margin)
        } else if isTop {
            return NSPoint(x: visible.minX + margin, y: visible.maxY - frame.height - margin)
        } else if isRight {
            return NSPoint(x: visible.maxX - frame.width - margin, y: visible.minY + margin)
        } else {
            return NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        }
    }
    
    // MARK: - Interactive View Check
    
    private func isInteractiveView(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let current = v {
            if current.identifier?.rawValue == "non-draggable" { return true }
            if current is NSButton || current is NSSlider { return true }
            v = current.superview
        }
        return false
    }
    
    /// 检查点击位置是否在底部控件区域（进度条等）
    private func isInBottomControlsArea(event: NSEvent) -> Bool {
        let locationInWindow = event.locationInWindow
        // 底部 100px 是控件区域，不应该触发窗口拖拽
        // 注意：窗口坐标系原点在左下角
        return locationInWindow.y < 100
    }
    
    // MARK: - Public API
    
    public func snapToNearestCorner() {
        animationTarget = calculateTargetCorner(velocity: .zero)
        springVelocityX = 0
        springVelocityY = 0
        startSpringAnimation()
    }
    
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

public enum ScreenCorner {
    case topLeft, topRight, bottomLeft, bottomRight
}
