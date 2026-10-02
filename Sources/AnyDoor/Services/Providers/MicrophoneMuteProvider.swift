import CoreAudio
import Foundation
import PluginInterface

/// Toggle the system default input device's mute property.
///
/// Mirrors `MuteAudioProvider` but acts on the default **input** device with
/// `kAudioDevicePropertyScopeInput`. Not every input device exposes a settable
/// mute (built-in mics and AirPods commonly don't), so `setState` prechecks
/// `AudioObjectIsPropertySettable` and throws `BuiltinError.muteUnsupported`
/// rather than silently no-op-ing; `PanelStore` shows the "can't be muted"
/// notice for that error (`CommandFailure`).
actor MicrophoneMuteProvider: ToggleProvider {
    let itemKey: BuiltinItem = .microphoneMute
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        let deviceID = try currentInputDevice()
        var address = muteAddress
        // When the device has no mute property at all, report "not muted", so
        // the row renders off and a toggle reaches setState's settable
        // precheck, whose `muteUnsupported` gets the specific notice.
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else {
            throw BuiltinError.ioKitFailed(status)
        }
        return muted != 0
    }

    func setState(_ mute: Bool) async throws {
        let deviceID = try currentInputDevice()
        var address = muteAddress

        // Capability precheck: an active toggle on a device with no settable
        // mute should tell the user, not fail invisibly. Throwing here keeps
        // PanelStore from optimistically flipping the row's cached state and
        // makes it show the "can't be muted" notice, the only one this
        // failure gets.
        var settable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        guard settableStatus == noErr, settable.boolValue else {
            throw BuiltinError.muteUnsupported
        }

        var value: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        guard status == noErr else {
            throw BuiltinError.ioKitFailed(status)
        }
    }

    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func currentInputDevice() throws -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw BuiltinError.audioDeviceUnavailable
        }
        return deviceID
    }
}
