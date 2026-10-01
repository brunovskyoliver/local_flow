# Contract: meeting worker IPC (Feature 018)

`flowd-speech meeting --models <dir> --helper <path>` is a second child process of flowd, supervised like the dictation worker ([Feature 014 speech worker IPC](../../014-remote-dictation-server/contracts/speech-worker-ipc.md)). Framing is unchanged: `u32 header_len | JSON header (≤ 65,536) | u32 payload_len | payload`, big-endian lengths as in Feature 014; samples are little-endian f32.

## Start-up

The worker verifies the Whisper Turbo, Silero VAD, diarization and embedding descriptors, sends `ready` with the `models` object used for `ready.capabilities`, and loads nothing until the first job. Missing models → `unavailable{reason:"model_missing", missing:[…]}`; flowd then advertises no `meeting_jobs`.

## Messages

| Type | Direction | Header fields | Payload |
| --- | --- | --- | --- |
| `ready` | worker → flowd | `protocol: 1`, `models` | none |
| `unavailable` | worker → flowd | `reason`, `missing` | none |
| `transcribe` | flowd → worker | `job`, `sample_count` ≤ 1,920,000, `language`, `vocabulary_terms`, `pipeline` | f32le samples (flowd converts s16le) |
| `diarize` | flowd → worker | `job`, `sample_count` ≤ 9,600,000, `num_speakers` | f32le samples |
| `embed` | flowd → worker | `job`, `sample_count` 48,000–320,000 | f32le samples |
| `result` | worker → flowd | `job`, `kind`, `result`, `processing_ms` | none |
| `error` | worker → flowd | `job`, `code` (`model_unavailable`, `invalid_audio`, `repetition`, `failed`) | none |
| `state` | worker → flowd | `state` (`loading`, `active`, `releasing`) | none |
| `shutdown` | flowd → worker | none | none |

A diarization payload is at most 38.4 MB. flowd streams the payload to the worker's stdin as frames arrive and does not keep a second copy.

## Lifecycle

- One `ModelLifecycleCoordinator` owns the three meeting runtimes; one is resident at a time. A job of another kind releases the resident model first.
- The resident model is released after 10 idle minutes; the worker stays running.
- One job at a time. Deadline 300 s per job; on a deadline flowd kills the worker, answers the job `worker_unavailable`, and restarts it with the Feature 014 backoff.
- The Whisper runtime writes its temporary window file inside a private temporary directory, deleted after each job and at start-up.
