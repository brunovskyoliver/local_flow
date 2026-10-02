# Homebrew distribution

Releases are signed with the Developer ID of e-Net, s.r.o. (team 944A459UC3),
use the hardened runtime and are notarized by Apple, so Gatekeeper checks the
publisher and Apple's malware scan on first launch. Local packages without the
certificate are still ad-hoc signed; only notarized builds get a cask.

## Install

The command below becomes available after the first release is published and
its cask is synced to [homebrew-tap](https://github.com/brunovskyoliver/homebrew-tap).
Homebrew discovers that repository automatically from the tap name.

```sh
brew install --cask brunovskyoliver/tap/localflow
```

Open LocalFlow from Applications. macOS asks once whether to open an app
downloaded from the internet and names its developer, e-Net, s.r.o.

Allow Microphone access and follow the app's permission setup. Global shortcuts
need Input Monitoring; insertion may need Accessibility. Meeting capture requests
Screen & System Audio Recording. Install models through the app. Homebrew does
not download model weights or grant privacy permissions.

Quit the app before updating:

```sh
brew update
brew upgrade --cask brunovskyoliver/tap/localflow
```

The signature stays the same across updates, so privacy permissions carry over.
Users coming from an ad-hoc release (0.1.x) may need to remove and re-add LocalFlow
in Input Monitoring and Accessibility once after the first signed update.

## Use a shared LocalFlow server

A Homebrew install can send dictation, rewriting, summaries and meetings to a
LocalFlow server, such as the owner's Mac mini, instead of running models locally.
The server serves only its tailnet (`tailscale serve`, see
[remote-server.md](remote-server.md)), so each user first needs a route to it.

The server owner:

1. In the Tailscale admin console, open Machines › mac-mini › Share and send the
   invite link. Sharing gives the user that one machine and nothing else of the
   tailnet; shared users don't count against the plan's user limit.
2. Limit shared users to the HTTPS port in the tailnet policy, so they can't reach
   SSH, oMLX (8443) or other services on the machine. If the policy still has the
   default allow-all rule, change its `src` from `*` to `autogroup:member` first.

   ```json
   {"grants": [{"src": ["autogroup:shared"], "dst": ["*"], "ip": ["tcp:443"]}]}
   ```

3. Approve each user and device in the LocalFlow Server app (Devices tab) or
   with `flowd admin approve user|device <id>`.

The user:

1. Install Tailscale (`brew install --cask tailscale-app`, or the Mac App Store),
   sign in with any account and accept the share invite.
   `curl -s https://mac-mini.tailf15b6.ts.net/v1/remote/identity` should answer.
2. Install LocalFlow as above and grant its permissions.
3. In Settings › Server, turn on Remote dictation, confirm the consent sheet and
   enter `https://mac-mini.tailf15b6.ts.net`. Check that the fingerprint matches
   the one the owner gives you, then sign in with Google. Sign in with Apple
   needs an Apple-signed build and does not work in the Homebrew release.
4. The app shows "Waiting for approval" and dictates locally until the owner
   approves. Then turn on **Use this server for everything**. Check connection
   times one round trip.

Without Tailscale running, the app finds the server unreachable and dictates
locally. Local models are then needed only for that fallback.

The server must be at least as new as the app: flowd rejects request fields it
doesn't know. Update the server before publishing an app release.

Quit LocalFlow before `brew uninstall --cask localflow`. The cask preserves
Application Support data, including recordings, transcripts, models and settings.
There is deliberately no destructive `zap` stanza.

## Make a release

1. Commit the distribution setup to main and push it. The repository and release
   assets must be publicly readable for these installation commands.
2. Ensure GitHub Actions can write repository contents in both repositories.
   The app workflow publishes releases; the tap workflow updates its own main
   branch. No cross-repository token is required. Set the repository variable
   `LOCALFLOW_GOOGLE_CLIENT_ID` to the iOS OAuth client of `org.localflow.LocalFlow`;
   without it the release can't sign in to a server. Signing and notarization need
   these secrets: `DEVELOPER_ID_P12` (the Developer ID Application certificate and
   key exported as .p12, base64), `DEVELOPER_ID_P12_PASSWORD`, and `NOTARY_APP_PASSWORD`
   (an app-specific password of a team member's Apple ID, from account.apple.com);
   and the variable `NOTARY_APPLE_ID` with that Apple ID. The team's App Store
   Connect API access is off, which is why notarization uses an Apple ID.
3. Push a new version tag, such as `v0.1.0`. Use increasing X.Y.Z versions.
   To retry a failed release after fixing CI, run the release workflow manually
   from main with the original tag. This preserves the tagged source commit.
4. Run `make check` locally before tagging. CI builds on Apple Silicon, signs all nested
   binaries and the app with Developer ID and the hardened runtime, notarizes and
   staples it, checks it with `spctl`, creates a ZIP and checksum,
   publishes the GitHub Release with the generated `localflow.rb` asset.
   The tap checks for releases hourly and commits that cask to its main branch.
   For an immediate update, run its Sync LocalFlow release workflow manually.
5. Check the workflow, download URL, checksum and generated cask. Test installation,
   first launch, dictation, helper services, upgrading and uninstalling on a
   clean Mac before advertising the release.

The workflow uses the macos-26 ARM runner and its default Xcode. The local project
was developed with Xcode 26.4.1; hosted-runner compatibility must be established
by the first CI run. The signing certificate lives in a temporary keychain for the run.
If tap synchronization fails, rerun its workflow or copy the release's
`localflow.rb` asset into `Casks/localflow.rb` in homebrew-tap through a pull
request. Scheduled runs may be delayed; GitHub can disable schedules after
60 days without repository activity, so check the tap Actions page if it falls
behind. Never replace a published ZIP with different bytes.

For a local package, install Xcode, Go, CMake and FFmpeg, then run:

```sh
make check
./scripts/package-macos.sh 0.1.0 1
```

That package is ad-hoc signed. For a signed, notarized one, set
`LOCALFLOW_SIGNING_IDENTITY='Developer ID Application: e-Net, s.r.o. (944A459UC3)'`
and either `LOCALFLOW_NOTARY_PROFILE` (a `xcrun notarytool store-credentials` profile)
or `LOCALFLOW_NOTARY_APPLE_ID`, `LOCALFLOW_NOTARY_PASSWORD` and `LOCALFLOW_NOTARY_TEAM_ID`.

Artifacts are written to `build/distribution/0.1.0/`. Packaging does not install
or open the app and does not modify the source Info.plist. The existing
`make release` command remains a development launch command.

This setup does not establish clean-Mac acceptance, macOS 14 runtime compatibility,
or resource measurements. Optional local AI provisioning and background services
also need clean-Mac testing.

Constitution check: distribution tooling only; no app architecture, model lifecycle,
wire schema, storage or runtime dependency changes. No architecture exception.
