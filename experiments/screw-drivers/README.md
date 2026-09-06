# Screw Drivers experiments

`Test Screw Drivers MetalFX.command` is the first playable OpenBottle experiment.
it runs the existing Whisky installation with:

```text
renderer: DXMT 0.80
game render: 1728x1117
MetalFX output target: 3456x2234
frame cap: 120 FPS
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

120 FPS is now the normal mode after it felt noticeably more responsive in a
direct comparison. `Test Screw Drivers Lower Latency.command` remains as an alias
for it. the old 60 FPS mode is still available with `--balanced`.

read-only checks for both modes are:

```sh
./experiments/screw-drivers/Test\ Screw\ Drivers\ MetalFX.command --check
./experiments/screw-drivers/Test\ Screw\ Drivers\ MetalFX.command --check-balanced
```

## what to look for

- text and thin part edges should look clearer than the normal 1728x1117 launch;
- the UI should stay at a usable size;
- driving should not show halos, flicker, trails, or broken transparency;
- motion should feel at least as even as the normal DXVK launch.

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
