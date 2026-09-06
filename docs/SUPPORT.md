# support

OpenBottle is an early open-source project. Before reporting a problem, use the
in-app preflight check, retry with the conservative profile, and export the
scrubbed diagnostic report if the launch still fails.

- app bug: [bug report](https://github.com/EwoudVV/OpenBottle/issues/new/choose)
- game result: [compatibility report](https://github.com/EwoudVV/OpenBottle/issues/new/choose)
- idea: [feature request](https://github.com/EwoudVV/OpenBottle/issues/new/choose)
- private security problem: [security advisory](https://github.com/EwoudVV/OpenBottle/security/advisories/new)

A useful game report includes the OpenBottle version, macOS version, Mac model,
game and store version, selected renderer and runtime, what happened after Play,
and the exported report. Do not attach saves, account details, tokens, or raw
logs that have not been reviewed.

Some Windows games require kernel drivers, kernel anti-cheat, or DRM that Wine
cannot provide on macOS. OpenBottle should identify that case before launch and
say so plainly; a profile cannot work around it.
