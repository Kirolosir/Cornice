import Foundation
import CoreAudio
import AudioToolbox

/// The Mac's output volume, and when it changes.
///
/// Listens on the *current* default output device and re-attaches when that
/// device changes, because volume is a property of the device: plugging in
/// headphones does not merely change where sound goes, it changes which slider
/// the volume keys are moving.
public final class SystemVolumeMonitor: @unchecked Sendable {

    public struct Reading: Equatable, Sendable {
        /// 0...1 on the current output device.
        public let level: Double
        public let isMuted: Bool
        public let deviceName: String

        public init(level: Double, isMuted: Bool, deviceName: String) {
            self.level = level
            self.isMuted = isMuted
            self.deviceName = deviceName
        }
    }

    public typealias ChangeHandler = @Sendable (Reading) -> Void

    private let lock = NSLock()
    private var handler: ChangeHandler?
    private var isListening = false
    private var attachedDevice: AudioDeviceID?
    private var lastReading: Reading?
    /// The exact blocks handed to Core Audio.
    ///
    /// `AudioObjectRemovePropertyListenerBlock` matches on the block itself, so
    /// unregistering with a freshly-written closure removes nothing at all and
    /// leaves the listener firing into a deallocated object. They have to be
    /// kept and handed back.
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    private let queue = DispatchQueue(label: "dev.cornice.volume", qos: .utility)

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    public init() {}

    public func start(onChange: @escaping ChangeHandler) {
        lock.lock()
        guard !isListening else { lock.unlock(); return }
        isListening = true
        handler = onChange
        lock.unlock()

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.attachToDefaultDevice()
        }
        lock.lock()
        defaultDeviceListener = listener
        lock.unlock()

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            queue,
            listener
        )

        attachToDefaultDevice()
    }

    public func stop() {
        lock.lock()
        guard isListening else { lock.unlock(); return }
        isListening = false
        handler = nil
        let listener = defaultDeviceListener
        defaultDeviceListener = nil
        lock.unlock()

        if let listener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultDeviceAddress,
                queue,
                listener
            )
        }

        detachFromDevice()
    }

    /// The current reading, computed on demand.
    public func current() -> Reading? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        return Self.read(device: device)
    }

    // MARK: - Attachment

    private func attachToDefaultDevice() {
        guard let device = Self.defaultOutputDevice() else { return }

        lock.lock()
        let previous = attachedDevice
        guard previous != device else { lock.unlock(); return }
        lock.unlock()

        detachFromDevice()

        var registered: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        for var address in Self.watchedAddresses {
            guard AudioObjectHasProperty(device, &address) else { continue }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.publish()
            }
            guard AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr else {
                continue
            }
            registered.append((address, listener))
        }

        lock.lock()
        attachedDevice = device
        deviceListeners = registered
        // Seeded so the first *change* is what gets announced, not the volume
        // the machine happened to be at when the app launched.
        lastReading = Self.read(device: device)
        lock.unlock()

        Log.audio.notice(
            "volume: watching \(Self.name(device: device), privacy: .public) via \(registered.count) properties"
        )
    }

    private func detachFromDevice() {
        lock.lock()
        let device = attachedDevice
        let listeners = deviceListeners
        attachedDevice = nil
        deviceListeners = []
        lock.unlock()

        guard let device else { return }
        for (address, listener) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
        }
    }

    private func publish() {
        lock.lock()
        let device = attachedDevice
        lock.unlock()
        guard let device, let reading = Self.read(device: device) else { return }

        lock.lock()
        let previous = lastReading
        lastReading = reading
        let handler = self.handler
        lock.unlock()

        // Core Audio fires a volume notification per channel, so a single key
        // press arrives two or three times. Only a reading that actually differs
        // is worth raising a HUD for.
        guard previous != reading else { return }
        handler?(reading)
    }

    // MARK: - Reading

    private static var watchedAddresses: [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: 1
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
        ]
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

    static func read(device: AudioDeviceID) -> Reading? {
        guard let level = scalarVolume(device: device) else { return nil }
        return Reading(
            level: level,
            isMuted: isMuted(device: device),
            deviceName: name(device: device)
        )
    }

    /// Output volume, 0...1.
    ///
    /// Tries the main element first and falls back to averaging the stereo pair.
    /// Plenty of devices — a lot of USB interfaces, and aggregate devices —
    /// expose per-channel volume and nothing on the main element, and reading
    /// only the main element reports them as silent.
    private static func scalarVolume(device: AudioDeviceID) -> Double? {
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
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
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

    private static func name(device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else {
            return "Output"
        }
        return name as String
    }
}
