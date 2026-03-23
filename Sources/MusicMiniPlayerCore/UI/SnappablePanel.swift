import AppKit
import SwiftUI
import QuartzCore

/// 带物理惯性的可吸附窗口面板 - 复刻 iOS PiP 体验
public class SnappablePanel: NSPanel {

    // MARK: - Configuration

    public var cornerMargin: CGFloat = 16
    public var projectionFactor: CGFloat = 0.28
    public var snapToCorners: Bool = true
    public var edgeHiddenVisibleWidth: CGFloat = 6  // 贴边隐藏时露出的宽度

    // MARK: - Callbacks

    public var onDragStateChanged: ((Bool) -> Void)?
    public var onEdgeHiddenChanged: ((Bool) -> Void)?
    /// 获取当前页面状态（用于判断是否允许双指拖拽）
    public var currentPageProvider: (() -> PlayerPage)?
    /// 获取当前是否处于手动滚动状态（歌词页面）
    public var isManualScrollingProvider: (() -> Bool)?
    /// 触发进入手动滚动状态（歌词页面）
    public var onTriggerManualScroll: (() -> Void)?

    // MARK: - Drag State

    private var dragStartLocation: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var isDragging = false

    // 速度追踪
    private var positionHistory: [(pos: NSPoint, time: CFTimeInterval)] = []
    private let historySize = 5

    // ── 动画状态 ──
    private var isAnimating = false
    private var animationTarget: NSPoint = .zero

    // 弹簧速度（调用方设置初始速度）
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
        stopAllAnimations()
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
        case .mouseMoved:
            handleMouseMoved(event)
        case .scrollWheel:
            if let provider = currentPageProvider {
                let currentPage = provider()

                if currentPage == .album {
                    // ── 专辑页面：双指触控板手势用于贴边/隐藏（全方向）──
                    if event.phase == .began || event.phase == .changed {
                        handleScrollDrag(event)
                    } else if event.phase == .ended {
                        handleScrollEnd(event)
                    } else {
                        super.sendEvent(event)
                    }
                } else {
                    // ── 歌词/歌单页面：横向 = 贴边隐藏，纵向 = 传递给内容 ──
                    // 无需二次滑动，横向手势直接生效

                    // 抑制横向手势的残余动量（防止泄漏给 ScrollDetector 引发抽搐）
                    if event.momentumPhase != [] {
                        if suppressMomentum {
                            if event.momentumPhase == .ended { suppressMomentum = false }
                            return  // 吞掉
                        }
                        super.sendEvent(event)
                        return
                    }

                    if event.phase == .began {
                        scrollGestureDirection = .undecided
                        horizontalGestureStartOrigin = frame.origin
                        scrollVelocityX = 0
                        suppressMomentum = false
                        super.sendEvent(event)
                    } else if event.phase == .changed {
                        // 首次有效 delta 确定方向，一旦确定不再切换
                        if scrollGestureDirection == .undecided {
                            let absX = abs(event.scrollingDeltaX)
                            let absY = abs(event.scrollingDeltaY)
                            if absX > absY * 1.2 && absX > 2.0 {
                                scrollGestureDirection = .horizontal
                            } else if absY > 1.0 {
                                scrollGestureDirection = .vertical
                                horizontalGestureStartOrigin = nil
                            }
                        }
                        if scrollGestureDirection == .horizontal {
                            handleHorizontalHideGesture(event)
                        } else {
                            super.sendEvent(event)
                        }
                    } else if event.phase == .ended {
                        if scrollGestureDirection == .horizontal {
                            handleHorizontalHideGestureEnd(event)
                            suppressMomentum = true
                        } else {
                            super.sendEvent(event)
                        }
                        scrollGestureDirection = .undecided
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
        if isEdgeHidden {
            restoreFromEdge()
            return
        }

        if let hitView = contentView?.hitTest(event.locationInWindow),
           isInteractiveView(hitView) {
            super.sendEvent(event)
            return
        }

        if isInBottomControlsArea(event: event) {
            super.sendEvent(event)
            return
        }

        stopAllAnimations()
        onDragStateChanged?(false)

        let mousePos = NSEvent.mouseLocation
        dragStartLocation = mousePos
        dragStartOrigin = frame.origin
        isDragging = true
        NotificationCenter.default.post(name: .windowMovementBegan, object: self)

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
        NotificationCenter.default.post(name: .windowMovementEnded, object: self)

        let mousePos = NSEvent.mouseLocation
        let distance = hypot(mousePos.x - dragStartLocation.x, mousePos.y - dragStartLocation.y)

        if distance < 3 {
            super.sendEvent(event)
            return
        }

        // 鼠标拖拽只移动窗口，贴边/隐藏由双指触控板手势处理
        super.sendEvent(event)
    }

    // MARK: - Scroll (双指) Drag

    private var scrollDragOrigin: NSPoint = .zero
    private var isScrollDragging = false
    private var scrollVelocityX: CGFloat = 0
    private var scrollVelocityY: CGFloat = 0

    // ── 横向隐藏手势状态（歌词/歌单页面）──
    private enum GestureDirection { case undecided, horizontal, vertical }
    private var scrollGestureDirection: GestureDirection = .undecided
    private var horizontalGestureStartOrigin: NSPoint? = nil  // 手势前位置（取消时弹回）
    private var suppressMomentum = false

    private func handleScrollDrag(_ event: NSEvent) {
        guard abs(event.scrollingDeltaX) > 0 || abs(event.scrollingDeltaY) > 0 else {
            super.sendEvent(event)
            return
        }

        if !isScrollDragging {
            if isEdgeHidden {
                restoreFromEdge()
                return
            }

            stopAllAnimations()
            onDragStateChanged?(false)

            scrollDragOrigin = frame.origin
            isScrollDragging = true
            NotificationCenter.default.post(name: .windowMovementBegan, object: self)
            positionHistory.removeAll()
        }

        let sensitivity: CGFloat = 1.5
        let newX = frame.origin.x + event.scrollingDeltaX * sensitivity
        let newY = frame.origin.y - event.scrollingDeltaY * sensitivity
        setFrameOrigin(NSPoint(x: newX, y: newY))

        scrollVelocityX = event.scrollingDeltaX * sensitivity * 60
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

        // 解析解无 Euler 能量增益，传入完整速度
        springVelocityX = velocity.x
        springVelocityY = velocity.y

        if checkAndHideToEdgeWithVelocity(velocity) {
            return
        }

        if snapToCorners {
            animationTarget = calculateTargetCorner(velocity: velocity)
            startSpringAnimation()
        }
    }

    // MARK: - Horizontal Hide Gesture (歌词/歌单页面横向隐藏)

    private func handleHorizontalHideGesture(_ event: NSEvent) {
        let sensitivity: CGFloat = 1.5
        scrollVelocityX = event.scrollingDeltaX * sensitivity * 60  // px/s
        let newX = frame.origin.x + event.scrollingDeltaX * sensitivity
        setFrameOrigin(NSPoint(x: newX, y: frame.origin.y))
    }

    private func handleHorizontalHideGestureEnd(_ event: NSEvent) {
        let velocity = CGPoint(x: scrollVelocityX, y: 0)

        // 解析解无 Euler 能量增益，传入完整速度
        springVelocityX = velocity.x
        springVelocityY = 0

        if checkAndHideToEdgeWithVelocity(velocity) {
            horizontalGestureStartOrigin = nil
            return
        }

        // 没有隐藏 → 弹回手势开始前的位置
        if let origin = horizontalGestureStartOrigin {
            animationTarget = origin
            startSpringAnimation()
        }
        horizontalGestureStartOrigin = nil
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
        // 清零速度：贴边距离近，高速度只会制造过冲 + 更多重窗口帧
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
    private let peekAmount: CGFloat = 30

    private func handleMouseMoved(_ event: NSEvent) {
        guard isEdgeHidden else {
            super.sendEvent(event)
            return
        }

        let mouseInWindow = frame.contains(NSEvent.mouseLocation)

        if mouseInWindow && !isEdgePeeking {
            isEdgePeeking = true
            peekFromEdge()
        } else if !mouseInWindow && isEdgePeeking {
            isEdgePeeking = false
            hideBackToEdge()
        }

        super.sendEvent(event)
    }

    private func peekFromEdge() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        let targetX: CGFloat = hiddenEdge == .left
            ? visible.minX - frame.width + edgeHiddenVisibleWidth + peekAmount
            : visible.maxX - edgeHiddenVisibleWidth - peekAmount

        animationTarget = NSPoint(x: targetX, y: frame.origin.y)
        springVelocityX = 0
        springVelocityY = 0
        startPeekAnimation()
    }

    private func hideBackToEdge() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        let targetX: CGFloat = hiddenEdge == .left
            ? visible.minX - frame.width + edgeHiddenVisibleWidth
            : visible.maxX - edgeHiddenVisibleWidth

        animationTarget = NSPoint(x: targetX, y: frame.origin.y)
        springVelocityX = 0
        springVelocityY = 0
        startPeekAnimation()
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 弹簧动画（SwiftUI.Spring 解析解 + DisplayLink）
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // 🔑 直接移动真实窗口：用户要看到 hover 动画随窗口飞的灵动感
    // 🔑 SwiftUI.Spring 解析解：闭式解无数值噪声，WWDC23 参数
    // 🔑 性能：暂停 interpolation timer + 关阴影 + disableScreenUpdatesUntilFlush

    private var shadowWasEnabled = true
    private var currentSpring = Spring(duration: 0.5, bounce: 0.15)
    private var animStartTime: CFTimeInterval = 0
    private var animInitialOrigin: NSPoint = .zero
    private var animInitVelX: CGFloat = 0
    private var animInitVelY: CGFloat = 0
    private var displayLink: AnyObject?
    private var animationTimer: Timer?

    private func startSpringAnimation() {
        // WWDC23 手势吸附推荐：duration=0.5 bounce=0.15
        currentSpring = Spring(duration: 0.5, bounce: 0.15)
        launchAnimation()
    }

    private func startPeekAnimation() {
        currentSpring = Spring(duration: 0.3, bounce: 0.0)
        launchAnimation()
    }

    private func launchAnimation() {
        stopAllAnimations()
        isAnimating = true

        animStartTime = CACurrentMediaTime()
        animInitialOrigin = frame.origin
        animInitVelX = springVelocityX
        animInitVelY = springVelocityY

        shadowWasEnabled = hasShadow
        if hasShadow { hasShadow = false }

        NotificationCenter.default.post(name: .windowMovementBegan, object: self)

        if #available(macOS 14.0, *) {
            let link = self.displayLink(
                target: self,
                selector: #selector(displayLinkFired(_:))
            )
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60, maximum: 120, preferred: 120
            )
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            animationTimer = Timer.scheduledTimer(
                withTimeInterval: 1.0 / 60.0, repeats: true
            ) { [weak self] _ in self?.renderFrame() }
            RunLoop.main.add(animationTimer!, forMode: .common)
        }
    }

    @available(macOS 14.0, *)
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        renderFrame()
    }

    private func renderFrame() {
        guard isAnimating else { return }

        let t = CACurrentMediaTime() - animStartTime
        let targetDx = animationTarget.x - animInitialOrigin.x
        let targetDy = animationTarget.y - animInitialOrigin.y

        let x = animInitialOrigin.x + currentSpring.value(
            target: targetDx, initialVelocity: animInitVelX, time: t
        )
        let y = animInitialOrigin.y + currentSpring.value(
            target: targetDy, initialVelocity: animInitVelY, time: t
        )

        disableScreenUpdatesUntilFlush()
        setFrameOrigin(NSPoint(x: x, y: y))

        if t >= Double(currentSpring.settlingDuration) {
            setFrameOrigin(animationTarget)
            stopAllAnimations()
        }
    }

    private func stopAllAnimations() {
        let wasAnimating = isAnimating
        isAnimating = false

        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
        displayLink = nil
        animationTimer?.invalidate()
        animationTimer = nil

        if shadowWasEnabled && !hasShadow { hasShadow = true }

        if wasAnimating {
            NotificationCenter.default.post(name: .windowMovementEnded, object: self)
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

    private func isInBottomControlsArea(event: NSEvent) -> Bool {
        let locationInWindow = event.locationInWindow
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

    public override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        makeKey()
        if !UserDefaults.standard.bool(forKey: "showInDock") {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: false)
    }
}

public enum ScreenCorner {
    case topLeft, topRight, bottomLeft, bottomRight
}
