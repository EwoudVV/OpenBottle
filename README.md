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

checked 6 september 2026. the first proof is complete: one real game has a
repeatable sharp configuration, a protected local save, and a reversible launch.
the app still uses the Whisky name and bundle identifiers internally while the
product boundary is being established.

the first target is [Screw Drivers](https://store.steampowered.com/app/1279510/Screw_Drivers/)
on an M1 Max MacBook Pro. full-resolution rendering was too slow and the lower
working resolution looked soft. DXMT and MetalFX now render at 1728x1117 and
reconstruct the result to the panel's 3456x2234 pixel grid.

| mode | average game CPU | main menu ready |
| --- | ---: | ---: |
| DXVK | 111.6% | 44 s |
| DXMT | 320.4% | 42 s |
| DXVK, 60 FPS cap | 115.6% | 44 s |
| DXMT, 60 FPS cap | 157.7% | 43 s |

macOS reports 100% CPU as roughly one fully occupied core. these numbers come
from 60-second main-menu samples at 1728x1117. a later 21-minute MetalFX play
session completed four races and averaged 210.2% game CPU. it looked close to a
native-resolution run. a later direct comparison found that a 120 FPS cap felt
noticeably more responsive than 60 FPS, with average game CPU rising from 206.5%
to 238.3% across those short runs. the full method and limits are in
[the benchmark record](docs/benchmarks/screw-drivers-2026-09-05.md).

## first proof

the winning tested setup on this M1 Max is DXMT, MetalFX 2x, and a 120 FPS cap.
it renders at 1728x1117 and reconstructs to the built-in display's 3456x2234
pixel grid. Steam runs with sync disabled and the launcher verifies its temporary
renderer changes and local save state.

the reversible launcher, the lower-latency 120 FPS comparison, and the things to
check are in
[experiments/screw-drivers](experiments/screw-drivers/README.md).
the current experiment is local-save only: it refuses to start unless Steam Cloud
is disabled for Screw Drivers, and it starts that Steam session offline.

## project direction

the next milestone is the product rather than another Screw Drivers tweak:

1. send every game, installer, shortcut, and store through one safe Play
   transaction;
2. add automatic local save restore points and an explicit cloud policy;
3. give the fork its own OpenBottle identity without touching existing Whisky
   bottles;
4. keep versioned runtime slots and select hardware-aware profiles;
5. test different engines, Direct3D generations, launchers, input, audio, video,
   and failure classes;
6. publish a signed alpha whose normal flow is install, choose a game, and press
   Play.

the full architecture and compatibility boundary are in
[docs/PRODUCT-PLAN.md](docs/PRODUCT-PLAN.md). the ordered work is in
[docs/ROADMAP.md](docs/ROADMAP.md).

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
