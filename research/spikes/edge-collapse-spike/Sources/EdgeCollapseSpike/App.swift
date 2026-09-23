/**
 * [INPUT]: None — process entry point.
 * [OUTPUT]: @main EdgeCollapseSpikeApp — boots NSApplication, the edge panel,
 *           and the control window (wired up in later steps of this file).
 * [POS]: Standalone spike entry point. NOT app-portable (this file is the
 *        spike harness itself, unlike the other files in this target).
 * [PROTOCOL]: Keep this file thin — wiring only, no logic that belongs in the
 *             portable files (Tokens/Reducer/ClockScheduler/Shape).
 */

import AppKit

@main
enum EdgeCollapseSpikeApp {
    static func main() {
        // Unbuffered stdout so `[EdgeCollapse] ...` log lines (design §9)
        // stream live instead of sitting in a full-buffer until exit —
        // matters when this binary is launched with stdout redirected to a
        // file/pipe (not a TTY), which is exactly how a founder or a CI
        // check would capture it.
        setvbuf(stdout, nil, _IONBF, 0)
        // Before anything builds a URLSession (HTTPClient's is a lazy static).
        SpikeNetworkBlock.install()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = SpikeAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
