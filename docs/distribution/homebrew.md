# Homebrew distribution

The current v0.3.1 release is ad-hoc signed and not notarized, as requested by
the maintainer. In-app updates are disabled; use Homebrew to upgrade. Future
signed updates require the setup described in [signed updates](updates.md).

## Install

The v0.3.1 cask is published in
[homebrew-tap](https://github.com/brunovskyoliver/homebrew-tap).
Homebrew discovers that repository automatically from the tap name.

```sh
brew install --cask brunovskyoliver/tap/localflow
```

Open LocalFlow from Applications. If macOS blocks it, dismiss the warning and,
if you trust the download, go to System Settings > Privacy & Security and click
Open Anyway for LocalFlow. Confirm the dialog. This is Apple's per-app exception;
Gatekeeper stays enabled. Managed Macs may prohibit it. See
[Apple's instructions](https://support.apple.com/102445).

Allow Microphone access and follow the app's permission setup. Global shortcuts
need Input Monitoring; insertion may need Accessibility. Meeting capture requests
Screen & System Audio Recording. Install models through the app. Homebrew does
not download model weights or grant privacy permissions.

Quit the app before updating:

```sh
brew update
brew upgrade --cask brunovskyoliver/tap/localflow
```

This release does not declare `auto_updates`; the ordinary upgrade command above
is sufficient. macOS may request permissions again after replacement.

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

Follow [signed updates](updates.md). The release workflow now requires protected
signing/notarization credentials and a compatible-server attestation before it
can publish. Local signed test artifacts use the explicit `--signed-local` mode;
they are not notarized and have update checking disabled. No release has been
published merely by adding this workflow.
