import Foundation
import CoreAudio
import AudioToolbox

/// Read system output volume separately. The process tap captures audio before the fader,
/// so the spectrum alone doesn't tell us whether the Mac is muted.
public struct OutputVolumeReader: Sendable {

    public init() {}

    /// Read output volume from 0 to 1. A device without a volume control returns nil; that
    /// does not mean mute.
    public func current() -> Double? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        if Self.isMuted(device: device) { return 0 }
        return Self.scalarVolume(device: device)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Try the main volume control, then the stereo channels. Some devices only expose
    /// channel volume.
    static func scalarVolume(device: AudioDeviceID) -> Double? {
        if let main = scalar(device: device, element: kAudioObjectPropertyElementMain) {
            return main
        }
        let left = scalar(device: device, element: 1)
        let right = scalar(device: device, element: 2)
        switch (left, right) {
        case (let l?, let r?): return (l + r) / 2
        case (let l?, nil): return l
        case (nil, let r?): return r
        default: return nil
        }
    }

    private static func scalar(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return Double(value)
    }

    private static func isMuted(device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }
}
