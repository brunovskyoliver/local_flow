# Signed Mac updates

Public downloads do not grant server access. Users still sign in and wait for
administrator approval. LocalFlow's Mac client uses a single stable Sparkle feed,
with optional background checks and user-confirmed installation. The remote
server is deployed separately and must be compatible before a client release.

## Current release exception

The maintainer explicitly chose ad-hoc distribution for the v0.3.x releases. It is not notarized and has in-app updates disabled. Publish only its ZIP and checksum, without a signed appcast or the generated auto-updating Homebrew cask. Users install it manually and may need to approve its first launch in macOS Privacy & Security. The signed production procedure below remains the path for enabling in-app updates later.

Manual v0.3.x tags do not trigger the production-only release workflow. Its explicit
workflow dispatch remains available for a deliberately configured signed release,
and other version tags retain the signing and compatible-server prerequisites.

## First signed installation

Older ad-hoc builds contain no updater or trusted update public key. Install the
first signed release manually from its public GitHub Release ZIP or through the
Homebrew tap. Quit LocalFlow before replacement. Keep the same bundle identifier
and application data paths; never remove Application Support or reset Keychain as
part of an upgrade.

A transition from ad-hoc or Apple Development signing to Developer ID may require
macOS privacy permissions, background-item approval or credential access again.
Test each transition on a separate Mac and record what macOS requests. Existing
signing identities belonging to different Apple teams are not interchangeable
for future updates. Keep the chosen production Developer ID identity/team and
Sparkle verification key stable.

Subsequent updates use “Check for Updates…” in the app menu or Settings. The app
waits for active capture/finalization/model work before relaunching. Startup
reconciles owned bundled helpers, including after manual replacement; a stale
helper is not accepted as the newly installed version. No remote server agent or
other LocalFlow variant is restarted.

## Credentials and local preparation

Use the existing Developer ID Application identity in Keychain. Never paste
private keys or passwords into chat. Production packaging requires:

- `LOCALFLOW_SIGNING_IDENTITY`: the Developer ID Application identity name.
- `LOCALFLOW_NOTARY_PROFILE`: an existing `notarytool` Keychain profile.
- `LOCALFLOW_UPDATE_PUBLIC_KEY`: the Sparkle Ed25519 public verification key.
- `LOCALFLOW_UPDATE_KEY_FILE`: a protected private-key file supplied by the release
  environment for signing; remove temporary material after use.
- `LOCALFLOW_UPDATE_FEED_URL`: the fixed HTTPS feed. The prepared workflow uses
  `https://github.com/brunovskyoliver/local_flow/releases/latest/download/appcast.xml`.

The first public updater key must be provisioned and backed up deliberately.
Do not generate throwaway production keys. Test fixtures are not production keys.

`./scripts/package-macos.sh VERSION BUILD_NUMBER --signed-local` builds and signs
with the existing identity without notarization or a network timestamp. It is a
local verification artifact with updates disabled, not a distributable release.
`--ad-hoc` is also available explicitly for local testing. Default production
packaging fails if any required configuration is missing; it never falls back to
ad-hoc signing. Production mode submits to Apple and is an external action.

## Release procedure

1. Run `make check`, transport/signature tests and the clean-Mac acceptance cases
   below. Review the release commit, increasing build number and release notes.
2. Prepare and verify a compatible remote server deployment separately. Record
   its tested release tag in `LOCALFLOW_COMPATIBLE_SERVER_TAG`; this is an
   administrator attestation checked by CI, not an automatic compatibility probe.
3. Configure the protected `macos-release` GitHub environment and its secrets.
   The workflow lists required certificate, notarization and update-key names.
   Use environment approval protection. No such environment or secret is created
   by the local implementation.
4. With explicit authorization for notarization/publication, build the production
   archive, notarize, staple, verify and generate its signed appcast. Validate the
   complete artifact set before creating the draft GitHub Release. The workflow
   publishes the draft only after all files are attached.
5. Never replace published archive bytes. Consider GitHub immutable releases.
   Publish a higher build for corrections; do not downgrade a migrated database
   automatically. Keep Homebrew's cask synced to the same verified artifact.
6. Verify the stable feed, download URL, signature and installed app/helper build
   on a separate Mac. Exercise in-app updating and explicit Homebrew upgrading
   after an in-app update. Do not run the two installers simultaneously.

Homebrew's `auto_updates true` marks that the app has its own updater. Users who
choose manual Homebrew updates should use its documented `--greedy` upgrade
option for auto-updating casks and quit the app first.

## Acceptance still required before publication

- Ad-hoc and Apple Development bootstrap to the chosen Developer ID build.
- Signed version N to N+1 through the real feed, with permissions, background
  agents, Keychain, recordings, transcripts, settings and models preserved.
- Active-work deferral, cancelled quit, interrupted download, corrupt signature,
  unsupported OS, disk exhaustion and stale-helper restart failure.
- Correct helper identity after relaunch and no changes to another app variant
  or separately controlled server.
- Measured idle/update memory, download size and peak staging disk use, with
  hardware, OS and build recorded.

Local test results do not establish notarization, publication or these live
acceptance gates. See the feature's `acceptance/updates.md` for actual evidence.
