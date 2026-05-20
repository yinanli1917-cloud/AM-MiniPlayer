import Combine
import CoreAudio
import Foundation

public struct AudioOutputDevice: Identifiable, Equatable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transportType: UInt32
    public let isDefault: Bool
    public let isAvailable: Bool

    public var canSelect: Bool { isAvailable }
}

@MainActor
public final class AudioOutputDeviceService: ObservableObject {
    public static let shared = AudioOutputDeviceService()

    @Published public private(set) var devices: [AudioOutputDevice] = []
    @Published public private(set) var defaultDeviceID: AudioDeviceID?
    @Published public private(set) var lastErrorMessage: String?

    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?

    private init() {
        refresh()
        installListeners()
    }

    public func refresh() {
        let defaultID = Self.readDefaultOutputDeviceID()
        defaultDeviceID = defaultID
        devices = Self.readOutputDevices(defaultDeviceID: defaultID)
    }

    @discardableResult
    public func select(_ device: AudioOutputDevice) -> Bool {
        guard device.canSelect else {
            lastErrorMessage = "This output is unavailable."
            refresh()
            return false
        }

        let outputStatus = Self.setDefaultDevice(
            device.id,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )

        guard outputStatus == noErr else {
            lastErrorMessage = Self.statusMessage("Could not switch audio output", status: outputStatus)
            refresh()
            return false
        }

        _ = Self.setDefaultDevice(
            device.id,
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice
        )

        lastErrorMessage = nil
        refresh()
        return true
    }

    public func clearError() {
        lastErrorMessage = nil
    }

    private func installListeners() {
        let refreshBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        var devicesAddress = Self.systemAddress(kAudioHardwarePropertyDevices)
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            refreshBlock
        ) == noErr {
            devicesListener = refreshBlock
        }

        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        var defaultAddress = Self.systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main,
            defaultBlock
        ) == noErr {
            defaultOutputListener = defaultBlock
        }
    }

    private nonisolated static func readOutputDevices(defaultDeviceID: AudioDeviceID?) -> [AudioOutputDevice] {
        var address = systemAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }

        return ids
            .filter { hasOutputStreams(deviceID: $0) }
            .compactMap { deviceID in
                guard let name = propertyString(deviceID: deviceID, selector: kAudioObjectPropertyName) else {
                    return nil
                }
                return AudioOutputDevice(
                    id: deviceID,
                    uid: propertyString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "\(deviceID)",
                    name: name,
                    transportType: propertyUInt32(deviceID: deviceID, selector: kAudioDevicePropertyTransportType),
                    isDefault: deviceID == defaultDeviceID,
                    isAvailable: propertyUInt32(deviceID: deviceID, selector: kAudioDevicePropertyDeviceIsAlive) != 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private nonisolated static func readDefaultOutputDeviceID() -> AudioDeviceID? {
        var address = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private nonisolated static func setDefaultDevice(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> OSStatus {
        var address = systemAddress(selector)
        var mutableID = deviceID
        var settable: DarwinBoolean = false

        let settableStatus = AudioObjectIsPropertySettable(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            &settable
        )
        guard settableStatus == noErr, settable.boolValue else {
            return settableStatus == noErr ? kAudioHardwareUnsupportedOperationError : settableStatus
        }

        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableID
        )
    }

    private nonisolated static func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }

        return UnsafeMutableAudioBufferListPointer(bufferList)
            .contains { $0.mNumberChannels > 0 }
    }

    private nonisolated static func propertyString(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let valuePointer = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        valuePointer.initialize(to: nil)
        defer {
            valuePointer.deinitialize(count: 1)
            valuePointer.deallocate()
        }
        var size = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, valuePointer)
        guard status == noErr, let value = valuePointer.pointee else { return nil }

        let string = value as String
        return string.isEmpty ? nil : string
    }

    private nonisolated static func propertyUInt32(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    private nonisolated static func systemAddress(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private nonisolated static func statusMessage(_ prefix: String, status: OSStatus) -> String {
        _ = status
        return "\(prefix)."
    }
}
