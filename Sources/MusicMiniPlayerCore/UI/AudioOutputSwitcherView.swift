import CoreAudio
import SwiftUI

struct AudioOutputSwitcherView: View {
    var artworkBrightness: CGFloat = 0.5
    var isAlbumPage: Bool = false
    var onMenuPresentedChanged: ((Bool) -> Void)?

    @StateObject private var outputService = AudioOutputDeviceService.shared
    @State private var isMenuPresented = false
    @State private var failedDeviceID: AudioDeviceID?
    @State private var isTriggerHovering = false
    @State private var isTriggerPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentDeviceName: String {
        outputService.devices.first(where: \.isDefault)?.name ?? "No output selected"
    }

    var body: some View {
        Button(action: triggerMenu) {
            Image(systemName: "airplayaudio")
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .scaleEffect(triggerIconScale)
                .opacity(isMenuPresented ? 1 : 0.94)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
                .modifier(GlassButtonBackground(luminance: artworkBrightness))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isTriggerHovering = hovering
            } else {
                withAnimation(.smooth(duration: 0.16)) {
                    isTriggerHovering = hovering
                }
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.24, dampingFraction: 0.72), value: isTriggerPressed)
        .animation(reduceMotion ? .linear(duration: 0.1) : .smooth(duration: 0.18), value: isTriggerHovering)
        .animation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.28, dampingFraction: 0.78), value: isMenuPresented)
        .help("Switch audio output")
        .accessibilityLabel("Switch audio output")
        .accessibilityValue(currentDeviceName)
        .popover(isPresented: $isMenuPresented, arrowEdge: .top) {
            AudioOutputDeviceMenuContent(
                outputService: outputService,
                isPresented: $isMenuPresented,
                failedDeviceID: $failedDeviceID
            )
        }
        .onChange(of: outputService.defaultDeviceID) { _, _ in
            failedDeviceID = nil
        }
        .onChange(of: isMenuPresented) { _, presented in
            onMenuPresentedChanged?(presented)
        }
        .onDisappear {
            onMenuPresentedChanged?(false)
        }
    }

    private var triggerIconScale: CGFloat {
        if isTriggerPressed { return 0.88 }
        if isMenuPresented { return 1.08 }
        if isTriggerHovering { return 1.04 }
        return 1.0
    }

    private func triggerMenu() {
        if !reduceMotion {
            withAnimation(.spring(response: 0.12, dampingFraction: 0.82)) {
                isTriggerPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.7)) {
                    isTriggerPressed = false
                }
            }
        }
        toggleMenu()
    }

    private func toggleMenu() {
        outputService.clearError()
        outputService.refresh()
        failedDeviceID = nil

        if reduceMotion {
            isMenuPresented.toggle()
        } else {
            withAnimation(.smooth(duration: 0.18)) {
                isMenuPresented.toggle()
            }
        }
    }
}

private struct AudioOutputDeviceMenuContent: View {
    @ObservedObject var outputService: AudioOutputDeviceService
    @Binding var isPresented: Bool
    @Binding var failedDeviceID: AudioDeviceID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if outputService.devices.isEmpty {
                unavailableRow
            } else {
                ForEach(outputService.devices) { device in
                    Button {
                        select(device)
                    } label: {
                        AudioOutputDeviceRow(
                            device: device,
                            hasError: failedDeviceID == device.id
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!device.canSelect)
                }
            }

            if let error = outputService.lastErrorMessage {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 3)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(width: 252, alignment: .leading)
        .modifier(AudioOutputMenuSurface())
        .modifier(ConditionalGlassContainer())
        .onAppear {
            outputService.refresh()
        }
    }

    private var unavailableRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18)
            Text("No output devices found")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 34, alignment: .leading)
    }

    private func select(_ device: AudioOutputDevice) {
        outputService.clearError()

        guard outputService.select(device) else {
            failedDeviceID = device.id
            return
        }

        failedDeviceID = nil
        if reduceMotion {
            isPresented = false
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.smooth(duration: 0.16)) {
                    isPresented = false
                }
            }
        }
    }
}

private struct AudioOutputMenuSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        if #available(macOS 26.0, *) {
            content
                .background {
                    shape.fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
                }
                .overlay {
                    shape.fill(surfaceTint)
                }
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.14), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.18), radius: 18, x: 0, y: 12)
                .glassEffect(reduceTransparency ? .identity : .regular, in: shape)
        } else {
            content
                .background {
                    shape.fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
                }
                .overlay {
                    shape.fill(surfaceTint)
                }
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.14), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.18), radius: 18, x: 0, y: 12)
        }
    }

    private var surfaceTint: Color {
        if reduceTransparency {
            return Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.02)
        }
        return colorScheme == .dark ? Color.black.opacity(0.08) : Color.white.opacity(0.16)
    }
}

private struct AudioOutputDeviceRow: View {
    let device: AudioOutputDevice
    let hasError: Bool

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            iconBadge

            Text(device.name)
                .font(.system(size: 12.5, weight: device.isDefault ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if device.isDefault {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.orange)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .foregroundStyle(rowForeground)
        .padding(.horizontal, 7)
        .frame(height: 35)
        .background(rowBackground)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(device.canSelect ? 1 : 0.45)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.smooth(duration: 0.14)) {
                    isHovering = hovering
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(device.name)
        .accessibilityValue(device.isDefault ? "Current output" : "")
        .accessibilityAddTraits(device.isDefault ? [.isSelected] : [])
    }

    private var iconBadge: some View {
        Image(systemName: device.symbolName)
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconForeground)
            .frame(width: 23, height: 23)
            .background(iconBackground)
    }

    private var iconBackground: some View {
        Circle()
            .fill(iconFill)
            .overlay {
                Circle()
                    .strokeBorder(Color.primary.opacity(device.isDefault ? 0.12 : 0.08), lineWidth: 0.5)
            }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(backgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: device.isDefault || isHovering ? 0.75 : 0)
            }
    }

    private var backgroundColor: Color {
        if device.isDefault {
            return colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.10)
        }
        if isHovering {
            return colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.075)
        }
        return Color.clear
    }

    private var borderColor: Color {
        if device.isDefault {
            return Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.16)
        }
        if isHovering {
            return Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }
        return Color.clear
    }

    private var rowForeground: Color {
        device.canSelect ? .primary : .secondary
    }

    private var iconForeground: Color {
        if hasError { return .orange }
        if device.isDefault { return .accentColor }
        return device.canSelect ? .primary : .secondary
    }

    private var iconFill: Color {
        if device.isDefault {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.16)
        }
        if isHovering {
            return Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.08)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055)
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
