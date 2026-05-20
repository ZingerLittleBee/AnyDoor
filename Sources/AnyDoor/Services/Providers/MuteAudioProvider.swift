import CoreAudio
import Foundation

/// Toggle the system default output device's mute property.
///
/// Reads `kAudioDevicePropertyMute` on the default output device. Listens to
/// `kAudioHardwarePropertyDefaultOutputDevice` so we resubscribe when the user
/// switches outputs (e.g. AirPods connect/disconnect).
actor MuteAudioProvider: ToggleProvider {
    let itemKey: BuiltinItem = .muteAudio
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        let deviceID = try currentOutputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
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
        let deviceID = try currentOutputDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        guard status == noErr else {
            throw BuiltinError.ioKitFailed(status)
        }
    }

    private func currentOutputDevice() throws -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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
