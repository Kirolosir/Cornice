# Cornice

A media surface that lives in the MacBook notch.

Cornice turns the camera notch into something like a Dynamic Island. At rest you
can't see it. Move the pointer onto it and it grows out of the cut-out with the
album art, track and artist, then opens into a full transport with a draggable
scrubber, timers and system stats. Charging, network and VPN notices show up
there too.

It never takes focus, so clicking it doesn't pull you out of whatever you were
doing.

This is a passion project. I've wanted a Dynamic Island on my Mac since I first
used one on a phone, and I was using [Atoll](https://github.com/Atoll-Labs/Atoll)
before I started building this. Cornice is my own take on the same idea, written
from scratch in Swift 6 and SwiftUI. No Electron, no private APIs, no helper
daemon.

![The player](Docs/images/player.png)

---

## What it does

| | |
|---|---|
| **Now Playing** | Apple Music and Spotify: artwork, title, artist, a draggable scrubber, shuffle, repeat, output device. |
| **System** | CPU and memory as filled sparklines over the last 48 samples. |
| **Timers** | Up to four at once, with presets and an alarm. |
| **AirPods** | A live activity when a wireless device connects, with its charge. |
| **System HUDs** | Charging, battery low, full battery, no internet, VPN, downloads. Each gets its own size. |

![System](Docs/images/stats.png)
![Charging](Docs/images/hud-charging.png)

---

## Install

You need macOS 14 or later and a Mac with a notch.

```bash
git clone https://github.com/Kirolosir/Cornice.git
cd Cornice
make run
```

That builds a release bundle into `dist/` and launches it. There's no Dock icon.
The app lives in the menu bar.

The visualiser asks for System Audio Recording permission the first time you turn
it on. Nothing else needs a permission.

### Connecting Spotify (optional)

You only need this for real repeat-one. Everything else works without it. It also
needs Spotify Premium, because that's what the Web API's playback controls
require.

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
   and create an app. The name doesn't matter.
2. Add `cornice://spotify-callback` as a Redirect URI and tick **Web API**. Your
   app stays in Spotify's development mode, which is fine, because the owner of
   an app is always allowed to authorize it and the owner is you.
3. Paste the Client ID into **Settings → Spotify** and press **Connect Spotify**.

The client ID isn't a secret. The sign-in uses PKCE, so there's no secret to
keep. The refresh token it gives back is sensitive, and that goes in the Keychain.

---

## How it works

### One object that changes size

There's only ever one shape on screen. Resting, peek, activity, expanded and
every HUD are the same view with different geometry, so it reads as the notch
growing instead of a panel appearing next to it.

| State | Size | Bottom radius | Flare |
|---|---|---|---|
| Resting | 209 × 38 | 10 | 0 |
| Peek | 425 × 48 | 16 | 14 |
| Activity | 425 × 54 | 20 | 16 |
| Expanded | 604 × 226 | 28 | 24 |

Three rules do most of the work. The top corners have no radius, since the top
edge is the physical edge of the screen. The shoulders are concave coves, so
extra width looks like it grew out of the notch rather than sitting beside it.
And nothing is drawn inside the notch's own rectangle, because that's a hole in
the display. Short states use the two margins either side of it and tall ones
start below it.

The album artwork is drawn once and then travels. Its frame is interpolated along
the same spring as the outline, so it moves outward and down instead of
cross-fading between two copies.

### The window never resizes

I tried resizing the `NSWindow` in step with the SwiftUI animation first. That
means the window server and SwiftUI are each animating a different thing at a
different cadence, and it stutters. So the window is created once at its maximum
size and never resized. All the motion happens inside it at display rate. That
window is much bigger than what you can see, so `hitTest` returns `nil` outside
the drawn shape and it doesn't swallow clicks meant for the desktop.

### The notch is measured, not looked up

A notch is a fixed number of pixels, but macOS reports displays in points, and
the ratio changes with whatever scaled resolution you picked in Settings. The
same Mac reports a different notch size depending on a setting you can change
whenever you like, so hardcoding a table of sizes doesn't work.

Cornice measures it instead, from `NSScreen.auxiliaryTopLeftArea` and
`auxiliaryTopRightArea`. The gap between those two is the notch. It re-measures
on display change, resolution change, rotation and wake.

### Measuring the machine

CPU load is `1 − Δidle/Δtotal` across two `host_statistics` readings. That lands
within a few tenths of a percent of `top` over the same window.

Memory took three tries, because the obvious page classes are the wrong ones:

    Memory Used = App Memory + Wired + Compressed
    App Memory  = internal pages − purgeable pages

`active` is not App Memory. It counts file-backed pages the kernel is caching and
leaves out inactive pages an app still owns, which read about 250 MB light on my
machine and drifted around depending on how much file cache happened to be warm.
Counting inactive file pages instead is what `top` calls "used", and that goes
too far the other way: every Mac looks permanently near capacity, because macOS
keeps that cache full on purpose and reclaims it when something needs the room.
With the formula above the probe agrees with Activity Monitor to the megabyte.

### Reading what's playing

Cornice talks to Apple Music and Spotify through macOS's own scripting
interfaces. It uses no private frameworks.

The obvious route is closed. `MediaRemote` is the private framework most notch
utilities use, and since macOS 15.4 Apple gates it on the caller's platform
signature, so a third-party app just gets an empty dictionary back. The known
workaround is to load a helper into an Apple-signed binary and inherit privileges
that binary was granted and you weren't. I didn't want to ship that.

The cost of staying on the supported path is browser audio, which Cornice can't
see. What you get for it is full metadata and artwork, working transport control,
and a binary that won't break on the next macOS release.

Repeat-one is the interesting case. Music has a real three-way `song repeat`.
Spotify's dictionary only has a boolean `repeating` and no way to ask for a
single track, so Cornice does it two ways.

If you connect Spotify in Settings, it asks the player directly. The Web API
takes `off`, `context` or `track`, so repeat-one becomes Spotify's own setting.
The `1` shows up on Spotify's button, it survives skips and restarts, and nothing
has to watch for the end of a song. The sign-in is authorization code with PKCE,
because an app bundle can't hold a client secret when anyone with the bundle can
read it. The refresh token goes in the Keychain, device-only. Cornice asks for two
scopes, both about playback, and never sees your password.

Without that sign-in it imitates the setting. With repeat-one on it seeks back to
the start just before the end, so the player never gets to the point where it
would move on.

Working out when "just before the end" is took some doing. Spotify can be set to
crossfade, which starts the next track seconds before the current one reaches the
length it reports, and that setting lives on Spotify's servers where I can't read
it. On my machine a 230.5 second track got abandoned at around 226. So the app
also watches for a track changing on its own near the end, puts it back, and
remembers how early it happened. The next loop lands ahead of the crossfade
instead of behind it.

All of that is a lot of machinery standing in for one API call, which is most of
why I went and made the API call.

One thing Cornice does differently from Spotify on purpose: with repeat-one on,
the skip button restarts the song instead of moving to the next one. Spotify's
own Next advances even with repeat-one set, but "repeat this song" and "now play
a different one" contradict each other, and I'd rather the button you pressed
most recently win. Press repeat again to release it and skip goes back to
skipping.

Everything else that differs between the two players gets normalised in one
place. Spotify reports duration in milliseconds and Music in seconds. Music
spells repeat as `off`/`one`/`all` where Spotify uses a boolean. AppleScript
renders numbers in the user's locale, so a comma-decimal machine hands back
`182,813` and a naive parse puts the playhead at zero for a good chunk of the
world.

### The visualiser is a real FFT

Audio is captured with a Core Audio process tap, the public API added in macOS
14.2. It's mixed to mono, windowed, transformed with vDSP, folded into log-spaced
bands, and run through energy-based onset detection for the beat.

The alternatives are worse. A virtual audio device needs an installer and a
reboot, and ScreenCaptureKit wants full Screen Recording permission just to read
a waveform.

Analysis happens in the audio callback and writes into a lock-protected box. The
UI pulls the newest frame on its own timer. I tried pushing observable updates
from the audio thread and it schedules main-actor work faster than it drains.

The playing indicator uses both halves of the analysis. The spectrum decides the
shape of the bars, and loudness decides how much room that shape has to move in.
Loudness has to mean what's actually reaching the room, so the volume fader is
part of it. A tap captures the stream before the fader, and on my machine
dropping the system volume from 70 to 25 only moved the captured level from 0.96
to 0.86. Without reading the fader separately, the bars can't tell blasting music
from the same track at a whisper.

Band magnitudes get compensated for music's natural downward slope. Recorded
music is roughly pink noise, meaning equal energy per octave, so the amplitude in
any one FFT bin falls off as `1/√f`. Reading the peak bin per band reports the
bottom of the spectrum as loud and the top as nearly silent, which is accurate
and useless. Measured against synthetic pink noise the lowest band came back
15.0× the highest, and `√f` predicts 15.5, so the compensation is `√(centre
frequency)`. That's a property of the signal rather than a curve I fitted to one
song. Pink noise now draws as a level row, which is the test that keeps it
honest.

Calibration was a separate problem. A pure tone puts all its energy in one FFT
bin and music spreads itself over hundreds, so a chain tuned on a sine wave reads
a real song as almost nothing. On this machine a full-scale 1 kHz tone put its
band at 0.89 and actual music put it at 0.06, which moved a 13 pt bar by a fifth
of a point. After correcting and retuning, the same audio reads 0.70.

One more thing worth knowing: macOS hands a tap silence instead of an error when
the permission is missing. So the app checks whether it's hearing anything while
music is playing and says so, rather than showing you dead bars and leaving you
to guess.

---

## Performance

Measured with `./Scripts/measure.sh`, not estimated. Release build, MacBook Air
(M3), surface resting with Spotify open, sampled 40 times over two minutes:

| | |
|---|---|
| CPU, mean | **2.9%** of one core |
| Memory, mean | **14.0 MB** |

Most of that is the AppleScript round-trip to Spotify, which costs roughly 100 ms
of CPU per poll and can't be avoided on the supported API. So the polling cadence
follows what's on screen instead of running at a fixed rate, and it drops sharply
when the panel is closed.

It took three rounds of profiling to get there, and two of the three things I
found were not what I expected:

- **The frame counter lived on the root view.** Every tick invalidated the root,
  so SwiftUI re-laid out the whole tree, including all four surface states and
  the two modules that weren't showing, to move one scrubber. It now lives in an
  observable object that only the few views redrawing per frame ever read.
- **Starting the audio tap blocked launch for 5.2 seconds.** Building a process
  tap, an aggregate device and an IO proc all ran on the main actor, so the
  surface ignored the pointer for five seconds after login and every other event
  source was stuck in line behind it. It runs on a detached task now.
- **The frame timer ran whenever music played**, including for a resting surface
  showing a title that only changes between tracks. It only runs now when
  something on screen actually moves.

---

## Built with

Swift 6 with strict concurrency, SwiftUI and AppKit, Core Audio, vDSP, IOKit,
SystemConfiguration, Network.framework, Carbon hot keys. No third-party
dependencies.

**201 tests** over the pure logic: parsing player replies, playhead
extrapolation, FFT and beat detection, notch geometry for every display
configuration, the HUD size table, the indicator's loudness mapping, band
calibration and spectral tilt, per-player repeat support, the Spotify OAuth
handshake including RFC 7636's own challenge vector, the telemetry probe against
the running machine, every AppleScript the app sends (compiled, not just parsed),
preference migration, and subprocess timeout and cancellation against real
processes. None of them need a running music player or audio permission.

```bash
make test
```

---

## Limitations

- Apple Music and Spotify only. Browser audio is invisible, for the reason above.
- Built-in display only, not every screen in a multi-monitor setup.
- Ad-hoc signed, so it isn't notarized. macOS ties permissions to the code
  signature, so **rebuilding invalidates the audio-capture grant**. If the
  visualiser goes quiet after a rebuild, reset it and relaunch:
  `tccutil reset AudioCapture dev.cornice.app`.
- For the same reason, macOS asks again before handing back the stored Spotify
  token after a rebuild, since the new binary is a different code identity.
  Answer **Always Allow**. It doesn't block startup; the app keeps polling while
  the prompt waits.
- Spotify's repeat-one is imitated unless you connect the Web API in Settings,
  which needs the free app registration above and a Premium account. Without it
  the fallback still replays the track, but Spotify's own button won't show the
  `1`.
- The hot key is fixed at ⌥⌘D.
- Do Not Disturb, AirDrop and Handoff HUDs are drawn but not wired up. macOS
  doesn't publish that state without Full Disk Access or an API that doesn't
  exist.
- English only.

---

## Credit

The idea comes from Apple's Dynamic Island, and
[Atoll](https://github.com/Atoll-Labs/Atoll) is what convinced me it could work
on a Mac. Cornice shares no code with it. Atoll is GPL v3 and this is MIT, which
only works because I wrote everything here from scratch, and writing it was the
whole point.

---

## License

MIT. See [LICENSE](LICENSE).
