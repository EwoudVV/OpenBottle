# Security policy

OpenBottle is early software. Security fixes are made on `main` and included in
the next preview. Old previews are not supported after a newer one is published.

## reporting a vulnerability

Please use GitHub's private
[vulnerability report](https://github.com/EwoudVV/OpenBottle/security/advisories/new).
Do not put an unpatched vulnerability in a public issue.

Include the affected version, what an attacker can do, steps to reproduce it,
and any fix you already tested. Reports about Wine, DXMT, DXVK, MoltenVK, or
another dependency should also go to that upstream project, but tell OpenBottle
when the problem can be reached through a normal game launch.

## trust boundary

Windows programs launched through Wine can read files that Wine exposes to the
prefix. OpenBottle does not turn an untrusted Windows executable into safe code.
Only run software you trust and review the folders mapped into its bottle.

OpenBottle verifies downloaded runtime manifests and archives before installing
them. Existing Whisky bottles are discovered read-only and migration makes a
verified copy; the source is never adopted or changed in place.

## private data

OpenBottle does not have a telemetry endpoint or send compatibility reports by
default. Saves, launch history, diagnostics, hardware details, and compatibility
results stay on the Mac unless the user exports and shares them. Diagnostic
exports redact home paths and known token patterns.

The save vault stores local copies inside OpenBottle's own application data.
Restores are verified and keep the replaced save as a rollback point.
