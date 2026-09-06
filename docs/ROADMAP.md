# roadmap

this is the order of work, with rough focused-development estimates. upstream
runtime work and game regressions can move the dates, but they do not change the
order. the architecture and compatibility boundary are in
[PRODUCT-PLAN.md](PRODUCT-PLAN.md).

## completed proof

- [x] create the public `EwoudVV/OpenBottle` fork in the canonical project folder
- [x] keep `frankea/Whisky` as the upstream remote
- [x] enable GitHub Actions and pass the full inherited workflow
- [x] add exact per-game variant selection to the Steam launch path
- [x] prove reversible DXMT and DXVK renderer changes
- [x] make 1728x1117 look close to native 3456x2234 with MetalFX
- [x] compare 60 and 120 FPS during real play and select 120 on the tested M1 Max
- [x] recover, verify, and protect local saves after a Steam Cloud conflict
- [x] verify the game launches from the correct folder with Steam sync disabled

Screw Drivers is now a completed proof case. more work on its vehicle calculations
or map loading is deferred unless a change to the shared runtime regresses it.

## weeks 1–3: one safe Play button

- [x] define portable save manifests with staged copies and SHA-256 verification
- [x] persist launch stages so interrupted cleanup remains recoverable
- [x] capture declared GameDB save paths in a per-bottle vault before Steam Play
- [x] journal Steam library launch requests and finish them after the game exits
- [ ] create one `LaunchTransaction` used by the library, CLI, shortcuts, Steam,
      and dragged files
- [ ] snapshot renderer DLLs, settings, and the known save set before launch
- [ ] apply a resolved profile only for that launch
- [ ] restore temporary configuration after exit, interruption, or failed startup
- [ ] add a per-game local/cloud save choice and show its current state beside Play
- [ ] keep at least one verified local restore point for every launched game
- [ ] show one plain launch result with a useful next action

exit: a supported Steam game and a standalone EXE both launch without manual
bottle or renderer work, and a failed launch can be rolled back from the game page.

## weeks 4–5: make it OpenBottle

- [ ] rename the app, targets, bundle identifiers, command, URL scheme, and visible
      strings
- [ ] replace inherited update, release, documentation, Homebrew, telemetry, and
      support endpoints
- [ ] add a read-only discovery screen for existing Whisky bottles
- [ ] keep migration explicit and preserve the original bottle until the imported
      copy launches successfully
- [ ] make the library the end of setup instead of asking a new user to understand
      bottles
- [ ] produce the first local OpenBottle build and migration smoke test

exit: OpenBottle launches under its own identity, sees the existing games without
changing them, and can be removed without affecting Whisky.

## weeks 6–9: runtime and profile engine

- [ ] replace the single mutable runtime with immutable Stable and Preview slots
- [ ] pin a known-good runtime per game and retain it across updates
- [ ] publish a reproducible manifest with hashes, licenses, sources, and declared
      capabilities for every runtime component
- [ ] detect executable architecture, Direct3D generation, launcher, dependencies,
      and known anti-cheat before launch
- [ ] add per-variant Mac model, GPU family, memory, display, refresh rate, macOS,
      and runtime constraints
- [ ] choose a conservative generated profile when the GameDB has no exact match
- [ ] add one-click runtime and profile rollback

exit: updating OpenBottle or its runtime cannot remove the last known working
configuration for an installed game.

## weeks 10–14: multi-game beta

- [ ] add the standalone installer adapter and a default per-game bottle flow
- [ ] add GOG import, then connect Epic, EA, Ubisoft, Rockstar, and Battle.net to
      the shared launch transaction
- [ ] build the engine and launcher test matrix from `PRODUCT-PLAN.md`
- [ ] run the matrix on at least two Apple silicon generations
- [ ] add a scrubbed, opt-in compatibility report export
- [ ] accept versioned community profiles with reviewable provenance
- [ ] detect stale profiles after game, runtime, renderer, or macOS updates
- [ ] publish an alpha, then promote it only after migration and rollback tests pass

exit: the app handles different APIs, engines, stores, input methods, media paths,
and failure classes without adding game-specific launcher scripts.

## ongoing runtime work

- [ ] track stable Wine and selected development builds with the same test matrix
- [ ] update DXMT and the compatible DXVK/MoltenVK path without silent regressions
- [ ] evaluate every open Direct3D 12 path against MoltenVK's actual capabilities
- [ ] keep optional user-supplied D3DMetal isolated from the open runtime
- [ ] upstream general Wine, launcher, and diagnostics fixes
- [ ] track Apple's post-macOS 27 legacy-game translation behavior
- [ ] treat a native Arm64 Wine/x86 engine as research until it runs the matrix

## release rules

- no compatibility claim without a reproducible report;
- no automatic runtime replacement without rollback;
- no launch without a save policy and recovery point;
- no raw account data, save contents, tokens, or home paths in shared reports;
- no claim that kernel-dependent anti-cheat or DRM can be fixed by a profile;
- no advanced Wine setting in the normal flow unless the user needs it to decide
  what happens.
