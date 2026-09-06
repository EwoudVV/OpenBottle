# release workflow

OpenBottle has two separate artifact streams:

- app releases use tags such as `app-v0.1.0-alpha.1` and contain matching DMG,
  ZIP, and SHA-256 files;
- the first alpha consumes the declared upstream runtime archive and installs
  it into a verified OpenBottle slot with its own manifest.

## preview

The Preview workflow builds the `OpenBottle` scheme on GitHub's macOS runner,
checks the app identity and bundled resources, ad-hoc signs the nested code and
app, makes a DMG, and uploads both it and its SHA-256 as workflow artifacts. A
preview does not claim Developer ID signing or notarization.

Run it with:

```sh
gh workflow run Preview.yml -f label=0.1.0-alpha.1
```

Download the finished artifact from that workflow run. For a public test build,
create a GitHub prerelease whose notes state that it is ad-hoc signed and not
notarized, then attach the same DMG, ZIP, and checksum.

## signed release

A normal macOS release needs an Apple Developer Program team, a Developer ID
Application certificate, and `notarytool` credentials stored in the Keychain.
Do not reuse an upstream team, certificate, Sparkle key, appcast signature, or
bundle identifier.

Store the notary credentials under a profile name, then run:

```sh
NOTARY_PROFILE=AC_PASSWORD ./scripts/release.sh 0.1.0
```

The script archives `OpenBottle.xcodeproj` with the `OpenBottle` scheme, exports
`OpenBottle.app`, verifies its signature, builds and signs the DMG, submits it to
Apple, staples the ticket, and prints the checksum.

Before publishing, verify:

```sh
codesign --verify --deep --strict --verbose=2 OpenBottle.app
spctl --assess --type execute --verbose=2 OpenBottle.app
xcrun stapler validate OpenBottle-0.1.0.dmg
shasum -a 256 OpenBottle-0.1.0.dmg
```

## Sparkle

App updates are disabled in `DistributionConfig` until the first signed release.
Before enabling them:

1. generate and securely back up a new OpenBottle Sparkle EdDSA key;
2. put only its public key in `Whisky/Info.plist`;
3. add the signed release to `dist/pages/appcast.xml`;
4. verify the enclosure URL, byte size, version, and signature;
5. enable `DistributionConfig.appUpdatesEnabled` in the same signed release.

Losing the private Sparkle key strands installed copies, so restore-test the
backup before shipping.

## release checks

- all package tests, Xcode schemes, UI tests, localization checks, and secret
  scans pass at the exact tag;
- the app bundle is `OpenBottle.app` with bundle identifier
  `io.github.ewoudvv.OpenBottle`;
- `/Applications/Whisky.app` and every Whisky data container remain untouched;
- a copied legacy bottle launches and its source hashes still match;
- a runtime update preserves the last known-good slot;
- save restore, launch cleanup, and interrupted-launch recovery pass;
- the compatibility notes state the tested Mac, macOS, game build, runtime, and
  profile.
