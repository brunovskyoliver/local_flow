# Remote dictation server: setup on the Mac mini

The steps that worked in the provisional run on 2026-09-28 (Feature 014, ADR 0028), written for a fresh Mac mini. The production variant is shown; add `--dev` everywhere for the development variant, whose labels gain `.dev`, whose ports are 18090/18091/18092, and whose folders end in ` Dev`.

## What the server runs

| Launch agent | Listens on | Role |
| --- | --- | --- |
| `org.localflow.LocalFlow.remote` | 127.0.0.1:8090 (remote channel), 127.0.0.1:8091 | flowd: accounts, the encrypted channel, scheduling; starts `flowd-speech` |
| `org.localflow.LocalFlow.remote.mtplx` | 127.0.0.1:8092 | the server's own MTPLX rewrite model, with its own key |

Data: `~/Library/Application Support/LocalFlow Server` (the account database, identity key, MTPLX key and speech models; mode 0700). Logs: `~/Library/Logs/LocalFlow Server`. Neither agent touches a LocalFlow app installed on the same Mac.

## Prerequisites

1. Xcode, to build `flowd-speech`, and Go 1.26 (`brew install go`).
2. An MTPLX runtime and model. The simplest way is to install LocalFlow.app on the Mac mini and let onboarding set up local AI; the installer then reuses its runtime and model. Otherwise pass `--mtplx PATH --model DIR`.
3. A permanent HTTPS hostname. For Cloudflare, that is a domain whose DNS Cloudflare runs, and `brew install cloudflared`. A quick tunnel (`cloudflared tunnel --url …`) changes its address on every start, and every address change means signing in and approval again.
4. A Google OAuth client of type iOS for each client bundle ID: `org.localflow.LocalFlow` for the everyday app, and `org.localflow.LocalFlow.dev` for development builds. The client ID is not secret.
5. Optional: Sign in with Apple needs a paid Apple Developer membership, App IDs with the capability, and a provisioning profile (`LOCALFLOW_PROVISIONING_PROFILE`).

## Install

```sh
git clone <repository> && cd local-flow && git checkout <branch with Feature 014>
GOOGLE=<iOS client ID for org.localflow.LocalFlow>
DATA="$HOME/Library/Application Support/LocalFlow Server"

# 1. Build and install. The first run stops at "the server is not initialized".
scripts/install-remote-server.sh --google-client-id "$GOOGLE"

# 2. Create the server identity. Note the fingerprint: clients pin it.
"$DATA/bin/flowd" admin --data-dir "$DATA" init
"$DATA/bin/flowd" admin --data-dir "$DATA" identity

# 3. Download and verify the speech models (Parakeet v3 and the term booster).
"$DATA/bin/flowd-speech" provision --models "$DATA/Models" --booster

# 4. Load both agents. Reuse the worker from step 1 instead of building it again.
scripts/install-remote-server.sh --google-client-id "$GOOGLE" --speech-worker "$DATA/bin/flowd-speech"

# 5. Check: backend "ready" and the identity answers.
curl -s http://127.0.0.1:8091/v1/rewrite/health
curl -s http://127.0.0.1:8090/v1/remote/identity
```

On the first dictation after install, the worker compiles the CoreML model, which took about 25 s on an M5.

## Tunnel (Cloudflare, permanent hostname)

```sh
cloudflared tunnel login
cloudflared tunnel create localflow
cloudflared tunnel route dns localflow flow.<your-domain>
cat > ~/.cloudflared/config.yml <<EOF
tunnel: localflow
credentials-file: $HOME/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: flow.<your-domain>
    service: http://127.0.0.1:8090
  - service: http_status:404
EOF
sudo cloudflared service install
curl -s https://flow.<your-domain>/v1/remote/identity   # same fingerprint as step 2
```

The client pins the server key, and audio and text are encrypted inside the channel, so Cloudflare sees only ciphertext.

## Clients

Build the app with the Google client for its bundle ID:

```sh
LOCALFLOW_GOOGLE_CLIENT_ID=<client ID> make run        # everyday app
LOCALFLOW_GOOGLE_CLIENT_ID=<dev client ID> make run-dev   # LocalFlow Dev, beside it
```

In the app: Settings › Remote dictation › Turn on, confirm the consent sheet, enter `https://flow.<your-domain>`, check the fingerprint, and sign in. The app shows "Waiting for approval" and keeps dictating locally.

## Administration

```sh
F="$DATA/bin/flowd"; A=(admin --data-dir "$DATA")
"$F" "${A[@]}" list                              # users and devices with their states
"$F" "${A[@]}" approve user <id>; "$F" "${A[@]}" approve device <id>
"$F" "${A[@]}" reject user <id>
"$F" "${A[@]}" revoke device <id>                # ends that device's live sessions at once
"$F" "${A[@]}" revoke user <id>
"$F" "${A[@]}" audit
```

After approval, the device's next dictation starts the check, and the one after it goes to the server; no restart is needed.

## Uninstall

```sh
for l in org.localflow.LocalFlow.remote org.localflow.LocalFlow.remote.mtplx; do
  launchctl bootout "gui/$(id -u)/$l"; rm -f "$HOME/Library/LaunchAgents/$l.plist"
done
rm -rf "$HOME/Library/Application Support/LocalFlow Server" "$HOME/Library/Logs/LocalFlow Server"
```

The MTPLX models in `~/.mtplx/models` are shared with LocalFlow.app and stay. To remove a development app, quit it, then delete `/Applications/LocalFlow Dev.app`, `~/Library/Application Support/LocalFlow Dev`, `~/Library/Logs/LocalFlow Dev`, the `org.localflow.LocalFlow.dev` defaults, and the Keychain items whose service starts with `org.localflow.LocalFlow.dev.remote`. Do not unload a development app's own `.dev.flowd`/`.dev.mtplx` agents with `launchctl bootout` while you intend to keep using it: Login Items still lists them as enabled, so they come back only at the next login.
