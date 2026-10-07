import AppKit
import Foundation
import CorniceKit

/// Spotify Web API controls, mainly for repeat-one. Without a connection, AppModel uses its
/// local repeat loop.
extension AppModel {

    /// Whether repeat can be asked for rather than imitated.
    var spotifyCanSetRepeat: Bool {
        spotifyStatus == .signedIn
    }

    /// Reads the client ID out of preferences and asks the remote where it stands.
    func configureSpotify() async {
        let remote = serviceContainer.spotify
        await remote.configure(clientID: preferences.spotifyClientID)
        let status = await remote.status()
        spotifyStatus = status
        guard status == .signedIn else { return }
        Log.media.notice("spotify: web api connected")

        // Stop our local loop when Spotify takes over repeat-one so both do not seek the
        // same song.
        if appliesRepeatOne {
            setAppliesRepeatOne(false)
            Log.media.notice("repeat one: handing over to spotify")
        }
    }

    /// Open Spotify's sign-in page in the browser. Cornice doesn't collect the password.
    func beginSpotifySignIn() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.serviceContainer.spotify.beginSignIn()
                NSWorkspace.shared.open(url)
            } catch let error as ServiceError {
                self.spotifyError = error.detail
                self.flashToast(error.headline)
            } catch {
                self.spotifyError = "Sign-in could not be started."
            }
        }
    }

    /// Handles the `cornice://spotify-callback` the browser sends back.
    func completeSpotifySignIn(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.serviceContainer.spotify.completeSignIn(callback: url)
                await self.configureSpotify()
                if self.spotifyStatus == .signedIn {
                    self.spotifyError = nil
                    self.flashToast("Spotify connected")
                }
                self.refreshNow("media")
            } catch let error as ServiceError {
                Log.media.error("spotify sign-in failed: \(error.headline, privacy: .public)")
                self.spotifyError = error.detail
                self.flashToast(error.headline)
            } catch {
                self.spotifyError = "Sign-in failed."
            }
        }
    }

    func disconnectSpotify() {
        Task { [weak self] in
            guard let self else { return }
            await self.serviceContainer.spotify.signOut()
            await self.configureSpotify()
        }
    }

    /// Use Spotify's repeat setting and stop our loop when it succeeds. If it fails, keep
    /// the local loop available.
    func sendSpotifyRepeat(_ mode: RepeatMode) {
        // Hold the new repeat mode briefly so an older API reading does not undo the click.
        spotifyRepeat = mode
        lastSpotifyRead = .now

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.serviceContainer.spotify.setRepeat(mode)
                self.spotifyError = nil
                self.setAppliesRepeatOne(false)
                self.spotifyRepeat = mode
                Log.media.notice("spotify: repeat set to \(mode.rawValue, privacy: .public)")
            } catch let error as ServiceError {
                Log.media.error("spotify repeat failed: \(error.headline, privacy: .public)")
                self.spotifyError = error.detail
                self.flashToast(error.headline)
                // Fall back to doing it ourselves.
                if mode == .one {
                    self.setAppliesRepeatOne(true)
                    self.scheduleRepeatOneLoop()
                }
            } catch {
                Log.media.error("spotify repeat failed")
            }
        }
    }

    /// Check the Web API less often than the local player. Repeat mode changes infrequently
    /// and the API has a request limit.
    func refreshSpotifyRepeat(for snapshot: MediaSnapshot?) async {
        guard spotifyCanSetRepeat, snapshot?.source == .spotify else { return }
        if let last = lastSpotifyRead, Date.now.timeIntervalSince(last) < 5 { return }
        lastSpotifyRead = .now

        do {
            guard let state = try await serviceContainer.spotify.playbackState() else { return }
            spotifyRepeat = state.repeatMode
        } catch let error as ServiceError {
            // A read failing is not worth a toast. It recovers on the next one.
            if case .unauthorized = error {
                Log.media.error("spotify: sign-in no longer accepted")
                await configureSpotify()
            }
        } catch {}
    }

    /// Spotify's own repeat mode, when it is the authority on the matter.
    var spotifyReportedRepeat: RepeatMode? {
        spotifyCanSetRepeat ? spotifyRepeat : nil
    }
}
