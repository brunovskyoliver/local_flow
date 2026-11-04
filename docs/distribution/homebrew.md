# Homebrew distribution

From v0.4.0 the cask installs the Rust desktop app (ADR 0036). Swift builds are no longer
published to Homebrew. The app is ad-hoc signed and not notarized; the cask clears the
download's quarantine flag so it opens without the Open Anyway step. Gatekeeper stays on
for everything else.

## Install

On a Mac with Apple silicon and macOS 14 or later:

```sh
brew install --cask brunovskyoliver/tap/localflow
```

Open LocalFlow from Applications. It runs in the menu bar. Setup asks what it's for:

- **Meeting notes**: record calls and get transcripts and notes. No shortcut and no
  keyboard permissions; only Microphone and Screen & System Audio Recording.
- **Dictation**: hold a key in any app and talk. Needs Microphone and Input
  Monitoring, and Accessibility for typing into some apps.
- **Both**.

Next it asks where the AI runs: on this Mac (models download inside the app) or on a
LocalFlow server (paste the token or link the server's owner gives you; nothing is
downloaded). A meetings-only install on a server is the lightest setup. Dictation can be
turned on later in Settings. On an Apple-silicon Mac, setup can also make this Mac the
server for other people (see [remote-server.md](remote-server.md)).

Update and uninstall through Homebrew:

```sh
brew upgrade --cask localflow
brew uninstall --cask localflow
```

The cask quits the app first. macOS may ask for permissions again after an upgrade,
because each ad-hoc build has a new signature. Uninstalling keeps Application Support
(recordings, transcripts, models and settings); there is deliberately no `zap` stanza.

A Mac that ran the Swift app keeps its data: the Rust app reads the Swift app's
settings, history and models on first launch.

## Make a release

On an Apple-silicon Mac with Xcode, Go and Rust, from a clean `main`:

```sh
scripts/package-rust-macos.sh X.Y.Z
git tag vX.Y.Z && git push origin vX.Y.Z
gh release create vX.Y.Z build/distribution/X.Y.Z/LocalFlow-X.Y.Z-arm64.zip \
  build/distribution/X.Y.Z/LocalFlow-X.Y.Z-arm64.zip.sha256 \
  build/distribution/X.Y.Z/localflow.rb --title "LocalFlow X.Y.Z" --notes-file NOTES.md --latest
```

The tap's sync workflow copies the release's `localflow.rb` to `Casks/localflow.rb` within
the hour; start it from the tap's Actions tab to publish at once. The signed Swift
workflow (`.github/workflows/release.yml`) now runs only when started by hand.

## Use a shared LocalFlow server

A Homebrew install can send dictation, rewriting, summaries and meetings to a
LocalFlow server, such as the owner's Mac mini, instead of running models locally.
The server serves only its tailnet (`tailscale serve`, see
[remote-server.md](remote-server.md)), so each user first needs a route to it.

The server owner:

1. In the Tailscale admin console, open Machines › (the server) › Share and send the
   invite link. Sharing gives the user that one machine and nothing else of the
   tailnet; shared users don't count against the plan's user limit.
2. Limit shared users to the HTTPS port in the tailnet policy, so they can't reach
   SSH, oMLX (8443) or other services on the machine. If the policy still has the
   default allow-all rule, change its `src` from `*` to `autogroup:member` first.

   ```json
   {"grants": [{"src": ["autogroup:shared"], "dst": ["*"], "ip": ["tcp:443"]}]}
   ```

3. On the server Mac, open LocalFlow › Users and choose **Add device…** for an
   existing person or **New person…**. Send the token or link it shows; it works
   once and expires.

The user:

1. Install Tailscale (`brew install --cask tailscale-app`, or the Mac App Store),
   sign in with any account and accept the share invite.
   `curl -s <server address>/v1/remote/identity` should answer.
2. Install LocalFlow as above and grant its permissions.
3. In setup, or later in Settings › Server, choose a LocalFlow server and paste
   the pairing token or link the owner made for you on the Users page. Check that
   the fingerprint matches the one the owner gives you.
4. A redeemed token approves the device at once. To add your other devices
   (for example your iPhone) to the same account, use **Add another device** in
   Settings › Server on a device that is already paired; no step is needed on
   the server Mac.

Without Tailscale running, the app finds the server unreachable and dictates
locally. Local models are then needed only for that fallback.

The server must be at least as new as the app: flowd rejects request fields it
doesn't know. Update the server before publishing an app release.
