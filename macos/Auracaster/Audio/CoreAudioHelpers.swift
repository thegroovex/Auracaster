import CoreAudio
import Foundation

/// Small, typed wrappers around the AudioObject property C API.
enum CoreAudioHelpers {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size POD property.
    static func value<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) throws -> T {
        var addr = Self.address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        try checkCA(status, "AudioObjectGetPropertyData(\(selector))")
        return value
    }

    /// Reads a CFString property (name, UID, …).
    static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        var addr = Self.address(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try checkCA(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value),
                    "AudioObjectGetPropertyData(string \(selector))")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    static func defaultSystemOutputDevice() throws -> AudioDeviceID {
        let device = try value(systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice,
                               initial: AudioDeviceID(kAudioObjectUnknown))
        guard device != AudioDeviceID(kAudioObjectUnknown) else { throw AudioCaptureError.noOutputDevice }
        return device
    }

    /// Translates a PID to its Core Audio process object (macOS 14.2+).
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var addr = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkCA(
            AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
            "TranslatePIDToProcessObject"
        )
        guard object != AudioObjectID(kAudioObjectUnknown) else { throw AudioCaptureError.processNotFound(pid) }
        return object
    }

    static func allDevices() throws -> [AudioDeviceID] {
        var addr = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try checkCA(AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size), "Devices size")
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        try checkCA(AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &devices), "Devices")
        return devices
    }

    static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var addr = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
        return status == noErr && size > 0
    }

    /// Input-capable hardware devices (microphones, interfaces), skipping
    /// private aggregate devices such as our own tap aggregate.
    static func inputDevices() -> [(id: AudioDeviceID, uid: String, name: String)] {
        guard let devices = try? allDevices() else { return [] }
        return devices.compactMap { device in
            guard hasInputStreams(device),
                  let uid = try? string(device, kAudioDevicePropertyDeviceUID),
                  let name = try? string(device, kAudioObjectPropertyName),
                  !uid.hasPrefix("de.groovex.auracaster")
            else { return nil }
            return (id: device, uid: uid, name: name)
        }
    }

    static func device(withUID uid: String) -> AudioDeviceID? {
        guard let devices = try? allDevices() else { return nil }
        return devices.first { (try? string($0, kAudioDevicePropertyDeviceUID)) == uid }
    }
}
