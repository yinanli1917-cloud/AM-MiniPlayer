import CoreAudio
import XCTest
@testable import MusicMiniPlayerCore

final class AudioOutputDeviceSymbolTests: XCTestCase {
    func testDeviceNamesUseHardwareSpecificSymbolsBeforeGenericTransportFallbacks() {
        XCTAssertEqual(symbol(for: "Yinan's AirPods Pro", transportType: 0), "airpodspro")
        XCTAssertEqual(symbol(for: "EarPods", transportType: 0), "earpods")
        XCTAssertEqual(symbol(for: "Mac Studio Speakers", transportType: kAudioDeviceTransportTypeBuiltIn), "macstudio")
        XCTAssertEqual(symbol(for: "DELL S2725QC", transportType: 0), "display")
        XCTAssertEqual(symbol(for: "Living Room Apple TV", transportType: 0), "appletv")
    }

    func testTransportTypesUseControlCenterLikeFallbackSymbols() {
        XCTAssertEqual(symbol(for: "USB-C Monitor", transportType: kAudioDeviceTransportTypeDisplayPort), "display")
        XCTAssertEqual(symbol(for: "Wireless Headset", transportType: kAudioDeviceTransportTypeBluetooth), "headphones")
        XCTAssertEqual(symbol(for: "Built-in Output", transportType: kAudioDeviceTransportTypeBuiltIn), "hifispeaker")
        XCTAssertEqual(symbol(for: "HomePod", transportType: kAudioDeviceTransportTypeAirPlay), "homepod")
        XCTAssertEqual(symbol(for: "Scarlett 2i2 USB", transportType: kAudioDeviceTransportTypeUSB), "audio.jack.stereo")
        XCTAssertEqual(symbol(for: "Thunderbolt Dock", transportType: kAudioDeviceTransportTypeThunderbolt), "cable.connector")
        XCTAssertEqual(symbol(for: "Omi Recorder Aggregate Input Device", transportType: kAudioDeviceTransportTypeAggregate), "speaker.wave.2")
        XCTAssertEqual(symbol(for: "ZoomAudioDevice", transportType: kAudioDeviceTransportTypeVirtual), "speaker.wave.2")
        XCTAssertEqual(symbol(for: "Multi-Output Device", transportType: kAudioDeviceTransportTypeAutoAggregate), "hifispeaker.2")
    }

    func testDefaultOutputVerificationRequiresExactDeviceMatch() {
        XCTAssertTrue(AudioOutputDeviceService.defaultOutputMatches(
            targetDeviceID: AudioDeviceID(42),
            outputDeviceID: AudioDeviceID(42)
        ))
        XCTAssertFalse(AudioOutputDeviceService.defaultOutputMatches(
            targetDeviceID: AudioDeviceID(42),
            outputDeviceID: AudioDeviceID(7)
        ))
        XCTAssertFalse(AudioOutputDeviceService.defaultOutputMatches(
            targetDeviceID: AudioDeviceID(42),
            outputDeviceID: nil
        ))
    }

    private func symbol(for name: String, transportType: UInt32) -> String {
        AudioOutputDevice(
            id: AudioDeviceID(1),
            uid: name,
            name: name,
            transportType: transportType,
            isDefault: false,
            isAvailable: true
        ).symbolName
    }
}
