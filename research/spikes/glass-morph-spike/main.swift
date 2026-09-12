// glass-morph-spike (rev 2 — 2026-09-10)
//
// Standalone probe: does SwiftUI glassEffect actually render (by equivalence
// against AppKit NSGlassEffectView, no screen-recording TCC needed), and does
// it morph, inside a transparent non-activating floating NSPanel replicated
// from Sources/MusicMiniPlayerCore/UI/SnappablePanel.swift:312-323 and
// Sources/MusicMiniPlayerApp/MusicMiniPlayerApp.swift.
//
// RENDER method (rev2): rev1 used a dlsym'd CGWindowListCreateImage pixel
// capture that needs screen-recording TCC and returned all-zero alpha (denied,
// not a real negative). Removed entirely — no private/obsoleted capture APIs.
// Instead we host a plain AppKit NSGlassEffectView on an identical panel,
// configured like the glass arm in
// Sources/MusicMiniPlayerCore/UI/Background/PanelBackdrop.swift:112-123
// (NSGlassEffectView(), cornerRadius = 16, tintColor set) — that arm is
// founder-verified to render on this exact panel class in nanoPod. We dump
// ITS layer tree with the same walkLayers() used for the SwiftUI tree and
// compare class names + bounds. Class-name/bounds inspection only, no
// private API calls, no pixel capture, no TCC prompt.
//
// MORPH method (rev2): rev1 only ever tracked the pill's pre-existing
// CABackdropLayer captured in a single 0.5s-pre-toggle snapshot; the card's
// glass layer is born mid-animation and was never enumerated, so MORPH=no
// was a methodology hole, not a real negative. Fixed: re-walk the ENTIRE
// hosting-view layer tree every recorded frame (16ms cadence, 600ms window)
// starting at the toggle. Every CABackdropLayer discovered at any frame is
// tracked by ObjectIdentifier from birth (first frame it's seen); its parent/
// shape layer is tracked too if that parent carries cornerRadius>0 or a mask.
// Each frame logs, per tracked layer: key, birth frame, presentation()
// bounds/position/cornerRadius.
//
// Verdict rule: MORPH=yes if any layer born after the toggle shows >=5
// intermediate frame-steps of continuously changing bounds/position between
// birth and settle, OR the pre-existing pill layer changes shape over >=5
// frame-steps. MORPH=no only if every tracked layer lands (stops changing)
// within <=2 frame-steps in the animated run AND the --no-animation control
// run also lands within <=2 frame-steps (proving the logger can tell a
// continuous morph from a single jump).
//
// Scenario 1 (--scenario=1, default): pill always mounted, card mounted only
// when state.expanded flips true (glassEffectID transition / union morph).
// Scenario 2 (--scenario=2): both pill and card stay mounted; HStack spacing
// toggles 4<->60 inside withAnimation(.smooth(duration:0.4)) (in-container
// proximity blend, no view identity change).
//
// Usage: glass-morph-spike [--no-animation] [--scenario=1|2]
// Writes JSONL frame log to stdout; final line is VERDICT=... JSON.

import AppKit
import SwiftUI
import CoreGraphics
import QuartzCore

let noAnimation = CommandLine.arguments.contains("--no-animation")
let mode = noAnimation ? "no-animation" : "animated"
var scenario = 1
for arg in CommandLine.arguments {
    if arg.hasPrefix("--scenario=") {
        scenario = Int(arg.dropFirst("--scenario=".count)) ?? 1
    }
}

// MARK: - State driving the toggle

final class SpikeState: ObservableObject {
    @Published var expanded: Bool = false
    @Published var spacing: CGFloat = 4
}

let state = SpikeState()

// MARK: - SwiftUI content (scenario 1: mount/unmount; scenario 2: spacing blend)

@available(macOS 26, *)
struct SpikeGlassView: View {
    @ObservedObject var state: SpikeState
    let scenario: Int
    @Namespace private var glassNS

    @ViewBuilder private var card: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(.clear)
            .frame(width: 140, height: 80)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
            .glassEffectID("b", in: glassNS)
    }

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: scenario == 2 ? state.spacing : 20) {
                Text("pill")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: Capsule())
                    .glassEffectID("a", in: glassNS)

                if scenario == 2 {
                    card
                } else if state.expanded {
                    card
                }
            }
            .padding(20)
        }
        .frame(width: 320, height: 120)
    }
}

// MARK: - Panel replication (SnappablePanel.swift:312-323 + MusicMiniPlayerApp.swift)

final class SpikePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func makePanel(origin: NSPoint) -> SpikePanel {
    let rect = NSRect(x: origin.x, y: origin.y, width: 320, height: 120)
    let panel = SpikePanel(
        contentRect: rect,
        styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = false
    panel.ignoresMouseEvents = true
    return panel
}

// MARK: - JSON logging

func jsonEscape(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "\\\"") }

func logLine(_ dict: [String: Any]) {
    var parts: [String] = []
    for (k, v) in dict {
        if let s = v as? String {
            parts.append("\"\(k)\":\"\(jsonEscape(s))\"")
        } else if let b = v as? Bool {
            parts.append("\"\(k)\":\(b)")
        } else {
            parts.append("\"\(k)\":\(v)")
        }
    }
    let line = "{" + parts.joined(separator: ",") + "}"
    print(line)
    FileHandle.standardOutput.synchronizeFile()
}

// MARK: - Layer tree walk

struct LayerInfo {
    let className: String
    let bounds: CGRect
    let cornerRadius: CGFloat
    let hasMask: Bool
    let depth: Int
    let layer: CALayer
}

func walkLayers(_ layer: CALayer?, depth: Int = 0, into out: inout [LayerInfo]) {
    guard let layer = layer else { return }
    out.append(LayerInfo(
        className: NSStringFromClass(type(of: layer)),
        bounds: layer.bounds,
        cornerRadius: layer.cornerRadius,
        hasMask: layer.mask != nil,
        depth: depth,
        layer: layer
    ))
    for sub in layer.sublayers ?? [] {
        walkLayers(sub, depth: depth + 1, into: &out)
    }
}

func isBackdropClassName(_ name: String) -> Bool {
    name.lowercased().contains("backdrop")
}

// MARK: - RENDER evidence: SwiftUI glassEffect tree vs. NSGlassEffectView tree

// Control panel hosts a plain AppKit NSGlassEffectView configured like the
// glass arm in Sources/MusicMiniPlayerCore/UI/Background/PanelBackdrop.swift:112-123
// (NativeGlassSurface.makeNSView: NSGlassEffectView(), cornerRadius = 16, tintColor set).
@available(macOS 26, *)
final class ControlGlassHost: NSView {
    let glassView = NSGlassEffectView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glassView.cornerRadius = 16
        glassView.tintColor = NSColor.systemBlue.withAlphaComponent(0.35)
        glassView.frame = NSRect(x: 40, y: 20, width: 140, height: 80)
        addSubview(glassView)
    }
    required init?(coder: NSCoder) { fatalError() }
}

func dumpTree(_ root: CALayer?, source: String) -> [LayerInfo] {
    var all: [LayerInfo] = []
    walkLayers(root, into: &all)
    for info in all {
        logLine([
            "phase": "layerdump",
            "source": source,
            "depth": info.depth,
            "class": info.className,
            "boundsW": Double(info.bounds.width),
            "boundsH": Double(info.bounds.height),
            "cornerRadius": Double(info.cornerRadius),
            "hasMask": info.hasMask
        ])
    }
    return all
}

var renderVerdict = "unknown"
var renderReason = ""

func evaluateRenderByEquivalence(swiftuiTree: [LayerInfo], controlTree: [LayerInfo]) {
    let swiftuiBackdrops = swiftuiTree.filter { isBackdropClassName($0.className) && $0.bounds.width > 0 && $0.bounds.height > 0 }
    let controlBackdrops = controlTree.filter { isBackdropClassName($0.className) && $0.bounds.width > 0 && $0.bounds.height > 0 }
    let swiftuiClasses = Set(swiftuiBackdrops.map { $0.className })
    let controlClasses = Set(controlBackdrops.map { $0.className })
    let shared = swiftuiClasses.intersection(controlClasses)
    if !shared.isEmpty {
        renderVerdict = "yes-by-equivalence"
        renderReason = "shared non-zero-bounds backdrop layer class(es) \(shared.sorted()) present in both the SwiftUI glassEffect tree (\(swiftuiBackdrops.count) backdrop layer(s)) and the founder-verified NSGlassEffectView control tree (\(controlBackdrops.count) backdrop layer(s)) — same underlying glass compositing primitive"
    } else {
        renderVerdict = "unknown"
        renderReason = "no shared non-zero-bounds backdrop class between trees; swiftui=\(swiftuiClasses.sorted()) control=\(controlClasses.sorted())"
    }
}

// MARK: - MORPH evidence: full-tree re-enumeration every frame, tracked by ObjectIdentifier

struct TrackedSample {
    let frame: Int
    let bounds: CGRect
    let position: CGPoint
    let cornerRadius: CGFloat
}

final class TrackedLayer {
    let key: ObjectIdentifier
    let className: String
    let birthFrame: Int
    let isPreExisting: Bool
    weak var layer: CALayer?
    var samples: [TrackedSample] = []
    init(key: ObjectIdentifier, className: String, birthFrame: Int, isPreExisting: Bool, layer: CALayer) {
        self.key = key
        self.className = className
        self.birthFrame = birthFrame
        self.isPreExisting = isPreExisting
        self.layer = layer
    }
}

var tracked: [ObjectIdentifier: TrackedLayer] = [:]
var trackOrder: [ObjectIdentifier] = []

/// Candidates per the fix spec: every CABackdropLayer, plus its parent/shape
/// layer if that parent carries cornerRadius>0 or a mask.
func trackingCandidates(root: CALayer?) -> [(CALayer, String)] {
    var all: [LayerInfo] = []
    walkLayers(root, into: &all)
    var result: [(CALayer, String)] = []
    var seen = Set<ObjectIdentifier>()
    for info in all where isBackdropClassName(info.className) {
        let k = ObjectIdentifier(info.layer)
        if !seen.contains(k) {
            seen.insert(k)
            result.append((info.layer, info.className))
        }
        if let parent = info.layer.superlayer, parent.cornerRadius > 0 || parent.mask != nil {
            let pk = ObjectIdentifier(parent)
            if !seen.contains(pk) {
                seen.insert(pk)
                result.append((parent, NSStringFromClass(type(of: parent))))
            }
        }
    }
    return result
}

func recordMorphFrame(_ frameIndex: Int, roots: [(CALayer?, String)]) {
    for (root, rootLabel) in roots {
        for (layer, className) in trackingCandidates(root: root) {
            let key = ObjectIdentifier(layer)
            let presented = layer.presentation() ?? layer
            let sample = TrackedSample(frame: frameIndex, bounds: presented.bounds, position: presented.position, cornerRadius: presented.cornerRadius)
            if let existing = tracked[key] {
                existing.samples.append(sample)
            } else {
                let t = TrackedLayer(key: key, className: className, birthFrame: frameIndex, isPreExisting: frameIndex == 0, layer: layer)
                t.samples.append(sample)
                tracked[key] = t
                trackOrder.append(key)
            }
            logLine([
                "phase": "morphframe",
                "root": rootLabel,
                "frame": frameIndex,
                "layerKey": String(UInt(bitPattern: key.hashValue)),
                "class": className,
                "birthFrame": tracked[key]!.birthFrame,
                "boundsW": Double(sample.bounds.width),
                "boundsH": Double(sample.bounds.height),
                "posX": Double(sample.position.x),
                "posY": Double(sample.position.y),
                "cornerRadius": Double(sample.cornerRadius)
            ])
        }
    }
}

func changedSteps(_ samples: [TrackedSample]) -> Int {
    guard samples.count >= 2 else { return 0 }
    var n = 0
    for i in 1..<samples.count {
        let a = samples[i - 1]
        let b = samples[i]
        let wD = abs(b.bounds.width - a.bounds.width)
        let hD = abs(b.bounds.height - a.bounds.height)
        let pD = hypot(b.position.x - a.position.x, b.position.y - a.position.y)
        if wD > 0.05 || hD > 0.05 || pD > 0.05 {
            n += 1
        }
    }
    return n
}

var morphVerdict = "unknown"
var morphReason = ""
var bornLayerFirstBounds: CGRect = .zero
var bornLayerLastBounds: CGRect = .zero
var bornLayerBirthFrame = -1

func evaluateMorph(isControlRun: Bool) -> (verdict: String, reason: String) {
    if tracked.isEmpty {
        return ("unknown", "no CABackdropLayer (or qualifying parent) found in any recorded frame")
    }
    var maxBornChangedSteps = 0
    var maxBornLayer: TrackedLayer?
    var maxPillChangedSteps = 0
    for key in trackOrder {
        guard let t = tracked[key] else { continue }
        let steps = changedSteps(t.samples)
        if t.birthFrame > 0 {
            if steps > maxBornChangedSteps {
                maxBornChangedSteps = steps
                maxBornLayer = t
            }
        } else {
            if steps > maxPillChangedSteps { maxPillChangedSteps = steps }
        }
    }
    if let born = maxBornLayer {
        bornLayerFirstBounds = born.samples.first!.bounds
        bornLayerLastBounds = born.samples.last!.bounds
        bornLayerBirthFrame = born.birthFrame
    }
    let allLandWithinTwo = trackOrder.allSatisfy { key in
        guard let t = tracked[key] else { return true }
        return changedSteps(t.samples) <= 2
    }
    if isControlRun {
        // Control run only evaluates "does everything land within <=2 steps".
        if allLandWithinTwo {
            return ("no(control-lands-fast)", "no-animation control: every tracked layer's bounds/position land within <=2 frame-steps (max born=\(maxBornChangedSteps), max pill=\(maxPillChangedSteps)) — confirms logger can distinguish a jump from a morph")
        } else {
            return ("unknown", "no-animation control: some tracked layer changed across >2 frame-steps (max born=\(maxBornChangedSteps), max pill=\(maxPillChangedSteps)) even without animation — logger baseline not clean")
        }
    }
    if maxBornChangedSteps >= 5 {
        return ("yes", "a layer born after the toggle (class \(maxBornLayer?.className ?? "?"), birthFrame=\(maxBornLayer?.birthFrame ?? -1)) shows \(maxBornChangedSteps) continuously-changing frame-steps between birth and settle")
    }
    if maxPillChangedSteps >= 5 {
        return ("yes", "the pre-existing pill-side backdrop layer changes shape/position across \(maxPillChangedSteps) frame-steps")
    }
    if allLandWithinTwo {
        return ("no", "every tracked layer lands within <=2 frame-steps (max born=\(maxBornChangedSteps), max pill=\(maxPillChangedSteps)); pending confirmation against the --no-animation control run")
    }
    return ("unknown", "changed across 3-4 frame-steps (max born=\(maxBornChangedSteps), max pill=\(maxPillChangedSteps)) — below the >=5 threshold for MORPH=yes but above the <=2 threshold for MORPH=no")
}

// MARK: - Main

guard #available(macOS 26, *) else {
    print("{\"error\":\"requires macOS 26\"}")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let swiftuiPanel = makePanel(origin: NSPoint(x: 40, y: 40))
let hostingView = NSHostingView(rootView: SpikeGlassView(state: state, scenario: scenario))
hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
swiftuiPanel.contentView = hostingView
swiftuiPanel.orderFrontRegardless()

let controlPanel = makePanel(origin: NSPoint(x: 40, y: 200))
let controlHost = ControlGlassHost(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
controlPanel.contentView = controlHost
controlPanel.orderFrontRegardless()

let startTime = CACurrentMediaTime()

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    let swiftuiTree = dumpTree(hostingView.layer, source: "swiftui")
    let controlTree = dumpTree(controlHost.layer, source: "control")
    evaluateRenderByEquivalence(swiftuiTree: swiftuiTree, controlTree: controlTree)
    logLine(["phase": "renderEvidence", "verdict": renderVerdict, "reason": renderReason])

    let toggleTime = CACurrentMediaTime() - startTime
    if noAnimation {
        if scenario == 2 { state.spacing = 60 } else { state.expanded = true }
    } else {
        withAnimation(.smooth(duration: 0.4)) {
            if scenario == 2 { state.spacing = 60 } else { state.expanded = true }
        }
    }
    logLine(["phase": "toggle", "t": toggleTime, "animated": !noAnimation, "scenario": scenario])

    var frameIndex = 0
    let frameIntervalMs = 16
    let totalMs = 600
    var elapsedMs = 0
    func tickFrame() {
        recordMorphFrame(frameIndex, roots: [(hostingView.layer, "swiftui")])
        frameIndex += 1
        elapsedMs += frameIntervalMs
        if elapsedMs < totalMs {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(frameIntervalMs) / 1000.0, execute: tickFrame)
        } else {
            let result = evaluateMorph(isControlRun: noAnimation)
            morphVerdict = result.verdict
            morphReason = result.reason
            let verdictLine = "VERDICT={\"mode\":\"\(mode)\",\"scenario\":\(scenario),\"RENDER\":\"\(renderVerdict)\",\"RENDER_REASON\":\"\(jsonEscape(renderReason))\",\"MORPH\":\"\(morphVerdict)\",\"MORPH_REASON\":\"\(jsonEscape(morphReason))\",\"trackedLayerCount\":\(tracked.count),\"frameCount\":\(frameIndex),\"bornBirthFrame\":\(bornLayerBirthFrame),\"bornFirstW\":\(Double(bornLayerFirstBounds.width)),\"bornFirstH\":\(Double(bornLayerFirstBounds.height)),\"bornLastW\":\(Double(bornLayerLastBounds.width)),\"bornLastH\":\(Double(bornLayerLastBounds.height))}"
            print(verdictLine)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                exit(0)
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(frameIntervalMs) / 1000.0, execute: tickFrame)
}

// Hard safety exit in case something hangs
DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
    exit(0)
}

app.run()
