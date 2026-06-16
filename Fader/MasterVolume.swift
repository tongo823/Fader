import Foundation
import CoreAudio
import AudioToolbox

// Read/write the system default output device's master volume, so Fader can show
// a master slider above the per-app rows.
enum MasterVolume {
    private static var outputDevice: AudioDeviceID { (try? AudioObjectID.readDefaultOutputDevice()) ?? .unknown }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    static var isAvailable: Bool {
        var addr = volumeAddress()
        return AudioObjectHasProperty(outputDevice, &addr)
    }

    static func get() -> Float {
        let dev = outputDevice
        guard dev.isValid else { return 0 }
        var addr = volumeAddress()
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value)
        return err == noErr ? value : 0
    }

    static func set(_ value: Float) {
        let dev = outputDevice
        guard dev.isValid else { return }
        var addr = volumeAddress()
        var v = Float32(max(0, min(1, value)))
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}
