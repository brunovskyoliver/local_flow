# LocalFlow rewrite server

`flowd rewrite` serves the LocalFlow v1 text-rewrite protocol. It calls a separately running OpenAI-compatible inference server such as MTPLX. It loads no weights, stores no transcripts, and uses only Go's standard library. Run commands below from `server/` (Go 1.23 or later).

```sh
go build -o ../build/flowd ./cmd/flowd
# Set LOCALFLOW_BACKEND_TOKEN to the inference server's API key if required.
# Set LOCALFLOW_REWRITE_TOKEN to the separate secret entered in LocalFlow Settings.
../build/flowd rewrite --listen 127.0.0.1:8080 \
  --backend http://127.0.0.1:8000/v1 \
  --model youssofal-qwen3.5-4b-mtplx-optimized-speed
```

Use the exact model id reported by the backend's `GET /v1/models`. A missing configured model reports `unavailable`; flowd never selects or loads a different model. Point the app at flowd (`http://127.0.0.1:8080`), not at the inference port. The protocol is in [rewrite-protocol.md](../specs/003-server-rewriting/contracts/rewrite-protocol.md).

| Option | Default | Meaning |
| --- | --- | --- |
| `--listen` | `127.0.0.1:8080` | HTTP bind address; host must be an IP literal |
| `--backend` | `http://127.0.0.1:8000/v1` | Inference API base URL, including `/v1` |
| `--model` | `youssofal-qwen3.5-4b-mtplx-optimized-speed` | Exact served model id |
| `--shield` | `on` | `on` or `off`; off reports shield version 0 |
| `--first-token-timeout` | `5s` | Deadline for the first content token |
| `--backend-timeout` | `20s` | Total inference deadline |
| `--debug-delay` | `0s` | Test delay, included in both deadlines |
| `--protocol-versions` | `1` | Analysis protocol versions; when given without `--rewrite-protocol-versions` it also sets the rewrite list (acceptance double) |
| `--rewrite-protocol-versions` | `1,2` | Rewrite versions advertised in health and accepted; `1` alone turns off reference context (v2) |

`LOCALFLOW_REWRITE_TOKEN` authenticates both LocalFlow routes. It is required when listening off-loopback. `LOCALFLOW_BACKEND_TOKEN` is sent only to the configured inference endpoint, for discovery and completions. The two credentials are independent, limited to 4,096 bytes, and never logged. Backend requests reject redirects and bypass environment proxy settings. Keep credentials out of shell history and tracked configuration. For launchd, provision credentials through your local service setup and run the compiled binary; Docker is unnecessary.

Flowd serves HTTP. For remote use, terminate HTTPS at a trusted proxy or deliberately configure the app's per-origin insecure override for a trusted private link. Bearer authentication does not encrypt text. No public listener is enabled by default.

## Endpoints and bounds

- `GET /v1/rewrite/health`: authenticated, content-free identity and backend status. Model discovery is bounded to 64 KiB and two seconds, cached for at least five seconds. A backend 503 reports `loading`; connection failures, authentication failures, other errors and missing model ids report `unavailable`.
- `POST /v1/rewrite`: validates the closed request schema and returns NDJSON with one terminal `result` or `error`. The input cap is 262,144 raw bytes, 20,000 text scalars and 65,536 text bytes. At most two requests run, including body decoding; excess requests receive 429 without queueing. A v2 request adds a closed `context` object of at most 8,192 bytes; it goes into the system message as delimited reference material, and the log line adds only `context_bytes`.
- Backend streaming is mandatory. Output accumulation has a fixed capacity of `min(4 × input_bytes, 65,536)` bytes. Every fragment is checked before append; overflow cancels inference and discards partial output. SSE lines are capped at 65,536 bytes and error bodies at 8,192 bytes. Restored output and the complete client response are checked again.
- Progress is sent at most once per 250 ms, with a 4 KiB auxiliary-event budget. No deltas are emitted, including when requested; v1 permits optional deltas. Response writes have five-second deadlines. Client disconnect cancels inference; SIGINT/SIGTERM cancels active work and closes the listener.
- Schema constraints are sent only when the selected `/models` entry explicitly advertises `capabilities.json_schema: true`. Otherwise prompts request plain text. A constrained response is a JSON string, decoded and validated before becoming `result.text`; the same accumulation cap still applies to its encoded bytes.
- Shield version 1 protects detected IPs, URLs, emails, paths, versions, currencies, numbers, dates and times. Missing, duplicated or unknown placeholders fail the request. Names and semantics still require quality review. Prompt hashes pin each mode's version.

Logs contain validated request ids, input/output byte counts, elapsed time and outcome codes. They contain no text, prompts, placeholders, backend error bodies or credentials. Output overflow also increments an in-process counter.

## Validation

```sh
go test -race ./...
go vet ./...
# From the repository root:
make check
```

The tests use in-process HTTP/SSE backends for deadlines, cancellation, concurrency, credential separation, shielding, corpus detector coverage, response validation and memory bounds. Live model quality, client interaction, latency and RSS acceptance are separate Phase 11 work. See [phase-10.md](../specs/003-server-rewriting/acceptance/phase-10.md) for the recorded smoke test.

## Shipped app

LocalFlow.app bundles flowd (`Contents/Helpers/flowd`) and registers it with MTPLX as
login items during onboarding; no Go toolchain, MTPLX.app or script is needed on the
user's Mac. See [ADR 0026](../docs/adr/0026-app-provisioned-local-ai.md). The labels are
`org.localflow.LocalFlow.flowd` and `org.localflow.LocalFlow.mtplx`, and the runtime
lives in `~/Library/Application Support/LocalFlow/LocalAI`. Remove the development
agents below before testing onboarding on the same Mac; both want ports 8000 and 8080.

## Start at login with MTPLX (development)

For the existing local setup (LocalFlow at `http://127.0.0.1:8080`, MTPLX at
`http://127.0.0.1:8000/v1`), run from the repository root:

```sh
scripts/install-rewrite-agent.sh youssofal-qwen3.5-4b-mtplx-optimized-speed
```

To serve the model without MTPLX.app, quit the app and run
`scripts/install-mtplx-agent.sh ~/.mtplx/models/<model-directory>`. It registers
`org.localflow.mtplx`, which runs `mtplx serve` on `127.0.0.1:8000` at login with
the app's serving flags. The app's dashboard polls the server continuously; the
headless service avoids that idle CPU and about 270 MB of GUI memory. Remove it
with `launchctl bootout gui/$(id -u)/org.localflow.mtplx` and delete
`~/Library/LaunchAgents/org.localflow.mtplx.plist`.

Use the exact model id served by your MTPLX instance. Stop any manually started
flowd first. The installer builds a separate binary under
`~/Library/Application Support/LocalFlow/RewriteServer/` and registers the user
launch agent `org.localflow.flowd.rewrite`. It starts at login, survives terminal
closure and restarts after exit, with a 30-second restart throttle. Re-run the
installer after server code or model selection changes. App redeployment does
not update this separate server binary.

On each start, the runner reads the existing LocalFlow secret from Keychain and
MTPLX's existing `daemon-api-key` file. Neither secret is copied into the plist or
runner. Missing credentials prevent startup; launchd retries. Keychain may ask
for access on first use. The agent discards stdout/stderr to avoid unbounded log
files; launchctl reports process state and the app's connection test reports
backend health.

This starts flowd only. MTPLX must also be running and serving the chosen model;
flowd reports backend unavailable until it is ready. Login and an unlocked
Keychain are required. This is a per-user service, not a pre-login system daemon.

```sh
launchctl print "gui/$(id -u)/org.localflow.flowd.rewrite"
# Stop and remove automatic startup:
launchctl bootout "gui/$(id -u)/org.localflow.flowd.rewrite"
rm "$HOME/Library/LaunchAgents/org.localflow.flowd.rewrite.plist"
```

This operational setup preserves the constitution's separate Go/inference
processes and loopback-only listener. It does not complete Phase 11's acceptance
or resource measurements.

## Remote dictation server (Feature 014)

flowd can also serve remote dictation to approved LocalFlow devices through a
Cloudflare Tunnel. It is off unless `--remote-listen` is given, and it then opens a
second loopback listener that serves only `/v1/remote/identity` and
`/v1/remote/channel` (an end-to-end encrypted WebSocket channel). The Feature 003
and 011 routes and the shared rewrite token grant nothing there. Speech recognition
runs in the `flowd-speech` worker, a Swift child process that uses the app's own
FluidAudio and term-boosting code; flowd loads no weights. Contracts:
[flowd-cli.md](../specs/014-remote-dictation-server/contracts/flowd-cli.md),
[remote-channel.md](../specs/014-remote-dictation-server/contracts/remote-channel.md),
[speech-worker-ipc.md](../specs/014-remote-dictation-server/contracts/speech-worker-ipc.md).

| Flag | Meaning |
| --- | --- |
| `--remote-listen 127.0.0.1:8090` | loopback address for the remote listener (development 18090) |
| `--data-dir <dir>` | holds `flowd-remote.sqlite`; must be owned by this user, mode 0700 |
| `--speech-worker <path>` | worker executable, default `flowd-speech` next to flowd |
| `--speech-models <dir>` | models the worker verifies, default `<data-dir>/Models` |
| `--apple-audience`, `--google-client-id` | accepted ID-token audiences; Google is refused without a client ID |
| `--dev` | read the identity key from the development Keychain service |

Accounts are created by Sign in with Apple or Google from the app and start pending.
The administrator approves them on the server; there is no remote admin API:

```sh
DATA="$HOME/Library/Application Support/LocalFlow Server"
"$DATA/bin/flowd" admin --data-dir "$DATA" init          # SQLite file and identity key
"$DATA/bin/flowd" admin --data-dir "$DATA" identity      # fingerprint to compare in the app
"$DATA/bin/flowd" admin --data-dir "$DATA" list --state pending
"$DATA/bin/flowd" admin --data-dir "$DATA" approve user 3
"$DATA/bin/flowd" admin --data-dir "$DATA" approve device 5
"$DATA/bin/flowd" admin --data-dir "$DATA" revoke device 5   # live channels close within 1 s
"$DATA/bin/flowd" admin --data-dir "$DATA" audit --limit 20
```

`scripts/install-remote-server.sh [--dev] [--dry-run] [--google-client-id IDS]
[--apple-audience IDS] [--mtplx PATH] [--model DIR]` builds flowd and `flowd-speech`,
installs them under `<data-dir>/bin` with the pinned model descriptors, and loads two
launch agents: `org.localflow.LocalFlow.remote` (remote listener 127.0.0.1:8090, normal
listener 127.0.0.1:8091) and the server's own MTPLX, `org.localflow.LocalFlow.remote.mtplx`
on 127.0.0.1:8092. With `--dev` the labels gain `.dev` and the ports are 18090, 18091 and
18092. The server's MTPLX stays loaded while its agent runs and needs no LocalFlow app;
its key is generated into `<data-dir>/mtplx-api-key` and handed to flowd by a wrapper
script, never through a plist. The runtime and model default to the installed app's.
Sign-in providers are refused unless `--google-client-id` or `--apple-audience` names
the accepted client. It never touches the app's `.flowd` and `.mtplx` agents, and it
stops before loading the agents until `flowd admin init` has run. Provision the speech model with
`"$DATA/bin/flowd-speech" provision --models "$DATA/Models" --booster`, then point the
tunnel hostname at the remote listener.

Logs carry identifiers, counts, durations and codes only; the worker's own stderr is
content-free, and FluidAudio's console output inside the worker is discarded.
`scripts/check-remote-logs.sh` scans logs for tokens, JWTs, fixture phrases and
Dictionary terms. Opt-in check of the real worker against the Go side:

```sh
LOCALFLOW_SPEECH_WORKER=<path to flowd-speech> LOCALFLOW_SPEECH_MODELS=<Models dir> \
LOCALFLOW_SPEECH_AUDIO=<16 kHz f32le file> go test ./internal/remote -run TestRealWorkerWindowsDecode -v
```
