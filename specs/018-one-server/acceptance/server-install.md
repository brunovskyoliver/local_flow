# Feature 018 server install (T092, quickstart §2)

Recorded 2026-10-01 on the Mac mini server (M5 Pro, 24 GB, macOS 27.0, user `test`), from `~/local-flow-283ebe6`, a `git archive` of commit `283ebe6` (`.source-commit`). Times are local (CEST, UTC+2) unless marked Z.

**Result: T092 stays open.** The server now runs both workers and serves analysis, but a fresh session's `ready` was not observed (no signed client on this machine), and the log scan reports 10 `dictionary term` findings that are model names (see Checks).

## Machine and toolchain

- Xcode is not installed on the Mac mini: there is no `Xcode.app`, and `xcode-select -p` is `/Library/Developer/CommandLineTools`, so `xcodebuild` fails and the installer cannot build `flowd-speech`.
- The installed `flowd-speech` from `ab32a5a` (and the identical copy in `~/local-flow/build/worker`) supports only `serve|provision`, without `meeting` or `--meeting`, so it could not be reused with `--speech-worker`.
- The worker therefore came from the MacBook: `flowd-speech` built Release from `283ebe6`, copied with `FluidAudio_FluidAudio.bundle` to `~/flowd-speech-283ebe6/`. `shasum -a 256 flowd-speech` = `8a6e3d1adbac6ff3e9a620b1f9300f414e2d39828bffec0e710b13c5cbe16c46`, matching the hash the owner gave; `flowd-speech --help` prints `usage: flowd-speech serve|meeting|provision --models <dir> [--helper <path>] [--booster] [--meeting] [--descriptors <dir>]`.
- CMake was not installed: `brew install cmake` installed CMake 4.4.3. Go 1.27.1; Apple clang 21.0.0 from the Command Line Tools.
- `third_party/sotto/vendor/whisper.cpp` was not empty: it held a partial copy (467 files, 10 MB, no `.git`, no `include/whisper.h`) of unknown origin, created 19:26 that day. It was renamed, not deleted, to `third_party/sotto/vendor/whisper.cpp.partial-20261001`, so `scripts/build-meeting-whisper.sh` could fetch the pinned revision.
- `~/Library/Application Support/LocalFlow/LocalAI/model-path` does not exist, so the installer cannot find the app's model by itself; `--model` was passed explicitly (the same directory the existing MTPLX agent served).

## Starting state (2026-10-01T17:55:24Z)

- `launchctl print gui/501/org.localflow.LocalFlow.remote`: `state = running`, `pid = 5598`; `.remote.mtplx`: `state = running`, `pid = 5561`. Install from `ab32a5a`; the flowd plist passed `--analysis=false` and no `--meeting-helper`.
- `curl -s http://127.0.0.1:8090/v1/remote/identity`: `"fingerprint":"799f-7d47-f4d9-1300-4b0a-928d-0591-c173"`.
- `curl -s http://127.0.0.1:8091/v1/rewrite/health`: `"backend":{"state":"ready","kind":"openai-compatible","model":"localflow"}`.
- `flowd.log` tail: ordinary remote dictation, rewrite and refresh lines, the last at 19:46:25 (`remote channel=65 purpose=refresh … code=closed`).
- `Models/` held `parakeet-v3` and `parakeet-ctc-110m` only.

## Commands run

```sh
export PATH=/opt/homebrew/bin:$PATH
DATA="$HOME/Library/Application Support/LocalFlow Server"
brew install cmake

mv third_party/sotto/vendor/whisper.cpp third_party/sotto/vendor/whisper.cpp.partial-20261001
TEMP_DIR="$PWD/build" scripts/build-meeting-whisper.sh
# fetched 371b5a7561823ab2bb32142d2751e35e7534727b; built
# build/meeting-whisper-native/Engine/sotto-engine in 15 s, with the Metal and BLAS (Accelerate) backends

INSTALL=(scripts/install-remote-server.sh
  --google-client-id 569511417357-t31grql32ppl5rtfvib7aiic6ujvigk6.apps.googleusercontent.com
  --mtplx "$HOME/Library/Application Support/LocalFlow/LocalAI/venv/bin/mtplx"
  --model "$HOME/.mtplx/models/Youssofal--Qwen3.5-4B-MTPLX-Optimized-Speed"
  --meeting-helper "$PWD/build/meeting-whisper-native/Engine/sotto-engine")
"${INSTALL[@]}" --dry-run                                   # plan reviewed by the owner (without --speech-worker)
"${INSTALL[@]}" --speech-worker "$HOME/flowd-speech-283ebe6/flowd-speech"      # run 1: failed, see below
launchctl bootout gui/501/org.localflow.LocalFlow.remote
"${INSTALL[@]}" --speech-worker "$HOME/flowd-speech-283ebe6/flowd-speech"      # run 2: exit 0

# step 4, with the flowd agent stopped (see below)
launchctl bootout gui/501/org.localflow.LocalFlow.remote
"$DATA/bin/flowd-speech" provision --models "$DATA/Models" --booster --meeting
launchctl bootstrap gui/501 ~/Library/LaunchAgents/org.localflow.LocalFlow.remote.plist
```

`flowd admin init` was not run. Tailscale Funnel, pmset and system settings were not touched; nothing needed sudo.

### Install run 1 failed: the running worker holds the model lock

Run 1 (20:00:22) installed the new `flowd`, `flowd-speech`, descriptors, helper and licences into `$DATA/bin`, then stopped at its provisioning step:

```
20:00:22 provision model=parakeet-v3 state=downloading
20:00:22 provision model=parakeet-v3 state=failed
```

Cause: the running dictation worker (pid 5607) holds an exclusive `flock` on `Models/.parakeet-v3.import.lock` for its whole life (`lsof`), and `ModelProvisioner` throws `alreadyInUse` when it cannot take that lock. `provision` always checks `parakeet-v3` first, so the installer's `provision --meeting` fails whenever the server is running, and the installer provisions before it reloads the agents. A copy of `parakeet-v3` in a scratch directory verified with the new worker (`state=verified`), so the files were not at fault. Until run 2, the old processes kept serving (identity and rewrite health unchanged) with the new binaries on disk under the old plist. **Installer defect:** an in-place upgrade of a running server fails at `provision`; the installer should stop the flowd agent before provisioning, or provision after the reload.

Run 2 stopped the flowd agent first (`bootout` at 20:01:34; the MTPLX agent kept running until the installer reloaded it) and finished with exit 0 at 20:02:06.

## Provisioning download

From run 2's timestamped output (1-second resolution):

```
20:01:35 provision model=parakeet-v3 state=verified
20:01:35 provision model=whisper-large-v3-turbo state=downloading
20:01:57 provision model=whisper-large-v3-turbo state=verified
20:01:57 provision model=speaker-diarization-offline state=downloading
20:02:06 provision model=speaker-diarization-offline state=verified
```

Downloading and verifying the meeting models took 31 s: 22 s for Whisper Turbo with its VAD file, 9 s for the offline diarization and voice models. The descriptors list about 1.63 GB and 0.02 GB of files.

Step 4 (`provision --booster --meeting`, 20:02:33–20:02:35) downloaded nothing and verified all four models in 2 s: `parakeet-v3`, `parakeet-ctc-110m`, `whisper-large-v3-turbo`, `speaker-diarization-offline`, each `state=verified`, exit 0. It too needs the flowd agent stopped (the dictation worker holds the `parakeet-v3` lock, the meeting worker the Whisper and diarization locks), so remote dictation was down for 2 s while it ran. Remote dictation was also down from 20:01:34 to 20:02:07 during run 2.

## Checks

| Check | Result |
| --- | --- |
| Both workers ready in `flowd.log` | Seen, after run 2 and again after step 4 |
| Meeting worker loads no model until the first job | Seen: no load line, no helper process, no model file open |
| Identity fingerprint unchanged | Seen, locally and through Funnel |
| Rewrite health `ready` | Seen |
| Six licence files in `bin/WhisperLicenses/` | Seen |
| A fresh session's `ready` lists `analysis`, `live_window`, `meeting_job`, meeting_jobs and three model identities | **Not observed**: no signed client on the Mac mini |
| `scripts/check-remote-logs.sh` finds nothing | **Not met**: 10 `dictionary term` findings, all the engine name `FluidAudio` |

`flowd.log` after step 4 (the run 2 start at 20:02:07 shows the same lines):

```
flowd meeting 2026/10/01 20:02:35 speech worker_state=starting
flowd meeting 2026/10/01 20:02:35 worker state=ready
flowd meeting 2026/10/01 20:02:35 speech worker_ready engine=whisper.cpp model_id=ggerganov/whisper.cpp-large-v3-turbo model_revision=5359861c739e955e79d9a303bcbc70fb988958b1
flowd meeting 2026/10/01 20:02:35 speech worker_ready engine=fluidaudio_offline_diarizer model_id=FluidInference/speaker-diarization-coreml model_revision=1ed7a662fdc7109e36d822db793ee6eebdaf8594
flowd meeting 2026/10/01 20:02:35 speech worker_ready engine=wespeaker_resnet34lm_256 model_id=FluidInference/speaker-diarization-coreml model_revision=1ed7a662fdc7109e36d822db793ee6eebdaf8594
flowd meeting 2026/10/01 20:02:35 speech worker_state=ready
flowd 2026/10/01 20:02:36 worker state=ready load_ms=385
flowd 2026/10/01 20:02:36 speech worker_ready engine=FluidAudio model_id=FluidInference/parakeet-tdt-0.6b-v3-coreml model_revision=7dd20fe6b1797d35f5e3307e8b1732d9a178edfe booster=ctc110m-v1 worker_build=flowd-speech 1
flowd 2026/10/01 20:02:36 speech worker_state=ready
flowd 2026/10/01 20:02:36 speech worker_runtime=active
flowd 2026/10/01 20:02:36 worker state=warm warmup_ms=281
```

On the first start after run 2 the dictation worker logged `load_ms=11579` (CoreML compile) and `warmup_ms=325`.

- **The meeting worker loads no model until the first job.** It reported `ready` in the second it started, with no load line. `lsof` on it (pid 13158) showed only `.speaker-diarization.import.lock`, `.whisper-large-v3-turbo.import.lock` and the `speaker-diarization-offline` directory, with no model file open. No `localflow-whisper-engine` process was running.
- **Identity and rewrite health.** After run 2 and again after step 4, the fingerprint on `127.0.0.1:8090` was `799f-7d47-f4d9-1300-4b0a-928d-0591-c173`; after run 2 `https://mac-mini.tailf15b6.ts.net/v1/remote/identity` returned the same. `/v1/rewrite/health` returned `"backend":{"state":"ready"…}` (first poll 20:02:14 after run 2; 20:02:36 after step 4). Agents: `.remote` pid 13148, `.remote.mtplx` pid 13027, both `state = running`.
- **Analysis.** The flowd plist no longer passes `--analysis=false` and now passes `--meeting-helper "$DATA/bin/localflow-whisper-engine"`. `curl -s http://127.0.0.1:8091/v1/analysis/health` returned HTTP 200 with `"service":"localflow-analysis"` and `"backend":{"state":"ready","kind":"openai-compatible","model":"localflow","json_schema":false}`.
- **Licences.** `bin/WhisperLicenses/` holds `JSON-LICENSE.txt`, `miniaudio-LICENSE.txt`, `Silero-LICENSE.txt`, `Sotto-LICENSE.txt`, `whisper-LICENSE.txt` and `Whisper-model-LICENSE.txt`.
- **`ready` over a session.** Not observed. Opening a signed session needs an approved device's key and tokens, which are on the MacBook; `server/cmd` has no client tool. To confirm, reconnect the MacBook app and check Settings › Server (Services row), or capture a fresh session's `ready`. Expected from the code (`server/internal/remote/meeting.go`): `meeting_jobs` `diarize`, `embed`, `transcribe` and the three models in the log lines above.
- **Log scan.** `scripts/check-remote-logs.sh "$HOME/Library/Logs/LocalFlow Server/flowd.log"` (952 lines) reported `log scan: 10 finding(s)`, all `dictionary term`, exit 1. Every finding is the term `FluidAudio` in a `speech worker_ready engine=FluidAudio …` line; 8 of the 10 lines predate this install. `FluidAudio` is in the vocabulary-boost corpus and is also the dictation engine's name, and the script exempts only `MTPLX` and `LocalFlow`. No token, JWT, transcript, analysis, vector or sample finding. `flowd.stderr.log` and `flowd.stdout.log` are empty.

## Not done or not measured

- A fresh session's `ready` (above).
- Nothing was measured beyond the times quoted here: no memory, latency or meeting job runs. No meeting job ran, so the meeting worker's model load on the first job was not seen.
- `make check` was not run on the Mac mini (no Xcode).

## Left on the machine

- `third_party/sotto/vendor/whisper.cpp.partial-20261001` (the renamed partial copy), the fetched `third_party/sotto/vendor/whisper.cpp` and `build/meeting-whisper-native/` in `~/local-flow-283ebe6`.
- `~/Applications/Claude Code URL Handler.app`, created 19:55:00 when the Claude Code session started, by the Claude Code client rather than by a command in this run. Left in place.

## Follow-up on the MacBook (2026-10-01)

Both defects found above were fixed in the repository after this run. Neither fix has been redeployed to the Mac mini; the server keeps the `283ebe6` install.

- **Installer.** `scripts/install-remote-server.sh` now stops the flowd agent before `provision --meeting`, and step 5 starts it again. If provisioning fails, the agent is started again with its earlier plist. Checked with a `--dev --dry-run` on the MacBook: the bootout comes before the provision, then both agents are reloaded. Not yet run against a live server.
- **Log scan.** `FluidAudio` is an engine name as well as a Dictionary term, so `scripts/check-remote-logs.sh` now exempts it, as it already did `MTPLX` and `LocalFlow`. `TestLogScanAllowsOperationalNames` feeds the dictation worker's `worker_ready` line from this log and expects no finding; without the exemption it reports `dictionary term`. Over a copy of the Mac mini's `flowd.log` (996 lines, copied after this run), the previous script reports the same 10 `dictionary term` findings and the fixed one reports none (exit 0).
- **`ready` over a session.** Seen on 2026-10-01 at 20:18, after the MacBook rebooted and the app opened a new channel. Its stored `ready.capabilities` read: ops `analysis`, `dictation_start`, `live_window`, `meeting_job`, `rewrite`; meeting_jobs `embed`, `transcribe`, `diarize`; models transcription `ggerganov/whisper.cpp-large-v3-turbo` at `5359861c…` (whisper.cpp), diarization `FluidInference/speaker-diarization-coreml` at `1ed7a662…` (fluidaudio_offline_diarizer), voice the same model (wespeaker_resnet34lm_256, dimension 256). With the two fixes above, every expected item of quickstart §2 has now been seen, and T092 is done.
