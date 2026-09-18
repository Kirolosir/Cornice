import AppKit
import Foundation
import CorniceKit

/// The Spotify Web API half of the media controls.
///
/// Everything here is about one thing the scripting interface cannot do. Spotify
/// exposes repeat as a single boolean, so "repeat this track" has to be either
/// faked — watch for the end, seek to zero — or asked for properly over the Web
/// API. When a sign-in is present this asks; when it is not, the loop in
/// `AppModel` still covers it, so the button behaves the same either way.
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

        // Stand the imitation down. Leaving it running alongside a real
        // repeat-one would mean two things seeking the same track back to zero,
        // one of them a second after the other had already done it.
        if appliesRepeatOne {
            setAppliesRepeatOne(false)
            Log.media.notice("repeat one: handing over to spotify")
        }
    }

    /// Opens the browser for the sign-in.
    ///
    /// The consent screen is Spotify's own page and has to be: an app that
    /// collected the password itself would be asking to be trusted with it, and
    /// this way Cornice never sees it.
    func beginSpotifySignIn() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.serviceContainer.spotify.beginSignIn()
                NSWorkspace.shared.open(url)
            } catch let error as ServiceError {
                self.spotifyStatus = .failing(error.detail)
                self.flashToast(error.headline)
            } catch {
                self.spotifyStatus = .failing("Sign-in could not be started.")
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
                self.flashToast("Spotify connected")
                self.refreshNow("media")
            } catch let error as ServiceError {
                Log.media.error("spotify sign-in failed: \(error.headline, privacy: .public)")
                self.spotifyStatus = .failing(error.detail)
                self.flashToast(error.headline)
            } catch {
                self.spotifyStatus = .failing("Sign-in failed.")
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

    /// Asks Spotify for a repeat mode outright.
    ///
    /// On success the app's own loop is stood down — there is nothing left for
    /// it to do, and running both would mean seeking a track that Spotify was
    /// already going to repeat. On failure it is stood back up, so a refusal
    /// (no Premium, no active device) degrades to the behaviour that worked
    /// before rather than to a button that does nothing.
    func sendSpotifyRepeat(_ mode: RepeatMode) {
        // Shown before it is confirmed, and the confirming read held off for a
        // moment. Without this the next poll would overlay the *old* mode on
        // top of the optimistic one and the glyph would flick back and forth.
        spotifyRepeat = mode
        lastSpotifyRead = .now

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.serviceContainer.spotify.setRepeat(mode)
                self.spotifyStatus = .signedIn
                self.setAppliesRepeatOne(false)
                self.spotifyRepeat = mode
                Log.media.notice("spotify: repeat set to \(mode.rawValue, privacy: .public)")
            } catch let error as ServiceError {
                Log.media.error("spotify repeat failed: \(error.headline, privacy: .public)")
                self.spotifyStatus = .failing(error.detail)
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

    /// The player's real repeat mode, re-read on a slow cadence.
    ///
    /// Slower than the media poll on purpose. The panel is redrawn about once a
    /// second, and this is a network round trip against a rate-limited API to
    /// read a value that only changes when somebody presses a button — polling
    /// it at the panel's rate would spend a hundred requests a minute learning
    /// nothing.
    func refreshSpotifyRepeat(for snapshot: MediaSnapshot?) async {
        guard spotifyCanSetRepeat, snapshot?.source == .spotify else { return }
        if let last = lastSpotifyRead, Date.now.timeIntervalSince(last) < 5 { return }
        lastSpotifyRead = .now

        do {
            guard let state = try await serviceContainer.spotify.playbackState() else { return }
            spotifyRepeat = state.repeatMode
        } catch let error as ServiceError {
            // A read failing is not worth a toast — it recovers on the next one.
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
