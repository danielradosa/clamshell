# Clamshell

Your desktop folds away as you close the lid.

Clamshell reads your MacBook's hinge angle from the built-in lid angle sensor and
bends a live copy of your screen in 3D to match — tilting it back on the hinge,
softening it with depth-of-field, and letting it fall into shadow as the lid
comes down. Open the lid past a threshold and it clears instantly.

It sits in the menu bar, needs no account, and sends nothing anywhere.

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
make install
```

`make install` builds the app, assembles the bundle, signs it and copies it to
`/Applications`. Other targets:

| Target | What it does |
| --- | --- |
| `make` | Build and sign into `.dist/Clamshell.app` |
| `make run` | Build and launch without installing |
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

If the effect never appears, check **System Settings ▸ Privacy & Security ▸
Screen & System Audio Recording**. Ad-hoc code signatures change on every
rebuild, so a rebuilt app can be left holding a stale grant; `make
reset-permission` clears it so the prompt comes back.

To keep the grant across rebuilds, sign with a self-signed certificate instead:

```bash
make CODESIGN_IDENTITY="Your Certificate Name"
```

## How it works

**Reading the hinge.** macOS exposes the lid angle as an undocumented HID device
on the Sensor usage page (`0x20`), usage `0x8A`, named `las`. Feature report 1
returns three bytes: a report ID followed by a little-endian `UInt16` holding the
angle in whole degrees. Opening the device succeeds for an ordinary unprivileged
process, even though opening the whole HID manager does not. Reads cost about
half a millisecond, so polling at display rate is comfortable.

**Smoothing.** The sensor quantises to whole degrees, which steps visibly if fed
straight to the renderer. A critically damped spring smooths it without the
overshoot a plain spring adds or the lag a moving average adds.

**Capture.** ScreenCaptureKit streams the display, with this application excluded
from its own capture — otherwise the overlay would be captured, rendered, and
captured again.

**Rendering.** The desktop texture is drawn on a 48×48 subdivided quad. The
vertex shader rotates it about the bottom edge and applies a single-term
perspective divide; because depth is zero at the hinge, the hinge stays pinned
exactly as a real lid does. The fragment shader mixes between the sharp texture
and a separably blurred half-resolution copy, with the mix weighted by depth so
the receding edge falls out of focus first.

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
