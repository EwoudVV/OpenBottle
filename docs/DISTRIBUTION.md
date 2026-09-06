# distribution

OpenBottle is its own app. Its bundle identifier, bottles, runtime, command,
links, and update feed do not overlap with Whisky.

## preview builds

Every preview is built from a tag in `EwoudVV/OpenBottle`. The release contains:

- `OpenBottle-<version>.dmg`;
- a SHA-256 checksum;
- the source commit and release notes;
- a runtime manifest naming every downloaded component, license, source, and
  hash.

Until a Developer ID signing identity and notarization credentials are configured,
previews are marked unsigned. They are useful for development and local testing,
but they are not presented as normal public installs.

## signed releases

`scripts/release.sh <version>` archives the `OpenBottle` scheme, exports a
Developer ID build, signs the DMG, sends it to Apple's notary service, staples
the result, and prints its SHA-256. It expects the signing certificate in the
Keychain and a `notarytool` profile named `AC_PASSWORD` unless
`NOTARY_PROFILE` is set.

The Sparkle updater stays disabled until OpenBottle has its own signing key and
at least one signed release. Enabling it requires an OpenBottle appcast entry,
signature, archive size, and release URL. An inherited Whisky feed must never be
used.

## Homebrew

The existing `whisky` casks belong to other projects. If an OpenBottle tap is
created, set the repository variable `HOMEBREW_TAP_REPOSITORY` to its
`owner/repository` name and add a `BREW_TOKEN` secret with write access. The tap
workflow only updates `Casks/openbottle.rb` and only for `app-v*` releases.

## documentation

GitHub Pages is built from `dist/pages` under the `/OpenBottle` base path. Pages
deployment remains opt-in through the `PUBLISH_DOCUMENTATION` repository
variable until the content and release links are ready.
