import CoreAudio
import Foundation

/// Toggle the system default input device's mute property.
///
/// Mirrors `MuteAudioProvider` but acts on the default **input** device with
/// `kAudioDevicePropertyScopeInput`, so it works across any conferencing app —
/// macOS has no built-in system-level microphone-mute hotkey.
actor MicrophoneMuteProvider: ToggleProvider {
    let itemKey: BuiltinItem = .microphoneMute
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        let deviceID = try currentInputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
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
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        guard status == noErr else {
            throw BuiltinError.ioKitFailed(status)
        }
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
