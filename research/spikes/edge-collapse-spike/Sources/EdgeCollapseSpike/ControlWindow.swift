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
            Section("State") {
                LabeledContent("presentation") {
                    Text(model.presentation.rawValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("track") {
                    Text(model.trackTitle)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Actions") {
                HStack(spacing: 10) {
                    Button("Collapse") { model.requestCollapse() }
                        .disabled(model.presentation != .card)
                    Button("Expand") { model.requestExpand() }
                        .disabled(model.presentation != .tucked && model.presentation != .floating)
                    Button("Next track") { model.nextTrack() }
                }
                Text("Two-finger swipe right on the panel = tuck into the edge. Hover the edge strip = capsule with cover, title, pause, next. Click the capsule or the strip = back to the panel.")
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
                Text("Collapse only. Bouncy: the strip tucks past the edge and pops back out. Settle: no rebound.")
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
