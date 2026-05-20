import CoreAudio
import SwiftUI

struct AudioOutputSwitcherView: View {
    var artworkBrightness: CGFloat = 0.5
    var isAlbumPage: Bool = false
    var onMenuPresentedChanged: ((Bool) -> Void)?

    @StateObject private var outputService = AudioOutputDeviceService.shared
    @Namespace private var glassNamespace
    @State private var isPanelPresented = false
    @State private var isTriggerHovering = false
    @State private var isTriggerPressed = false
    @State private var hoveredDeviceID: AudioDeviceID?
    @State private var failedDeviceID: AudioDeviceID?
    @State private var selectionPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if isPanelPresented {
                routePanel
                    .padding(.top, 37)
                    .padding(.trailing, 0)
                    .transition(panelTransition)
                    .zIndex(2)
            }

            triggerButton
                .zIndex(3)
        }
        .frame(width: isPanelPresented ? panelWidth : triggerSize, height: isPanelPresented ? panelHeight + 37 : triggerSize, alignment: .topTrailing)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if isPanelPresented {
                        dismissPanel()
                    }
                }
        )
        .modifier(AudioOutputGlassGroup(spacing: 10))
        .animation(panelAnimation, value: isPanelPresented)
        .animation(reduceMotion ? .linear(duration: 0.1) : .smooth(duration: 0.18), value: isTriggerHovering)
        .onExitCommand { dismissPanel() }
        .help("Switch audio output")
        .accessibilityLabel("Switch audio output")
        .accessibilityValue(currentDeviceName)
        .onAppear {
            outputService.refresh()
        }
        .onChange(of: outputService.defaultDeviceID) { _, _ in
            failedDeviceID = nil
            if isPanelPresented {
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.0 : 0.10)) {
                    dismissPanel()
                }
            }
        }
        .onChange(of: isPanelPresented) { _, presented in
            onMenuPresentedChanged?(presented)
            if presented {
                outputService.clearError()
                outputService.refresh()
            } else {
                hoveredDeviceID = nil
                failedDeviceID = nil
            }
        }
    }

    private var triggerButton: some View {
        Button {
            togglePanel()
        } label: {
            Image(systemName: currentSymbolName)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: selectionPulse)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .scaleEffect(triggerIconScale)
                .contentShape(Capsule())
                .modifier(GlassButtonBackground(luminance: artworkBrightness))
        }
        .buttonStyle(.plain)
        .modifier(AudioOutputNonDraggable())
        .onHover { hovering in
            updateTriggerHover(hovering)
            if hovering { outputService.refresh() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in setTriggerPressed(true) }
                .onEnded { _ in setTriggerPressed(false) }
        )
    }

    private var routePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(panelDevices) { device in
                routeRow(for: device)
            }

            if outputService.devices.isEmpty {
                emptyRouteRow
            }

            if let error = outputService.lastErrorMessage {
                Divider()
                    .opacity(0.35)
                    .padding(.top, 2)
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
            }
        }
        .padding(7)
        .frame(width: panelWidth, alignment: .leading)
        .modifier(AudioOutputNonDraggable())
        .modifier(AudioOutputPanelGlass(
            namespace: glassNamespace,
            reduceTransparency: reduceTransparency
        ))
    }

    private func routeRow(for device: AudioOutputDevice) -> some View {
        let isCurrent = device.isDefault
        let isHovering = hoveredDeviceID == device.id
        let hasError = failedDeviceID == device.id

        return Button {
            selectDevice(device)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(routeIconForeground(isCurrent: isCurrent, hasError: hasError))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(routeIconFill(isCurrent: isCurrent, isHovering: isHovering))
                    )

                Text(device.name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                } else if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.tint)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .foregroundStyle(device.canSelect ? rowForeground(isCurrent: isCurrent) : .secondary)
            .padding(.horizontal, 7)
            .frame(height: 32)
            .background(rowBackground(isCurrent: isCurrent, isHovering: isHovering))
            .scaleEffect(isHovering && !reduceMotion ? 1.015 : 1, anchor: .center)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!device.canSelect)
        .onHover { hovering in
            updateHoveredDevice(hovering ? device.id : nil)
        }
        .accessibilityLabel(device.name)
        .accessibilityValue(isCurrent ? "Current output" : "")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private var emptyRouteRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
            Text("No output devices found")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 32)
    }

    private var panelDevices: [AudioOutputDevice] {
        Array(outputService.devices.prefix(6))
    }

    private var currentDevice: AudioOutputDevice? {
        outputService.devices.first(where: \.isDefault)
    }

    private var currentDeviceName: String {
        currentDevice?.name ?? "No output selected"
    }

    private var currentSymbolName: String {
        currentDevice?.symbolName ?? (outputService.devices.isEmpty ? "speaker.slash" : "airplayaudio")
    }

    private var triggerSize: CGFloat { 32 }
    private var panelWidth: CGFloat { 214 }
    private var panelHeight: CGFloat {
        let rows = max(panelDevices.count, outputService.devices.isEmpty ? 1 : 0)
        let errorHeight: CGFloat = outputService.lastErrorMessage == nil ? 0 : 33
        return CGFloat(rows * 38) + 14 + errorHeight
    }

    private var triggerIconScale: CGFloat {
        if isTriggerPressed { return 0.88 }
        if selectionPulse { return 1.07 }
        if isPanelPresented { return 1.03 }
        if isTriggerHovering { return 1.05 }
        return 1.0
    }

    private var panelAnimation: Animation {
        reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.30, dampingFraction: 0.82)
    }

    private var panelTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .scale(scale: 0.78, anchor: .topTrailing).combined(with: .opacity),
            removal: .scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity)
        )
    }

    private func togglePanel() {
        if reduceMotion {
            isPanelPresented.toggle()
        } else {
            withAnimation(panelAnimation) {
                isPanelPresented.toggle()
            }
        }
    }

    private func dismissPanel() {
        if reduceMotion {
            isPanelPresented = false
        } else {
            withAnimation(.smooth(duration: 0.16)) {
                isPanelPresented = false
            }
        }
    }

    private func selectDevice(_ device: AudioOutputDevice) {
        if device.isDefault {
            dismissPanel()
            return
        }

        outputService.clearError()
        guard outputService.select(device) else {
            failedDeviceID = device.id
            return
        }

        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
            selectionPulse.toggle()
        }
    }

    private func updateTriggerHover(_ hovering: Bool) {
        if reduceMotion {
            isTriggerHovering = hovering
        } else {
            withAnimation(.smooth(duration: 0.16)) {
                isTriggerHovering = hovering
            }
        }
    }

    private func setTriggerPressed(_ pressed: Bool) {
        guard isTriggerPressed != pressed else { return }
        if reduceMotion {
            isTriggerPressed = pressed
        } else {
            withAnimation(.spring(response: pressed ? 0.10 : 0.22, dampingFraction: 0.74)) {
                isTriggerPressed = pressed
            }
        }
    }

    private func updateHoveredDevice(_ deviceID: AudioDeviceID?) {
        if reduceMotion {
            hoveredDeviceID = deviceID
        } else {
            withAnimation(.smooth(duration: 0.13)) {
                hoveredDeviceID = deviceID
            }
        }
    }

    private func rowForeground(isCurrent: Bool) -> Color {
        isCurrent ? .primary : .primary.opacity(colorScheme == .dark ? 0.88 : 0.82)
    }

    private func routeIconForeground(isCurrent: Bool, hasError: Bool) -> Color {
        if hasError { return .orange }
        return isCurrent ? .accentColor : .primary.opacity(colorScheme == .dark ? 0.86 : 0.72)
    }

    private func routeIconFill(isCurrent: Bool, isHovering: Bool) -> Color {
        if isCurrent { return Color.accentColor.opacity(0.16) }
        if isHovering { return Color.white.opacity(colorScheme == .dark ? 0.20 : 0.58) }
        return Color.white.opacity(colorScheme == .dark ? 0.10 : 0.34)
    }

    private func rowBackground(isCurrent: Bool, isHovering: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(rowFill(isCurrent: isCurrent, isHovering: isHovering))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(rowStroke(isCurrent: isCurrent, isHovering: isHovering), lineWidth: 0.6)
            )
    }

    private func rowFill(isCurrent: Bool, isHovering: Bool) -> Color {
        if isCurrent { return Color.white.opacity(colorScheme == .dark ? 0.22 : 0.50) }
        if isHovering { return Color.white.opacity(colorScheme == .dark ? 0.15 : 0.38) }
        return Color.clear
    }

    private func rowStroke(isCurrent: Bool, isHovering: Bool) -> Color {
        if isCurrent { return Color.white.opacity(colorScheme == .dark ? 0.22 : 0.66) }
        if isHovering { return Color.white.opacity(colorScheme == .dark ? 0.14 : 0.42) }
        return Color.clear
    }
}

private struct AudioOutputNonDraggable: ViewModifier {
    func body(content: Content) -> some View {
        content.background(AudioOutputNonDraggableRepresentable().frame(width: 0, height: 0))
    }
}

private struct AudioOutputNonDraggableRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("non-draggable")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct AudioOutputGlassGroup: ViewModifier {
    let spacing: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct AudioOutputPanelGlass: ViewModifier {
    let namespace: Namespace.ID
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        if #available(macOS 26.0, *) {
            content
                .background {
                    shape
                        .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.86)) : AnyShapeStyle(.regularMaterial))
                        .overlay(shape.fill(Color.white.opacity(reduceTransparency ? 0.10 : 0.16)))
                }
                .overlay {
                    shape.strokeBorder(Color.white.opacity(reduceTransparency ? 0.54 : 0.46), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(reduceTransparency ? 0.16 : 0.18), radius: 20, x: 0, y: 11)
                .glassEffect(reduceTransparency ? .identity : .regular, in: shape)
                .background {
                    clearBackplate(shape: shape)
                }
        } else {
            content
                .background {
                    shape
                        .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
                        .overlay(shape.fill(Color.white.opacity(0.18)))
                }
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.46), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 11)
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(shape.fill(Color.white.opacity(0.08)))
                }
        }
    }

    @available(macOS 26.0, *)
    private func clearBackplate(shape: RoundedRectangle) -> some View {
        shape
            .fill(Color.white.opacity(reduceTransparency ? 0 : 0.055))
            .glassEffect(reduceTransparency ? .identity : .clear, in: shape)
            .glassEffectID("audio-route-glass", in: namespace)
    }
}

extension AudioOutputDevice {
    var symbolName: String {
        let normalized = name.lowercased()

        switch transportType {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return displaySymbolName(normalized)
        case kAudioDeviceTransportTypeAirPlay:
            return airPlaySymbolName(normalized)
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return personalAudioSymbolName(normalized) ?? "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return builtInSymbolName(normalized)
        case kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeAVB:
            return interfaceSymbolName(normalized)
        case kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate,
             kAudioDeviceTransportTypeVirtual:
            return softwareRouteSymbolName(normalized)
        default:
            return namedFallbackSymbolName(normalized)
        }
    }

    private func namedFallbackSymbolName(_ normalized: String) -> String {
        if let personalSymbol = personalAudioSymbolName(normalized) {
            return personalSymbol
        }
        if isAirPlayName(normalized) {
            return airPlaySymbolName(normalized)
        }
        if isDisplayName(normalized) {
            return displaySymbolName(normalized)
        }
        if isBuiltInName(normalized) {
            return builtInSymbolName(normalized)
        }
        if isInterfaceName(normalized) {
            return interfaceSymbolName(normalized)
        }
        if isSoftwareRouteName(normalized) {
            return softwareRouteSymbolName(normalized)
        }
        return "speaker.wave.2"
    }

    private func personalAudioSymbolName(_ normalized: String) -> String? {
        if normalized.contains("airpods pro") { return "airpodspro" }
        if normalized.contains("airpods max") { return "airpodsmax" }
        if normalized.contains("airpods") { return "airpods" }
        if normalized.contains("earpods") { return "earpods" }
        if normalized.contains("beats") {
            return normalized.contains("ear") || normalized.contains("bud") ? "beats.earphones" : "beats.headphones"
        }
        if normalized.contains("earbuds") ||
            normalized.contains("ear buds") ||
            normalized.contains("buds") ||
            normalized.contains("earphones") ||
            normalized.contains("earpiece") {
            return "earbuds"
        }
        if normalized.contains("headphone") ||
            normalized.contains("headphones") ||
            normalized.contains("headset") ||
            normalized.contains("wh-") ||
            normalized.contains("wf-") {
            return "headphones"
        }
        return nil
    }

    private func airPlaySymbolName(_ normalized: String) -> String {
        if normalized.contains("homepod") { return "homepod" }
        if normalized.contains("apple tv") { return "appletv" }
        return "airplayaudio"
    }

    private func displaySymbolName(_ normalized: String) -> String {
        if normalized.contains("tv") || normalized.contains("projector") {
            return "tv"
        }
        return "display"
    }

    private func builtInSymbolName(_ normalized: String) -> String {
        if normalized.contains("mac studio") { return "macstudio" }
        if normalized.contains("mac mini") { return "macmini" }
        if normalized.contains("macbook") { return "laptopcomputer" }
        if normalized.contains("imac") { return "desktopcomputer" }
        return "hifispeaker"
    }

    private func interfaceSymbolName(_ normalized: String) -> String {
        if normalized.contains("dock") || normalized.contains("hub") {
            return "cable.connector"
        }
        if normalized.contains("thunderbolt") {
            return "bolt.horizontal"
        }
        return "audio.jack.stereo"
    }

    private func softwareRouteSymbolName(_ normalized: String) -> String {
        if normalized.contains("multi-output") || normalized.contains("multi output") {
            return "hifispeaker.2"
        }
        return "speaker.wave.2"
    }

    private func isAirPlayName(_ normalized: String) -> Bool {
        normalized.contains("airplay") ||
            normalized.contains("apple tv") ||
            normalized.contains("homepod") ||
            normalized.contains("airport express")
    }

    private func isDisplayName(_ normalized: String) -> Bool {
        normalized.contains("display") ||
            normalized.contains("monitor") ||
            normalized.contains("hdmi") ||
            normalized.contains("displayport") ||
            normalized.contains("dell") ||
            normalized.contains("lg ") ||
            normalized.contains("tv") ||
            normalized.contains("projector")
    }

    private func isBuiltInName(_ normalized: String) -> Bool {
        normalized.contains("built-in") ||
            normalized.contains("built in") ||
            normalized.contains("internal speaker") ||
            normalized.contains("mac studio") ||
            normalized.contains("mac mini") ||
            normalized.contains("macbook") ||
            normalized.contains("imac")
    }

    private func isInterfaceName(_ normalized: String) -> Bool {
        normalized.contains("usb") ||
            normalized.contains("dac") ||
            normalized.contains("interface") ||
            normalized.contains("focusrite") ||
            normalized.contains("scarlett") ||
            normalized.contains("apollo") ||
            normalized.contains("motu") ||
            normalized.contains("rme") ||
            normalized.contains("thunderbolt") ||
            normalized.contains("firewire") ||
            normalized.contains("dock")
    }

    private func isSoftwareRouteName(_ normalized: String) -> Bool {
        normalized.contains("aggregate") ||
            normalized.contains("multi-output") ||
            normalized.contains("multi output") ||
            normalized.contains("virtual") ||
            normalized.contains("blackhole") ||
            normalized.contains("soundflower") ||
            normalized.contains("loopback") ||
            normalized.contains("zoom") ||
            normalized.contains("omi recorder")
    }
}
