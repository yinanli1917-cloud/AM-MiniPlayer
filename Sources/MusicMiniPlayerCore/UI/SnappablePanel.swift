import AppKit
import SwiftUI

/// 带物理惯性的可吸附窗口面板 - 复刻 iOS PiP 体验
public class SnappablePanel: NSPanel {
    
    // MARK: - Configuration

    public var cornerMargin: CGFloat = 16
    public var projectionFactor: CGFloat = 0.12
    public var snapToCorners: Bool = true
    public var edgeHiddenVisibleWidth: CGFloat = 6  // 🔑 贴边隐藏时露出的宽度

    // MARK: - Callbacks

    public var onDragStateChanged: ((Bool) -> Void)?
    public var onEdgeHiddenChanged: ((Bool) -> Void)?
    /// 获取当前页面状态（用于判断是否允许双指拖拽）
    public var currentPageProvider: (() -> PlayerPage)?
    /// 🔑 获取当前是否处于手动滚动状态（歌词页面）
    public var isManualScrollingProvider: (() -> Bool)?
    /// 🔑 触发进入手动滚动状态（歌词页面）
    public var onTriggerManualScroll: (() -> Void)?
    
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
    private(set) public var hiddenEdge: Edge = .none

    public enum Edge {
        case none, left, right
    }
    
    // MARK: - Init
    
    public override init(contentRect: NSRect,
                         styleMask style: NSWindow.StyleMask,
                         backing: NSWindow.BackingStoreType,
                         defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        self.isMovableByWindowBackground = false
        self.acceptsMouseMovedEvents = true
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
        // 🔑 鼠标移动 - 用于贴边隐藏的 hover 效果
        case .mouseMoved:
            handleMouseMoved(event)
        // 双指拖拽支持
        case .scrollWheel:
            if let provider = currentPageProvider {
                let currentPage = provider()

                if currentPage == .album {
                    // 🔑 专辑页面：双指触控板手势用于贴边/隐藏（全方向）
                    if event.phase == .began || event.phase == .changed {
                        handleScrollDrag(event)
                    } else if event.phase == .ended {
                        handleScrollEnd(event)
                    } else {
                        super.sendEvent(event)
                    }
                } else {
                    // 🔑 歌词/歌单页面：横向手势用于隐藏，纵向手势传递给 ScrollView
                    // 🔑 两次滑动逻辑：自然滚动时第一次横滑进入手动滚动，第二次才隐藏
                    if event.phase == .began {
                        // 重置标志
                        justTriggeredManualScroll = false
                        // 开始时判断是否为横向主导手势
                        let isHorizontalDominant = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5
                        if isHorizontalDominant {
                            // 🔑 检查是否已经在手动滚动状态
                            let isManualScrolling = isManualScrollingProvider?() ?? false
                            if isManualScrolling {
                                // 已在手动滚动状态，这次横滑可以隐藏
                                isHorizontalScrollGesture = true
                                horizontalScrollAccumulated = 0
                                handleHorizontalHideGesture(event)
                            } else {
                                // 不在手动滚动状态，第一次横滑只触发进入手动滚动
                                onTriggerManualScroll?()
                                justTriggeredManualScroll = true  // 🔑 标记本次手势已触发手动滚动
                                isHorizontalScrollGesture = false
                                horizontalScrollAccumulated = 0
                                super.sendEvent(event)
                            }
                        } else {
                            isHorizontalScrollGesture = false
                            horizontalScrollAccumulated = 0
                            super.sendEvent(event)
                        }
                    } else if event.phase == .changed {
                        if isHorizontalScrollGesture {
                            handleHorizontalHideGesture(event)
                        } else if !justTriggeredManualScroll {
                            // 🔑 只有在本次手势周期内没有触发过手动滚动时，才检查是否切换
                            // 累积横向滚动量，如果超过阈值且已在手动滚动状态则切换为横向手势
                            horizontalScrollAccumulated += event.scrollingDeltaX
                            let isManualScrolling = isManualScrollingProvider?() ?? false
                            let shouldSwitchToHorizontal = isManualScrolling &&
                                abs(horizontalScrollAccumulated) > 30 &&
                                abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 2
                            if shouldSwitchToHorizontal {
                                isHorizontalScrollGesture = true
                                handleHorizontalHideGesture(event)
                            } else {
                                super.sendEvent(event)
                            }
                        } else {
                            // 本次手势已触发手动滚动，继续传递事件
                            super.sendEvent(event)
                        }
                    } else if event.phase == .ended {
                        if isHorizontalScrollGesture {
                            handleHorizontalHideGestureEnd(event)
                            isHorizontalScrollGesture = false
                        } else {
                            super.sendEvent(event)
                        }
                        horizontalScrollAccumulated = 0
                        justTriggeredManualScroll = false  // 🔑 手势结束，重置标志
                    } else {
                        super.sendEvent(event)
                    }
                }
            } else {
                super.sendEvent(event)
            }
        default:
            super.sendEvent(event)
        }
    }
    
    // MARK: - Mouse Drag
    
    private func handleMouseDown(_ event: NSEvent) {
        // 🔑 如果窗口处于贴边隐藏状态，点击恢复窗口，不穿透到内容
        if isEdgeHidden {
            restoreFromEdge()
            // 不调用 super.sendEvent(event)，阻止这次点击穿透
            return
        }

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

        // 🔑 所有页面：鼠标拖拽只移动窗口，不触发贴角/贴边
        // 贴边/隐藏由双指触控板手势处理
        super.sendEvent(event)
    }
    
    // MARK: - Scroll (双指) Drag

    private var scrollDragOrigin: NSPoint = .zero
    private var isScrollDragging = false
    private var scrollVelocityX: CGFloat = 0
    private var scrollVelocityY: CGFloat = 0

    // 🔑 横向隐藏手势状态（歌词/歌单页面）
    private var isHorizontalScrollGesture = false
    private var horizontalScrollAccumulated: CGFloat = 0
    private var justTriggeredManualScroll = false  // 🔑 防止同一手势周期内触发隐藏
    
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

    // MARK: - Horizontal Hide Gesture (歌词/歌单页面横向隐藏)

    private func handleHorizontalHideGesture(_ event: NSEvent) {
        let sensitivity: CGFloat = 1.5
        horizontalScrollAccumulated += event.scrollingDeltaX * sensitivity
        scrollVelocityX = event.scrollingDeltaX * sensitivity * 60  // 转换为 px/s

        // 🔑 实时移动窗口（仅水平方向）
        let newX = frame.origin.x + event.scrollingDeltaX * sensitivity
        setFrameOrigin(NSPoint(x: newX, y: frame.origin.y))
    }

    private func handleHorizontalHideGestureEnd(_ event: NSEvent) {
        let velocity = CGPoint(x: scrollVelocityX, y: 0)

        // 🔑 检查是否满足隐藏条件
        if checkAndHideToEdgeWithVelocity(velocity) {
            horizontalScrollAccumulated = 0
            return
        }

        // 🔑 没有隐藏，回弹到最近的角落
        if snapToCorners {
            animationTarget = calculateTargetCorner(velocity: velocity)
            springVelocityX = velocity.x * 0.3
            springVelocityY = 0
            startSpringAnimation()
        }

        horizontalScrollAccumulated = 0
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

        // 🔑 贴边隐藏，露出 edgeHiddenVisibleWidth
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
        isEdgePeeking = false
        onEdgeHiddenChanged?(false)
    }

    // MARK: - Edge Peek (hover 时偷看效果)

    private var isEdgePeeking = false
    private let peekAmount: CGFloat = 30  // hover 时露出的额外宽度

    // 🔑 peek 动画参数（更快更干脆）
    private let peekStiffness: CGFloat = 500
    private let peekDamping: CGFloat = 30

    private func handleMouseMoved(_ event: NSEvent) {
        // 只在贴边隐藏状态下处理
        guard isEdgeHidden else {
            super.sendEvent(event)
            return
        }

        let mouseInWindow = frame.contains(NSEvent.mouseLocation)

        if mouseInWindow && !isEdgePeeking {
            // 鼠标进入，开始偷看
            isEdgePeeking = true
            peekFromEdge()
        } else if !mouseInWindow && isEdgePeeking {
            // 鼠标离开，结束偷看
            isEdgePeeking = false
            hideBackToEdge()
        }

        super.sendEvent(event)
    }

    /// 偷看：稍微露出窗口
    private func peekFromEdge() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        let targetX: CGFloat = hiddenEdge == .left
            ? visible.minX - frame.width + edgeHiddenVisibleWidth + peekAmount
            : visible.maxX - edgeHiddenVisibleWidth - peekAmount

        animationTarget = NSPoint(x: targetX, y: frame.origin.y)
        springVelocityX = 0
        springVelocityY = 0
        startPeekAnimation()  // 🔑 使用更快的 peek 动画
    }

    /// 回到贴边隐藏状态
    private func hideBackToEdge() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        let targetX: CGFloat = hiddenEdge == .left
            ? visible.minX - frame.width + edgeHiddenVisibleWidth
            : visible.maxX - edgeHiddenVisibleWidth

        animationTarget = NSPoint(x: targetX, y: frame.origin.y)
        springVelocityX = 0
        springVelocityY = 0
        startPeekAnimation()  // 🔑 使用更快的 peek 动画
    }

    // 🔑 专门用于 peek 的快速动画
    private func startPeekAnimation() {
        stopAllAnimations()
        isAnimating = true

        // 🔑 60fps（从 120fps 降低，减少 CPU 占用）
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.updatePeekAnimation()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    private func updatePeekAnimation() {
        guard isAnimating else { return }

        let current = frame.origin
        let target = animationTarget

        let dt: CGFloat = 1.0 / 60.0  // 🔑 60fps

        let dx = target.x - current.x
        let dy = target.y - current.y

        let forceX = peekStiffness * dx - peekDamping * springVelocityX
        let forceY = peekStiffness * dy - peekDamping * springVelocityY

        springVelocityX += forceX * dt
        springVelocityY += forceY * dt

        let newX = current.x + springVelocityX * dt
        let newY = current.y + springVelocityY * dt

        setFrameOrigin(NSPoint(x: newX, y: newY))

        let distance = hypot(dx, dy)
        let speed = hypot(springVelocityX, springVelocityY)

        // 🔑 提高收敛阈值，更快结束动画
        if distance < 0.5 && speed < 5 {
            setFrameOrigin(target)
            isAnimating = false
            animationTimer?.invalidate()
            animationTimer = nil
        }
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

        // 🔑 60fps（从 120fps 降低，减少 CPU 占用）
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.updateSpringAnimation()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    private func updateSpringAnimation() {
        guard isAnimating else { return }

        let current = frame.origin
        let target = animationTarget

        let stiffness: CGFloat = 280
        let damping: CGFloat = 24
        let mass: CGFloat = 1.0
        let dt: CGFloat = 1.0 / 60.0  // 🔑 60fps

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

        // 🔑 提高收敛阈值，更快结束动画
        if distance < 0.5 && speed < 5 {
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
