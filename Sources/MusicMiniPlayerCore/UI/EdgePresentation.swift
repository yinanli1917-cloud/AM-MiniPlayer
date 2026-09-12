/**
 * [INPUT]: No external dependencies (pure state model + main-actor publisher)
 * [OUTPUT]: EdgePresentation state enum + SnapEvent + EdgePresentationReducer (pure) + EdgePresentationModel (ObservableObject)
 * [POS]: C1 贴边形变设计 §1/§9 commit 1 — SnappablePanel 与 SwiftUI 内容层之间的状态桥
 * [PROTOCOL]: 变更时更新此头部，然后检查 research/c1-edge-morph-design-2026-09-12.md §1/§9
 */

import Foundation

/// 贴边面板的呈现态。见 research/c1-edge-morph-design-2026-09-12.md §1。
///
/// 计划者对设计文档 §1 的偏离：设计文档原定把这个状态发布在
/// `MusicController.@Published var edgePresentation` 上；这里改为独立的
/// `EdgePresentationModel`（见下），因为 `MusicController` 是播放态门面，
/// 不该承载窗口呈现态，二者生命周期与职责都不同。
public enum EdgePresentation: Equatable {
    case card            // 正常/贴边前
    case hidingToPill     // hideToEdge 触发 → pill 落定前的过渡态
    case pill            // isEdgeHidden == true 且未 peek
    case peeking         // isEdgePeeking == true
    case restoringToCard // restoreFromEdge 触发 → card 落定前
}

/// 驱动 `EdgePresentation` 转移的事件。由 `SnappablePanel` 的
/// `onGeometryMorphWillStart`/`onGeometryMorphDidSettle` 回调转译而来。
public enum SnapEvent: Equatable {
    case hideRequested
    case restoreRequested
    case peekEntered
    case peekExited
    case settled
}

/// 纯函数状态机：`(current, event) -> next`。非法组合原样返回 `current`
/// （例如已经是 `.pill` 时又收到 `hideRequested`）。
///
/// 转移表（穷举，`.` 表示保持不变）：
///
/// | current \ event      | hideRequested   | restoreRequested  | peekEntered | peekExited | settled           |
/// |-----------------------|-----------------|--------------------|-------------|------------|-------------------|
/// | card                  | hidingToPill    | .                  | .           | .          | .                 |
/// | hidingToPill          | .               | restoringToCard    | .           | .          | pill              |
/// | pill                  | .               | restoringToCard    | peeking     | .          | .                 |
/// | peeking               | .               | restoringToCard    | .           | pill       | .                 |
/// | restoringToCard       | hidingToPill    | .                  | .           | .          | card              |
///
/// 说明：
/// - `hideRequested` 只在 `card`（正常起手）与 `restoringToCard`（restore 途中
///   反悔重新贴边，允许打断，见 SnappablePanel 现有的 `startSpringAnimation`
///   会先 `stopAllAnimations()` 打断上一个几何动画）时生效。
/// - `restoreRequested` 在 `hidingToPill`/`pill`/`peeking` 任意一个「已贴边或
///   正在贴边」的态上都合法（同样对应几何动画可被打断重定向）。
/// - `peekEntered`/`peekExited` 只在 `pill`/`peeking` 之间来回，不影响
///   `hidingToPill`/`restoringToCard`/`card`。
/// - `settled` 只在两个过渡态上真正落定：`hidingToPill -> pill`，
///   `restoringToCard -> card`；其余态收到 `settled`（理论上不该发生，因为
///   `onGeometryMorphDidSettle` 只在几何弹簧真的跑完时触发）保持不变。
public enum EdgePresentationReducer {
    public static func reduce(current: EdgePresentation, event: SnapEvent) -> EdgePresentation {
        switch (current, event) {
        case (.card, .hideRequested):
            return .hidingToPill
        case (.restoringToCard, .hideRequested):
            return .hidingToPill

        case (.hidingToPill, .restoreRequested):
            return .restoringToCard
        case (.pill, .restoreRequested):
            return .restoringToCard
        case (.peeking, .restoreRequested):
            return .restoringToCard

        case (.pill, .peekEntered):
            return .peeking
        case (.peeking, .peekExited):
            return .pill

        case (.hidingToPill, .settled):
            return .pill
        case (.restoringToCard, .settled):
            return .card

        default:
            return current
        }
    }
}

/// 独立于 `MusicController` 的窗口呈现态发布者（main-actor）。计划者偏离
/// 设计文档 §1：不把 `edgePresentation` 挂到 `MusicController` 上，改用这个
/// 专属 ObservableObject，由 App 侧和 `MusicController` 一起通过
/// `.environmentObject` 注入给 SwiftUI 内容层。
/// 面板当前贴靠的屏幕边缘。与 `SnappablePanel.Edge` 同构（`.none/.left/.right`），
/// 独立声明是因为 `SnappablePanel` 不是 SwiftUI 可见类型——`EdgeMorphHost` 需要
/// 一个纯 Swift 值来决定 pill 从哪条边露出。
public enum SnappedEdge: Equatable {
    case none, left, right
}

@MainActor
public final class EdgePresentationModel: ObservableObject {
    @Published public private(set) var presentation: EdgePresentation = .card

    /// commit 2 新增（design §9 commit 2 的 TODO）：`SnappablePanel.hiddenEdge` 是
    /// 已经公开的只读属性，但 SwiftUI 内容层没有到 `SnappablePanel` 的引用。
    /// `MusicMiniPlayerApp.swift` 在既有的 `onGeometryMorphWillStart`/
    /// `onGeometryMorphDidSettle` 回调里多读一次 `snappableWindow.hiddenEdge`
    /// 并写进这里——不新增 hook、不改 `SnappablePanel.swift`。
    @Published public private(set) var snappedEdge: SnappedEdge = .none

    public init() {}

    /// 应用一个 `SnapEvent`，纯函数 `EdgePresentationReducer.reduce` 落地为发布状态。
    public func apply(_ event: SnapEvent) {
        presentation = EdgePresentationReducer.reduce(current: presentation, event: event)
    }

    /// 由 App 层在几何回调里同步写入 `SnappablePanel.hiddenEdge` 的镜像值。
    public func updateSnappedEdge(_ edge: SnappedEdge) {
        snappedEdge = edge
    }
}
