# 0026: App-provisioned local AI services

## Status

Proposed, 2026-09-25.

## Context

Rewriting and meeting analysis need flowd and an MTPLX server on the user's Mac. Until now both were set up by development scripts: `install-rewrite-agent.sh` compiles flowd with Go on the user's machine, and `install-mtplx-agent.sh` reuses the Python runtime that MTPLX.app installs. A downloaded LocalFlow.app has neither Go nor MTPLX.app, so a new user could dictate but never get rewriting.

## Decision

LocalFlow.app carries everything except downloads, and onboarding installs the rest after explicit consent.

- The Xcode build compiles flowd into `Contents/Helpers/flowd` and signs it with the hardened runtime (`scripts/bundle-local-ai.sh`).
- Two launch agents ship in `Contents/Library/LaunchAgents` and register through `SMAppService`, so they appear under LocalFlow in Login Items: `org.localflow.LocalFlow.mtplx` and `org.localflow.LocalFlow.flowd`. Both `BundleProgram`s are sealed shell scripts in `Contents/Resources/LocalAI`, so updating the app updates the serving flags and flowd.
- The MTPLX runtime lives in `~/Library/Application Support/LocalFlow/LocalAI`: python-build-standalone CPython 3.13.15 checked against a pinned SHA-256, and a venv installed with `pip --require-hashes --no-deps` from the bundled `mtplx-requirements.txt` (MTPLX 2.12.0 and 44 dependencies). The venv is rebuilt when the lock's hash changes.
- Models come from a five-entry catalog of MTPLX packs, each pinned to a Hugging Face commit and gated by physical memory. `mtplx pull` stores them in `~/.mtplx/models`, so a model MTPLX.app already downloaded is reused.
- MTPLX serves the chosen model as `--model-id localflow` on 127.0.0.1:8000 with a generated key file (0600). flowd always asks for `localflow`, so changing models restarts only MTPLX. The serving flags are the ones measured with the headless development agent: serial scheduler, latency batching, no SSD session cache, reasoning off, no stats footer. Fan mode is `default` rather than `smart`: smart needs a helper that MTPLX.app installs with sudo, and on the development agent it accumulated idle `mtplx.thermal_sidecar` processes (five in eleven minutes, about 8 MB each). Draft depth and profile come from MTPLX's per-model preset and any `mtplx tune` result.
- The model is loaded only while LocalFlow runs. The mtplx agent has neither `RunAtLoad` nor `KeepAlive`: the app kickstarts it at launch, when a dictation starts (a no-op while it runs, and the recovery after an MTPLX crash) and when the rewrite endpoint is switched back to the local services, and sends it `SIGTERM` when it quits or the endpoint moves to a server. Before each start the app writes its PID to `app-pid`; the agent's script checks it every five seconds and stops the model once that PID is no longer a LocalFlow executable, so a crashed app doesn't leave gigabytes loaded. If LocalFlow relaunches while that orphaned model is stopping, the script starts it again. flowd holds no weights and stays up. Rewrites are one-shot, so MTPLX keeps little context between them: its MLX buffer cache is emptied after every request and capped at 256 MB, and the session bank keeps one entry of at most 512 MB. Measured on the 4B Speed model with four long rewrites: MTPLX's defaults grew the server from 3.6 to 4.2 GB; with these limits it stayed at 3.3 GB, and the four rewrites took 4 s in both runs. MTPLX only expires idle session entries when the next request arrives, so these caps, not an idle timer, bound what it keeps between uses.
- Onboarding offers the same AI on a server the user runs instead: the app points the rewrite endpoint at that flowd, stores its token in Keychain, and requires a passing connection test. Rewriting and meeting analysis both follow that endpoint; speech recognition and meeting transcription stay on the Mac (principle 5), and nothing is downloaded or registered for local AI.
- When both services answer, the app sets the rewrite endpoint to `http://127.0.0.1:8080` and turns rewriting on. Loopback needs no LocalFlow credential.

## Constitution check

- Principle 1: the client stays native. Python runs only inside the separate MTPLX process that launchd owns (ADR 0005); the client never loads it.
- Principle 4: dictation needs only the speech model. Local AI and meeting models are optional and download in the background.
- Principle 5: nothing leaves the Mac at run time. Setup downloads from GitHub, PyPI and Hugging Face after consent; `HF_HUB_DISABLE_TELEMETRY` and `DO_NOT_TRACK` are set for every MTPLX command. Setup output goes to `~/Library/Logs/LocalFlow/local-ai-setup.log`, truncated at the start of each setup, and never includes text.
- Principle 8: flowd still loads no weights and runs under launchd without Docker.
- Principle 14: MTPLX is Apache-2.0. Its dependencies are pinned, but their license review is not done yet and must finish before release.

## Consequences

About 540 MB of runtime (measured: 70 MB Python, 469 MB venv) plus the chosen model (2.6 to 20.7 GB) on disk. `--unsafe-force-unverified` is kept from MTPLX.app's own launch flags; the commit pins are what make the weights trustworthy. If port 8000 or 8080 is already taken (MTPLX.app, or the development agents), setup stops and asks the user to quit the other server rather than killing it. Settings has no local AI page yet, so a skipped setup can only be resumed by a later feature. Unloading the model while LocalFlow is idle is not done: reloading takes seconds, longer than flowd's first-token timeout, so the first rewrite after idle would fall back to plain text. Rewrite latency and load time under the bundled agents have not been measured.

## Alternatives considered

Requiring MTPLX.app (a second app and dashboard with idle CPU cost); Homebrew (most users don't have it); bundling Python in the app (roughly 540 MB added to every download, including for users who skip AI); unpinned `pip install mtplx`.
