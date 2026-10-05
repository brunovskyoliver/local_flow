# Remote dictation server: setup on the Mac mini

The steps that worked in the provisional run on 2026-09-28 (Feature 014, ADR 0028), written for a fresh Mac mini. The production variant is shown; add `--dev` everywhere for the development variant, whose labels gain `.dev`, whose ports are 18090/18091/18092, and whose folders end in ` Dev`.

## What the server runs

| Launch agent | Listens on | Role |
| --- | --- | --- |
| `org.localflow.LocalFlow.remote` | 127.0.0.1:8090 (remote channel), 127.0.0.1:8091 | flowd: accounts, the encrypted channel, scheduling, summaries; starts `flowd-speech serve` (dictation, live meeting preview) and `flowd-speech meeting` (Whisper Turbo final transcripts, speaker labels, voice regions) |
| `org.localflow.LocalFlow.remote.mtplx` | 127.0.0.1:8092 | the server's own MTPLX rewrite model, with its own key |

Data: `~/Library/Application Support/LocalFlow Server` (the account database, identity key, MTPLX key and speech models; mode 0700). Logs: `~/Library/Logs/LocalFlow Server`. Neither agent touches a LocalFlow app installed on the same Mac.

## Prerequisites

1. Xcode, to build `flowd-speech`, Go 1.26 (`brew install go`) and CMake for the Whisper helper (`brew install cmake`).
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

# 4. Load both agents. Reuse the worker and the Whisper helper from step 1 instead of
#    building them again. This run also downloads and verifies the meeting models.
scripts/install-remote-server.sh --google-client-id "$GOOGLE" --speech-worker "$DATA/bin/flowd-speech" \
  --meeting-helper "$DATA/bin/localflow-whisper-engine"

# 5. Check: backend "ready" and the identity answers.
curl -s http://127.0.0.1:8091/v1/rewrite/health
curl -s http://127.0.0.1:8090/v1/remote/identity
```

On the first start after install or an update, the worker compiles the CoreML model, which took about 25 s on an M5 and 10 s on the M5 Pro mini. It then runs one silent window before taking jobs (`state=warm` in `flowd.log`, about 280 ms), so the first dictation doesn't pay the first-inference cost (3.3 s right after install, about 0.3 s on later starts).

Over SSH, `flowd admin init` fails with "keychain access failed": the identity key goes into the login Keychain, which only the logged-in GUI session has unlocked. Run `init` in that session, for example in Screen Sharing or as a one-shot job in the `gui/$(id -u)` launchd domain. flowd itself already runs there.

Xcode isn't needed on the server: build `flowd-speech` on another Apple silicon Mac (`xcodebuild -project apps/macos/LocalFlow.xcodeproj -target flowd-speech -configuration Release`), copy it with its `FluidAudio_FluidAudio.bundle` and pass `--speech-worker`. Without LocalFlow.app, create the MTPLX runtime the way the app does (`LocalAIInstaller`): the pinned python-build-standalone in `~/Library/Application Support/LocalFlow/LocalAI/python`, a `venv` beside it installed with `pip --require-hashes --no-deps --only-binary :all: -r apps/macos/LocalFlow/Resources/LocalAI/mtplx-requirements.txt`, then `mtplx pull <id> --revision <commit>` from the `LocalAIModel` catalog.

## Meetings and summaries (Feature 018)

The same install serves summaries and meeting work; there is no extra setting. The script:

- builds the Whisper helper with `scripts/build-meeting-whisper.sh` (the pinned whisper.cpp revision) and installs it as `bin/localflow-whisper-engine`, or takes a prebuilt one with `--meeting-helper PATH`;
- installs `whisper-large-v3-turbo.json` and `speaker-diarization-offline.json` beside `flowd-speech`;
- runs `flowd-speech provision --models "$DATA/Models" --meeting`, which downloads Whisper Turbo (with its VAD file) and the offline diarization and voice models once and verifies every file against the pinned hashes on each later run;
- no longer passes `--analysis=false`, and passes `--meeting-helper` to flowd, which starts `flowd-speech meeting --models <--meeting-models> --helper <--meeting-helper>` beside the dictation worker. flowd's `--meeting-models` defaults to the `--speech-models` directory and `--meeting-helper` to `localflow-whisper-engine` beside flowd, so the installer sets only the helper.

Upgrading a running server stops flowd before provisioning, because its workers hold the models' import locks, and starts it again once both agents are reloaded; remote dictation is down for that time (33 s on the Mac mini on 2026-10-01, with the meeting models downloading). If provisioning fails, flowd is started again with its earlier plist.

`ready.capabilities` then lists `analysis`, `live_window` and `meeting_job` with the three model identities. If the meeting models or the helper are missing, the meeting worker reports what is missing in `flowd.log` (`meeting` prefix) and the server stops offering meeting jobs; dictation and rewriting are unaffected.

Licences copied with the install, in `bin/WhisperLicenses/`: Sotto (the helper's source), whisper.cpp (MIT), the Whisper model weights (MIT), Silero VAD (MIT), nlohmann JSON (MIT) and miniaudio. The offline diarization and voice models are downloaded from their source at provisioning, not shipped, and are not modified. Attribution: `FluidInference/speaker-diarization-coreml` at revision `1ed7a662fdc7109e36d822db793ee6eebdaf8594`, a CoreML conversion of pyannote `speaker-diarization-community-1` and the WeSpeaker ResNet34 embedding, all licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The licence review and the pinned model card are in `docs/licenses/speaker-diarization-coreml.md` and `docs/licenses/speaker-diarization-coreml-model-card.md`; `THIRD_PARTY_NOTICES.md` carries the same notice.

## Meeting handoff and iPhone meetings (ADR 0033, Feature 020)

The installer also builds `flowd-meeting`, the headless meeting processor (ADR 0033), installs it as `bin/flowd-meeting` and starts flowd with `--meeting-processor` pointing at it. Pass `--meeting-processor PATH` to install a prebuilt one instead. flowd keeps uploaded meetings in `$DATA/handoff/<user-id>/<meeting>/` and deletes them after the client has its result, or after 7 days at most.

Feature 020 lets the LocalFlow iPhone app record meetings and send them here (ADR 0034). Two things change on the server.

**Redeploy flowd and `flowd-meeting` together.** `flowd-meeting` opens each uploaded meeting with the clients' own database migrations, and the phone's bundles are at migration v19 (`phone-meetings-v19`). An older `flowd-meeting` fails those meetings, and an older flowd doesn't know the new handoff fields (partial start, device, copy, release). One install run from the Feature 020 branch replaces both:

```sh
scripts/install-remote-server.sh --google-client-id "$GOOGLE,$PHONE_GOOGLE" \
  --speech-worker "$DATA/bin/flowd-speech" --meeting-helper "$DATA/bin/localflow-whisper-engine"
```

Leave out `--meeting-processor` so the script builds `flowd-meeting` from the same checkout. Keep the `--analysis-backend` and `--analysis-model` flags if the server uses oMLX. A Mac needs a Feature 020 build to import phone meetings; older Macs ignore them (ADR 0034).

**Add the phone's Google client ID.** The iPhone app signs in with its own iOS OAuth client, so flowd has to accept it next to the Mac's. `--google-client-id` takes a comma-separated list:

```sh
PHONE_GOOGLE=569511417357-6130aocbp9ggo4g5meuifjjhbsr7aavj.apps.googleusercontent.com   # public
```

Without it, Google sign-in on the phone fails and the phone never shows up as a pending device.

The phone reaches the server the way the Macs do. The Mac mini serves the channel on the tailnet only, so the phone needs the Tailscale app on and connected. Approve the phone like any other device (`flowd admin list`, then `approve device <id>`, or the LocalFlow Server app).

A phone meeting with **Copy meetings to my Mac** on stays on the server after the phone has merged its result, until a Mac signed in as the same user imports it, and never longer than 7 days. It counts against the per-user limits (16 meetings, 8 GiB) until then. A Mac imports phone meetings only when the capabilities it last received from the server list `handoff`; it records them from the server's `ready` every time it opens a channel, so after the redeploy the next dictation or **Check connection** is enough.

Check after the redeploy:

```sh
curl -s http://127.0.0.1:8090/v1/remote/identity                 # same fingerprint as before
plutil -p "$HOME/Library/LaunchAgents/org.localflow.LocalFlow.remote.plist" | grep -A1 google-client-id   # both IDs
ls -l "$DATA/bin/flowd" "$DATA/bin/flowd-meeting"                # both with the new timestamp
```

## Choosing the rewrite model

Measured on the Mac mini (M5 Pro, 24 GB, macOS 27.0) on 2026-10-01 with `scripts/rewrite-quality.py fixtures/rewrite/corpus-v1.json` against `http://127.0.0.1:8091`, 40 items × 3 modes per model:

| Model | Median total, short / ordinary | Median first token | Protected-entity failures |
| --- | --- | --- | --- |
| Qwen 3.5 4B Speed | 280–300 / 413–491 ms | 151–183 ms | 0 |
| Qwen 3.5 9B Speed | 517–519 / 718–877 ms | 246–309 ms | 1 |
| Bonsai 2 27B | 1,164–1,311 / 1,929–2,309 ms | 632–806 ms | 2 |

The 4B model is the one to serve. Faster isn't the only reason: in the spot-checked outputs, the 9B model translated mixed Slovak and English dictation into English ("Pošli the report na dev@example.com prosím" became "Please send the report to dev@example.com."), and Bonsai wrote Czech forms into Slovak text ("Pošlu", "je potřeba prověřit"). `mtplx tune` picked draft depth 2 for the 4B model on this Mac: 142.6 tok/s against 87.8 tok/s without speculation. The first rewrite after 11 idle minutes took 354 ms, so the 4B model needs no extra GPU keepalive.

## A second model for summaries (oMLX)

Rewriting stays on the 4B MTPLX model. Summaries and meeting analysis can go to any other OpenAI-compatible server on the Mac mini, such as oMLX:

```sh
DATA="$HOME/Library/Application Support/LocalFlow Server"
(umask 077 && printf '%s' '<oMLX API key>' >"$DATA/analysis-api-key")
scripts/install-remote-server.sh --google-client-id "$GOOGLE" --speech-worker "$DATA/bin/flowd-speech" \
  --meeting-helper "$DATA/bin/localflow-whisper-engine" \
  --analysis-backend http://127.0.0.1:8443/v1 --analysis-model smart
curl -s http://127.0.0.1:8091/v1/analysis/health   # backend.model is the oMLX model
```

The model ID is one oMLX lists in `GET /v1/models`: a model, its alias (`smart` is the alias of `Qwen3.5-9B-MLX-4bit` on the Mac mini) or a profile exposed as a model (`smart:fast`). flowd sets temperature 0 and turns thinking off itself, so the alias with its 32K context is the one to use. flowd skips oMLX's keepalive chunks (`"model":"keepalive"`). While oMLX is down or answers with an error, analysis runs on MTPLX as before; flowd checks oMLX again on every request, at most every 5 s. Only those fallback calls wait for dictation rewrites; calls served by oMLX run beside them on the same GPU. flowd plans meeting analysis for `--analysis-context-tokens` (32,768 by default), so set the oMLX model's context window to at least that, or pass a lower value. If other machines use oMLX too, keep it off the public internet and give it a long random API key; flowd only needs 127.0.0.1.

## Tuning the Mac mini

The machine needs auto-login (and therefore FileVault off), because both agents are `Aqua` LaunchAgents and start only once the user is logged in. Then, with sudo:

```sh
pmset -a sleep 0 disksleep 0 powernap 0 autorestart 1 womp 1 powermode 2   # never sleep, come back after a power cut
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
mdutil -a -i off                                                          # no Spotlight indexing
```

Install macOS updates by hand. An update clears the CoreML cache, so the worker's next start compiles again. Keep one Tailscale: the standalone Tailscale.app is enough with auto-login, and a second `tailscaled` daemon only competes with it for DNS and routes. Leave `iogpu.wired_limit_mb` at its default: the 24 GB machine already gives the GPU about 18 GB, far more than the 4B model's 3.3 GB.

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

## Tailscale Funnel instead of Cloudflare

The Mac mini uses Funnel (ADR 0028 amendment). Approve Funnel for the node once in the Tailscale admin console (the first `tailscale funnel` prints the link), then:

```sh
/opt/homebrew/bin/tailscale funnel --bg 8090        # over SSH; Tailscale.app's own CLI needs the GUI
/opt/homebrew/bin/tailscale funnel status
curl -s https://mac-mini.tailf15b6.ts.net/v1/remote/identity   # same fingerprint as step 2
```

`--bg` keeps the configuration across restarts. In the app, enter `https://mac-mini.tailf15b6.ts.net` as the server.

### Tailnet only (the Mac mini since 2026-10-01)

To serve only devices on the tailnet, replace Funnel with Serve under the same name. Clients then keep their URL, pinned key and enrollment (ADR 0028, amendment of 2026-10-01):

```sh
T=/opt/homebrew/bin/tailscale
$T funnel --https=443 off                          # this also removes the 443 handler
$T serve --bg --https=443 http://127.0.0.1:8090    # the same proxy, tailnet only
$T serve status                                    # "(tailnet only)", no "Funnel on"
```

A client off the tailnet then gets no answer and dictates locally. On 2026-10-01 the owner's MacBook reached the mini over a WireGuard tunnel (an iPhone hotspot underneath) in about 62 ms for a TCP connect and about 230 ms for a whole HTTPS request.

## Clients

Build the app with the Google client for its bundle ID:

```sh
LOCALFLOW_GOOGLE_CLIENT_ID=<client ID> make run        # everyday app
LOCALFLOW_GOOGLE_CLIENT_ID=<dev client ID> make run-dev   # LocalFlow Dev, beside it
```

In the app: Settings › Server, turn on Remote dictation, confirm the consent sheet, enter `https://flow.<your-domain>`, check the fingerprint, and sign in. The app shows "Waiting for approval" and keeps dictating locally.

Once the device is approved, the Server section shows **Use this server for everything** and a Services row saying where dictation, rewriting, summaries and meetings run. With the switch on, all four go to this server; a service the server does not list in `ready.capabilities` shows as "Not offered by this server" and stays on the Mac. **Check connection** times one round trip over the channel and shows "Answered in N ms". Advanced (collapsed) can send Rewriting or Summaries to this Mac or to a custom server, and Meetings to this Mac. A device that confirmed the Feature 014 consent is asked once to confirm the updated one before summaries and meetings go to the server. The app side is described in `apps/macos/README.md`.

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

## The LocalFlow Server app

`scripts/install-server-app.sh <ssh-host>` builds the LocalFlow Server menu bar app on a Mac with Xcode and installs it in the server's `/Applications` (ADR 0032). It shows flowd, both speech workers, MTPLX and oMLX as Ready, Loading or Down, restarts flowd and MTPLX, tails `flowd.log`, keeps request stats that survive log rotation, approves and revokes devices with the commands above (it runs in the GUI session, so the Keychain is unlocked), and switches the rewrite model and the summaries backend with a rollback if the agent doesn't come back healthy. The installer starts flowd with `--admin-listen 127.0.0.1:8093` for it; the token is in `$DATA/admin-token` (0600), and the admin routes are not on 8090 or 8091. See [server-app.md](server-app.md).

## Uninstall

```sh
for l in org.localflow.LocalFlow.remote org.localflow.LocalFlow.remote.mtplx; do
  launchctl bootout "gui/$(id -u)/$l"; rm -f "$HOME/Library/LaunchAgents/$l.plist"
done
rm -rf "$HOME/Library/Application Support/LocalFlow Server" "$HOME/Library/Logs/LocalFlow Server"
```

The MTPLX models in `~/.mtplx/models` are shared with LocalFlow.app and stay. To remove a development app, quit it, then delete `/Applications/LocalFlow Dev.app`, `~/Library/Application Support/LocalFlow Dev`, `~/Library/Logs/LocalFlow Dev`, the `org.localflow.LocalFlow.dev` defaults, and the Keychain items whose service starts with `org.localflow.LocalFlow.dev.remote`. Do not unload a development app's own `.dev.flowd`/`.dev.mtplx` agents with `launchctl bootout` while you intend to keep using it: Login Items still lists them as enabled, so they come back only at the next login.
