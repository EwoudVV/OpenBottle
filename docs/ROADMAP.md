# roadmap

OpenBottle should earn each compatibility claim with a repeatable test. the first
milestone is one Windows game running visibly better on the same Mac, with enough
evidence to explain which layer made the difference.

## 0. establish the project

- [x] create the public `EwoudVV/OpenBottle` fork
- [x] clone it into the canonical `Documents/projects/OpenBottle` folder
- [x] keep `frankea/Whisky` as the upstream Git remote
- [x] record the first Screw Drivers renderer comparison
- [x] enable GitHub Actions and pass the full inherited CI workflow
- [ ] rename the app, targets, bundle identifiers, and user-facing strings without
      breaking existing Whisky bottles
- [ ] replace inherited release, update, documentation, and Homebrew links

## 1. make Screw Drivers better

- [x] verify Wine 11, Direct3D 11, DXVK 1.10.3, and DXMT 0.80
- [x] compare DXVK and DXMT at 1728x1117
- [x] compare both backends with a 60 FPS limit
- [x] create a reversible DXMT + MetalFX launcher with hash-checked restoration
- [x] visually test DXMT with 2x MetalFX spatial reconstruction
- [x] preserve the first real play session in a verified save backup
- [x] make the experiment launch through Steam and wait for its cloud-save check
- [ ] verify the corrected Steam launch writes to the game folder
- [ ] compare the 60 and 120 FPS MetalFX modes for input latency and CPU use
- [ ] record FPS and frame-time evidence during the same driving route
- [ ] profile one vehicle calculation with `sample`
- [ ] time one cold and one warm map load
- [ ] repeat the winning configuration three times
- [ ] publish the first verified Screw Drivers profile

the first profile can be called verified when another launch reproduces it from a
cleanly restored bottle, the renderer files match their pinned source hashes, and
the sharp mode improves image quality without making frame pacing or calculation
time worse.

## 2. make benchmarks part of the app

- [ ] store the game, executable, app version, macOS version, Mac model, runtime
      versions, renderer, resolution, and profile hash with every run
- [ ] collect launch time, steady-state CPU and memory, and available Metal timing
      data without requiring administrator access
- [ ] mark warm-up, measurement, and user-triggered events on one timeline
- [ ] compare two runs and show the difference instead of dumping raw logs
- [ ] restore every temporary DLL, preference, and environment change after a run
- [ ] export a small scrubbed report that can be attached to a GitHub issue

## 3. turn measurements into profiles

- [x] keep an explicitly applied profile selected for Steam launches, with a safe
      fallback when the saved entry or variant no longer exists
- [ ] give every profile a source, hardware record, date, runtime versions, and
      confidence level
- [ ] keep safe defaults separate from experimental renderer and upscaler choices
- [ ] detect stale results after a game, Wine, renderer, or macOS update
- [ ] add a one-click rollback to the last known working profile
- [ ] accept community reports without treating one report as a universal answer

## 4. improve the runtime

- [ ] build a reproducible runtime manifest with hashes and licenses
- [ ] compare upstream Wine, Wine Staging, and published CodeWeavers sources on the
      same tests
- [ ] track DXMT and DXVK changes against saved game regressions
- [ ] separate open redistributable components from optional proprietary imports
- [ ] send general Wine and launcher fixes upstream

## 5. move beyond Rosetta

- [ ] reproduce an ARM64 Wine build on macOS
- [ ] evaluate the open FEX work needed for x86-64 Windows games
- [ ] test ARM64 DXMT with a small Direct3D 11 suite before testing full games
- [ ] keep the current Rosetta runtime available while the ARM64 path is incomplete

## first alpha

the first alpha needs to install Steam, import or create a bottle, identify Screw
Drivers, apply a measured profile, launch it, capture a benchmark, and restore the
previous configuration. it does not need a large compatibility list. one honest,
repeatable result is enough to prove the workflow.
