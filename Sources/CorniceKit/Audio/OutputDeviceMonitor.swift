import Foundation
import CoreAudio
import AudioToolbox

/// The Mac's current audio output.
public struct AudioOutputDevice: Equatable, Sendable {
    public let deviceID: AudioDeviceID
    public let name: String
    /// Core Audio's transport type, e.g. built-in, Bluetooth, USB, AirPlay.
    public let transport: Transport

    public enum Transport: Equatable, Sendable {
        case builtIn
        case bluetooth
        case usb
        case airPlay
        case displayPort
        case other

        public var symbol: String {
            switch self {
            case .builtIn: "laptopcomputer"
            case .bluetooth: "headphones"
            case .usb: "headphones"
            case .airPlay: "airplayaudio"
            case .displayPort: "display"
            case .other: "speaker.wave.2"
            }
        }
    }

    public init(deviceID: AudioDeviceID, name: String, transport: Transport) {
        self.deviceID = deviceID
        self.name = name
        self.transport = transport
    }

    /// Whether this looks like a pair of Apple wireless earbuds.
    ///
    /// Matched on the name because Core Audio reports AirPods as an ordinary
    /// Bluetooth output. There is no "these are AirPods" flag. The match is
    /// deliberately loose: the consequence of a false positive is showing a
    /// headphone glyph for a pair of Beats, which is fine.
    public var isAirPods: Bool {
        guard transport == .bluetooth else { return false }
        let lowered = name.lowercased()
        return lowered.contains("airpods") || lowered.contains("beats")
    }

    public var isWireless: Bool { transport == .bluetooth || transport == .airPlay }
}

/// Watches the default audio output device.
///
/// Used for two things: showing which output the music is going to, and
/// noticing when a wireless device connects so the surface can announce it.
///
/// Core Audio posts a property-changed notification when the default output
/// changes, so this is event-driven rather than polled. Connecting AirPods
/// switches the default output, which is exactly the moment worth reacting to.
/// It needs no Bluetooth permission and no Bluetooth framework at all.
public final class OutputDeviceMonitor: @unchecked Sendable {

    public typealias ChangeHandler = @Sendable (AudioOutputDevice?) -> Void

    private let lock = NSLock()
    private var handler: ChangeHandler?
    private var isListening = false

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private let queue = DispatchQueue(label: "dev.cornice.outputdevice", qos: .utility)

    public init() {}

    /// Current output device, read synchronously.
    public func current() -> AudioOutputDevice? {
        Self.defaultOutputDevice()
    }

    public func start(onChange: @escaping ChangeHandler) {
        lock.lock()
        guard !isListening else { lock.unlock(); return }
        handler = onChange
        isListening = true
        lock.unlock()

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue
        ) { [weak self] _, _ in
            guard let self else { return }
            let device = Self.defaultOutputDevice()
            self.lock.lock()
            let handler = self.handler
            self.lock.unlock()
            handler?(device)
        }
        if status != noErr {
            Log.audio.error("could not observe default output device: \(status)")
        }
    }

    public func stop() {
        lock.lock()
        guard isListening else { lock.unlock(); return }
        isListening = false
        handler = nil
        lock.unlock()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, { _, _ in }
        )
    }

    // MARK: - Core Audio queries

    static func defaultOutputDevice() -> AudioOutputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }

        return AudioOutputDevice(
            deviceID: deviceID,
            name: name(of: deviceID) ?? "Output",
            transport: transport(of: deviceID)
        )
    }

    private static func name(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        let result = name as String
        return result.isEmpty ? nil : result
    }

    private static func transport(of deviceID: AudioDeviceID) -> AudioOutputDevice.Transport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return .other
        }
        return classify(transport)
    }

    /// Maps Core Audio's transport constants onto the cases the UI cares about.
    static func classify(_ transport: UInt32) -> AudioOutputDevice.Transport {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: .displayPort
        default: .other
        }
    }
}
