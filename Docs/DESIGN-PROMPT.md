# Design prompt: a notch-resident media surface

A self-contained brief for generating the visual and motion design of this
surface. It describes intent and constraints rather than a component list,
because the hard part is the motion and the restraint, not the layout.

---

## What this is

A media control surface that lives in the MacBook notch. It is not a window,
not a popover, and not a menu-bar dropdown. It is a single object that appears
to be *part of the hardware*: it begins as the notch itself and grows out of it.

The reference point is Apple's Dynamic Island on iPhone — not its appearance,
its **behaviour**. What makes that interaction good is that one shape changes
size continuously, absorbing and releasing content, and never stops feeling
like the same physical object.

Design for a user who sees this every day for a year. Nothing may be
attention-seeking. The success condition is that it is invisible until wanted
and immediate when wanted.

---

## The three states

Design one object in three sizes. Not three components — one object.

**1. Resting.** Exactly the size of the hardware notch, pure black, seamless
with the cut-out. When music is playing it may show a small album thumbnail on
one side of the notch and a live spectrum or the track title on the other,
inside the margins it adds either side. When nothing is playing it shows
nothing at all and is completely invisible.

**2. Peek.** Triggered the instant the pointer arrives — no delay whatsoever.
Grows roughly 108pt on each side and about 10pt taller. Shows album art, track
title, artist, and a playing indicator. This state exists *entirely* to make the
interaction feel instantaneous: it is the acknowledgement that something is
about to happen. It follows the pointer exactly and disappears the moment the
pointer leaves.

**3. Open.** Around 560pt wide. A full player: large album art, title, artist,
source badge, a draggable progress bar with elapsed and remaining times, and a
transport row. Plus two secondary panels reachable by tabs — timers and system
stats.

---

## Silhouette

This is the detail that separates a considered notch surface from a rounded
rectangle placed near the top of the screen.

- **The top edge is flush with the screen and its corners have zero radius.**
  Rounding them would show desktop wallpaper above the surface and instantly
  break the illusion that it is part of the display.
- **The bottom corners are convex**, matching the hardware cut-out's radius when
  resting and growing to roughly 28pt when open.
- **Where the surface is wider than the notch, the top corners flare outward
  with a concave curve.** The extra width appears to grow *out of* the notch
  rather than being a rectangle stuck beside it. This is non-negotiable; without
  it the surface looks pasted on.

The corner radii must animate along with the size, as one continuous
interpolation of the outline.

---

## Motion

Motion is the product. Get this wrong and nothing else matters.

- **Opening**: a spring with slight overshoot — approximately 0.38s response,
  0.76 damping. It should arrive with weight, not ease politely to a stop.
- **Closing**: faster and more damped — approximately 0.30s, 0.86 damping. A
  dismissal that bounces reads as indecision.
- **Peek**: very fast — approximately 0.22s, 0.82 damping. This is pure
  acknowledgement.
- **Content changes inside an already-open panel**: quick and near-linear,
  around 0.16s. The user asked for this; it is not an entrance.
- **Numeric values updating on a timer**: gentle ease, around 0.45s, and only
  the number animates.

Hard constraints:

- The surface must never appear to be **redrawn** or to **resize in steps**. It
  is one object changing size, at display rate, every frame.
- Never overshoot *upward*. The surface is anchored to the top edge of the
  screen; a bounce past that edge looks like it has come unstuck.
- Never animate for longer than the user's patience for a glance. Nothing above
  0.4s.

---

## Colour

Near-monochrome, with colour borrowed from the music.

- The surface is **true black** — not a dark grey, not a material. It has to be
  seamless against an unlit region of the display.
- Text: white at full strength for the track title, roughly 62% white for the
  artist, roughly 50% for timestamps and secondary labels.
- **The accent colour is extracted from the current album artwork** and used for
  the progress fill, the spectrum, and active control states. It must be
  saturation-weighted (averaging a cover gives mud) and brightness-clamped
  (unclamped artwork colours destroy contrast against white text).
- A very faint artwork-coloured gradient may bleed down from the top of the open
  panel — on the order of 25% opacity fading to nothing. Any stronger and it
  becomes a colour wash.
- Status colours — green, amber, red — are reserved for genuine status and never
  used decoratively.

---

## Typography

Four sizes, no more. A surface this small stops reading as one object if it has
a full type scale.

- Track title: 15pt semibold
- Artist: 12pt medium
- Labels and captions: 10–11pt medium
- Timestamps, durations, counters: monospaced **digits** only — the surrounding
  letterforms stay proportional, so numbers do not jitter as they update while
  prose still reads normally.

---

## The transport row

Follow Apple's weighting exactly, because it is correct and because it is what
people already know:

- Play/pause is the primary control: a filled **white circle** with a black
  glyph, around 38pt.
- Previous and next are secondary: glyph-only on a faint circular background,
  around 32pt.
- Shuffle and repeat are tertiary, pushed to the outer edges, around 28pt, and
  tinted with the artwork accent only when active.
- Every control dips to roughly 92% scale on press, over about 80ms. Without
  this the surface feels dead, because it never takes focus and gives no other
  feedback.

---

## The visualiser

Bars driven by a real FFT of the system audio, grown from the **vertical
centre** rather than from a baseline — that reads as a waveform rather than a
bar chart. Attack is fast and decay is slow; symmetric smoothing looks either
sluggish or jittery.

The album art may pulse on detected beats, but by no more than about 3%. This
sits two feet from the user's eyes for hours.

**When audio capture is off or denied, do not draw the bars at all.** A
visualiser at rest looks broken, and animating it without audio behind it would
misrepresent what the app knows.

---

## What to avoid

- Any glow, neon, or bloom.
- Gradients used as decoration rather than to carry artwork colour.
- Bouncy, playful, or elastic easing.
- More than one thing moving at a time.
- Any element that animates continuously while resting.
- Skeuomorphic speaker grilles, vinyl records, or VU-meter needles.
- Text below 9pt.

---

## Deliverables

1. The three states, at 2×, on a realistic desktop backdrop with the notch visible.
2. The open state with three different album covers, showing how the extracted
   accent changes.
3. A frame-by-frame study of the resting → peek → open transition, showing how
   width, height, and corner radii interpolate together.
4. Light-mode treatment of the open panel. The resting and peek states stay black
   regardless, because they sit against physical hardware.
