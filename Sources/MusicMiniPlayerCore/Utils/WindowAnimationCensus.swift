/**
 * [INPUT]: NSWindow layer trees (all app windows, frame view included)
 * [OUTPUT]: One-shot census of attached CAAnimations + NSVisualEffectView inventory; formatted dump appended to /tmp/nanopod_anim_census.log
 * [POS]: MusicMiniPlayerCore diagnosis tool for defect 5 (static panel billing WindowServer) — on-demand via nanopod://debug/animsweep, never per-frame
 */

import AppKit

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Whole-window animation census.
//
// Why this exists: a paused static panel bills WindowServer with ZERO app-side
// commits sampled. No commits means the compositor work was armed earlier and
// keeps running server-side — the signature of an infinite CAAnimation nobody
// removed. Attached animations stay listed in the MODEL layer's animationKeys()
// (infinite ones never auto-remove), so a one-shot model-tree walk can name the
// culprit even while the app is completely idle.
//
// Scope: every app window, walked from the frame view (contentView.superview)
// so titlebar chrome is covered; masks included. Also inventories
// NSVisualEffectView instances (behind-window glass is a standing compositor
// suspect) and basic layer stats for bisection context.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
public enum WindowAnimationCensus {

    public struct AnimationEntry: Equatable {
        public let layerPath: String
        public let layerClass: String
        public let layerIsHidden: Bool
        public let layerOpacity: Float
        public let key: String
        public let animationClass: String
        public let keyPath: String?
        public let duration: CFTimeInterval
        public let isInfinite: Bool
        public let isRemovedOnCompletion: Bool
    }

    public struct EffectViewEntry: Equatable {
        public let viewClass: String
        public let blendingMode: String
        public let materialRawValue: Int
        public let isHidden: Bool
        public let frame: CGRect
    }

    public struct Stats: Equatable {
        public let layerCount: Int
        public let filterLayerCount: Int
        public let rasterizedLayerCount: Int
    }

    public struct Report {
        public let windowDescription: String
        public let animations: [AnimationEntry]
        public let effectViews: [EffectViewEntry]
        public let stats: Stats
    }

    // MARK: - Sweep

    @MainActor
    public static func sweep(window: NSWindow) -> Report {
        // Prefer the frame view (covers titlebar chrome), but it is not always
        // layer-backed; fall back to the content view's tree.
        let frameView = window.contentView?.superview
        let root = (frameView?.layer != nil) ? frameView : window.contentView
        var animations: [AnimationEntry] = []
        var layerCount = 0
        var filterLayerCount = 0
        var rasterizedLayerCount = 0

        var stack: [(CALayer, String)] = []
        if let rootLayer = root?.layer { stack.append((rootLayer, "frame")) }
        while let (layer, path) = stack.popLast() {
            layerCount += 1
            if layer.filters?.isEmpty == false { filterLayerCount += 1 }
            if layer.shouldRasterize { rasterizedLayerCount += 1 }
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key) else { continue }
                animations.append(entry(for: animation, key: key, layer: layer, path: path))
            }
            if let mask = layer.mask { stack.append((mask, path + ".mask")) }
            for (index, sublayer) in (layer.sublayers ?? []).enumerated() {
                stack.append((sublayer, path + "." + (sublayer.name ?? String(index))))
            }
        }

        return Report(
            windowDescription: describe(window),
            animations: animations,
            effectViews: root.map(effectViews(under:)) ?? [],
            stats: Stats(
                layerCount: layerCount,
                filterLayerCount: filterLayerCount,
                rasterizedLayerCount: rasterizedLayerCount
            )
        )
    }

    @MainActor
    public static func sweepAllWindows() -> [Report] {
        NSApp.windows.map { sweep(window: $0) }
    }

    private static func entry(for animation: CAAnimation, key: String, layer: CALayer, path: String) -> AnimationEntry {
        AnimationEntry(
            layerPath: path + "<\(type(of: layer))>",
            layerClass: String(describing: type(of: layer)),
            layerIsHidden: layer.isHidden,
            layerOpacity: layer.opacity,
            key: key,
            animationClass: String(describing: type(of: animation)),
            keyPath: keyPathDescription(of: animation),
            duration: animation.duration,
            isInfinite: animation.repeatCount == .infinity || animation.repeatDuration == .infinity,
            isRemovedOnCompletion: animation.isRemovedOnCompletion
        )
    }

    private static func keyPathDescription(of animation: CAAnimation) -> String? {
        if let property = animation as? CAPropertyAnimation { return property.keyPath }
        if let group = animation as? CAAnimationGroup {
            let children = (group.animations ?? []).compactMap(keyPathDescription(of:))
            return children.isEmpty ? nil : children.joined(separator: "+")
        }
        if let transition = animation as? CATransition { return "transition:\(transition.type.rawValue)" }
        return nil
    }

    @MainActor
    private static func effectViews(under root: NSView) -> [EffectViewEntry] {
        var entries: [EffectViewEntry] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let effect = view as? NSVisualEffectView {
                entries.append(EffectViewEntry(
                    viewClass: String(describing: type(of: effect)),
                    blendingMode: effect.blendingMode == .behindWindow ? "behindWindow" : "withinWindow",
                    materialRawValue: effect.material.rawValue,
                    isHidden: effect.isHiddenOrHasHiddenAncestor,
                    frame: effect.frame
                ))
            }
            stack.append(contentsOf: view.subviews)
        }
        return entries
    }

    @MainActor
    private static func describe(_ window: NSWindow) -> String {
        let title = window.title.isEmpty ? "untitled" : window.title
        return "\(type(of: window)) \"\(title)\" visible=\(window.isVisible) level=\(window.level.rawValue)"
    }

    // MARK: - Formatting + dump

    public static func format(_ reports: [Report]) -> String {
        var lines: [String] = []
        for report in reports {
            lines.append("== \(report.windowDescription)")
            lines.append("   layers=\(report.stats.layerCount) filtered=\(report.stats.filterLayerCount) rasterized=\(report.stats.rasterizedLayerCount)")
            for effect in report.effectViews {
                lines.append("   effectView \(effect.viewClass) blending=\(effect.blendingMode) material=\(effect.materialRawValue) hidden=\(effect.isHidden) frame=\(Int(effect.frame.width))x\(Int(effect.frame.height))")
            }
            if report.animations.isEmpty {
                lines.append("   animations: none")
            }
            for anim in report.animations {
                let infinity = anim.isInfinite ? " INFINITE" : ""
                let hidden = anim.layerIsHidden ? " hidden" : ""
                lines.append("   ANIM \(anim.layerPath) key=\(anim.key) \(anim.animationClass)(\(anim.keyPath ?? "?")) dur=\(String(format: "%.2f", anim.duration))\(infinity) removedOnCompletion=\(anim.isRemovedOnCompletion)\(hidden) opacity=\(String(format: "%.2f", anim.layerOpacity))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One-shot append; safe by construction (single write per user-triggered URL command,
    /// unlike the per-frame probe sinks gated behind NANOPOD_PROBES).
    @MainActor
    public static func dump(to path: String = "/tmp/nanopod_anim_census.log") {
        let block = "─── census \(ISO8601DateFormatter().string(from: Date())) ───\n"
            + format(sweepAllWindows()) + "\n"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(block.utf8))
        handle.closeFile()
    }
}
