# Feature 014 acceptance

Status on 2026-09-27: the deterministic implementation is complete and its suites pass
(see "Deterministic evidence"). None of the hardware, network or sign-in acceptance in
quickstart §2 to §6 has been run, so **no success criterion is reported as met**. ADR 0028
stays Proposed until the rows below marked "not measured" have recorded values.

## Success criteria

| SC | Target | Measured value | Where |
| --- | --- | --- | --- |
| SC-001 added time after release, remote vs local | median < 150 ms Wi-Fi, < 400 ms LTE | not measured | T093, `latency-and-equality.md` |
| SC-002 per-user added wait with 2 and 4 users | ≤ 1 window (2 users), ≤ 3 (4 users) | not measured. Scheduler logic: every fairness test passes (`server/internal/speech/scheduler_test.go`, T084) | T087, `concurrency.md` |
| SC-003 fallback time and outcome with the server gone | ≤ threshold + local recognition; 100% inserted or recoverable | not measured. Every FR-017 trigger ends in local text or a pending retry in the routing and session suites | T093 |
| SC-004 flowd RSS idle / four dictations | 100 MB / 250 MB | not measured | T092, `resources.md` |
| SC-005 remote and local transcripts identical | identical, or documented timing differences | not measured on recordings. The equality test (`WindowSourceTests`) shows byte-identical results for the same windows delivered locally and as server results | T093 |
| SC-006 cross-user isolation suite | zero cross-user cases | 0 cases in `server/internal/remote/isolation_test.go` (deterministic suite, two users, every message type) | this file |
| SC-007 revocation ends live sessions within 1 s | 100% of trials | server logic on loopback only: 50 of 50 within 1 s, median 126.6 ms, maximum 232.7 ms ([revocation.md](revocation.md)). End to end through the tunnel: not measured | T082 |
| SC-008 installed app unchanged by a dev build cycle | byte- or state-identical | met on 2026-09-28 (M5): empty before/after diff across a dev dictation, `kill -9` and uninstall ([dev-coexistence.md](dev-coexistence.md)) | T037 |
| SC-009 no content or credentials in logs | zero findings | deterministic runs: 0 findings in the verbose Go logs of the remote packages and the app's unified log for the scoped XCTest runs (`scripts/check-remote-logs.sh`). Benchmark and hardware logs: not scanned | T094, `log-scan.md` |

## Remote delivery gate (constitution 2.0.0)

| Gate item | Covered by | State |
| --- | --- | --- |
| Threat: stolen refresh token | refresh needs a device signature over the channel binding (`remote/refresh_test.go`), rotation and reuse revocation (`accounts/tokens_test.go`), client signing with the device key (`RemoteEnrollmentTests`) | tests pass |
| Threat: stolen laptop | admin revocation closes live channels within 1 s and refuses refresh (`remote/revocation_test.go`, 50-trial acceptance variant) | tests pass; tunnel latency not measured |
| Threat: unapproved account | pending by default, 100-pending cap, sign-in rate limit, OIDC issuer/audience/nonce/expiry/kid checks (`remote/enroll_test.go`, `oidc/verifier_test.go`, `remote/session_auth_test.go`); client routes pending devices locally (`RemoteDictationRoutingTests`) | tests pass |
| Threat: replayed or reordered frames | sequence-checked HPKE frames both ways (`remote/channel_test.go`, `RemoteChannelTests`, shared vectors) | tests pass |
| Threat: compromised tunnel provider | inner HPKE channel pinned at enrollment; close 4001 becomes `pin_mismatch` and never re-pins (`RemoteChannelTests`, `RemoteEnrollmentTests`) | tests pass |
| Threat: one user reading another's data | scoping from the token only, isolation suite, per-job leases in the worker (`remote/isolation_test.go`, `ModelOwnershipTests`, worker hint validation in `remote/dictation.go`) | tests pass |
| Authentication and revocation | Sign in with Apple and Google, admin approval, 15-minute access tokens, Secure Enclave–bound refresh | code and tests done; real Apple/Google sign-in not exercised (needs the owner's App ID, Google client and tunnel, T051) |
| Per-user isolation | as above | tests pass |
| Fallback behaviour | every FR-017 trigger (`RemoteDictationSessionTests`), routing and pending retries (`RemoteDictationRoutingTests`, `PendingRemoteRetrierTests`) | tests pass |
| Measured network latency on the Mac mini | quickstart §6 | not measured |

## Deterministic evidence

- `make check` steps other than the full XCTest run pass: Swift format lint, script syntax,
  import checks (including `check-speech-worker-imports.sh`), schema and example validation,
  the Python quality checks, `plutil`, `gofmt`, `go vet`, `go test ./...` and
  `go test -tags localflow_debug ./...`, and the `flowd-speech` target build.
- XCTest: every class touched by this feature was run in scoped runs and passes (list in
  the T095 report in `tasks.md` context). The full suite was not run here because it plays a
  sound on the owner's machine; run `make check` once before merging.
- Real worker smoke test (not an SC measurement): on this Mac (Apple M5, 32 GB, macOS 27.0),
  a Debug `flowd-speech` with a clone of the installed Parakeet v3 and CTC 110M models loaded
  in 25 s cold (0.3 s warm file cache) and recognized 239,360-sample windows in 140–350 ms.
  `TestRealWorkerWindowsDecode` (opt-in) passed with the Go supervisor driving that worker.
  That run also found and fixed a real defect (a `state` frame sent before `ready`).

## Hardware and network tasks still open

T051 (enrollment against the Mac mini),
T082 (remote dictation and fallback through the tunnel), T087 (2 and 4 users),
T092 (flowd and worker memory), T093 (latency and transcript equality on Wi-Fi and LTE)
and T094 (log scan of those runs). Each needs the owner prerequisites in quickstart.md.
T037 passed on 2026-09-28 ([dev-coexistence.md](dev-coexistence.md)).
