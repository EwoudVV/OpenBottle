# Screw Drivers experiments

`Test Screw Drivers MetalFX.command` is the first playable OpenBottle experiment.
it runs the existing Whisky installation with:

```text
renderer: DXMT 0.80
game render: 1728x1117
MetalFX output target: 3456x2234
frame cap: 60 FPS
```

double-click the command or run it from Terminal. it finds the single Screw
Drivers installation under Whisky's bottle folder, so no bottle UUID or username
is stored in this repository. Steam launches app 1279510 offline inside the test
desktop, which keeps the game's working directory correct without syncing saves.

the launcher is local-save only. it reads Steam's per-game setting and refuses to
start unless cloud is disabled for Screw Drivers. other games are not changed.

use `--check` for a read-only preflight:

```sh
./experiments/screw-drivers/Test\ Screw\ Drivers\ MetalFX.command --check
```

`Test Screw Drivers Lower Latency.command` runs the same setup at a 120 FPS cap.
it is an A/B test for the small amount of input latency found in the first full
play session, and it is expected to use more CPU. its read-only check is:

```sh
./experiments/screw-drivers/Test\ Screw\ Drivers\ MetalFX.command --check-lower-latency
```

## what to look for

- text and thin part edges should look clearer than the normal 1728x1117 launch;
- the UI should stay at a usable size;
- driving should not show halos, flicker, trails, or broken transparency;
- motion should feel at least as even as the normal DXVK launch;
- vehicle calculation and map loading should be tested separately.

quit the game normally when the comparison is finished. Steam may still evaluate
its cached file list, but the command requires the `Sync Disabled` marker and
rejects any actual sync mode. it then closes the test bottle and restores the exact
metadata, program settings, and eight renderer DLLs it found before launch.
interruption and Terminal close use the same restore path.

the first direct-launch version wrote one session under `C:\windows`. that exact
44-file session is now restored beside the game as the active local save. both the
older Steam state and the later cloud-modified state have separate verified
rollback backups.

each run writes hashes, process samples, and the Unity player log under
`~/Library/Logs/OpenBottle`. those machine-specific logs are local and should not
be committed directly.
