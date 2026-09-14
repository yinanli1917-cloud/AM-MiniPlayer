import AppKit
import ApplicationServices
import Foundation

// AX spike: read Music.app's "Playing Next" table via AXUIElement C API.
// Reference patterns from Hammerspoon hs.axuielement (libaxuielement.m) and
// AXSwift: use kAX*Attribute string constants directly with
// AXUIElementCopyAttributeValue / AXUIElementCopyAttributeValues (ranged),
// kAXPressAction via AXUIElementPerformAction, AXObserverCreate + notifications.

func now() -> Double { Date().timeIntervalSince1970 }
func ms(_ t0: Double, _ t1: Double) -> String { String(format: "%.1fms", (t1 - t0) * 1000) }

func log(_ s: String) {
    print(s)
    fflush(stdout)
}

// MARK: - AX helpers

func axCopyAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
    if err != .success { return nil }
    return value
}

func axCopyAttrs(_ el: AXUIElement, _ attr: String, index: Int, count: Int) -> [AnyObject]? {
    var values: CFArray?
    let err = AXUIElementCopyAttributeValues(el, attr as CFString, index, count, &values)
    if err != .success { return nil }
    return (values as? [AnyObject])
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    guard let v = axCopyAttr(el, kAXChildrenAttribute as String) as? [AXUIElement] else { return [] }
    return v
}

func axRole(_ el: AXUIElement) -> String {
    (axCopyAttr(el, kAXRoleAttribute as String) as? String) ?? "?"
}

func axDesc(_ el: AXUIElement) -> String {
    (axCopyAttr(el, kAXDescriptionAttribute as String) as? String) ?? ""
}

func axTitle(_ el: AXUIElement) -> String {
    (axCopyAttr(el, kAXTitleAttribute as String) as? String) ?? ""
}

func axValueStr(_ el: AXUIElement) -> String {
    if let s = axCopyAttr(el, kAXValueAttribute as String) as? String { return s }
    return ""
}

// depth-first search with a predicate, bounded depth/node count for safety
func axFind(_ root: AXUIElement, maxDepth: Int = 40, maxNodes: Int = 20000, predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    while !stack.isEmpty {
        let (el, depth) = stack.removeLast()
        visited += 1
        if visited > maxNodes { return nil }
        if predicate(el) { return el }
        if depth >= maxDepth { continue }
        for c in axChildren(el) { stack.append((c, depth + 1)) }
    }
    return nil
}

func axFindAll(_ root: AXUIElement, maxDepth: Int = 40, maxNodes: Int = 20000, predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    var results: [AXUIElement] = []
    while !stack.isEmpty {
        let (el, depth) = stack.removeLast()
        visited += 1
        if visited > maxNodes { break }
        if predicate(el) { results.append(el) }
        if depth >= maxDepth { continue }
        for c in axChildren(el) { stack.append((c, depth + 1)) }
    }
    return results
}

func musicApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first
}

func musicAXApp() -> AXUIElement? {
    guard let app = musicApp() else { return nil }
    return AXUIElementCreateApplication(app.processIdentifier)
}

func mainWindow(_ appEl: AXUIElement) -> AXUIElement? {
    if let w = axCopyAttr(appEl, kAXMainWindowAttribute as String) {
        return (w as! AXUIElement)
    }
    if let windows = axCopyAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement], let first = windows.first {
        return first
    }
    return nil
}

func runOsascript(_ script: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// Find the Playing Next AXTable: look for an AXTable whose parent scroll area's
// description/identifier differs from the main "playlist details" table, by
// diffing table set before/after toggling the checkbox.
func findAllTables(_ root: AXUIElement) -> [AXUIElement] {
    axFindAll(root) { axRole($0) == (kAXTableRole as String) }
}

func findPlayingNextCheckbox(_ root: AXUIElement) -> AXUIElement? {
    axFind(root) { el in
        axRole(el) == (kAXCheckBoxRole as String) && axDesc(el).lowercased().contains("playing next")
    }
}

func rowStaticTexts(_ row: AXUIElement) -> [String] {
    let texts = axFindAll(row, maxDepth: 6) { axRole($0) == (kAXStaticTextRole as String) }
    return texts.map { t -> String in
        let v = axValueStr(t)
        return v.isEmpty ? axTitle(t) : v
    }.filter { !$0.isEmpty }
}

// MARK: - Commands

func cmdPermission() {
    let optsPromptFalse = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    let trustedNoPrompt = AXIsProcessTrustedWithOptions(optsPromptFalse)
    log("AXIsProcessTrustedWithOptions(prompt:false) = \(trustedNoPrompt)")
    log("binary pid = \(ProcessInfo.processInfo.processIdentifier)")
    if !trustedNoPrompt {
        log("NOT TRUSTED. Stopping per instructions (no bypass attempts).")
        exit(2)
    }
}

func cmdFindTable() {
    guard let appEl = musicAXApp() else { log("Music not running"); exit(1) }
    guard let win = mainWindow(appEl) else { log("no main window"); exit(1) }
    let before = findAllTables(win)
    log("tables before toggle: \(before.count)")
    guard let cb = findPlayingNextCheckbox(win) else {
        log("checkbox 'playing next' not found; dumping checkbox descriptions:")
        let boxes = axFindAll(win) { axRole($0) == (kAXCheckBoxRole as String) }
        for b in boxes { log("  desc=\(axDesc(b)) title=\(axTitle(b))") }
        exit(1)
    }
    log("found checkbox desc=\(axDesc(cb))")
    let t0 = now()
    let pressErr = AXUIElementPerformAction(cb, kAXPressAction as CFString)
    let t1 = now()
    log("AXPress on checkbox: err=\(pressErr.rawValue) time=\(ms(t0,t1))")
    Thread.sleep(forTimeInterval: 0.5)
    let after = findAllTables(win)
    log("tables after toggle: \(after.count)")
    for (i, t) in after.enumerated() {
        let rows = axCopyAttr(t, kAXRowsAttribute as String) as? [AXUIElement]
        log("  table[\(i)] rows=\(rows?.count ?? -1)")
    }
}

func getPlayingNextTable(_ win: AXUIElement) -> AXUIElement? {
    let tables = findAllTables(win)
    // Pick the table with the most rows as a heuristic for Playing Next (queue),
    // since "playlist details" table is typically the visible library list.
    var best: (AXUIElement, Int)? = nil
    for t in tables {
        let rows = axCopyAttr(t, kAXRowsAttribute as String) as? [AXUIElement]
        let c = rows?.count ?? 0
        if best == nil || c > best!.1 { best = (t, c) }
    }
    return best?.0
}

// Idempotent: only presses the checkbox if the Playing Next table isn't
// already visible with a plausible row count (panel state persists across
// process launches since it's Music's own UI state, not ours).
func ensurePlayingNextOpen(_ win: AXUIElement) -> AXUIElement? {
    if let t = getPlayingNextTable(win), let rows = axCopyAttr(t, kAXRowsAttribute as String) as? [AXUIElement], rows.count > 1 {
        return t
    }
    guard let cb = findPlayingNextCheckbox(win) else { return nil }
    _ = AXUIElementPerformAction(cb, kAXPressAction as CFString)
    Thread.sleep(forTimeInterval: 0.6)
    if let t = getPlayingNextTable(win), let rows = axCopyAttr(t, kAXRowsAttribute as String) as? [AXUIElement], rows.count > 1 {
        return t
    }
    return nil
}

func cmdReadRows(_ n: Int) {
    guard let appEl = musicAXApp(), let win = mainWindow(appEl) else { log("no window"); exit(1) }
    guard let table = ensurePlayingNextOpen(win) else { log("no table found"); exit(1) }

    func countOnly() -> Double {
        let t0 = now()
        let rows = axCopyAttr(table, kAXRowsAttribute as String) as? [AXUIElement]
        let t1 = now()
        log("row count = \(rows?.count ?? -1) time=\(ms(t0,t1))")
        return t1 - t0
    }

    func readFirstN() -> Double {
        let t0 = now()
        let rows = axCopyAttrs(table, kAXRowsAttribute as String, index: 0, count: n) as? [AXUIElement]
        var lines: [String] = []
        if let rows = rows {
            for r in rows {
                let texts = rowStaticTexts(r)
                lines.append(texts.joined(separator: " | "))
            }
        }
        let t1 = now()
        log("read first \(n) rows: got=\(rows?.count ?? 0) time=\(ms(t0,t1))")
        for (i, l) in lines.enumerated() { log("  [\(i)] \(l)") }
        return t1 - t0
    }

    log("--- cold: count ---")
    _ = countOnly()
    log("--- cold: read first \(n) ---")
    _ = readFirstN()
    log("--- warm runs x3: count ---")
    for _ in 0..<3 { _ = countOnly() }
    log("--- warm runs x3: read first \(n) ---")
    for _ in 0..<3 { _ = readFirstN() }
}

func cmdWindowState(_ state: String) {
    guard let appEl = musicAXApp(), let win = mainWindow(appEl) else { log("no window"); exit(1) }
    _ = ensurePlayingNextOpen(win)
    switch state {
    case "occlude":
        _ = runOsascript("tell application \"TextEdit\" to activate")
        Thread.sleep(forTimeInterval: 0.4)
        _ = runOsascript("""
        tell application "System Events"
            tell process "TextEdit"
                set position of window 1 to {0, 0}
                set size of window 1 to {1200, 900}
            end tell
        end tell
        """)
    case "minimize":
        _ = runOsascript("tell application \"System Events\" to tell process \"Music\" to set value of attribute \"AXMinimized\" of window 1 to true")
    case "restore-minimize":
        _ = runOsascript("tell application \"System Events\" to tell process \"Music\" to set value of attribute \"AXMinimized\" of window 1 to false")
    case "close":
        _ = runOsascript("tell application \"Music\" to close window 1")
    case "reopen":
        _ = runOsascript("tell application \"Music\" to reopen")
    default:
        break
    }
    Thread.sleep(forTimeInterval: 0.5)
    // Try to read table without activating Music
    guard let win2 = mainWindow(appEl) ?? win as AXUIElement? else { log("no window after state change"); return }
    guard let table = getPlayingNextTable(win2) else {
        log("state=\(state): table not found (nil)")
        return
    }
    let t0 = now()
    let rows = axCopyAttrs(table, kAXRowsAttribute as String, index: 0, count: 5) as? [AXUIElement]
    let t1 = now()
    log("state=\(state): rows=\(rows?.count ?? -1) time=\(ms(t0,t1))")
}

final class ObserverBox {
    var observer: AXObserver?
    var callbackTimes: [String: Double] = [:]
}

func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let box = Unmanaged<ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
    box.callbackTimes[notification as String] = now()
    log("[observer] \(notification) at \(now())")
}

func cmdObserve() {
    guard let app = musicApp() else { log("Music not running"); exit(1) }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    guard let win = mainWindow(appEl) else { log("no window"); exit(1) }
    guard let table = ensurePlayingNextOpen(win) else { log("no table"); exit(1) }

    var observer: AXObserver?
    let err = AXObserverCreate(app.processIdentifier, axObserverCallback, &observer)
    guard err == .success, let obs = observer else { log("AXObserverCreate failed: \(err.rawValue)"); exit(1) }
    let box = ObserverBox()
    box.observer = obs
    let refcon = Unmanaged.passUnretained(box).toOpaque()

    let notifications = [kAXRowCountChangedNotification, kAXValueChangedNotification, kAXSelectedRowsChangedNotification]
    for note in notifications {
        let e = AXObserverAddNotification(obs, table, note as CFString, refcon)
        log("add notification \(note) on table -> err=\(e.rawValue)")
        let e2 = AXObserverAddNotification(obs, win, note as CFString, refcon)
        log("add notification \(note) on window -> err=\(e2.rawValue)")
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)

    log("observing for 20s; will trigger next-track at t=3s and shuffle toggle at t=10s")
    let start = now()
    var firedNext = false
    var firedShuffle = false
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.1, true)
        let t = now() - start
        if t > 3 && !firedNext {
            firedNext = true
            let t0 = now()
            _ = runOsascript("tell application \"Music\" to next track")
            log("[trigger] next track osascript issued at \(t0)")
        }
        if t > 10 && !firedShuffle {
            firedShuffle = true
            let t0 = now()
            _ = runOsascript("tell application \"Music\" to set shuffle enabled to not shuffle enabled")
            log("[trigger] shuffle toggle osascript issued at \(t0)")
        }
    }
    log("observation window done")
}

func cmdShuffleCheck() {
    guard let appEl = musicAXApp(), let win = mainWindow(appEl) else { log("no window"); exit(1) }
    guard let table = ensurePlayingNextOpen(win) else { log("no table"); exit(1) }
    let rows = axCopyAttrs(table, kAXRowsAttribute as String, index: 0, count: 5) as? [AXUIElement]
    var predicted: [String] = []
    if let rows = rows {
        for r in rows { predicted.append(rowStaticTexts(r).joined(separator: " | ")) }
    }
    log("predicted upcoming (first 5 rows):")
    for (i, p) in predicted.enumerated() { log("  [\(i)] \(p)") }

    for i in 0..<3 {
        Thread.sleep(forTimeInterval: 2.0)
        _ = runOsascript("tell application \"Music\" to next track")
        Thread.sleep(forTimeInterval: 0.3)
        let cur = runOsascript("tell application \"Music\" to get name of current track")
        log("after next #\(i+1): current track = \(cur)")
    }
}

// MARK: - main

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "help"

switch cmd {
case "permission":
    cmdPermission()
case "find-table":
    cmdPermission()
    cmdFindTable()
case "read-rows":
    cmdPermission()
    let n = args.count > 2 ? Int(args[2]) ?? 20 : 20
    cmdReadRows(n)
case "window-state":
    cmdPermission()
    let state = args.count > 2 ? args[2] : "occlude"
    cmdWindowState(state)
case "observe":
    cmdPermission()
    cmdObserve()
case "shuffle-check":
    cmdPermission()
    cmdShuffleCheck()
case "rowmap":
    cmdPermission()
    cmdRowmap()
case "shuffle-redo":
    cmdPermission()
    cmdShuffleRedo()
case "speed-bench":
    cmdPermission()
    cmdSpeedBench()
case "minimize-ax":
    cmdPermission()
    cmdMinimizeAX()
case "observe2":
    cmdPermission()
    cmdObserve2()
case "observe-closed-then-open":
    cmdPermission()
    cmdObserveClosedThenOpen()
default:
    log("usage: axspike <permission|find-table|read-rows [n]|window-state <occlude|minimize|restore-minimize|close|reopen>|observe|shuffle-check>")
}

// MARK: - Round 4 follow-up (2026-09-13)

func axRowText(_ row: AXUIElement) -> String {
    rowStaticTexts(row).joined(separator: " | ")
}

func cmdRowmap() {
    guard let appEl = musicAXApp(), let win = mainWindow(appEl) else { log("no window"); exit(1) }
    guard let table = ensurePlayingNextOpen(win) else { log("no table"); exit(1) }
    guard let rows = axCopyAttr(table, kAXRowsAttribute as String) as? [AXUIElement] else {
        log("no rows attribute"); exit(1)
    }
    log("total rows = \(rows.count)")
    var lines: [String] = []
    var historyIdx: [Int] = []
    var headerIdx: [Int] = []
    for (i, r) in rows.enumerated() {
        let role = axRole(r)
        let text = axRowText(r)
        lines.append("[\(i)] role=\(role) text=\(text)")
        let lower = text.lowercased()
        if lower.contains("history") || text.contains("历史") { historyIdx.append(i) }
        if lower.contains("playing next") || text.contains("接下来播放") || lower.contains("up next") { headerIdx.append(i) }
    }
    let outPath = "research/spikes/ax-playing-next/rowmap.txt"
    try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    log("wrote \(lines.count) lines to \(outPath)")
    log("history-header candidate indices: \(historyIdx)")
    log("playing-next-header candidate indices: \(headerIdx)")
    if let h = historyIdx.first, let p = headerIdx.first {
        log("assuming: rows 0..<\(p) or similar are 'History' section (header at \(h)), 'Playing Next' header at \(p)")
        log("history rows count (0..<headerAfterHistory) = \(p) ; upcoming rows count (after \(p)) = \(rows.count - p - 1)")
    } else {
        log("could not confidently locate both headers by text match; inspect rowmap.txt manually")
    }
}

func firstNAfterIndex(_ rows: [AXUIElement], _ idx: Int, _ n: Int) -> [String] {
    let start = idx + 1
    guard start < rows.count else { return [] }
    let end = min(start + n, rows.count)
    return (start..<end).map { axRowText(rows[$0]) }
}

func findHeaderIndex(_ rows: [AXUIElement]) -> Int? {
    for (i, r) in rows.enumerated() {
        let t = axRowText(r).lowercased()
        if t.contains("playing next") || t.contains("up next") || t.contains("continue playing") || axRowText(r).contains("接下来播放") { return i }
    }
    return nil
}

func setShuffle(_ on: Bool) {
    _ = runOsascript("tell application \"Music\" to set shuffle enabled to \(on ? "true" : "false")")
}

func cmdShuffleRedo() {
    guard let appEl = musicAXApp(), let win = mainWindow(appEl) else { log("no window"); exit(1) }
    guard let table = ensurePlayingNextOpen(win) else { log("no table"); exit(1) }
    guard let rows0 = axCopyAttr(table, kAXRowsAttribute as String) as? [AXUIElement] else { log("no rows"); exit(1) }
    let origShuffle = runOsascript("tell application \"Music\" to get shuffle enabled")
    log("original shuffle enabled = \(origShuffle)")

    log("=== step A: shuffle ON, wait 2s, no panel reopen, dump first 8 after header ===")
    setShuffle(true)
    Thread.sleep(forTimeInterval: 2.0)
    guard let rowsA = axCopyAttr(table, kAXRowsAttribute as String) as? [AXUIElement] else { log("no rows after shuffle on"); return }
    guard let hdrA = findHeaderIndex(rowsA) else { log("no header row found after shuffle on"); return }
    let firstA = firstNAfterIndex(rowsA, hdrA, 8)
    for (i, s) in firstA.enumerated() { log("  A[\(i)] \(s)") }

    log("=== step B: next track x3, 2s apart, recording current track ===")
    var actuals: [String] = []
    for i in 0..<3 {
        Thread.sleep(forTimeInterval: 2.0)
        _ = runOsascript("tell application \"Music\" to next track")
        Thread.sleep(forTimeInterval: 0.3)
        let cur = runOsascript("tell application \"Music\" to get name of current track")
        actuals.append(cur)
        log("  next#\(i+1) current track = \(cur)")
    }
    log("=== comparison: predicted first 8 (A) vs actual next x3 ===")
    for (i, a) in actuals.enumerated() {
        let matched = firstA.contains { $0.contains(a) }
        log("  actual[\(i)]=\(a) matchesPredictedSet=\(matched)")
    }

    log("=== step C: does table content change on shuffle toggle? dump before/after 2s, diff first 8 ===")
    guard let rowsC0 = axCopyAttr(table, kAXRowsAttribute as String) as? [AXUIElement],
          let hdrC0 = findHeaderIndex(rowsC0) else { log("no rows/header before toggle"); return }
    let beforeToggle = firstNAfterIndex(rowsC0, hdrC0, 8)
    let curShuffle = runOsascript("tell application \"Music\" to get shuffle enabled")
    setShuffle(curShuffle == "true" ? false : true)
    Thread.sleep(forTimeInterval: 2.0)
    guard let rowsC1 = axCopyAttr(table, kAXRowsAttribute as String) as? [AXUIElement],
          let hdrC1 = findHeaderIndex(rowsC1) else { log("no rows/header after toggle"); return }
    let afterToggle = firstNAfterIndex(rowsC1, hdrC1, 8)
    for i in 0..<max(beforeToggle.count, afterToggle.count) {
        let b = i < beforeToggle.count ? beforeToggle[i] : "<missing>"
        let a = i < afterToggle.count ? afterToggle[i] : "<missing>"
        log("  diff[\(i)] before=\(b)")
        log("           after =\(a)")
        log("           same=\(b == a)")
    }

    log("=== step D: off -> on -> off, check if order returns ===")
    setShuffle(false)
    Thread.sleep(forTimeInterval: 1.5)
    guard let rowsOff0 = axCopyAttr(table, kAXRowsAttribute as String) as? [AXUIElement],
          let hOff0 = findHeaderIndex(rowsOff0) else { log("no rows off0"); return }
    let off0 = firstNAfterIndex(rowsOff0, hOff0, 8)
    setShuffle(true)
    Thread.sleep(forTimeInterval: 1.5)
    _ = axCopyAttr(table, kAXRowsAttribute as String)
    setShuffle(false)
    Thread.sleep(forTimeInterval: 1.5)
    guard let rowsOff1 = axCopyAttr(table, kAXRowsAttribute as String) as? [AXUIElement],
          let hOff1 = findHeaderIndex(rowsOff1) else { log("no rows off1"); return }
    let off1 = firstNAfterIndex(rowsOff1, hOff1, 8)
    for i in 0..<max(off0.count, off1.count) {
        let a = i < off0.count ? off0[i] : "<missing>"
        let b = i < off1.count ? off1[i] : "<missing>"
        log("  off-on-off[\(i)] first=\(a) second=\(b) same=\(a == b)")
    }

    // restore original shuffle state
    setShuffle(origShuffle == "true" ? true : false)
    log("restored shuffle enabled = \(origShuffle)")
}

func cmdSpeedBench() {
    guard let appEl = musicAXApp(), let win = mainWindow(appEl) else { log("no window"); exit(1) }
    guard let table = ensurePlayingNextOpen(win) else { log("no table"); exit(1) }
    guard let rows = axCopyAttr(table, kAXRowsAttribute as String) as? [AXUIElement], let hdr = findHeaderIndex(rows) else {
        log("no rows/header"); exit(1)
    }
    let start = hdr + 1
    let n = 20
    guard start + n <= rows.count else { log("not enough rows after header"); exit(1) }
    let targetRows = Array(rows[start..<(start+n)])

    log("=== fast path: kAXChildrenAttribute once per row, then value/title per child (title+artist) ===")
    for run in 1...3 {
        let t0 = now()
        for r in targetRows {
            let children = axChildren(r)
            for c in children {
                _ = axValueStr(c)
                _ = axTitle(c)
            }
        }
        let t1 = now()
        log("  fast-path run \(run): \(ms(t0,t1)) for \(n) rows (\((t1-t0)*1000/Double(n)) ms/row)")
    }

    log("=== AXUIElementCopyMultipleAttributeValues on each row's cell child ===")
    let attrs = [kAXValueAttribute as CFString, kAXTitleAttribute as CFString] as CFArray
    for run in 1...3 {
        let t0 = now()
        for r in targetRows {
            let children = axChildren(r)
            for c in children {
                var values: CFArray?
                let err = AXUIElementCopyMultipleAttributeValues(c, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
                _ = err
                _ = values
            }
        }
        let t1 = now()
        log("  multi-attr run \(run): \(ms(t0,t1)) for \(n) rows (\((t1-t0)*1000/Double(n)) ms/row)")
    }

    log("=== kAXVisibleRowsAttribute on table ===")
    let t0 = now()
    let visible = axCopyAttr(table, kAXVisibleRowsAttribute as String) as? [AXUIElement]
    let t1 = now()
    log("visible rows count = \(visible?.count ?? -1) time=\(ms(t0,t1))")
    if let visible = visible {
        let t2 = now()
        var texts: [String] = []
        for r in visible { texts.append(axRowText(r)) }
        let t3 = now()
        log("read visible rows text: \(ms(t2,t3)) for \(visible.count) rows (\(visible.count > 0 ? (t3-t2)*1000/Double(visible.count) : 0) ms/row)")
    }
}

func cmdMinimizeAX() {
    guard let appEl = musicAXApp(), let win = mainWindow(appEl) else { log("no window"); exit(1) }
    _ = ensurePlayingNextOpen(win)

    func readMinimized() -> Bool? {
        (axCopyAttr(win, kAXMinimizedAttribute as String) as? Bool)
    }
    log("minimized before = \(String(describing: readMinimized()))")

    let setErr1 = AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    log("AXUIElementSetAttributeValue(true) err=\(setErr1.rawValue)")
    Thread.sleep(forTimeInterval: 0.5)
    log("minimized after set-true = \(String(describing: readMinimized()))")

    // try reading table while minimized
    if let win2 = mainWindow(appEl) {
        if let table = getPlayingNextTable(win2) {
            let rows = axCopyAttrs(table, kAXRowsAttribute as String, index: 0, count: 5) as? [AXUIElement]
            log("while minimized: table found, read \(rows?.count ?? -1) rows")
        } else {
            log("while minimized: table NOT found via win2")
        }
    } else {
        log("while minimized: mainWindow() returned nil")
    }
    // also try reading directly off the original `win` handle
    if let table2 = getPlayingNextTable(win) {
        let rows2 = axCopyAttrs(table2, kAXRowsAttribute as String, index: 0, count: 5) as? [AXUIElement]
        log("while minimized (via original win handle): read \(rows2?.count ?? -1) rows")
    } else {
        log("while minimized (via original win handle): table NOT found")
    }

    let setErr2 = AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    log("AXUIElementSetAttributeValue(false) err=\(setErr2.rawValue)")
    Thread.sleep(forTimeInterval: 0.5)
    log("minimized after set-false = \(String(describing: readMinimized()))")
}

func cmdObserve2() {
    guard let app = musicApp() else { log("Music not running"); exit(1) }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    guard let win = mainWindow(appEl) else { log("no window"); exit(1) }
    guard let table = ensurePlayingNextOpen(win) else { log("no table"); exit(1) }

    var observer: AXObserver?
    let err = AXObserverCreate(app.processIdentifier, axObserverCallback, &observer)
    guard err == .success, let obs = observer else { log("AXObserverCreate failed: \(err.rawValue)"); exit(1) }
    let box = ObserverBox()
    box.observer = obs
    let refcon = Unmanaged.passUnretained(box).toOpaque()

    let windowAppNotes = [
        kAXLayoutChangedNotification,
        kAXCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXValueChangedNotification,
        kAXRowCountChangedNotification,
        kAXFocusedUIElementChangedNotification
    ]
    for note in windowAppNotes {
        let ew = AXObserverAddNotification(obs, win, note as CFString, refcon)
        log("add \(note) on WINDOW -> err=\(ew.rawValue)")
        let ea = AXObserverAddNotification(obs, appEl, note as CFString, refcon)
        log("add \(note) on APPLICATION -> err=\(ea.rawValue)")
    }
    let tableNotes = [kAXRowCountChangedNotification, kAXSelectedRowsChangedNotification]
    for note in tableNotes {
        let et = AXObserverAddNotification(obs, table, note as CFString, refcon)
        log("add \(note) on TABLE -> err=\(et.rawValue)")
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
    log("observing for 25s; triggers: t=3 next track, t=10 shuffle toggle, t=17 next track")
    let start = now()
    var fired3 = false, fired10 = false, fired17 = false
    let deadline = Date().addingTimeInterval(25)
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.1, true)
        let t = now() - start
        if t > 3 && !fired3 {
            fired3 = true
            let t0 = now()
            _ = runOsascript("tell application \"Music\" to next track")
            log("[trigger] t=3 next track issued at \(t0)")
        }
        if t > 10 && !fired10 {
            fired10 = true
            let t0 = now()
            _ = runOsascript("tell application \"Music\" to set shuffle enabled to not shuffle enabled")
            log("[trigger] t=10 shuffle toggle issued at \(t0)")
        }
        if t > 17 && !fired17 {
            fired17 = true
            let t0 = now()
            _ = runOsascript("tell application \"Music\" to next track")
            log("[trigger] t=17 next track issued at \(t0)")
        }
    }
    log("observation window done. callback count = \(box.callbackTimes.count)")
    for (k, v) in box.callbackTimes { log("  fired: \(k) at \(v)") }
}

func cmdObserveClosedThenOpen() {
    guard let app = musicApp() else { log("Music not running"); exit(1) }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    guard let win = mainWindow(appEl) else { log("no window"); exit(1) }

    // ensure panel closed first
    if let t = getPlayingNextTable(win), let rows = axCopyAttr(t, kAXRowsAttribute as String) as? [AXUIElement], rows.count > 1 {
        if let cb = findPlayingNextCheckbox(win) {
            _ = AXUIElementPerformAction(cb, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.6)
        }
    }
    log("panel should be closed now; tables=\(findAllTables(win).count)")

    var observer: AXObserver?
    let err = AXObserverCreate(app.processIdentifier, axObserverCallback, &observer)
    guard err == .success, let obs = observer else { log("AXObserverCreate failed: \(err.rawValue)"); exit(1) }
    let box = ObserverBox()
    box.observer = obs
    let refcon = Unmanaged.passUnretained(box).toOpaque()
    let e1 = AXObserverAddNotification(obs, win, kAXCreatedNotification as CFString, refcon)
    log("add kAXCreatedNotification on WINDOW -> err=\(e1.rawValue)")
    let e2 = AXObserverAddNotification(obs, appEl, kAXCreatedNotification as CFString, refcon)
    log("add kAXCreatedNotification on APPLICATION -> err=\(e2.rawValue)")
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)

    log("will reopen panel at t=3s, observing 10s total")
    let start = now()
    var fired = false
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.1, true)
        let t = now() - start
        if t > 3 && !fired {
            fired = true
            if let cb = findPlayingNextCheckbox(win) {
                _ = AXUIElementPerformAction(cb, kAXPressAction as CFString)
                log("[trigger] pressed checkbox to reopen panel at \(now())")
            }
        }
    }
    log("done. callback count = \(box.callbackTimes.count)")
    for (k, v) in box.callbackTimes { log("  fired: \(k) at \(v)") }
}
