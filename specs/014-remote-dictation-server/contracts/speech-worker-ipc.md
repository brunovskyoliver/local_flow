# Contract: flowd ↔ speech worker

The speech worker (`flowd-speech`, a Swift command-line target in `apps/macos/LocalFlow.xcodeproj`) is a child process of flowd. It has no network access and no listener. flowd is its only client, over the child's stdin and stdout. Stderr carries content-free log lines, which flowd copies into its capped log with a `worker` prefix. See [research.md](../research.md) R10.

The interface is generic on purpose (FR-029): a later worker, for example a CUDA one, implements the same messages and flowd selects it with `--speech-worker <path>`. flowd depends only on these messages, never on `flowd-speech` itself, and the client protocol does not change.

## Framing

Each message, both directions:

```text
header_length (u32 BE) | header (UTF-8 JSON, ≤ 65,536 bytes) | payload_length (u32 BE) | payload
```

`payload_length` is 0 unless the header says otherwise. A malformed frame is fatal: the reader closes and flowd restarts the worker.

## Messages

Worker → flowd at start, before anything else, after the speech runtime is loaded:

```json
{ "type": "ready", "protocol": 1,
  "model": { "engine": "FluidAudio", "model_id": "…", "model_revision": "…", "manifest_hash": "…",
             "sdk": "0.15.7", "booster": "ctc110m-v1", "worker_build": "…" } }
```

`booster` is absent if the keyword spotter is not installed. A worker that cannot find a verified speech model sends `{ "type": "unavailable", "reason": "model_missing" }` and exits 0; flowd answers remote sessions with `worker_unavailable` and retries the start every 60 s.

flowd → worker:

```json
{ "type": "recognize", "job": 17, "sample_count": 239360,
  "boost": { "terms": [{ "entry_id": "…", "canonical": "…" }], "governed": ["…"] } }
```

Payload: `sample_count × 4` bytes of Float32 LE. `sample_count` is 1…239,360. `boost` is optional.

```json
{ "type": "shutdown" }
```

`shutdown` releases the runtime and exits.

Worker → flowd, exactly one per `recognize`, in job order:

```json
{ "type": "result", "job": 17, "window": { …same fields as window_result in remote-channel.md, without op/index/sample_start… }, "recognition_ms": 142 }
{ "type": "error", "job": 17, "code": "invalid_audio" | "model_unavailable" | "failed" }
```

And unsolicited, for flowd's measurements only: `{ "type": "state", "state": "active" | "releasing" }`.

## Rules

- One job at a time. flowd never sends a second `recognize` before the answer to the first.
- The worker holds one `ModelLifecycleCoordinator` configured with only the speech factory. Each job: `acquire(session: <new UUID>, boost:)`, `transcribe`, `finish`. It keeps no state between jobs besides the resident runtime; terms from one job are never used for the next (FR-014, FR-025).
- The worker calls `setKeepLoaded(true)` and loads the runtime before `ready`; it stays loaded until the process exits (FR-032). There is no idle release.
- Job deadline 30 s, enforced by flowd. On timeout, EOF, a non-zero exit or a malformed frame, flowd kills the process group, answers every waiting job of every session with `worker_unavailable`, and restarts the worker with backoff 1 s, 2 s, 4 s … capped at 60 s (FR-030). flowd itself keeps serving.
- The worker never logs text, terms or samples: only job IDs, sample counts, durations, state changes and error codes.
- The worker's memory is outside flowd's SC-004 budget and is measured separately (constitution principle 2).

## Provisioning

```sh
flowd-speech provision --models "<data-dir>/Models"
flowd-speech provision --models "<data-dir>/Models" --booster
```

Runs the app's `ModelProvisioner` against the bundled pinned descriptors and verifies every file hash. `flowd-speech serve --models <dir>` is the mode flowd starts.
