import CoreAudio
import SwiftUI

struct AudioOutputSwitcherView: View {
    var artworkBrightness: CGFloat = 0.5
    var isAlbumPage: Bool = false
    var onMenuPresentedChanged: ((Bool) -> Void)?

    @StateObject private var outputService = AudioOutputDeviceService.shared
    @State private var isTriggerHovering = false
    @State private var selectionPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            menuContent
        } label: {
            triggerIcon
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isTriggerHovering = hovering
            } else {
                withAnimation(.smooth(duration: 0.16)) {
                    isTriggerHovering = hovering
                }
            }
            if hovering {
                outputService.refresh()
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.1) : .smooth(duration: 0.18), value: isTriggerHovering)
        .help("Switch audio output")
        .accessibilityLabel("Switch audio output")
        .accessibilityValue(currentDeviceName)
        .onAppear { outputService.refresh() }
        .onChange(of: outputService.defaultDeviceID) { _, _ in
            onMenuPresentedChanged?(false)
        }
    }

    private var triggerIcon: some View {
        Image(systemName: currentSymbolName)
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: selectionPulse)
            .scaleEffect(triggerIconScale)
            .opacity(isTriggerHovering ? 1 : 0.94)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
            .modifier(GlassButtonBackground(luminance: artworkBrightness))
    }

    @ViewBuilder
    private var menuContent: some View {
        if outputService.devices.isEmpty {
            Label("No output devices found", systemImage: "speaker.slash")
        } else {
            Picker("Sound Output", selection: selectedDeviceID) {
                ForEach(outputService.devices) { device in
                    Label(device.name, systemImage: device.symbolName)
                        .tag(device.id)
                        .disabled(!device.canSelect)
                }
            }
            .pickerStyle(.inline)
        }

        if let error = outputService.lastErrorMessage {
            Divider()
            Label(error, systemImage: "exclamationmark.triangle")
        }
    }

    private var selectedDeviceID: Binding<AudioDeviceID> {
        Binding(
            get: { outputService.defaultDeviceID ?? AudioDeviceID(0) },
            set: { selectDeviceID($0) }
        )
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

    private var triggerIconScale: CGFloat {
        if selectionPulse { return 1.08 }
        if isTriggerHovering { return 1.04 }
        return 1.0
    }

    private func selectDeviceID(_ deviceID: AudioDeviceID) {
        guard deviceID != outputService.defaultDeviceID else { return }
        guard let device = outputService.devices.first(where: { $0.id == deviceID }) else { return }

        outputService.clearError()
        guard outputService.select(device) else { return }

        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
            selectionPulse.toggle()
        }
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
