import Foundation
import CorniceKit

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    print("PASS: \(message)")
}

let before = CPUCounterReading(user: 100, system: 50, idle: 200, nice: 10)
let after = CPUCounterReading(user: 120, system: 60, idle: 270, nice: 10)
check(abs(after.usage(since: before)! - 0.3) < 0.00001, "CPU uses the interval across all states")
check(before.usage(since: before) == nil, "unchanged counters are unavailable")
let rollover = CPUCounterReading(user: 5, system: 60, idle: 270, nice: 10)
let nearRollover = CPUCounterReading(user: UInt32.max - 14, system: 50, idle: 200, nice: 10)
check(abs(rollover.usage(since: nearRollover)! - 0.3) < 0.00001, "one counter can wrap independently")
check(before.usage(since: after) == nil, "counter resets do not invent a load")
check(!TelemetrySample.empty.cpuAvailable && !TelemetrySample.empty.memoryAvailable, "startup is not zero usage")

for capture in [true, false] {
    for running in [true, false] {
        for sound in [true, false] {
            check(AudioIndicatorMode.resolve(captureEnabled: capture, captureRunning: running,
                  hasTrack: true, isPlaying: false, hasAudio: sound) == .resting,
                  "paused song stays still (capture: \(capture), running: \(running), sound: \(sound))")
        }
    }
}
check(AudioIndicatorMode.resolve(captureEnabled: true, captureRunning: true,
      hasTrack: true, isPlaying: true, hasAudio: false) == .resting, "silence never becomes fake playback")
check(AudioIndicatorMode.resolve(captureEnabled: true, captureRunning: false,
      hasTrack: true, isPlaying: true, hasAudio: true) == .resting, "failed capture stays still")
check(AudioIndicatorMode.resolve(captureEnabled: true, captureRunning: true,
      hasTrack: true, isPlaying: true, hasAudio: true) == .spectrum, "playing audio drives the spectrum")
check(AudioIndicatorMode.resolve(captureEnabled: true, captureRunning: true,
      hasTrack: false, isPlaying: false, hasAudio: true) == .spectrum, "browser audio works without a loaded song")
check(AudioIndicatorMode.resolve(captureEnabled: false, captureRunning: false,
      hasTrack: true, isPlaying: true, hasAudio: false) == .playback, "capture-off animation requires actual playback")

let probe = HostTelemetryProbe()
let first = await probe.sample()
check(!first.cpuAvailable, "first CPU reading waits for a delta")
check(first.memoryAvailable && first.memoryUsedBytes > 100_000_000, "live memory is available")
check(first.memoryUsedBytes <= first.memoryTotalBytes, "used memory fits installed memory")
check(abs(first.memoryUsage - Double(first.memoryUsedBytes) / Double(first.memoryTotalBytes)) < 0.00001,
      "memory bytes and percentage agree")
try await Task.sleep(for: .milliseconds(300))
let second = await probe.sample()
check(second.cpuAvailable && (0...1).contains(second.cpuUsage), "second CPU reading is a measured fraction")
print("System and playback checks passed")
