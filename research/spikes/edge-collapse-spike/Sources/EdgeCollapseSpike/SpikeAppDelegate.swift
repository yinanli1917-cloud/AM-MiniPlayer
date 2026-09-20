/**
 * [INPUT]: NSApplication lifecycle notifications.
 * [OUTPUT]: SpikeAppDelegate — creates the EdgeCollapseAppModel, the edge
 *           panel (docked right, vertically centered, card-sized to start),
 *           and the ordinary control window; wires the two-finger-scroll
 *           gesture into `model.requestCollapse()`.
 * [POS]: Standalone spike entry-point wiring (see also App.swift).
 * [PROTOCOL]: Keep this file to wiring only.
 */

import AppKit
import SwiftUI

@MainActor
final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    let model = EdgeCollapseAppModel()
    var panel: EdgeCollapsePanel?
    var controlWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[EdgeCollapse] launch pid=\(ProcessInfo.processInfo.processIdentifier)")

        let panel = makeEdgeCollapsePanel(initialContentSize: EdgeCollapseTokens.cardSize)
        let hostingView = EdgeGestureHostingView(rootView: RootContentView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: EdgeCollapseTokens.cardSize)
        hostingView.onHorizontalSwipeToEdge = { [weak model] in
            guard let model, model.presentation == .card else { return }
            model.requestCollapse(edge: .right)
        }
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        EdgeCollapseLog.frame(panel.frame, state: .card)

        model.panel = panel
        self.panel = panel

        let controlWindow = makeControlWindow(model: model)
        controlWindow.makeKeyAndOrderFront(nil)
        self.controlWindow = controlWindow

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
