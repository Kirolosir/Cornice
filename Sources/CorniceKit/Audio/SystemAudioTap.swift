import Foundation
import CoreAudio
import AudioToolbox

/// Why the tap cannot run.
public enum AudioTapUnavailable: Error, Equatable, Sendable {
    /// Needs macOS 14.2 or later.
    case unsupportedSystem
    /// The user declined the system-audio recording prompt, or it was never granted.
    case permissionDenied
    /// Core Audio refused at some step; carries the OSStatus for diagnosis.
    case coreAudioError(Int32, stage: String)

    public var message: String {
        switch self {
        case .unsupportedSystem:
            "The visualiser needs macOS 14.2 or later."
        case .permissionDenied:
            "Cornice needs permission to read system audio. Enable it in System Settings › Privacy & Security › Audio Recording, then turn the visualiser on again."
        case .coreAudioError(let status, let stage):
            "Core Audio refused to start the tap (\(stage), status \(status))."
        }
    }
}

/// Captures the audio the Mac is playing, using a Core Audio process tap.
///
/// This is the public API Apple added in macOS 14.2 for exactly this purpose.
/// The alternative approaches are worse in ways that matter: installing a
/// virtual audio device requires an installer and a reboot and permanently
/// alters the user's audio chain, and ScreenCaptureKit's audio capture demands
/// full Screen Recording permission (the right to read the screen) to read a
/// waveform.
///
/// The tap is created with `muteBehavior = .unmuted`, so audio continues to
/// play normally while it is being observed, and `isPrivate = true`, so it does
/// not appear in other applications' device lists.
///
/// Nothing is ever written to disk. Samples are analysed in the IO callback's
/// own buffer and discarded.
public final class SystemAudioTap: @unchecked Sendable {

    /// Called on the audio IO queue with a block of mono samples.
    ///
    /// Deliberately not hopping to another actor first: this fires at the audio
    /// device's cadence and hopping per block would queue work faster than it
    /// drains. The callback does the analysis and hands on only the finished
    /// levels.
    public typealias SampleHandler = @Sendable ([Float], Double) -> Void

    private let lock = NSLock()
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private var sampleRate: Double = 48_000

    private let queue = DispatchQueue(label: "dev.cornice.audiotap", qos: .userInitiated)

    public init() {}

    public var running: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunning
    }

    /// Starts capturing. Throws `AudioTapUnavailable` if it cannot.
    ///
    /// The permission prompt appears on `AudioDeviceStart`, not on tap
    /// creation, so a failure at that last step is the signal that the user
    /// declined, and is reported as such rather than as an opaque status code.
    public func start(handler: @escaping SampleHandler) throws {
        guard #available(macOS 14.2, *) else { throw AudioTapUnavailable.unsupportedSystem }

        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        // 1. A global tap that excludes nothing: we want whatever the Mac is
        //    playing, from any application.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Cornice Visualiser"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &createdTap)
        guard status == noErr, createdTap != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioTapUnavailable.coreAudioError(status, stage: "create tap")
        }
        tapID = createdTap

        // 2. The tap has to be attached to an aggregate device built around the
        //    current default output, because a tap is not itself a device you
        //    can run IO against.
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            cleanupLocked()
            throw AudioTapUnavailable.coreAudioError(-1, stage: "resolve default output")
        }

        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cornice Visualiser",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Private: this device is ours and should not clutter the user's
            // sound settings or appear to other apps.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &createdAggregate
        )
        guard status == noErr, createdAggregate != AudioObjectID(kAudioObjectUnknown) else {
            cleanupLocked()
            throw AudioTapUnavailable.coreAudioError(status, stage: "create aggregate device")
        }
        aggregateID = createdAggregate

        // 3. The tap's own format tells us the sample rate the analyser should
        //    assume; hardcoding 48 kHz would mis-place every frequency band on a
        //    44.1 kHz device.
        if let format = Self.tapFormat(tapID) {
            sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        }
        let capturedRate = sampleRate

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            _, inputData, _, _, _ in
            Self.deliver(inputData, sampleRate: capturedRate, to: handler)
        }
        guard status == noErr, let procID else {
            cleanupLocked()
            throw AudioTapUnavailable.coreAudioError(status, stage: "create IO proc")
        }
        ioProcID = procID

        // 4. This is the call that prompts for permission the first time.
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            cleanupLocked()
            // A refusal here is overwhelmingly the user declining the prompt;
            // reporting "status 560227702" instead would be useless to them.
            throw AudioTapUnavailable.permissionDenied
        }

        isRunning = true
        Log.audio.notice("system audio tap started at \(capturedRate, format: .fixed(precision: 0)) Hz")
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        cleanupLocked()
    }

    /// Tears down whatever was created, in reverse order, tolerating partial
    /// construction so a failure halfway through `start` still cleans up.
    private func cleanupLocked() {
        if let ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if isRunning { AudioDeviceStop(aggregateID, ioProcID) }
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if isRunning {
            isRunning = false
            Log.audio.notice("system audio tap stopped")
        }
    }

    deinit {
        cleanupLocked()
    }

    // MARK: - Sample extraction

    /// Mixes the incoming buffers down to mono and hands them to the analyser.
    ///
    /// Mono because the visualiser shows one spectrum: summing the channels
    /// costs one add per frame and avoids running the FFT twice for a display
    /// that cannot show the difference.
    private static func deliver(
        _ bufferList: UnsafePointer<AudioBufferList>,
        sampleRate: Double,
        to handler: SampleHandler
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard buffers.count > 0 else { return }

        // Non-interleaved float is what a tap produces in practice, but
        // interleaved stereo is legal, so both are handled rather than assumed.
        let first = buffers[0]
        guard let rawData = first.mData else { return }
        let channelCount = Int(first.mNumberChannels)
        let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(1, channelCount)
        guard frameCount > 0 else { return }

        let pointer = rawData.assumingMemoryBound(to: Float.self)
        var mono = [Float](repeating: 0, count: frameCount)

        if buffers.count > 1 {
            // Non-interleaved: one buffer per channel.
            for frame in 0..<frameCount { mono[frame] = pointer[frame] }
            for bufferIndex in 1..<min(buffers.count, 2) {
                guard let otherData = buffers[bufferIndex].mData else { continue }
                let other = otherData.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount { mono[frame] = (mono[frame] + other[frame]) * 0.5 }
            }
        } else if channelCount > 1 {
            // Interleaved: stride across channels.
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += pointer[frame * channelCount + channel] }
                mono[frame] = sum / Float(channelCount)
            }
        } else {
            for frame in 0..<frameCount { mono[frame] = pointer[frame] }
        }

        handler(mono, sampleRate)
    }

    // MARK: - Core Audio queries

    private static func defaultOutputDeviceUID() -> String? {
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

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &uidSize, pointer)
        }
        guard status == noErr else { return nil }
        return uid as String
    }

    @available(macOS 14.2, *)
    private static func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else {
            return nil
        }
        return format
    }
}
