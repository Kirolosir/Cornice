import XCTest
@testable import CorniceKit

final class AudioIndicatorModeTests: XCTestCase {
    func testPausedSongStaysStillEvenIfCaptureHearsAnotherApp() {
        XCTAssertEqual(AudioIndicatorMode.resolve(captureEnabled: true, captureRunning: true,
                       hasTrack: true, isPlaying: false, hasAudio: true), .resting)
    }

    func testSilentCaptureDoesNotBecomeAPlaybackAnimation() {
        XCTAssertEqual(AudioIndicatorMode.resolve(captureEnabled: true, captureRunning: true,
                       hasTrack: true, isPlaying: true, hasAudio: false), .resting)
    }

    func testCaptureOffRequiresPlayback() {
        XCTAssertEqual(AudioIndicatorMode.resolve(captureEnabled: false, captureRunning: false,
                       hasTrack: true, isPlaying: false, hasAudio: false), .resting)
        XCTAssertEqual(AudioIndicatorMode.resolve(captureEnabled: false, captureRunning: false,
                       hasTrack: true, isPlaying: true, hasAudio: false), .playback)
    }

    func testBrowserAudioWithoutATrackStillUsesTheSpectrum() {
        XCTAssertEqual(AudioIndicatorMode.resolve(captureEnabled: true, captureRunning: true,
                       hasTrack: false, isPlaying: false, hasAudio: true), .spectrum)
    }
}
