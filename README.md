# Clamshell

Your desktop folds away as you close the lid.

Clamshell reads your MacBook's hinge angle from the built-in lid angle sensor and
bends a live copy of your screen in 3D to match — tilting it back on the hinge,
softening it with depth-of-field, and letting it fall into shadow as the lid
comes down. Open the lid past a threshold and it clears instantly.

It sits in the menu bar, needs no account, and sends nothing anywhere.

The menu bar icon is the interface: **Pause**, **Preview Effect**, **Open at
Login**, **Screen Recording…** and **Settings…**. The icon carries a warning
badge whenever screen access is missing. On first successful launch the Settings
window opens by itself, so there is something to look at.

<!-- Add a screen recording here once you have one. -->

## Requirements

- **macOS 14 Sonoma or later**
- **A MacBook with a lid angle sensor.** Every Apple silicon MacBook has one, as
  do Intel MacBook Pros from 2019 on. Verified working on an M2 MacBook Air.
- Anything else — a desktop Mac, an older MacBook — still runs the app, which
  falls back to a looping demo so you can see and tune the effect.

## Install

Download the DMG from [Releases](https://github.com/danielradosa/clamshell/releases),
drag Clamshell to Applications, then open it once from the right-click menu:

```bash
xattr -dr com.apple.quarantine /Applications/Clamshell.app
```

The app is signed, but with a self-signed certificate rather than a paid Apple
Developer ID, so it is not notarised and Gatekeeper will refuse a plain
double-click on first run. The command above clears the download quarantine flag.
Right-click ▸ Open works too. Everything after the first launch is normal.

Grant Screen Recording when asked, then relaunch once.

## Building

You do **not** need Xcode. The Command Line Tools are enough:

```bash
xcode-select --install
```

Then:

```bash
git clone https://github.com/danielradosa/clamshell.git
cd clamshell
make setup
```

`make setup` creates a local signing certificate, builds, installs to
`/Applications`, clears any stale permission state and launches the app. Grant
Screen Recording once when asked, then relaunch. Other targets:

| Target | What it does |
| --- | --- |
| `make setup` | Certificate, build, install, launch — start here |
| `make dmg` | Build a distributable disk image |
| `make` | Build and sign into `.dist/Clamshell.app` |
| `make run` | Build, install and launch |
| `make diagnose` | Report what the app can actually see |
| `make certificate` | Create the local signing identity |
| `make remove-certificate` | Delete it again |
| `make preview` | Render the effect offscreen to PNGs in `.dist/preview` |
| `make debug` | Unoptimised build with symbols |
| `make reset-permission` | Clear the Screen Recording grant |
| `make uninstall` | Remove from `/Applications` |

### Why there is no Xcode project

Two things usually tie a Metal app to Xcode, and this project avoids both.

The offline `metal` compiler ships only inside Xcode, so shaders normally have to
be built into a `.metallib` ahead of time. Clamshell keeps its shaders as source
and compiles them with `MTLDevice.makeLibrary(source:)` at launch instead, which
the Metal runtime handles on its own.

`swift build` cannot help either: the `PackageDescription` module shipped in the
Command Line Tools is internally inconsistent — its module interface and its
dylib disagree about `Package.init`, so no manifest will parse. The Makefile
calls `swiftc` directly, which one target does not really need a package manager
for anyway. `Package.swift` is kept only so the directory reads as a Swift
package to editors.

## Permissions

Clamshell asks for **Screen Recording**. The effect is a bent copy of your
desktop, so macOS classes it as screen capture. Frames go from ScreenCaptureKit
straight to the GPU and are discarded — nothing is written to disk, and there is
no network code in the app at all.

Reading the lid angle needs no permission, no entitlement and no root.

### Why permission used to be asked for over and over

macOS ties a Screen Recording grant to the app's *designated requirement*. Under
an ad-hoc signature that requirement is the binary's code hash, which changes on
every single build — so each rebuild looked like a brand-new app, the previous
grant was stranded, and the prompt came back. Granting it repeatedly never
helped, because every grant was against a build that no longer existed. System
Settings would show Clamshell switched on while the running app had no access.

`make certificate` fixes this at the root by creating a self-signed code-signing
identity in your login keychain. The requirement becomes

```
identifier "com.danielradosa.clamshell" and certificate root = H"..."
```

which depends on the bundle ID and that certificate rather than on the binary, so
it is byte-identical across rebuilds. Grant once; it stays granted.

The certificate is local and self-signed. It is not a developer ID, it confers no
trust, it signs nothing but this app, and `make remove-certificate` deletes it.

### If it still is not working

```bash
make diagnose
```

The app also keeps a running trace at `~/Library/Logs/Clamshell-trace.log`,
recording state changes, overlay lifecycle, sleep and wake, and each opening
animation with timings. It is written to a file rather than stderr precisely
because the interesting events happen either side of a lid close, where a
terminal capture is lost.

`make diagnose` launches the app in a mode that reports what it can actually see — whether
ScreenCaptureKit will hand over a display, which is the authoritative test, plus
the lid sensor state and current angle. The report is also written to
`~/Library/Logs/Clamshell-diagnostics.txt`.

Two things worth knowing:

- A running app cannot pick up a grant made after it started. Always relaunch.
- Two copies of the app in different folders are two different apps to macOS.
  Keep one, in `/Applications`.

## How it works

**Reading the hinge.** macOS exposes the lid angle as an undocumented HID device
on the Sensor usage page (`0x20`), usage `0x8A`, named `las`. Opening the device
succeeds for an ordinary unprivileged process, even though opening the whole HID
manager does not. A read costs about half a millisecond, so polling at display
rate is comfortable.

The device answers two reports that both carry the angle, as a little-endian
`UInt16` at bytes 1–2:

| Report | Units | Measured on an M2 Air |
| --- | --- | --- |
| 7 | hundredths of a degree | 112.59 – 112.72 |
| 1 | whole degrees, 9-bit field | a flat 113 |

Clamshell prefers report 7 and falls back to report 1. Most published
implementations use only report 1; the extra two decimal places matter here
because the hinge angle *is* the animation, and whole-degree steps are visible in
the fold.

**Smoothing.** Even at 0.01°, the reading jitters by a few hundredths. A
critically damped spring smooths it without the overshoot a plain spring adds or
the lag a moving average adds.

**Capture.** ScreenCaptureKit streams the display, with this application excluded
from its own capture — otherwise the overlay would be captured, rendered, and
captured again.

**Rendering.** The desktop texture is drawn on a 48×48 subdivided quad. The
vertex shader rotates it about the bottom edge and applies a single-term
perspective divide; because depth is zero at the hinge, the hinge stays pinned
exactly as a real lid does. Whatever the panel does not cover stays black, which
is what gives the effect its sense of the screen falling away. Darkness then
creeps down from the top edge and in from the corners, weighted so the top two
corners lead and the bottom two follow — the way a panel tipping backwards
actually goes.

Blur width comes from a mip chain rather than a wider kernel. Nine taps spread
across forty texels sample a comb, not a gaussian, and the gaps show as ghosting
on anything with strong horizontal structure. Instead the capture is prefiltered
into a quarter-resolution texture, mipmapped, and read back at a level that rises
with the fold — each level doubles the blur for one bilinear fetch, and
interpolating between levels keeps the ramp continuous.

**The curve.** The mapping from hinge angle to fold progress is a cubic ease-in,
and the shape is constrained by hardware rather than taste: the panel backlight
cuts out somewhere around 10–15°, so a curve that saves its motion for the last
few degrees plays most of the animation on a screen that is already dark. A
quintic is still under 0.1 at 25°, which is why it is not the default.

**Colour.** Capture and the overlay's layer use the same *named* colour space.
Built-in Apple displays report an unnamed ICC profile, so asking the screen for
its space yields something that cannot be handed to ScreenCaptureKit. Taking the
profile for the layer and quietly falling back to sRGB for the capture is worse
than picking one: the overlay then renders in a different space from the desktop
it covers, and every colour shifts the instant it is removed, which looks exactly
like a flash.

**Cost.** Measured on an M2 Air:

| State | CPU | Notes |
| --- | --- | --- |
| Idle, lid open | 0.6% | Sensor polled 10×/s, no capture stream |
| Folding | 16% | Live capture plus render at Retina resolution |
| One frame, 3420×2224 | 1.29 ms | Heaviest style; a 764 fps ceiling |

The 16% only applies for the second or two the lid is actually moving.
Reproduce the frame time with `make preview`.

**Opening.** The unfold is played on its own clock rather than tracked from the
hinge. A lid is thrown open in a couple of tenths of a second, and the panel does
not light up until it is already past about 15°, so a sensor-following unfold has
almost no visible travel left and reads as a blink rather than an animation. The
animation runs for 0.75s by default, adjustable in Settings, and eases onto
whatever angle the lid actually ends up at — so opening it halfway settles at the
right amount of fold instead of unfolding flat and snapping back.

It starts on a wake notification, and also on simply seeing the angle come back
up from shut. Whether a lid close sleeps the whole Mac, only the panel, or
nothing at all depends on power assertions and attached displays, and the
matching notification does not always arrive; the angle always does.

**Across sleep.** Closing the lid kills the capture stream, so on wake there is
nothing to draw and the unfold would be missed entirely. The renderer keeps a
private copy of the last desktop frame, taken while the lid is closing; the
desktop does not change during sleep, so it is the correct image rather than a
stand-in. Because it is a picture of the desktop it is discarded the moment the
session locks, and an unfold owed by a lid close then replays after unlock
against a live frame instead.

Sleep also latches the whole state machine. Without that the effect flickers
several times per close: sleep hides the overlay and drops the state back, but
the lid is shut so the fold is still at maximum and the next tick turns it
straight back on — and two sleep notifications arrive, so it happens more than
once.

**Power.** The capture stream is not left running. It starts when the lid drops
near the engage angle *or* when the lid starts moving downward faster than 15°/s
— a hand closing a MacBook moves an order of magnitude faster than that, so
motion alone arms the stream in time. Otherwise the app polls the sensor ten
times a second and does nothing else.

## Settings

| Control | Effect |
| --- | --- |
| **Style** | Satin (glossy), Eclipse (deep shadow), Glacier (frosted) |
| **Depth / Blur / Shadow** | Multipliers on the active style, so switching presets keeps your tuning |
| **Clears above** | Hinge angle at which the effect gets out of the way |
| **Drag to preview** | Scrub an angle by hand, to judge a style at an angle you cannot hold |

**Pause** and **Preview Effect** are in the menu bar. Escape also pauses, but only
while the fold is actually on screen — a globally registered Escape would be
swallowed from every other app, so it is armed for the second or two the effect
is visible and torn down immediately after. It needs no Accessibility permission,
because it goes through Carbon's `RegisterEventHotKey` rather than an `NSEvent`
global monitor. Registration is verified on macOS 27 with Accessibility denied;
delivery has not been verified on this machine, since testing it would require
synthesising a keypress, which needs the very permission being avoided.

On a Mac with no lid sensor the effect stays dormant rather than looping — use
**Preview Effect**, or open Settings and scrub the angle slider.

The feel of the effect lives in one function: `FoldCurve.ease` in
[`Sources/Clamshell/Model/FoldCurve.swift`](Sources/Clamshell/Model/FoldCurve.swift).
It maps hinge travel onto fold progress. The default is a quintic ease-in;
alternatives are documented in place.

## Relationship to Bendy

[Bendy](https://trybendy.app/) is a paid closed-source app with a similar idea,
and it is what prompted this one. Clamshell is an independent implementation
written from public documentation, Apple's own APIs and existing open-source work
on the lid angle sensor. No Bendy code, assets, artwork or copy were examined,
decompiled or reused, and the two share no names for anything user-facing.

If you want the polished commercial product, buy theirs.

## Prior art

The lid angle sensor protocol was originally reverse engineered by
[Sam Henri Gold](https://github.com/samhenrigold/LidAngleSensor), with further
open-source implementations by
[andrewcharlesmoss](https://github.com/andrewcharlesmoss/lid-angle),
[deepakness](https://github.com/deepakness/LidAngle) and
[tcsenpai](https://github.com/tcsenpai/pybooklid).

## License

MIT. See [LICENSE](LICENSE).
