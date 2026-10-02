/**
 * [INPUT]: LiquidEdgeController's display-link frames (target timestamp,
 *          tick cost) and the main run loop's turn boundaries; `measure`
 *          markers from main-thread work that may land inside a frame.
 * [OUTPUT]: EdgeHitchTrace — per-frame deadline accounting during edge
 *           motions only, an in-memory ring of recent frames and long run-loop
 *           turns, main-thread stack samples taken during stalls, and an
 *           off-main append-only log (~/Library/Logs/nanoPod/edge-hitch.log,
 *           capped near 256KB) written only after a motion that missed a
 *           deadline by more than 25ms.
 * [POS]: Real-device evidence for "the edge animation stutters now and then".
 *        Zero cost while no edge motion runs: no observers, no sampler, and
 *        `measure` is one Bool test.
 * [PROTOCOL]:
 *   - A frame misses its deadline when the run-loop turn that carried its
 *     tick finished (after Core Animation's commit) later than the display
 *     link's targetTimestamp, or when the target jumped by more than one
 *     refresh interval since the previous frame (the display link skipped
 *     frames because the main thread was busy before the tick).
 *   - Stack samples come from a helper thread that reads the main thread's
 *     program counter and frame-pointer chain with public Mach calls while the
 *     main thread is suspended for microseconds. It allocates nothing and
 *     takes no lock while the main thread is suspended, and only fires when a
 *     turn has already run past `stallSampleAfter`.
 *   - File I/O only ever happens on `writeQueue`, never on the main thread.
 */

import Foundation
import QuartzCore
import Darwin
import os

public final class EdgeHitchTrace: @unchecked Sendable {
    public static let shared = EdgeHitchTrace()

    // MARK: Tunables

    /// A motion whose worst miss exceeds this is written to the log.
    public static let logThresholdMs: Double = 25
    /// A turn longer than this is kept in the ring even without a frame.
    static let longTurnMs: Double = 8
    static let ringCapacity = 96
    static let maxLogBytes = 256 * 1024
    static let maxLoggedEntries = 40
    /// Start taking stack samples once a turn has run this long.
    nonisolated(unsafe) static var stallSampleAfter: Double = 0.012

    // MARK: Hot flag (main thread only)

    /// True only while an edge motion is being traced; `measure` is a no-op otherwise.
    nonisolated(unsafe) public private(set) static var isRecording = false

    /// Runs `body`, and when a motion is being traced notes its cost under
    /// `name` against the run-loop turn it ran in.
    @inline(__always)
    public static func measure<T>(_ name: StaticString, _ body: () -> T) -> T {
        guard isRecording else { return body() }
        let t0 = CACurrentMediaTime()
        let r = body()
        shared.note(name, CACurrentMediaTime() - t0, at: t0)
        return r
    }

    // MARK: Records

    public struct Note {
        public let name: StaticString
        public let ms: Double
        /// Milliseconds after the turn started.
        public let atMs: Double
    }

    public struct Entry {
        public enum Kind: String { case frame, turn }
        public var kind: Kind
        public var motion: String
        public var wall: Date
        /// Frame: the display link's target; turn: the turn's start.
        public var target: CFTimeInterval
        /// Frame only: target minus the previous target, ms.
        public var gapMs: Double
        /// Frame only: nominal refresh interval, ms.
        public var nominalMs: Double
        /// Frame only: callback arrival after the link's `timestamp`, ms.
        public var startDelayMs: Double
        /// Frame only: our tick's own cost, ms.
        public var tickMs: Double
        /// The run-loop turn's busy time (wake to before-waiting, after CA commit), ms.
        public var turnMs: Double
        /// The main thread's own CPU time over that turn, ms. A turn much longer
        /// than this was blocked (WindowServer, XPC, a lock) or preempted, not computing.
        public var turnCpuMs: Double
        /// Frame only: how far past the target the turn ended, ms (negative = early).
        public var lateMs: Double
        public var notes: [Note]
        public var stacks: [[UInt]]

        /// The deadline miss this entry stands for, ms (0 = none).
        public var missMs: Double {
            switch kind {
            case .frame: return max(0, lateMs, gapMs - nominalMs)
            case .turn: return 0
            }
        }
    }

    // MARK: State (main thread)

    private var motionName = ""
    private var nominal: CFTimeInterval = 1.0 / 60
    private var active = false
    private var ending = false
    private var wakeObserver: CFRunLoopObserver?
    private var sleepObserver: CFRunLoopObserver?
    private var turnStart: CFTimeInterval = 0
    private var turnCpuStart: UInt64 = 0
    private var turnNotes: [Note] = []
    private var pendingFrame: (target: CFTimeInterval, gapMs: Double, startDelayMs: Double, wall: Date)?
    private var tickMs: Double = 0
    private var lastTarget: CFTimeInterval = 0
    private var ring: [Entry] = []
    private var ringNext = 0
    private var worstMissMs: Double = 0
    private var sampler: MainThreadStallSampler?
    private var turnToken: UInt64 = 0

    /// Test seam: sees every finalised entry on the main thread (frames and long turns).
    public var entrySink: ((Entry) -> Void)?
    /// Test seam: where the log goes. Under XCTest it is nil unless a test sets it.
    public var logURLOverride: URL?
    private let writeQueue = DispatchQueue(label: "nanoPod.edge-hitch-log", qos: .utility)

    public init() { ring.reserveCapacity(Self.ringCapacity) }

    // MARK: Motion lifecycle (main thread)

    /// Called when a display-linked motion starts from idle.
    public func begin(motion: String, nominalInterval: CFTimeInterval) {
        if active {
            // A new motion in the turn the last one ended: keep tracing.
            ending = false
            Self.isRecording = true
            return
        }
        active = true
        ending = false
        Self.isRecording = true
        motionName = motion
        nominal = nominalInterval > 0 ? nominalInterval : 1.0 / 60
        lastTarget = 0
        worstMissMs = 0
        pendingFrame = nil
        turnNotes.removeAll(keepingCapacity: true)
        turnStart = CACurrentMediaTime()
        turnCpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        ring.removeAll(keepingCapacity: true)
        ringNext = 0

        let runLoop = CFRunLoopGetMain()
        // Wake: a new turn begins. The earliest order so it precedes all other observers.
        wakeObserver = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { [weak self] _, _ in
            self?.turnBegan()
        }
        // Sleep: after Core Animation's own commit observer (order 2_000_000).
        sleepObserver = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { [weak self] _, _ in
            self?.turnEnded()
        }
        CFRunLoopAddObserver(runLoop, wakeObserver, .commonModes)
        CFRunLoopAddObserver(runLoop, sleepObserver, .commonModes)

        let s = sampler ?? MainThreadStallSampler()
        sampler = s
        s.start(turnStart: turnStart)
    }

    /// Called when the motion has settled (still inside the final tick).
    public func end() {
        guard active, !ending else { return }
        ending = true
        Self.isRecording = false
        // The observers stay until the end of this turn so the last frame is accounted.
    }

    // MARK: Frame callbacks (main thread)

    /// The display link fired.
    public func frameBegan(target: CFTimeInterval, timestamp: CFTimeInterval) {
        guard active else { return }
        let now = CACurrentMediaTime()
        let gap = lastTarget > 0 ? (target - lastTarget) * 1000 : nominal * 1000
        lastTarget = target
        pendingFrame = (target, gap, max(0, (now - timestamp) * 1000), Date())
        tickMs = 0
    }

    /// Our tick for that frame finished; `cost` is what it took.
    public func frameTicked(cost: CFTimeInterval) {
        tickMs = cost * 1000
    }

    fileprivate func note(_ name: StaticString, _ cost: CFTimeInterval, at start: CFTimeInterval) {
        turnNotes.append(Note(name: name, ms: cost * 1000, atMs: (start - turnStart) * 1000))
    }

    // MARK: Turn boundaries (main thread, run-loop observers)

    private func turnBegan() {
        turnStart = CACurrentMediaTime()
        turnCpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        turnNotes.removeAll(keepingCapacity: true)
        turnToken &+= 1
        sampler?.turnStarted(at: turnStart, token: turnToken)
    }

    private func turnEnded() {
        let now = CACurrentMediaTime()
        sampler?.turnEnded()
        let turnMs = (now - turnStart) * 1000
        let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- turnCpuStart) / 1_000_000
        let stacks = sampler?.takeSamples(token: turnToken) ?? []
        if let f = pendingFrame {
            let e = Entry(kind: .frame, motion: motionName, wall: f.wall, target: f.target, gapMs: f.gapMs,
                          nominalMs: nominal * 1000, startDelayMs: f.startDelayMs, tickMs: tickMs, turnMs: turnMs, turnCpuMs: cpuMs,
                          lateMs: (now - f.target) * 1000, notes: turnNotes, stacks: stacks)
            pendingFrame = nil
            record(e)
        } else if turnMs > Self.longTurnMs {
            let e = Entry(kind: .turn, motion: motionName, wall: Date(), target: turnStart, gapMs: 0,
                          nominalMs: nominal * 1000, startDelayMs: 0, tickMs: 0, turnMs: turnMs, turnCpuMs: cpuMs, lateMs: 0,
                          notes: turnNotes, stacks: stacks)
            record(e)
        }
        turnNotes.removeAll(keepingCapacity: true)
        if ending { finish() }
    }

    private func record(_ e: Entry) {
        // A turn that overran with no frame in it is what the NEXT frame's gap
        // pays for; keep both so the log shows cause and effect.
        worstMissMs = max(worstMissMs, e.missMs)
        if ring.count < Self.ringCapacity { ring.append(e) } else { ring[ringNext] = e }
        ringNext = (ringNext + 1) % Self.ringCapacity
        entrySink?(e)
    }

    private func finish() {
        if let o = wakeObserver { CFRunLoopObserverInvalidate(o) }
        if let o = sleepObserver { CFRunLoopObserverInvalidate(o) }
        wakeObserver = nil
        sleepObserver = nil
        sampler?.stop()
        active = false
        ending = false
        guard worstMissMs > Self.logThresholdMs else { return }
        // Oldest first.
        let snapshot = ring.count < Self.ringCapacity ? ring : Array(ring[ringNext...] + ring[..<ringNext])
        let motion = motionName
        let worst = worstMissMs
        let url = logURLOverride ?? Self.defaultLogURL
        guard let url else { return }
        writeQueue.async { Self.append(snapshot, motion: motion, worstMs: worst, to: url) }
    }

    /// Blocks until queued log writes finish (tests).
    public func drainLogWrites() { writeQueue.sync {} }

    // MARK: Log file (off-main)

    static var defaultLogURL: URL? {
        // A test process must opt in with `logURLOverride`: it never writes the founder's real log.
        if NSClassFromString("XCTestCase") != nil { return nil }
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        return lib.appendingPathComponent("Logs/nanoPod/edge-hitch.log")
    }

    static func append(_ entries: [Entry], motion: String, worstMs: Double, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = "== \(ISO8601DateFormatter().string(from: Date())) motion=\(motion) worst=\(fmt(worstMs))ms frames=\(entries.count)\n"
        // The cause and the damage, not every near-miss: long turns, real misses, anything
        // sampled; the newest few dozen, so a handful of bad motions fit the cap.
        let worthy = entries.filter { $0.kind == .turn || $0.missMs > 8 || !$0.stacks.isEmpty }
        for e in worthy.suffix(maxLoggedEntries) { text += format(e) }
        guard let data = text.data(using: .utf8) else { return }
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size + data.count > maxLogBytes,
           let old = try? Data(contentsOf: url) {
            // Keep the newest half, from a line start.
            var tail = old.suffix(maxLogBytes / 2)
            if let nl = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: nl)...] }
            try? Data(tail).write(to: url, options: .atomic)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    /// One entry, human-readable. Public for the test that renders what the log would say.
    public static func format(_ e: Entry) -> String {
        var line: String
        switch e.kind {
        case .frame:
            line = "frame[\(e.motion)] target=\(String(format: "%.4f", e.target)) gap=\(fmt(e.gapMs))/\(fmt(e.nominalMs))ms late=\(fmt(e.lateMs))ms start+\(fmt(e.startDelayMs)) tick=\(fmt(e.tickMs)) turn=\(fmt(e.turnMs)) cpu=\(fmt(e.turnCpuMs))"
        case .turn:
            line = "turn[\(e.motion)](no frame) start=\(String(format: "%.4f", e.target)) busy=\(fmt(e.turnMs))ms cpu=\(fmt(e.turnCpuMs))"
        }
        if !e.notes.isEmpty {
            line += " | " + e.notes.map { "\($0.name) \(fmt($0.ms))ms@+\(fmt($0.atMs))" }.joined(separator: "; ")
        }
        line += "\n"
        for s in e.stacks.prefix(2) { line += "    stack: " + String(symbolicate(s).prefix(900)) + "\n" }
        return line
    }

    /// The innermost frames (what the thread was doing), then the outermost app frames
    /// (who asked for it). With no app frame in the chain (SwiftUI / Core Animation
    /// working on its own) the next system frames stand in for them.
    static func symbolicate(_ pcs: [UInt]) -> String {
        let frames: [(label: String, isApp: Bool)] = pcs.map { pc in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0 else { return (String(pc, radix: 16), false) }
            let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
            guard let sym = info.dli_sname else { return ("\(image)+0x\(String(pc - UInt(bitPattern: info.dli_fbase), radix: 16))", false) }
            let name = String(cString: sym)
            // Swift mangles the module into the symbol; the app's Core is a library inside the app binary.
            let isApp = name.contains("MusicMiniPlayerCore") || name.contains("MusicMiniPlayerAppKit")
            return ("\(image)`\(name)", isApp)
        }
        let top = frames.prefix(4).map(\.label)
        let rest = frames.dropFirst(4)
        let app = rest.filter(\.isApp).prefix(10).map(\.label)
        let tail = app.isEmpty ? Array(rest.prefix(14).map(\.label)) : app
        return (top + (tail.isEmpty ? [] : ["..."] + tail)).joined(separator: " < ")
    }
}

// MARK: - Main-thread stall sampler

/// Samples the main thread's call chain when a run-loop turn has run long.
/// arm64 only (frame-pointer chain); elsewhere it records nothing.
final class MainThreadStallSampler: @unchecked Sendable {
    private let mainThread: mach_port_t
    /// Raw bits of the current turn's start (CACurrentMediaTime), 0 while the
    /// main thread sleeps. Written by main, read by the sampler: a benign
    /// race on an aligned 64-bit word, deliberately lock-free so the sampler
    /// never holds a lock the suspended main thread might own.
    private let turnStartBits: UnsafeMutablePointer<UInt64>
    private let turnTokenBits: UnsafeMutablePointer<UInt64>
    private let scratch: UnsafeMutablePointer<UInt>
    private static let maxDepth = 40
    private static let maxSamplesPerTurn = 4

    private let lock = OSAllocatedUnfairLock(initialState: [(token: UInt64, stack: [UInt])]())
    private var running = false
    private var thread: Thread?

    init() {
        // Created on the main thread (EdgeHitchTrace.begin), so this is its port.
        mainThread = mach_thread_self()
        turnStartBits = .allocate(capacity: 1); turnStartBits.initialize(to: 0)
        turnTokenBits = .allocate(capacity: 1); turnTokenBits.initialize(to: 0)
        scratch = .allocate(capacity: Self.maxDepth); scratch.initialize(repeating: 0, count: Self.maxDepth)
    }

    func start(turnStart: CFTimeInterval) {
        guard !running else { return }
        running = true
        turnStartBits.pointee = turnStart.bitPattern
        lock.withLock { $0.removeAll() }
        let t = Thread { [self] in loop() }
        t.name = "nanoPod.edge-hitch-sampler"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() { running = false; turnStartBits.pointee = 0 }

    func turnStarted(at time: CFTimeInterval, token: UInt64) {
        turnTokenBits.pointee = token
        turnStartBits.pointee = time.bitPattern
    }

    func turnEnded() { turnStartBits.pointee = 0 }

    func takeSamples(token: UInt64) -> [[UInt]] {
        lock.withLock { all in
            let mine = all.filter { $0.token == token }.map(\.stack)
            all.removeAll()
            return mine
        }
    }

    private func loop() {
        var lastToken: UInt64 = 0
        var takenThisTurn = 0
        var lastTakenAt: CFTimeInterval = 0
        while running {
            usleep(3000)
            let startBits = turnStartBits.pointee
            guard startBits != 0 else { continue }
            let token = turnTokenBits.pointee
            if token != lastToken { lastToken = token; takenThisTurn = 0 }
            let now = CACurrentMediaTime()
            guard now - Double(bitPattern: startBits) > EdgeHitchTrace.stallSampleAfter,
                  takenThisTurn < Self.maxSamplesPerTurn, now - lastTakenAt > 0.006 else { continue }
            let depth = captureMainStack()
            takenThisTurn += 1
            lastTakenAt = now
            guard depth > 0 else { continue }
            let stack = Array(UnsafeBufferPointer(start: scratch, count: depth))
            lock.withLock { $0.append((token, stack)) }
        }
    }

    /// Suspends the main thread, copies its PC and frame-pointer chain into
    /// `scratch`, resumes it. Nothing here may allocate or lock.
    private func captureMainStack() -> Int {
        #if arch(arm64)
        // Everything the suspended window needs is a local first: no lazy static, no
        // allocation, no lock between suspend and resume (the main thread may hold any of them).
        let maxDepth = Self.maxDepth
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF
        let task = mach_task_self_
        let scratch = self.scratch
        let thread = mainThread
        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        var depth = 0
        if kr == KERN_SUCCESS {
            scratch[0] = UInt(state.__pc) & mask
            depth = 1
            // A leaf function (vImage, memmove...) has no frame yet: its caller is in LR.
            let lr = UInt(state.__lr) & mask
            if lr != 0 { scratch[1] = lr; depth = 2 }
            var fp = UInt(state.__fp)
            var pair: (UInt, UInt) = (0, 0)
            var first = true
            while depth < maxDepth, fp != 0, fp & 0xF == 0 {
                var read: vm_size_t = 0
                let ok = withUnsafeMutablePointer(to: &pair) {
                    vm_read_overwrite(task, vm_address_t(fp), 16, vm_address_t(bitPattern: $0), &read)
                }
                guard ok == KERN_SUCCESS, read == 16, pair.1 != 0 else { break }
                let ret = pair.1 & mask
                // The first frame record's return address is LR again when the function has a frame.
                if !(first && ret == lr) { scratch[depth] = ret; depth += 1 }
                first = false
                guard pair.0 > fp else { break }
                fp = pair.0
            }
        }
        thread_resume(thread)
        return depth
        #else
        return 0
        #endif
    }
}
