import Foundation
import CoreAudio
import AudioToolbox

/// Reads how loud the Mac is actually playing.
///
/// A Core Audio process tap captures the application's stream, not the output
/// after the volume fader: measured on this machine, dropping the system volume
/// from 70 to 25 moved the captured level from 0.96 to 0.86. So the analyser on
/// its own cannot tell blasting music from the same track at a whisper, and the
/// visualiser has to combine the two.
///
/// Deliberately a *reader* rather than a monitor: no property listeners, no
/// state to keep in step. The value is wanted at a few frames per second, and
/// each read is a couple of microseconds of Core Audio.
public struct OutputVolumeReader: Sendable {

    public init() {}

    /// Output volume, 0...1, or `nil` when the device exposes no volume control
    /// — some HDMI and aggregate devices do not — in which case the caller
    /// should assume full rather than silent.
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

    /// Tries the main element, then averages the stereo pair.
    ///
    /// Plenty of devices expose per-channel volume and nothing on the main
    /// element — AirPods among them — and reading only the main element reports
    /// those as having no volume at all.
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
