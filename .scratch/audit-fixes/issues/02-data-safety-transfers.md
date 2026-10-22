# 02 Data safety and transfers (audit items 1, 2, 5)

Source: `~/agent-runs/2026-10-22-localflow-audit/audit.md` ("Implementation order" rows 1, 2 and 5, and "Resource improvements") and `runtime-resources.md` R1, R3, R7 and R9.

## What changed

### Item 1: iPhone orphan recovery keeps the audio until History commits

`apps/ios/App/Storage/OrphanSpoolRecovery.swift`

- Left-over recordings are parked as `TemporaryAudio/Orphans/<id>.pcm`. The file name is the dictation ID the recovered row gets.
- `recover` copies a parked file into a working spool in `TemporaryAudio/Recovery/<id>/` and runs the pipeline with `deletesSpool: false`. It deletes the parked file only after `PhoneDictationStore.save` commits. A model or load failure, cancellation, failed save, or empty output from an incomplete pass keeps the file for the next model-ready event. Empty output from a complete pass (silence) deletes it.
- Retries are idempotent. Before transcribing, `PhoneDictationStore.contains(_:)` checks whether the ID is already in History. If it is, recovery only cleans up, which covers a process death between commit and cleanup. A save that fails because a concurrent recovery committed first counts as done.
- `adopt()` now parks:
  - every left-over UUID session folder (before, a second recording was deleted when one was already parked),
  - `Recovery/<id>/` folders whose parked file is gone (left by a build that deleted the parked file before inference),
  - the pre-fix `orphan.pcm`.

  A recovery copy whose parked file still exists is redundant and is removed. Capacity is 8 recordings. Past that, the oldest is removed with a log line, never the newest.
- `PhoneDictationPipeline.Output.transcriptionIncomplete` lets recovery tell silence from an incomplete pass.
- `specs/016-ios-dictation-foundation/data-model.md` describes the new behavior.

### Item 2: bounded handoff transfers (Mac and iPhone)

New `packages/LocalFlowCore/Sources/LocalFlowCore/Remote/HandoffFileTransfer.swift`, used by `MeetingHandoff` (Mac upload, result download, phone-meeting import of the bundle and AAC files) and `MeetingUploader` (phone upload and result download).

- Uploads read 48 KB chunks with `FileHandle` and hash in 1 MiB reads. There is no whole-file `Data` or mapping.
- Downloads write each chunk to a private `<file>.part` file (0600, `O_NOFOLLOW`) and update the SHA-256 incrementally. Every reply is checked: announced size from 0 to 1 GiB, a 64-hex checksum, the same size and checksum on every chunk, the right offset, a non-empty chunk of at most 1 MiB, and nothing past the announced size. The file is published with one `rename` after `fsync`.
- Resume: a `<file>.part.<sha256>` marker records which version the partial holds. A later attempt against the same version continues from the partial's size. A different version starts over. A checksum failure deletes the partial and its marker.
- Every read and write runs in an `autoreleasepool`. Without them, `FileHandle` buffers piled up on task threads. In the first test run, before pools were added to both this code and the test's fake server, the footprint grew 204,734,608 bytes during the 96 MiB download.
- Error mapping keeps the old behavior. A Mac download checksum failure is still `protocolError`. The phone download mismatch is still `MeetingUploadError.checksum`, and the phone upload's 3rd mismatch is still `protocolError`.
- No wire schema change.

### Item 5: bounded checksum retries on the Mac

- `HandoffFileTransfer.put` stops after 3 rejected checksums (`maximumMismatches`, the same as the phone). The wait between attempts is `retryDelay` (default 1 s), doubled each time and cancellable.
- The Mac `MeetingHandoff.step` then returns `.waiting("checksum_mismatch")` (`MeetingHandoff.checksumMismatch`). The queue's server wait retries it later, and the local bundle and audio stay. `MeetingHandoff` and `MeetingUploader` take `uploadRetryDelay` for tests.

### Server: less work under the handoff lock (audit "Resource improvements", R7)

`server/internal/remote/handoff.go`

- The per-user byte count is cached in `usage` and updated by appends, truncations and `rows.sqlite` resets. A missing entry is reconciled by one directory walk. `forget` (delete, start, sweep, requeue) and the end of a processor run drop it. Puts no longer walk the directory on every chunk.
- Each file's SHA-256 is built as its chunks arrive (`uploads`), so the final put compares a digest instead of reading the file under `s.mu`. A put resumed by another flowd process has no running hash and still reads the file once.
- The first `get` of a done file is hashed outside `s.mu`. The sum is cached only if the state is still `done` and the file's size and mtime did not change.
- `s.mu` is still one global lock. I did not add per-meeting locks.

## How it was verified

- `swift test --package-path packages/LocalFlowCore`: 17 tests, 0 failures. The 11 new `HandoffFileTransferTests` cover:
  - a 96 MiB synthetic round trip with every put at most 48 KB,
  - an empty file,
  - six malformed replies: over 1 GiB, negative size, data past the announced size, wrong offset, malformed checksum, and a size smaller than the data,
  - a download checksum failure that drops the partial,
  - a dropped connection followed by a resume that fetches only the missing chunks,
  - cancellation mid-download, then a successful retry,
  - a partial of another version starting over,
  - a peer that always rejects the checksum ending after exactly 3 checksum puts with the original unchanged,
  - one rejection followed by success,
  - cancellation during the backoff,
  - a resumed upload.
- Memory: the 96 MiB test samples `phys_footprint` on every server call during the download and asserts growth under 32 MiB. One diagnostic run printed 32,768 bytes of growth. This is a Debug unit test on this Mac with an in-process fake server, not a device or production measurement.
- `xcodebuild test` (macOS, `-only-testing` MeetingHandoffTests, MeetingHandoffImportTests, MeetingTranscriptionCoordinatorTests): 39 passed, 0 failed. This includes the new `testAPeerThatAlwaysRejectsTheChecksumEndsTheStepAndKeepsTheOriginals`, which expects `.waiting("checksum_mismatch")`, 3 checksum puts, and the bundle and audio still on disk.
- `xcodebuild test` (iOS Simulator "iPhone 18 Pro", all of LocalFlowPhoneTests): 223 passed, 0 failed. The old `testFailingOrphanIsDeleted` is replaced. New PipelineTests cover:
  - model failure, then a retry,
  - model load failure,
  - History save failure (a trigger), then a retry that stores exactly one row,
  - cancellation, then a retry,
  - a retry after a committed save (no duplicate),
  - a redundant recovery copy,
  - an interrupted recovery folder,
  - the legacy `orphan.pcm`,
  - two left-over recordings both kept,
  - the capacity bound keeping the newest,
  - clean silence deleted.
- `go vet ./internal/remote` and `go test ./...` in `server/` pass, and `go test -race ./internal/remote` passes. New `TestHandoffPutUsageAndRunningHash` (cached count equals a fresh walk after chunks, a mismatch and a rows reset; resume by a new instance falls back to reading the file; delete clears both caches) and `TestHandoffGetHashesOutsideTheLock`.
- `swift format lint --strict` on every changed Swift file.

## What is left

- `make check` was not run here. The parent runs it after merging.
- Settings still says "1 unrecovered recording" when more than one is parked, and Delete removes all of them (`SettingsView.swift`, left alone to avoid conflicts with the UI workstream, which owns "confirm orphan deletion"). `OrphanSpoolRecovery.orphanCount` is there for a count label.
- A recording that fails recovery forever is retried at every model-ready event until the owner deletes it. There is no attempt cap.
- A Mac upload that keeps hitting checksum mismatches is retried, 3 attempts per step, at the queue's server-wait cadence. It does not fall back to local finalization by itself.
- The server's handoff lock is still global. A put resumed after a flowd restart, and a get whose hash could not be cached, still read the whole file under it. Per-meeting locks would remove that. I did not benchmark concurrent uploads against a nearly full 16-meeting account.
- Hardware checks are still owed: peak memory while importing large AAC and result files on a real Mac and iPhone, and a forced quit during recovery on a device.
