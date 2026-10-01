/**
 * [INPUT]: AppKit's NSEvent monitors + CFRunLoop observers; MusicMiniPlayerCore's SnappablePanel.scrollDecisionObserver.
 * [OUTPUT]: TourGestureTrace (always-on, in-memory evidence of every two-finger gesture while the tour is on screen),
 *           TourGestureLogWriter (the injected sink), TourGestureFileWriter (~/Library/Logs/nanoPod/tour-gesture.log).
 * [POS]: Onboarding tour diagnostics. Born from the founder's report (2026-09-30) that the two-finger drag "often" stops
 *        working during the tour, which three in-process investigations could not reproduce: the real app now leaves its own
 *        evidence, with no defaults switch to forget. Zero cost outside the tour (start/stop own every monitor, observer and
 *        timer); during it the main thread only appends to a bounded in-memory ring. Disk is touched OFF the main thread, once
 *        per gesture that looks wrong and once at teardown (this project was burned twice by per-event synchronous I/O).
 */

import AppKit
import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Sink
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Where flushed text goes. `append` is ALWAYS called on the trace's private background queue, never on the main thread.
protocol TourGestureLogWriter: AnyObject {
    func append(_ text: String)
}

/// `tour-gesture.log` with one backup: when the file reaches `rotateAt` it becomes `tour-gesture.log.1` (replacing the old
/// backup), so the pair never holds much more than 2 x `rotateAt` (256 KB with the default).
final class TourGestureFileWriter: TourGestureLogWriter {
    static let fileName = "tour-gesture.log"
    let directory: URL
    let rotateAt: Int

    /// `~/Library/Logs/nanoPod` for the app; a temp directory under XCTest, so no test can write the founder's log.
    static func defaultDirectory() -> URL {
        if NanoPodCacheLocation.ProcessIdentity.current.isXCTest {
            return FileManager.default.temporaryDirectory.appendingPathComponent("nanoPod-test-logs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/nanoPod", isDirectory: true)
    }

    init(directory: URL = TourGestureFileWriter.defaultDirectory(), rotateAt: Int = 128 * 1024) {
        self.directory = directory
        self.rotateAt = rotateAt
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func append(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size >= rotateAt {
            let backup = directory.appendingPathComponent(Self.fileName + ".1")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: url, to: backup)
        }
        guard let data = text.data(using: .utf8) else { return }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Bounded ring
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct TourTraceRing<Element> {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: nil, count: self.capacity)
    }

    mutating func append(_ element: Element) {
        storage[(head + count) % capacity] = element
        if count < capacity { count += 1 } else { head = (head + 1) % capacity }
    }

    /// Oldest first.
    var elements: [Element] { (0..<count).compactMap { storage[(head + $0) % capacity] } }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Trace
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor
final class TourGestureTrace {
    /// Everything the trace reads from the outside, injectable so tests need no live tour.
    struct Environment {
        var page: () -> String
        var tourState: () -> String
        var cardYielded: () -> Bool
        var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
        var uptime: () -> CFTimeInterval = { ProcessInfo.processInfo.systemUptime }
        /// The window WindowServer puts topmost at a screen point, as a short description.
        var topmostWindow: (NSPoint, SnappablePanel) -> String = TourGestureTrace.describeTopmostWindow
    }

    struct Entry {
        let seq: Int
        let uptime: CFTimeInterval
        let wall: Date
        let gesture: Int
        let text: String
    }

    enum Source { case local, otherApp, direct }

    /// One two-finger gesture, from its first event until it goes quiet.
    struct Gesture {
        var id: Int
        var startedAt: CFTimeInterval
        var lastEventAt: CFTimeInterval
        var firstSeq: Int
        var startFrame: NSRect
        var page: String
        var cursorOverPanel = false
        var sumDX: CGFloat = 0
        var sumDY: CGFloat = 0
        var travel: CGFloat = 0
        var events = 0
        var localEvents = 0
        var otherAppEvents = 0
        var sawMayBegin = false, sawBegan = false, sawEnded = false, sawCancelled = false
        var momentumEvents = 0
        var routeCounts: [String: Int] = [:]
        var lastRoute: String?
        var lastRouteRun = 0
        var deltasApplied = 0
        var peakDisplacement: CGFloat = 0
        var tucked = false
        var projectedTarget: NSPoint?
        var projectedCorner: String?
        var isAnimating = false
        var isEdgeHidden = false
        var isScrollDragging = false
        var yields = 0, restores = 0, raises = 0
        var maxLatency: CFTimeInterval = 0
        var latencyStalls = 0
        var loopStalls = 0
        var maxLoopStall: CFTimeInterval = 0
    }

    static let ringCapacity = 400
    static let minimumTravel: CGFloat = 40
    static let minimumDisplacement: CGFloat = 4
    static let stallThreshold: CFTimeInterval = 0.05

    /// How long a gesture must stay quiet (no event) before it is judged: long enough for the corner spring to land.
    var settleDelay: TimeInterval = 1.2

    private let env: Environment
    private let writer: TourGestureLogWriter
    private let writeQueue = DispatchQueue(label: "nanoPod.tourGestureTrace.write", qos: .utility)
    private weak var panel: SnappablePanel?

    private(set) var ring = TourTraceRing<Entry>(capacity: TourGestureTrace.ringCapacity)
    private var nextSeq = 0
    private var flushedUpTo = -1
    private var nextGestureID = 1
    private(set) var open: Gesture?
    private var settleWork: DispatchWorkItem?

    private var monitors: [Any] = []
    private var stallObserver: CFRunLoopObserver?
    private var loopWake: CFTimeInterval = 0
    private(set) var gesturesSeen = 0
    private(set) var failuresFlushed = 0

    /// Number of live event monitors (0 whenever the trace is not running).
    var monitorCount: Int { monitors.count }
    private(set) var isRunning = false
    var hasLoopObserver: Bool { stallObserver != nil }

    init(environment: Environment, writer: TourGestureLogWriter) {
        self.env = environment
        self.writer = writer
    }

    // MARK: Lifecycle

    func start(panel: SnappablePanel, installMonitors: Bool = true) {
        guard !isRunning else { return }
        isRunning = true
        self.panel = panel
        panel.scrollDecisionObserver = { [weak self] decision in
            MainActor.assumeIsolated { self?.noteDecision(decision) }
        }
        append(gesture: 0, "TOUR-ON panel=\(Self.rect(panel.frame)) page=\(env.page()) tour=\(env.tourState())")
        guard installMonitors else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event, source: .local) }
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event, source: .otherApp) }
        }) { monitors.append(global) }
    }

    /// Tour teardown: judges any open gesture now, writes what the ring still holds (when anything was seen), and releases
    /// every monitor. Idempotent.
    func stop() {
        guard isRunning else { return }
        finalizeOpenGesture()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panel?.scrollDecisionObserver = nil
        stopStallWatch()
        isRunning = false
        let summary = "TOUR-OFF gestures=\(gesturesSeen) flushedFailures=\(failuresFlushed)"
        append(gesture: 0, summary)
        flush(upTo: nextSeq - 1, header: gesturesSeen > 0 ? "tour teardown (\(gesturesSeen) gestures)" : "tour teardown (no scroll gesture seen)",
              fromSeq: gesturesSeen > 0 ? flushedUpTo + 1 : nextSeq - 1)
        panel = nil
    }

    /// Blocks until everything handed to the writer has been written. Tests and teardown paths only.
    func drainWrites() { writeQueue.sync {} }

    // MARK: Tour notes

    func noteYield(_ yielded: Bool) {
        if yielded { open?.yields += 1 } else { open?.restores += 1 }
        append(gesture: open?.id ?? 0, yielded ? "tour: card yielded (panel movement began)" : "tour: card restored")
    }

    func noteRaise() {
        open?.raises += 1
        append(gesture: open?.id ?? 0, "tour: raiseTourWindows (panel.orderFrontRegardless + card.orderFront)")
    }

    // MARK: Events

    /// One scroll event, as seen by a monitor (or delivered directly in tests).
    func observe(_ event: NSEvent, source: Source) {
        guard isRunning, let panel else { return }
        let phase = event.phase, momentum = event.momentumPhase
        guard phase != [] || momentum != [] else { return }          // a plain wheel: not a trackpad gesture

        let now = env.uptime()
        let mouse = env.mouseLocation()
        let over = panel.frame.contains(mouse)
        // The global monitor reports every scroll on the machine; only those over the panel are evidence.
        if source == .otherApp, !over, open == nil { return }

        if phase == .mayBegin || phase == .began, let g = open, g.sawEnded || g.sawCancelled || g.momentumEvents > 0 || g.sawBegan {
            finalizeOpenGesture()
        }
        if open == nil { beginGesture(event: event, source: source, now: now, over: over, panel: panel) }

        guard var g = open else { return }
        g.events += 1
        g.lastEventAt = now
        g.cursorOverPanel = g.cursorOverPanel || over
        switch source {
        case .local: g.localEvents += 1
        case .otherApp: g.otherAppEvents += 1
        case .direct: break
        }
        let latency = max(0, now - event.timestamp)
        if latency > g.maxLatency { g.maxLatency = latency }
        if latency > Self.stallThreshold { g.latencyStalls += 1 }
        if momentum != [] {
            g.momentumEvents += 1
        } else {
            if phase == .mayBegin { g.sawMayBegin = true }
            if phase == .began { g.sawBegan = true }
            if phase == .ended { g.sawEnded = true }
            if phase == .cancelled { g.sawCancelled = true }
            if phase == .began || phase == .changed {
                g.sumDX += event.scrollingDeltaX
                g.sumDY += event.scrollingDeltaY
                g.travel += abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY)
            }
        }
        open = g
        if phase == .ended || phase == .cancelled || (momentum != [] ) || phase == .mayBegin || phase == .began {
            append(gesture: g.id, "\(Self.phaseName(phase, momentum)) d=(\(Self.num(event.scrollingDeltaX)),\(Self.num(event.scrollingDeltaY))) src=\(Self.sourceName(source, event: event, panel: panel)) latency=\(Int(latency * 1000))ms")
        }
        armSettle()
    }

    /// What the panel decided for the event it just received (called from inside `SnappablePanel.sendEvent`).
    func noteDecision(_ d: SnappablePanel.ScrollDecision) {
        guard isRunning, let panel else { return }
        if open == nil {
            // The panel saw an event no monitor announced (direct delivery): open a gesture for it.
            beginGesture(event: nil, source: .direct, now: env.uptime(), over: true, panel: panel)
        }
        guard var g = open else { return }
        let route = d.route.rawValue
        g.routeCounts[route, default: 0] += 1
        if d.route == .albumDragApplied || d.route == .hideDragApplied {
            if d.frameAfter.origin != d.frameBefore.origin { g.deltasApplied += 1 }
        }
        let displacement = hypot(d.frameAfter.origin.x - g.startFrame.origin.x, d.frameAfter.origin.y - g.startFrame.origin.y)
        g.peakDisplacement = max(g.peakDisplacement, displacement)
        if d.route == .liquidSwipeFired || d.route == .albumEndTucked || d.isEdgeHidden { g.tucked = true }
        if let target = d.projectedTarget { g.projectedTarget = target; g.projectedCorner = d.projectedCorner.map { "\($0)" } ?? "none" }
        g.isAnimating = d.isAnimating
        g.isEdgeHidden = d.isEdgeHidden
        g.isScrollDragging = d.isScrollDragging
        if g.lastRoute == route {
            g.lastRouteRun += 1
        } else {
            let was = g.lastRoute.map { " (after \(g.lastRouteRun)x \($0))" } ?? ""
            g.lastRoute = route
            g.lastRouteRun = 1
            append(gesture: g.id, "panel: route=\(route)\(was) page=\(d.page.map { "\($0)" } ?? "?") frame=\(Self.rect(d.frameAfter)) animating=\(d.isAnimating) edgeHidden=\(d.isEdgeHidden) dragging=\(d.isScrollDragging) liquidOwned=\(d.liquidSwipeOwned)"
                + (d.projectedTarget.map { " target=(\(Self.num($0.x)),\(Self.num($0.y))) corner=\(g.projectedCorner ?? "none")" } ?? ""))
        }
        open = g
    }

    // MARK: Gesture lifecycle

    private func beginGesture(event: NSEvent?, source: Source, now: CFTimeInterval, over: Bool, panel: SnappablePanel) {
        let id = nextGestureID
        nextGestureID += 1
        gesturesSeen += 1
        let mouse = env.mouseLocation()
        let page = env.page()
        let g = Gesture(id: id, startedAt: now, lastEventAt: now, firstSeq: nextSeq, startFrame: panel.frame, page: page, cursorOverPanel: over)
        open = g
        startStallWatch()
        let topmost = over ? env.topmostWindow(mouse, panel) : "n/a (cursor outside the panel)"
        append(gesture: id, "BEGIN src=\(Self.sourceName(source, event: event, panel: panel)) cursor=\(over ? "over-panel" : "outside-panel")(\(Self.num(mouse.x)),\(Self.num(mouse.y))) topmost=\(topmost) page=\(page) panel=\(Self.rect(panel.frame)) tour=\(env.tourState()) yielded=\(env.cardYielded())")
    }

    /// ONE timer per gesture, not one per event (events arrive at 120 Hz): when it fires it re-arms for whatever quiet time
    /// the gesture still lacks, otherwise judges it.
    private func armSettle(after delay: TimeInterval? = nil) {
        guard settleWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settleWork = nil
                guard let g = self.open else { return }
                let remaining = self.settleDelay - (self.env.uptime() - g.lastEventAt)
                if remaining > 0.01 { self.armSettle(after: remaining) } else { self.finalizeOpenGesture() }
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? settleDelay), execute: work)
    }

    /// Judges the open gesture now; flushes it (with the notes just before it) when it looks wrong.
    func finalizeOpenGesture() {
        settleWork?.cancel(); settleWork = nil
        guard var g = open, let panel else { open = nil; return }
        open = nil
        stopStallWatch()
        let endOrigin = (g.isAnimating ? g.projectedTarget : nil) ?? panel.frame.origin
        let displacement = hypot(endOrigin.x - g.startFrame.origin.x, endOrigin.y - g.startFrame.origin.y)
        g.peakDisplacement = max(g.peakDisplacement, hypot(panel.frame.origin.x - g.startFrame.origin.x, panel.frame.origin.y - g.startFrame.origin.y))
        let horizontal = abs(g.sumDX) > abs(g.sumDY) * 1.2
        let expectsMove = g.page == "album" || horizontal
        let failed = g.cursorOverPanel && g.travel > Self.minimumTravel && displacement <= Self.minimumDisplacement && !g.tucked && expectsMove
        let noEnd = !(g.sawEnded || g.sawCancelled) && g.momentumEvents == 0 && g.events > 0
        let suspect: String? = g.sawCancelled ? "cancelled" : (noEnd ? "noEnd" : (g.localEvents > 0 && g.otherAppEvents > 0 ? "split" : nil))
        let verdict = failed ? "FAILED" : (suspect.map { "SUSPECT(\($0))" } ?? "ok")
        var routes = g.routeCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        if routes.isEmpty { routes = "none (the panel's router never saw it)" }
        let text = "END \(verdict) travel=\(Self.num(g.travel)) events=\(g.events)(local \(g.localEvents), other-app \(g.otherAppEvents), momentum \(g.momentumEvents)) "
            + "phases[mayBegin=\(g.sawMayBegin) began=\(g.sawBegan) ended=\(g.sawEnded) cancelled=\(g.sawCancelled)] page=\(g.page) cursorOverPanel=\(g.cursorOverPanel) "
            + "routes{\(routes)} deltasApplied=\(g.deltasApplied) start=(\(Self.num(g.startFrame.origin.x)),\(Self.num(g.startFrame.origin.y))) end=(\(Self.num(endOrigin.x)),\(Self.num(endOrigin.y))) "
            + "displacement=\(Self.num(displacement)) peak=\(Self.num(g.peakDisplacement)) projectedCorner=\(g.projectedCorner ?? "none") tucked=\(g.tucked) "
            + "isAnimating=\(g.isAnimating) isEdgeHidden=\(g.isEdgeHidden) isScrollDragging=\(g.isScrollDragging) "
            + "yields=\(g.yields) restores=\(g.restores) raises=\(g.raises) maxLatency=\(Int(g.maxLatency * 1000))ms latencyStalls=\(g.latencyStalls) loopStalls=\(g.loopStalls)(max \(Int(g.maxLoopStall * 1000))ms) "
            + "tour=\(env.tourState()) yielded=\(env.cardYielded())"
        append(gesture: g.id, text)
        if failed || suspect != nil {
            failuresFlushed += 1
            // The gesture, plus the tour notes that led up to it (yield / restore / raise) in the 3 s before.
            let from = ring.elements.first { $0.uptime >= g.startedAt - 3 && $0.seq > flushedUpTo }?.seq ?? g.firstSeq
            flush(upTo: nextSeq - 1, header: "\(verdict) gesture \(g.id)", fromSeq: min(from, g.firstSeq))
        }
    }

    // MARK: Main-thread stalls

    /// Run-loop iterations that kept the main thread busy for more than 50 ms while a gesture was open. Installed per gesture,
    /// never standing.
    private func startStallWatch() {
        guard stallObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity([.afterWaiting, .beforeWaiting]).rawValue, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.loopActivity(activity) }
        }
        stallObserver = observer
        loopWake = env.uptime()
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func stopStallWatch() {
        if let observer = stallObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        stallObserver = nil
    }

    private func loopActivity(_ activity: CFRunLoopActivity) {
        let now = env.uptime()
        if activity.contains(.afterWaiting) { loopWake = now; return }
        let busy = now - loopWake
        guard busy > Self.stallThreshold, var g = open else { return }
        g.loopStalls += 1
        g.maxLoopStall = max(g.maxLoopStall, busy)
        open = g
        append(gesture: g.id, "STALL main thread busy \(Int(busy * 1000))ms in one run-loop turn")
    }

    // MARK: Ring + flush

    private func append(gesture: Int, _ text: String) {
        ring.append(Entry(seq: nextSeq, uptime: env.uptime(), wall: Date(), gesture: gesture, text: text))
        nextSeq += 1
    }

    /// Hands ring entries `fromSeq...upTo` to the writer on the background queue. The main thread formats nothing and
    /// touches no file.
    private func flush(upTo: Int, header: String, fromSeq: Int) {
        let from = max(fromSeq, flushedUpTo + 1)
        let entries = ring.elements.filter { $0.seq >= from && $0.seq <= upTo }
        flushedUpTo = max(flushedUpTo, upTo)
        guard !entries.isEmpty else { return }
        let writer = self.writer
        writeQueue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            var text = "=== \(formatter.string(from: Date())) \(header) ===\n"
            for e in entries { text += "\(formatter.string(from: e.wall)) g\(e.gesture) \(e.text)\n" }
            writer.append(text)
        }
    }

    // MARK: Formatting

    nonisolated static func num(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
    nonisolated static func rect(_ r: NSRect) -> String { "(\(num(r.minX)),\(num(r.minY)) \(num(r.width))x\(num(r.height)))" }

    nonisolated static func phaseName(_ phase: NSEvent.Phase, _ momentum: NSEvent.Phase) -> String {
        if momentum != [] {
            switch momentum {
            case .began: return "momentum-began"
            case .changed: return "momentum-changed"
            case .ended: return "momentum-ended"
            default: return "momentum(\(momentum.rawValue))"
            }
        }
        switch phase {
        case .mayBegin: return "mayBegin"
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "ended"
        case .cancelled: return "CANCELLED"
        case .stationary: return "stationary"
        default: return "phase(\(phase.rawValue))"
        }
    }

    nonisolated static func sourceName(_ source: Source, event: NSEvent?, panel: SnappablePanel) -> String {
        switch source {
        case .otherApp: return "OTHER-APP (global monitor: this app never got it)"
        case .direct: return "direct"
        case .local:
            guard let w = event?.window else { return "local(no window)" }
            return w === panel ? "local(PANEL)" : "local(\(type(of: w))#\(w.windowNumber))"
        }
    }

    nonisolated static func describeTopmostWindow(at point: NSPoint, panel: SnappablePanel) -> String {
        let n = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        if n == panel.windowNumber { return "PANEL" }
        if let w = NSApp.window(withWindowNumber: n) { return "\(type(of: w))#\(n) level=\(w.level.rawValue)" }
        return "another app's window #\(n)"
    }
}
