# Quickstart: validating Feature 018

Deterministic checks run in `make check`. Sections 2–6 are hardware and network acceptance on the owner's Mac mini (M5 Pro, 24 GB, macOS 27.0) and MacBook; record results in `acceptance/`, measured values only.

## 1. Deterministic suites

```sh
make check
```

Must include: Go tests for the `analysis`, `live_window` and `meeting_job` ops (fake meeting worker, fake clock), the extended isolation suite, schema and example validation for the new messages, the speech-worker import check (now covering the moved meeting runtimes), XCTest for routing (`servedByServer` truth table), the settings migration (research R13), residency (MTPLX stop and no wake; keep-loaded off while served), remote runtimes with a fake channel (success, busy, unreachable, `not_offered`, cancellation), waiting-for-server and **Run on this Mac**, and migration `one-server-v17`.

## 2. Server install with every workload

On the Mac mini, from the repository:

```sh
DATA="$HOME/Library/Application Support/LocalFlow Server"
"$DATA/bin/flowd-speech" provision --models "$DATA/Models" --booster --meeting   # adds Whisper Turbo, Silero VAD, diarization, embeddings
scripts/install-remote-server.sh --google-client-id <id> --speech-worker <worker> --model <4B dir>
```

Expected:
- `flowd.log` shows both workers ready. The meeting worker logs `ready` with its models and no load until the first job.
- A fresh session's `ready` lists `analysis`, `live_window`, `meeting_job` and the three model identities.

## 3. One switch on the MacBook

1. Upgrade the everyday app with the Feature 018 build. Settings opens with the Server section first and the one-time notice naming the kept summaries server (ai-vm) as a custom override.
2. With the switch on and every override at "Your server", dictate with rewriting, record a 5-minute meeting, stop it, and let the summary run.
3. Expected: the server logs one dictation, one rewrite, live-preview windows during recording, transcribe/diarize/embed jobs after stop, and one analysis op. On the Mac, `pgrep -f localflow-mtplx` finds nothing within 10 s of launch, and no local model load appears in the app log. **Check connection** reports every service on the server.
4. Set Summaries to Custom (ai-vm): the next summary goes to ai-vm. Stop ai-vm: the summary is produced by the server instead.

## 4. Failure and retry

| Step | Expected |
| --- | --- |
| Stop the server mid-recording | Recording continues; live preview shows `server_unavailable` gaps; nothing lost |
| Stop the server mid-finalization | Meeting shows "Waiting for your server" with **Run on this Mac**; stored windows kept |
| Start the server again | Finalization resumes from the last stored window within the backoff; no window transcribed twice (compare `progress_sequence` and segment counts) |
| Press **Run on this Mac** while waiting | Remaining work runs locally; `inference_path = local_after_server_failure` |
| Revoke the device | Every service returns to this Mac; local models start again on demand |

## 5. Resources and timing (SC-002, SC-003, SC-005, SC-007)

- Mac: RSS of LocalFlow at idle with the switch on, during a 20-minute remote meeting, after finalization; confirm no MTPLX or meeting-model process (`scripts/memory-report.sh`).
- Server: working set of each worker and MTPLX with all models loaded; meeting worker RSS per resident model.
- Finalization time for a 20-minute and a 2-hour meeting on the server versus the same meetings locally on the MacBook; upload bytes per meeting.
- Second-user dictation added wait while a meeting finalizes (two users), per SC-007.
- Network latency through Funnel for dictation, rewrite and a live window (remote delivery gate).

## 6. Comparison and privacy (SC-006, SC-009)

- Reference meetings transcribed locally and on the server: diff final transcripts, speaker turns and identification suggestions; document every difference.
- Scan server and client logs from sections 3–5 with `scripts/check-remote-logs.sh`: zero transcript, summary, voice or credential findings.
