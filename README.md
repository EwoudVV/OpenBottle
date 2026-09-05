# OpenBottle

i'm building a free, open-source way to run Windows games on Apple silicon Macs.
the goal is to make each game choose a measured working setup instead of making
people guess between Wine versions, graphics backends, sync modes, and random
launch flags.

OpenBottle starts from [frankea/Whisky](https://github.com/frankea/Whisky). that
already gives it a native SwiftUI app, Wine bottle management, Steam support,
DXVK, DXMT, and diagnostics. this fork is focused on the part i care about next:
measuring real games, keeping the fast configurations, and making the result easy
to reproduce.

## status

checked 5 september 2026. the repository and upstream link are set up, and the
first controlled renderer comparison is complete. the app still uses the Whisky
name and bundle identifiers internally while the project boundary is being
established.

the first target is [Screw Drivers](https://store.steampowered.com/app/1279510/Screw_Drivers/)
on an M1 Max MacBook Pro. it runs through Wine 11 and Direct3D 11, but full display
resolution is too slow and the lower working resolution looks soft.

| mode | average game CPU | main menu ready |
| --- | ---: | ---: |
| DXVK | 111.6% | 44 s |
| DXMT | 320.4% | 42 s |
| DXVK, 60 FPS cap | 115.6% | 44 s |
| DXMT, 60 FPS cap | 157.7% | 43 s |

macOS reports 100% CPU as roughly one fully occupied core. these numbers come
from 60-second main-menu samples at 1728x1117. they do not include a trustworthy
FPS measurement yet, so they are evidence about CPU cost rather than a complete
renderer ranking. the full method and limits are in
[the benchmark record](docs/benchmarks/screw-drivers-2026-09-05.md).

## first playable experiment

the measured default remains DXVK with a 60 FPS cap. the first sharp-output
experiment uses DXMT's MetalFX spatial scaler to reconstruct 1728x1117 to the
MacBook panel's 3456x2234 pixel grid. it stays experimental until it has been
checked visually and measured during actual driving.

vehicle calculation and map loading are separate CPU workloads. the next test
will sample the game while those operations happen instead of assuming a graphics
backend can fix them.

## project direction

1. make Screw Drivers sharp and stable, then measure driving, vehicle calculation,
   and map loading;
2. add repeatable benchmark capture to the app;
3. turn results into versioned per-game profiles with clear provenance;
4. update and compare Wine, DXVK, DXMT, and synchronization implementations;
5. follow the ARM64 Wine and FEX work needed after general Rosetta support ends.

the tracked plan is in [docs/ROADMAP.md](docs/ROADMAP.md).

## stack and licensing

OpenBottle's redistributable path uses Wine, DXMT, DXVK, and MoltenVK. the app
code remains under GPL-3.0 because it is derived from Whisky. Apple's D3DMetal is
proprietary and will stay an optional user-supplied component with its own license;
it is not part of the fully open runtime path.

the upstream project and the people maintaining Wine, DXMT, DXVK, MoltenVK, and
the macOS Wine builds are doing the hard compatibility work underneath this app.
OpenBottle will keep an `upstream` Git remote and should send generally useful
fixes back when they fit there.

## build

the current app target is still named Whisky. open `Whisky.xcodeproj` in Xcode to
build the app. with a full Xcode toolchain, run the core test suite with:

```sh
swift test --package-path WhiskyKit
```

there is no OpenBottle release yet.

## license

OpenBottle is available under [GPL-3.0](LICENSE). the bundled runtime components
keep their own licenses; see [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).
