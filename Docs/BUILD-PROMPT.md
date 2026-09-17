# Build prompt: Cornice

A complete specification for rebuilding this application from nothing. Every
number here is the value actually shipped, and every "because" is a bug that was
hit or a constraint that was verified on a real machine. Hand this to a capable
engineer or agent and they should arrive at the same place.

---

## 1. What to build

A native macOS application that turns the MacBook notch into a media control
surface.

At rest it is invisible — indistinguishable from the hardware cut-out. Move the
pointer onto it and it grows out of the notch showing album art, title and
artist. Commit to it and it opens into a full player: draggable scrubber,
transport controls, an audio spectrum that follows the actual music, plus
secondary panels for timers and system telemetry. When AirPods connect, it
briefly announces them with a rotating 3D glyph and a charge ring, then
dismisses itself.

It must never take focus. Clicking it must not pull the user out of whatever
they were typing in.

The interaction model to match is Apple's Dynamic Island — not its appearance,
its *behaviour*: one object that changes size continuously and never stops
feeling like the same physical thing.

**Build it natively.** Swift, SwiftUI, AppKit, Swift Concurrency, Core Audio,
Accelerate. No Electron, no web view, no third-party UI framework. The window
behaviour, settings, and event handling must feel like part of macOS.

---

## 2. Hard constraints discovered by verification

These are not design preferences. They were established by testing on macOS 26.1
and they determine the architecture.

### 2.1 MediaRemote is closed

`MRMediaRemoteGetNowPlayingInfo` is the private API that reports system-wide Now
Playing state. **Since macOS 15.4 Apple gates it on the caller's platform
signature.** Verified: an ordinary signed binary loads the framework, resolves
the symbol, invokes the call, the callback fires — and returns a dictionary with
**zero keys**.

The known workaround is to load a helper library into `/usr/bin/perl`, which is
Apple-signed with a `com.apple.` identifier and therefore passes the check.

**Do not do this.** It is loading your code into a system binary to inherit
privileges granted to that binary and not to you. It also breaks whenever Apple
tightens the gate further, and it cannot be honestly notarized.

**Instead:** drive Apple Music and Spotify through their documented AppleScript
interfaces. Accept the loss of browser audio. Put the provider behind a protocol
so a MediaRemote-backed provider could be added later by someone who chooses
that trade-off for themselves.

### 2.2 Notch size is not a property of the Mac model

The notch is a fixed number of physical pixels, but macOS reports displays in
points, and the points-per-pixel ratio changes with the user's chosen scaled
resolution.

Verified: a `Mac15,12` in a scaled 1710 pt mode reports its notch as
**209 × 38 pt**. Published per-model tables list 165–184 pt for that class,
measured at default scaling. Neither is wrong — the point size simply is not a
model attribute.

**Never ship a table of per-model notch point sizes.** Measure at runtime.

### 2.3 Animating an NSWindow's frame is the source of "laggy"

Resizing the window in step with a SwiftUI animation means the window server and
SwiftUI each animate a different thing on a different cadence. The result
stutters and trails the pointer regardless of how the curves are tuned.

**The window is created once at its maximum size and never resized.**

### 2.4 Polling a music player is expensive

Neither player supports reading a track's properties as a single record —
Spotify raises outright on `properties of current track`. Every property read is
its own Apple event to another process. Profiling put **one Spotify round-trip
at roughly 100 ms of CPU**, almost all of it inside `OSAExecute` waiting on
Spotify's own handler.

This dominates the app's energy cost and must be designed around, not ignored.

---

## 3. Surface states and geometry

Four states. One object.

| State | Trigger | Size |
|---|---|---|
| `collapsed` | default | exactly the measured notch |
| `peek` | pointer arrives, **zero delay** | notch + 108 pt each side, + 10 pt tall |
| `activity` | a wireless device connects | notch + 108 pt each side, + 16 pt tall |
| `expanded` | dwell, click, or ⌥⌘D | 604 pt wide, notch height + 188 pt |

`peek` exists solely for perceived latency. A dwell timer with nothing happening
during it feels broken however short it is. Respond *instantly* with a small
growth, then commit to the full panel — the same total duration then reads as
immediate.

### Corner radii

| State | Bottom radius | Flare radius |
|---|---|---|
| `collapsed` | notch's own radius | 0 |
| `peek` | notch + 6 | 14 |
| `activity` | notch + 10 | 16 |
| `expanded` | 28 | 24 |

### Silhouette rules

- **The top edge is flush with the screen and its corners have zero radius.**
  Rounding them shows desktop wallpaper above the surface and destroys the
  illusion instantly.
- **Bottom corners are convex**, matching the hardware cut-out when resting.
- **Where the surface is wider than the notch, the top corners flare outward
  with a concave curve**, so the extra width appears to grow out of the notch
  rather than being a rectangle stuck beside it. Non-negotiable.
- Radii must animate together with size, as one interpolation of the outline.
  Implement `animatableData` on the shape.

### The flare trap

The flare is conceptually a corner treatment, but geometrically it insets the
shape's sides **for their whole height**. So the usable body is
`width − 2 × flareRadius`.

Content laid out to the full surface width will be clipped by exactly that much
on each side. This is invisible at small flare values and obvious at 24 pt — it
clipped the tab strip, the source badge and both timestamps. Expose
`contentInset(for:)` and apply it before any other padding.

### The wing trap

In wing-shaped states (`peek`, `activity`) do **not** lay out two fixed-width
columns plus the notch. That total exceeds the surface width and both sides get
silently clipped — which renders the device announcement as an empty pill.
Derive wing width:

```
wing = (contentWidth − 2 × padding − notchWidth) / 2
```

### The ZStack height trap

If all state layouts live in one `ZStack`, it sizes to its **tallest** child —
the expanded panel. Any layer using `maxHeight: .infinity` then centres itself
against that height instead of the current surface's, placing its content far
below the visible area. **Pin every layer to the surface's own size explicitly.**

---

## 4. Motion

Motion is the product. Everything else is judged through it.

| Transition | Curve |
|---|---|
| Opening | `spring(response: 0.38, dampingFraction: 0.76)` |
| Closing | `spring(response: 0.30, dampingFraction: 0.86)` |
| Peek / activity | `spring(response: 0.22, dampingFraction: 0.82)` |
| Content swap inside an open panel | `easeOut(0.16)` |
| Values updating on a timer | `easeOut(0.45)` |
| Button press | `easeOut(0.08)`, scale to 0.92 |

Opening overshoots slightly so it arrives with weight. Closing is faster and
more damped, because a dismissal that bounces reads as indecision.

**Never overshoot upward.** The surface is anchored to the top edge of the
screen; a bounce past it looks like it has come unstuck from the hardware.

### Keeping it smooth

- **Build every state's content at all times and cross-fade with opacity.**
  Switching layouts with a `switch` makes SwiftUI tear down one tree and
  construct another *during* the animation — building the player, decoding
  artwork, laying out transport — exactly when there is no frame budget. This is
  the single largest cause of a hitchy expand. Costs a little idle layout and a
  few MB; worth both.
- **No `.blendMode()` on the surface.** It forces an offscreen compositing pass
  every frame. A layered gradient renders identically for free.
- **No `.drawingGroup()` on small `Canvas` views.** It adds an offscreen pass for
  something `Canvas` already does efficiently.
- **No shadow while collapsed.** A drop shadow under a black shape sitting in a
  black cut-out just darkens the bezel around it.

---

## 5. The window

- `NSPanel`, `[.borderless, .nonactivatingPanel]`. Non-activating is what stops
  clicks stealing focus.
- Level: `CGWindowLevelForKey(.mainMenuWindow) + 1`.
- Collection behaviour: `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
  .ignoresCycle]`.
- `isOpaque = false`, clear background, `hasShadow = false` (SwiftUI draws a
  shaped shadow), `sharingType = .readOnly` so the app can be screen-recorded
  and demoed.
- `canBecomeKey = true` (text fields), `canBecomeMain = false` (never deactivate
  the user's app).
- Created once at maximum size. **Never resized.**

Because the window is permanently much larger than what is drawn:

- **Override `hitTest` to return `nil` outside the drawn shape**, or the app
  swallows clicks across a large rectangle of the user's desktop.
- **Compute hover from `mouseMoved` against a shape-derived region**, not from
  the window's bounds.
- **`acceptsFirstMouse` must return `true`** so a first click acts on the control
  under the pointer.

### The hover region is not the click region

The drawn shape at rest is exactly the notch — but the notch is a *hole*. Aiming
at it means aiming at nothing, and requiring a hit inside its exact bounds makes
the surface feel like it only opens if you clip its edge.

Pad the hover region by **26 pt horizontally, 14 pt vertically** while resting so
approaching from any direction opens it, including from directly below. Once
expanded, hover matches the panel exactly — a padded region around an open panel
would hold it open while the pointer is clearly elsewhere.

### Hover sequence

1. Pointer enters → `peek` **immediately**, no delay.
2. After the configured dwell (default **0.05 s**) → `expanded`.
3. Pointer leaves `peek` → `collapsed` at once; peek is feedback, not a state to
   linger in.
4. Pointer leaves `expanded` → close after **220 ms**, so crossing a gap between
   controls or overshooting the edge by a few pixels does not dismiss it.

Global hot key ⌥⌘D via Carbon's `RegisterEventHotKey` — **specifically to avoid
Accessibility permission**, which would mean the right to read every keystroke
the user types in order to open a panel.

---

## 6. Notch measurement

Three paths, in order.

1. **Measured.** `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea` give
   the usable menu-bar strips either side of the notch. The gap between them *is*
   the notch, exactly, in the display's current point space. Available on every
   notched Mac from macOS 12, so this is the path that runs.
2. **Derived.** Some configurations — a mirrored notched panel especially —
   report `safeAreaInsets.top` without the auxiliary areas. The inset is still an
   exact *height*; derive width from a measured aspect ratio (**5.5**), not an
   invented per-model constant.
3. **Synthetic.** No notch: external displays, Intel laptops, desktops. Reserve a
   notch-shaped region centred in the menu bar, clamped to the menu bar's height,
   and behave identically everywhere else.

**Reject implausible measurements**: a gap narrower than 40 pt is not a notch, and
one wider than a third of the display would place a window across the whole menu
bar. Fall through rather than trust them.

Re-resolve on display attach/detach, resolution or scaling change, rotation, and
**wake from sleep** (which can reconfigure displays without posting a screen
parameter change).

Report width as a **fraction of display width** for any cross-machine
comparison; point sizes are not comparable.

**Read `NSScreen` in exactly one place**, converting to a plain value type. It
cannot be constructed in a test, so this seam is what makes every awkward
display configuration a fixture instead of requiring four different MacBooks.

Identify the machine separately: `hw.model` via `sysctl` immediately (cheap,
in-process), then marketing name and chip once from `system_profiler` off the
main actor. Show both, and which resolution path ran, in an About tab.

---

## 7. Media integration

Use `NSAppleScript` **in-process**, compiled once and cached. Do not spawn
`osascript` — that is a process launch per poll.

Confine it to **one serial queue**: `NSAppleScript` is neither thread-safe nor
`Sendable`. Reduce results to plain values before they cross an actor boundary;
never let an `NSAppleEventDescriptor` escape the queue.

Check whether a player is running via `NSRunningApplication` **before** scripting
it — scripting a stopped app *launches* it, which is a spectacularly bad thing
for a background poller to do. It also needs no permission.

### Normalisation — every one of these produces a plausible but wrong UI

- **Spotify reports duration in milliseconds; Apple Music in seconds.** A
  four-minute track otherwise renders as 272,394 seconds.
- **Spotify exposes `artwork url`; Music only hands over raw image data** via a
  data descriptor.
- **Music spells repeat as `off`/`one`/`all`; Spotify uses a boolean `repeating`.**
- **Both report volume 0–100, not 0–1.**
- **AppleScript renders reals in the user's locale.** A comma-decimal machine
  returns `182,813`. Parsed naively the playhead sits at zero for a large part of
  the world. Parse with a fallback comma swap; **format** seek values POSIX-style,
  because a comma decimal is a syntax error in generated AppleScript.
- **Separate fields with US (0x1f)**, not a printable character. Track and album
  names contain pipes, tabs, quotation marks and everything else.
- **Guard every property read with `try`**: a player open with nothing loaded
  raises rather than returning empty. Degrade to a "stopped" answer.

### Two-tier reads

Given ~100 ms CPU per round-trip:

- **Frequent poll** fetches only what changes between polls: state, playhead,
  volume, and the track title as a change signal.
- **Full metadata read** runs only when title or duration says the track moved
  on.

### Extrapolate the playhead

Poll about once a second; redraw the scrubber every frame. Advance the position
locally from the last known sample and correct when a real one lands. This is the
difference between a scrubber that glides and one that ticks — and it is what
lets the poll rate drop sharply when the panel is closed without anything looking
stale.

### Source selection

Several players open at once is ordinary. Rules:

1. Whichever is **playing** wins.
2. If none is playing, hold the **last shown** source — pausing must not make the
   panel jump to another app's stale track.
3. Otherwise, any player with a track loaded.

### Artwork

Fetch **once per track**, keyed on a track identity that deliberately **ignores
the playhead** — otherwise every poll looks like a new song and the cover reloads
continuously. Cache ~12 entries. Size-cap downloads. A failed fetch yields a
placeholder, never an error state where the art goes.

### Permission

Automation is refused per-app. Record the refusal and **stop polling that
source** — re-prompting every second is hostile. Offer an in-panel explanation, a
link to the right Settings pane, and an explicit retry that clears the refusal.
Ship `NSAppleEventsUsageDescription` describing what and why.

---

## 8. The visualiser

A real FFT of the system audio. Not an animation on a timer.

Capture with a **Core Audio process tap** — `AudioHardwareCreateProcessTap`,
macOS 14.2+. Rejected alternatives: a virtual audio device needs an installer and
a reboot and permanently alters the user's audio chain; ScreenCaptureKit's audio
capture demands full Screen Recording permission — the right to read the screen —
to read a waveform.

Tap setup: `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`,
`muteBehavior = .unmuted` (playback continues), `isPrivate = true` (invisible to
other apps). Build an aggregate device around the current default output with the
tap in its tap list, create an IO proc, then `AudioDeviceStart` — **which is what
triggers the permission prompt**, so a failure there means the user declined and
should be reported as such rather than as an opaque status code.

Read the tap's own sample rate; hardcoding 48 kHz misplaces every band on a
44.1 kHz device. Rebuild the analyser if the rate changes mid-session.

### DSP chain

mono mixdown → Hann window → vDSP real FFT (1024) → log-spaced bands (8) →
asymmetric smoothing → energy-based onset detection.

- **Log-spaced bands**, 40 Hz to min(16 kHz, Nyquist). Pitch is logarithmic;
  linear bands put six of eight bars above 10 kHz where there is no energy.
- **Peak, not mean, within each band**, so a narrow tone moves its bar fully
  instead of being averaged into nothing by the silent bins beside it.
- **Asymmetric smoothing**: attack 0.55, release 0.12. Symmetric smoothing looks
  either sluggish on transients or jittery on decay; the asymmetry is what makes
  bars look locked to the music.
- **Perceptual compression**: `log10(1 + v × 9)`, so quiet passages still move
  the bars.
- **Onset detection**: rolling mean of low-band energy over ~43 frames, minimum
  12 frames of history, fire when energy exceeds `mean × 1.35` and `0.08`, with a
  **10-frame refractory period** so one kick does not fire on six consecutive
  frames. A sustained tone must not read as a beat.
- Cache `FFTSetup` per transform length; creating one per call is wasteful.

### Threading

Audio arrives on Core Audio's IO queue hundreds of times a second; SwiftUI wants
one value per frame. **Analyse in the callback and write into a lock-protected
box; let the UI *pull* the latest frame on its own display timer.** Pushing
observable updates from the audio thread schedules main-actor work faster than it
drains and stutters the entire interface.

Decay the bars to rest when audio stops arriving, so pausing settles them rather
than freezing them mid-spectrum.

### Rendering

Bars grow from the **vertical centre**, not a baseline — that reads as a waveform
rather than a bar chart. Album art may pulse on beats by **no more than 3%**.

**Off by default.** Ask for audio permission only when enabled, and explain what
it does at that moment. **When capture is off, draw no bars at all** — a
visualiser sitting at a resting height looks broken, and animating it without
audio behind it would misrepresent what the app knows. Fall back to the track
title or a static glyph.

Ship `NSAudioCaptureUsageDescription`. State plainly that audio is analysed in
memory and discarded: never written to disk, never transmitted.

---

## 9. Wireless device announcement

Detect AirPods connecting by **observing Core Audio's default output device
property**. Connecting them switches the default output, which is exactly the
moment worth reacting to. This needs **no Bluetooth permission and no
CoreBluetooth** — the obvious approach would require both for strictly less
reliable results.

Classify `kAudioDevicePropertyTransportType` into built-in / Bluetooth / USB /
AirPlay / DisplayPort. Announce only wireless devices, and only on an actual
device change, so unrelated audio reconfiguration does not re-announce.

Read battery from `AppleDeviceManagementHIDEventService` in the IO registry —
`BatteryPercentCombined`, falling back to per-bud levels. Registry properties
only: no private calls, no permission. **Omit the ring entirely when absent**,
which is normal for non-Apple headphones and for the first second after
connecting.

Present it in the `activity` state: the device glyph turning once about the Y
axis with `rotation3DEffect` and `perspective: 0.6` (real projection, so it reads
as an object rotating rather than an image being squeezed), easing out over
~1.1 s, with a charge ring drawing in behind it. Dismiss after **3.5 s**.

**An announcement must never steal a panel the user has open.** Skip it if the
surface is already expanded. Resolve SF Symbol names defensively — availability
varies by macOS version, and a missing symbol renders as nothing at all.

The transport row should also carry a permanent output-device control, because
with wireless audio "where is this actually playing?" is a real question.

---

## 10. Visual design

- **The surface is true black** — not dark grey, not a material. It must be
  seamless against an unlit region of the display.
- **Text**: title white, artist ~66% white, timestamps ~52%.
- **Accent colour is extracted from the current album artwork.** Downsample to
  16×16; weight by saturation (averaging a cover gives mud); ignore near-black,
  near-white and desaturated pixels; **clamp saturation to 0.75 and brightness to
  0.45–0.72**, because unclamped artwork colours destroy contrast against white
  text.
- **Tint**: a vertical gradient at 0.50 / 0.20 / 0.06 opacity plus a radial wash
  from the top-left at 0.42, so the colour reads as light spilling off the
  artwork rather than a flat tinted panel. Noticeable, not overwhelming.
- **The announcement state takes no tint** — it is not about music.
- **Status colours** (green / amber / red) are reserved for genuine status.
- **Typography**: four sizes only. Title 13.5 semibold, artist 11.5 medium,
  captions 10–11, and **monospaced digits only** for timestamps — surrounding
  letterforms stay proportional so numbers do not jitter while prose reads
  normally.
- **Transport weighting follows Apple**: play/pause is a filled **white circle**
  with a black glyph (34 pt); previous/next are glyph-on-faint-circle (32 pt);
  shuffle/repeat/output are tertiary at the edges (28 pt), tinted only when
  active.
- **Collapsed and peek are always dark** regardless of system appearance,
  because they sit against physical hardware. The expanded panel may follow the
  system appearance.

Avoid: glow, neon, bloom, decorative gradients, elastic easing, more than one
thing moving at once, anything animating while at rest, skeuomorphic vinyl or VU
needles, text below 9 pt.

---

## 11. Architecture

Two targets.

```
CorniceKit/     all logic; imports no SwiftUI and no NSScreen
  Media/        models, script runner, per-player controller, source selection,
                artwork cache
  Audio/        process tap, vDSP FFT, spectrum + beat analysis, output monitor,
                wireless battery
  Telemetry/    Mach / sysctl / IOKit probe
  Focus/        countdown state machine, timer board
  Settings/     Preferences, atomic file store
  Notch/        ScreenMetrics, geometry resolver, model catalog
  Process/      subprocess runner with timeout and cancellation
  Support/      errors, Loadable, logging, redaction, formatting
CorniceApp/     interface; holds no business logic
  Window/       NSPanel, SurfaceGeometry, hit testing, global hot key
  Design/       theme tokens, the morphing surface shape
  Model/        AppModel, actions, service container, artwork palette
  Views/        the four states, panes, settings, docs capture
```

- **One geometry type** computes the surface rect per state and is used by
  **both** the renderer and the hit-tester. When those were computed separately
  the interactive region drifted out of step with the visible one mid-animation.
- **Service protocols, not concrete types**: `MediaControlling`,
  `TelemetryProbing`, `PreferencesPersisting`, `ProcessRunning`. The payoff is a
  preview container that runs the entire app on scripted data with no change to
  any view — used for documentation images and for testing states that are
  awkward to arrange.
- **One composition root.** A struct of `let` properties built in the app
  delegate. No registry, no resolver, no property-wrapper magic.
- **Observable state is `private(set)`**, mutated only through named operations.

---

## 12. Concurrency

Swift 6 language mode, strict checking, both targets.

- Actors for services holding mutable state; `@MainActor` for the UI layer.
- **Time is injected, never read implicitly.** Every countdown and the playhead
  derive from a passed-in instant. This is what makes "pause for an hour then
  resume" and "sleep through the deadline" testable at all — and a method that
  reads `.now` internally is both untestable and inconsistent with a caller that
  has already decided which instant it is rendering.
- Subprocess execution must resolve a **three-way completion handshake** —
  stdout EOF, stderr EOF, process exit — resuming its continuation exactly once,
  under one lock, and escalate SIGTERM → SIGKILL on timeout. **Read pipes on a
  dedicated queue, never the cooperative pool**: `readDataToEndOfFile` blocks,
  and blocking cooperative threads deadlocks a concurrency-heavy app.
- **One display timer for the whole UI**, not one per component.

---

## 13. Performance

Budget: **under 1% of one core and under ~20 MB resident** while resting.

The first working build measured **9.9% mean CPU**. Profiling (`sample`) found
two causes, both worth stating because neither was obvious:

1. **The frame timer ran whenever music played** — driving repaints for a
   *collapsed* surface showing album art and a title, neither of which changes
   between tracks. Gate it on things that genuinely move: the spectrum while
   capture is on, a running countdown, or the scrubber while the panel is open.
   Resting with the visualiser off there should be **no timer at all**.
2. **AppleScript polling**, per §2.4.

Rules:

- Frame timer: **60 Hz open, 10 Hz collapsed**.
- Media poll: configured rate when open (default 1.0 s); **4 s** collapsed while
  playing; **8 s** when paused or when the collapsed surface shows nothing.
  Staleness is erased by forcing an immediate refresh on hover, which completes
  while the peek animation is still running.
- Telemetry: 2 s open, **15 s** closed.
- Kernel reads (`host_statistics`, `sysctl`, `getifaddrs`, IOKit) for CPU,
  memory, network and battery — never subprocesses.
- Skip redundant preference writes; settings views emit a change per keystroke.

Measure with a script in the repo. **Quote only measured numbers.**

---

## 14. Reliability

Each integration fails in its own pane and keeps its last good value.

Handle explicitly: no player running; player open with nothing loaded; automation
refused; both players open; player quits mid-track; artwork fetch failure; audio
permission denied; output device changes mid-session; playback paused; corrupted
preferences; preferences missing newer keys; Mac without a notch; display or
scaling change; wake from sleep; no display attached.

Errors must carry whether they are **retryable**, and the UI must only offer
"Retry" when retrying could actually work.

Preferences: atomic writes, `0600`, **decode field-by-field with per-key
fallbacks**. The synthesised `Codable` initialiser requires every key, so adding
one setting would make every existing file fail to decode — and since a decode
failure falls back to defaults, upgrading would silently reset everyone's
configuration. Quarantine a corrupt file with a timestamp rather than
overwriting it, and still launch.

Clamp every value on load so a hand-edited file cannot make the app poll a player
a hundred times a second.

---

## 15. Security and privacy

- **No private frameworks.** No MediaRemote, no injection into Apple binaries, no
  SIP changes.
- **Audio analysed in memory and discarded.** Never written, never transmitted.
- **Exactly two permissions, both explained, both optional**: automation, and
  system audio recording only if the visualiser is enabled. No camera,
  microphone, location, contacts, or full disk.
- **Carbon hot key** to avoid Accessibility permission.
- **No network except album artwork** from the URL the player itself supplied.
- **No analytics, no telemetry upload, no account.**
- Logs never contain track contents; redact the home directory from paths.
- CI fails the build if a credential-shaped string appears in the tree.

---

## 16. Settings

A real, focusable `NSWindow` — not a pane inside the surface. The surface is
non-activating and closes when the pointer leaves it, which is right for glancing
at a track and completely wrong for reading a permission explanation.

Expose: activation style (hover / click-only) and dwell; what the collapsed
surface shows; artwork tinting; which panels are enabled (media cannot be
disabled); launch at login via `SMAppService`; timer-completion notifications;
automation status with a link and retry; the visualiser toggle with its full
explanation and current status; poll interval.

---

## 17. Testing

Everything interesting must be testable without a running music player, a
listening socket, or audio permission. Mock every external dependency.

Cover at minimum:

- **Player reply parsing** — the millisecond/second mismatch, locale decimals,
  volume normalisation, a stopped player, titles containing pipes and tabs, and
  malformed replies.
- **Playhead extrapolation** — advances while playing, does not while paused,
  clamps to duration after a long sleep, and track identity ignores the playhead.
- **Source selection** — playing beats paused, stable while all paused, stopped
  players skipped, refusal recorded once and resettable.
- **FFT** — a pure tone lands in the bin its frequency predicts; a higher tone
  moves the peak up; silence produces no magnitude; short and empty buffers are
  tolerated rather than trapping in the audio callback.
- **Spectrum** — 60 Hz lands low, 9 kHz lands high, louder reads higher, silence
  settles, compression is concave.
- **Beat detection** — periodic kicks register; the refractory period stops
  repeats; a sustained tone is not a beat.
- **Timers** — pause across arbitrary real time, completion reported exactly
  once, survives sleeping past the deadline.
- **Notch geometry** — every display configuration in §6, including the ones that
  cannot be reproduced without extra hardware.
- **Preferences** — clamping, corruption quarantine, permissions, field-by-field
  decoding.
- **Subprocess** — timeout termination, cancellation, output capping, and many
  concurrent commands not deadlocking.

Drive audio tests with **synthetic waveforms**. Feeding a 60 Hz sine and
asserting the energy lands in the lowest band is a far better check than watching
bars move, which can look plausible while being completely wrong.

---

## 18. Packaging and documentation

- SwiftPM, two targets plus tests. Assemble the `.app` with a script: the app
  **must** run from a bundle for `LSUIElement`, the usage-description strings,
  and `SMAppService`.
- `LSUIElement` true — no Dock icon. A menu-bar item for settings and quitting.
- GitHub Actions: build, test, assemble, and **run the bundle headlessly** to
  prove display geometry resolves — a build that compiles but cannot place itself
  is broken in the way that matters most. Plus a credential scan.
- Release workflow with signing and notarization **conditional on secrets**, inert
  and honest without them. Never fake a signature.
- A `--capture-docs` mode that renders the real view hierarchy through
  `ImageRenderer` against the preview services, so README images are
  deterministic, regenerable in one command, and need no Screen Recording
  permission.
- A `--probe-media` mode that prints exactly what the media layer can see.
- A README written like an engineer explaining a real system: what it does, the
  decisions and why, measured numbers only, an honest limitations section, and a
  roadmap. No badge walls, no emoji spam, no marketing voice.

---

## 19. Explicitly not in scope

Lyrics, queue management, library browsing, clipboard history, a colour picker,
AI features, localisation, per-display surfaces, and anything that turns this
into a general productivity dashboard.

macOS has no third-party lock-screen widget API, so the surface exists only while
logged in and unlocked. Do not promise otherwise.

---

## 20. Definition of done

Runs reliably on modern macOS; supports notched and non-notched Macs; measures
the notch rather than assuming it; opens with no perceptible delay and animates
at display rate; reads and controls Music and Spotify; shows a spectrum genuinely
driven by system audio; announces wireless devices; survives every condition in
§14; persists configuration and recovers from corruption; stays under the
performance budget with measured evidence; has meaningful automated tests; builds
green in CI; ships a professional README with real screenshots; and contains no
embedded secrets and no private API use.
