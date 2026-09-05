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
is stored in this repository.

use `--check` for a read-only preflight:

```sh
./experiments/screw-drivers/Test\ Screw\ Drivers\ MetalFX.command --check
```

## what to look for

- text and thin part edges should look clearer than the normal 1728x1117 launch;
- the UI should stay at a usable size;
- driving should not show halos, flicker, trails, or broken transparency;
- motion should feel at least as even as the normal DXVK launch;
- vehicle calculation and map loading should be tested separately.

quit the game normally when the comparison is finished. the command then closes
the test bottle and restores the exact metadata, program settings, and eight
renderer DLLs it found before launch. interruption and Terminal close use the same
restore path.

each run writes hashes, process samples, and the Unity player log under
`~/Library/Logs/OpenBottle`. those machine-specific logs are local and should not
be committed directly.
