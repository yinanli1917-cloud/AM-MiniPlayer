/**
 * [INPUT]: NSApplication lifecycle notifications, DistributedNotificationCenter
 *          "collapse"/"expand" pokes (probe automation, top-level task
 *          instruction #7).
 * [OUTPUT]: SpikeAppDelegate — creates the EdgeCollapseAppModel, the fixed
 *           320×360 edge panel (right-edge pinned, vertically centered), and
 *           the ordinary control window; wires the two-finger-scroll gesture,
 *           hover tracking, and hit-region into the model.
 * [POS]: Standalone spike entry-point wiring (see also App.swift).
 * [PROTOCOL]: Keep this file to wiring only.
 */

import AppKit
import SwiftUI
import MusicMiniPlayerCore

/// Distributed-notification names `probe.sh` posts (via `NSDistributedNotificationCenter`,
/// public API) to drive a collapse/expand round-trip without a screen —
/// top-level task instruction #7's "pick one, document" (Distributed
/// Notification chosen over a `nanopodspike://` URL scheme: this binary is a
/// bare SwiftPM executable, not an app-bundle with a registered
/// `CFBundleURLTypes`, so a custom URL scheme would need extra bundling
/// machinery a throwaway spike doesn't warrant). `probe.sh` posts via a
/// tiny ad-hoc `swift <script>.swift` process using the exact same API —
/// an `osascript -l JavaScript` ObjC-bridge poster was tried first and its
/// call reported success but silently never delivered, confirmed by an A/B
/// against the plain-Swift poster, so probe.sh uses the one that verifiably
/// works.
enum EdgeCollapseProbeNotification {
    static let collapse = Notification.Name("com.nanopod.edgeCollapseSpike.collapse")
    static let expand = Notification.Name("com.nanopod.edgeCollapseSpike.expand")
    static let hover = Notification.Name("com.nanopod.edgeCollapseSpike.hover")
    static let unhover = Notification.Name("com.nanopod.edgeCollapseSpike.unhover")
    static let variant = Notification.Name("com.nanopod.edgeCollapseSpike.variant")
}

@MainActor
final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    let model = EdgeCollapseAppModel()
    var panel: EdgeCollapsePanel?
    var controlWindow: NSWindow?
    var hostingView: EdgeGestureHostingView<RootContentView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable the app's old C1 EdgeMorphHost inside the hosted MiniPlayerView.
        UserDefaults.standard.set("v0", forKey: MicroInteractionFeel.edgeMorphDefaultsKey)
        _ = MusicController.shared
        print("[EdgeCollapse] launch pid=\(ProcessInfo.processInfo.processIdentifier) probe=\(EdgeCollapseProbe.isActive)")

        let panel = makeEdgeCollapsePanel()
        let hostingView = EdgeGestureHostingView(rootView: RootContentView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: EdgeCollapseTokens.containerSize)
        hostingView.onHorizontalSwipeToEdge = { [weak model] in
            model?.requestCollapse(edge: .right)
        }
        hostingView.onHoverChange = { [weak model] hovering in
            guard let model else { return }
            if hovering {
                model.requestHoverEnter()
            } else {
                model.requestHoverExit()
            }
        }
        hostingView.activeHitRegionProvider = { [weak model] in
            model?.activeHitRegion() ?? .zero
        }
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        print("[EdgeCollapse] frame=\(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y)),\(Int(panel.frame.width)),\(Int(panel.frame.height)) state=card")

        model.hostingView = hostingView
        self.panel = panel
        self.hostingView = hostingView
        hostingView.refreshHitRegion()

        let controlWindow = makeControlWindow(model: model)
        controlWindow.makeKeyAndOrderFront(nil)
        self.controlWindow = controlWindow

        DistributedNotificationCenter.default().addObserver(
            forName: EdgeCollapseProbeNotification.collapse, object: nil, queue: .main
        ) { [weak model] _ in
            Task { @MainActor in model?.requestCollapse(edge: .right) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: EdgeCollapseProbeNotification.expand, object: nil, queue: .main
        ) { [weak model] _ in
            Task { @MainActor in model?.requestExpand() }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: EdgeCollapseProbeNotification.hover, object: nil, queue: .main
        ) { [weak model] _ in
            Task { @MainActor in model?.requestHoverEnter() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: EdgeCollapseProbeNotification.unhover, object: nil, queue: .main
        ) { [weak model] _ in
            Task { @MainActor in model?.requestHoverExit() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: EdgeCollapseProbeNotification.variant, object: nil, queue: .main
        ) { [weak model] note in
            Task { @MainActor in
                guard let model else { return }
                model.variant = (note.object as? String) == "v" ? .v : .h
                model.hostingView?.refreshHitRegion()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
