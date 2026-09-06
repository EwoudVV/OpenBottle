# Screw Drivers baseline — 5 september 2026

this is the first OpenBottle benchmark. it answers a narrow question: what changes
when the same Screw Drivers menu scene runs through DXVK or DXMT on the same Mac?

## test machine

| item | value |
| --- | --- |
| Mac | MacBook Pro 16-inch, 2021 (`MacBookPro18,2`) |
| chip | Apple M1 Max, 10 CPU cores and 32 GPU cores |
| memory | 64 GB |
| display | 3456x2234 built-in Liquid Retina XDR |
| macOS | 26.5.2 |
| app | Whisky 3.6.1 |
| Wine | 11.0 |
| DXVK | 1.10.3 |
| DXMT | 0.80 |
| game | Screw Drivers, Steam app 1279510, Unity 6000.0.73f1 |

## method

each run used the same existing Wine bottle and a 1728x1117 virtual desktop. the
runner did the following:

1. saved the bottle metadata and all eight 32-bit and 64-bit renderer DLLs;
2. selected one backend and verified the active DLLs against the pinned runtime;
3. started Steam and waited for its successful-login log entry;
4. started `Screw Drivers.exe` in the same virtual desktop;
5. waited for the game's own `Setting Drivers License main menu pic mode to big pic`
   marker;
6. sampled the real game process once per second for 60 seconds;
7. closed the test bottle and restored every saved file;
8. compared the restored SHA-256 manifest with the original manifest.

the capped runs used `DXVK_FRAME_RATE=60` or
`DXMT_CONFIG=d3d11.preferredMaxFrameRate=60`. macOS process CPU can exceed 100%;
100% is roughly one fully occupied CPU core.

## results

| backend | cap | menu ready | average CPU | CPU range | average resident memory | average threads |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| DXVK | none | 44 s | 111.64% | 92.7–131.8% | 5213.4 MB | 97.9 |
| DXMT | none | 42 s | 320.44% | 101.9–352.9% | 5296.6 MB | 103.3 |
| DXVK | 60 FPS | 44 s | 115.62% | 91.8–124.6% | 5159.1 MB | 97.0 |
| DXMT | 60 FPS | 43 s | 157.72% | 153.8–161.3% | 5298.3 MB | 88.0 |

every backend hash check passed. every restoration hash check passed. the DXVK
log reported Direct3D 11 feature level 11.0 and the DXMT log reported feature
level 11.1 on the Apple M1 Max.

## first full play session

the 60 FPS DXMT + MetalFX 2x launcher then ran for 21 minutes and 3 seconds. it
collected 1,227 process samples with 210.23% average game CPU and 5,942.3 MB
average resident memory. the game moved through its garage, building, selection,
and driving scenes, completed four races, wrote four ghost results, awarded XP,
and updated driven distance.

the visual result looked close to native resolution during actual driving. the
UI remained usable and no visible upscaling problem was reported. a small amount
of input latency remained. frame times were not captured, so this is a successful
visual and playability check rather than a complete latency result.

the first direct test launch also exposed a save-path bug: its Windows working
directory was `C:\windows`, so that session created a separate fresh save instead
of changing the older Steam-managed save beside the game. both trees were copied
into one timestamped backup and all 812 payload hashes passed verification. the
the launcher was then changed to use Steam's `-applaunch 1279510` path, wait for
Steam Cloud's per-game evaluation after exit, and refuse to run while a separate
save still needed a deliberate choice.

that cloud behavior was removed on 6 september. Steam later changed the active
game-folder copy, so the cloud-modified state was preserved in a second verified
rollback backup and the 44-file local session was restored byte-for-byte. the
launcher now refuses to run unless Steam's per-game `cloudenabled` value is `0`,
starts Steam with `-offline`, records the active save hash before and after play,
and checks that the cloud log did not receive another sync event.

a short 120 FPS startup check confirmed the game process used the Screw Drivers
install folder as its working directory. Steam logged `AC Launch,Sync Disabled`,
the active save hash stayed unchanged, every renderer restoration hash matched,
and the bottle returned to DXVK.

## what this says

DXMT did much more work when uncapped. its 60 FPS limiter cut average CPU use by
about half, from 320.44% to 157.72%. DXVK changed very little when capped, which
suggests it was already close to or below that rate in the menu scene.

at the same requested cap, DXMT used about 36% more CPU than DXVK. that is not a
complete performance ranking because the test could not confirm how many frames
each backend actually delivered. DXMT may still be the smoother renderer.

menu-load time was effectively tied. the several-second differences in Steam
startup were dominated by launcher and network state and are not being treated as
a renderer result.

## measurement limit

Apple's Metal HUD appeared and `libMTLHud` loaded, but the Wine game process did
not emit the documented once-per-second `metal-HUD` records. the test tried both
`MTL_HUD_LOGGING_ENABLED=1` and the `MetalForceHudEnabled` user default, with the
default restored after the run. Xcode's newer Metal tracing utilities were not
installed.

the raw logs stay out of Git because they contain local paths and Steam account
details. this file contains the scrubbed result.

## next test

the working visual configuration is DXMT with:

```text
DXMT_METALFX_SPATIAL_SWAPCHAIN=1
DXMT_CONFIG=d3d11.preferredMaxFrameRate=60;d3d11.metalSpatialUpscaleFactor=2.0
```

the 2x factor maps the current 1728x1117 render to the panel's 3456x2234 pixel
grid. DXMT already keeps this swapchain at one queued frame, so there is no extra
queue depth to remove. the next controlled comparison is the same route at 60
and 120 FPS. 120 FPS cuts the target frame interval from about 16.7 ms to 8.3 ms,
but the earlier uncapped result shows that it will probably use substantially more
CPU.

after that, one repeatable vehicle calculation and one map load need event markers
and process samples. those operations are the useful CPU test; an idle menu cannot
tell us whether Wine, Rosetta, synchronization, or the game itself is responsible
for their delay.
