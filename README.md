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

That launches the app in a mode that reports what it can actually see — whether
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
exactly as a real lid does. The fragment shader mixes between the sharp texture
and a separably blurred half-resolution copy, with the mix weighted by depth so
the receding edge falls out of focus first.

**Speed.** One frame at 3420×2224 — the backing store the window server actually
renders the M2 Air's panel from — takes 1.31 ms in the heaviest style. That is a
764 fps ceiling, against a 16.67 ms budget at 60 Hz. Reproduce it with
`make preview`.

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
