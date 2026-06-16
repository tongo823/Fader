import Foundation
import AudioToolbox
import CoreAudio
import Darwin

// Minimal Core Audio property helpers, adapted from the technique used in
// insidegui/AudioCap.

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown
    var isUnknown: Bool { self == .unknown }
    var isValid: Bool { !isUnknown }

    // Generic property read.
    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 defaultValue: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw "data size read failed for \(selector.fourCC): \(err)" }
        var value = defaultValue
        err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, $0)
        }
        guard err == noErr else { throw "data read failed for \(selector.fourCC): \(err)" }
        return value
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        try read(selector, defaultValue: "" as CFString) as String
    }

    func readBool(_ selector: AudioObjectPropertySelector) -> Bool {
        let v: UInt32 = (try? read(selector, defaultValue: 0)) ?? 0
        return v == 1
    }

    // System-object level reads.
    static func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(.system, &address, 0, nil, &dataSize)
        guard err == noErr else { throw "process list size read failed: \(err)" }
        var value = [AudioObjectID](repeating: .unknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(.system, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { throw "process list read failed: \(err)" }
        return value
    }

    static func readDefaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, defaultValue: AudioDeviceID.unknown)
    }

    /// Reads `kAudioHardwarePropertyDevices` (all audio devices on the system).
    func readDeviceList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw "device list size read failed: \(err)" }
        var value = [AudioObjectID](repeating: .unknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { throw "device list read failed: \(err)" }
        return value
    }

    // Per-object reads.
    func readPID() -> pid_t { (try? read(kAudioProcessPropertyPID, defaultValue: pid_t(-1))) ?? -1 }
    func readBundleID() -> String? {
        guard let s = try? readString(kAudioProcessPropertyBundleID), !s.isEmpty else { return nil }
        return s
    }
    func readIsRunningOutput() -> Bool { readBool(kAudioProcessPropertyIsRunningOutput) }
    func readDeviceUID() throws -> String { try readString(kAudioDevicePropertyDeviceUID) }
    func readTapStreamFormat() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }
}

extension AudioObjectPropertySelector {
    var fourCC: String {
        let v = self
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }
}
