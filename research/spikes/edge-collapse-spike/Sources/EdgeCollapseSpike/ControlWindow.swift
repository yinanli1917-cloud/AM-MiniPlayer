/**
 * [INPUT]: EdgeCollapseAppModel
 * [OUTPUT]: ControlPanelView (SwiftUI) + makeControlWindow(model:) — an
 *           ORDINARY titled NSWindow (not the floating panel) with the
 *           tint/bounce/tempo/reduceMotion switches, Collapse/
 *           Expand/Next-track buttons, and a live state label — top-level
 *           task instruction #6.
 * [POS]: Standalone spike control surface.
 * [PROTOCOL]: This window never drives EdgePresentation directly — every
 *             button calls an `EdgeCollapseAppModel.request*`/toggle method,
 *             same path as the panel's own gesture/hover/click handlers.
 */

import AppKit
import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var model: EdgeCollapseAppModel

    var body: some View {
        Form {
            Section("Actions") {
                HStack(spacing: 10) {
                    // No live state here: re-laying out this Form on every
                    // state change cost a ~23ms frame on the edge panel.
                    Button("Collapse") { model.requestCollapse() }
                    Button("Expand") { model.requestExpand() }
                    Button("Next track") { model.nextTrack() }
                }
                Text("Two-finger swipe right on the panel = tuck at once; swipe left on the capsule or the edge sliver = back to the panel at once. Rest the cursor on the edge sliver = a drop comes out and becomes the capsule. Click the capsule or the handle = back to the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Progress light") {
                Picker("Style", selection: $model.progressStyle) {
                    ForEach(EdgeCollapseProgressStyle.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
            }

            Section("Track change") {
                Toggle("Show the capsule on a track change", isOn: $model.autoPeekEnabled)
                Toggle("Player already notifies on song change (simulated)", isOn: $model.playerAlreadyNotifies)
                Button("Simulate a track change") { model.simulateTrackChange() }
                Text("There is no public API to read whether Music or Spotify posts song-change notifications, so the real app needs a setting; the second switch stands in for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Material") {
                Picker("Tint", selection: $model.tint) {
                    ForEach(EdgeCollapseTint.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
            }

            Section("Bounce / Tempo") {
                Picker("Bounce", selection: $model.bounce) {
                    ForEach(EdgeCollapseBounce.allCases) { b in Text(b.rawValue).tag(b) }
                }
                .pickerStyle(.segmented)
                Text("Collapse only. Bouncy: the handle overshoots into the edge and settles back. Settle: no rebound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Tempo", selection: $model.tempo) {
                    Text("1.0×").tag(EdgeCollapseTempo.normal)
                    Text("1.5×").tag(EdgeCollapseTempo.slow)
                }
                .pickerStyle(.segmented)
            }

            Section("Motion") {
                Toggle("Reduce Motion override", isOn: Binding(
                    get: { model.reduceMotionOverride ?? false },
                    set: { model.reduceMotionOverride = $0 ? true : nil }
                ))
                Text(model.reduceMotionOverride == nil
                     ? "following system Reduce Motion setting"
                     : "override: Reduce Motion forced ON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 480)
    }
}

func makeControlWindow(model: EdgeCollapseAppModel) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = "edge-collapse-spike controls"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: ControlPanelView(model: model))
    window.center()
    return window
}
