# Client rewrite contract

Behavior of the macOS client's rewrite path: boundaries, bounds, ordering, insertion and user interface. Storage shapes are in [../data-model.md](../data-model.md); the wire format is in [rewrite-protocol.md](rewrite-protocol.md).

## Boundaries and doubles

| Boundary | Protocol | Production | Test double |
| --- | --- | --- | --- |
| Server transport | `RewriteTransporting`: `rewrite(request, credential, timeout) -> AsyncThrowingStream<RewriteEvent>`; `health(endpoint, credential) -> HealthResponse` | `URLSession`-backed `RewriteClient` | `FakeRewriteTransport` scripted per request id: succeed, delay, fail with any category, deliver a stale result, emit malformed or oversized bytes, hang until cancelled |
| Credential store | `RewriteCredentialStoring`: `read(origin)`, `write(origin, secret)`, `remove(origin)` | Keychain generic password | In-memory dictionary |
| Attempt persistence | `RewriteAttemptStoring`: `begin` (admission: throws `attempt_limit`, `concurrency_limit` or `capacity_exceeded` without writing), `recordResult`, `recordFailure` (persisted codes only), `recordCancelled`, `markStale`, `attempts(for:)`, `cancelPendingOnStartup`, `recordDelivered` | `TranscriptionStore` extension (same database, same actor) | Existing fake store gains the same methods |
| Policy and ordering | `RewriteCoordinator` (`@MainActor @Observable`) | one instance in `AppServices` | Driven directly in tests with a fake clock |

`DictationCoordinator` gains an optional `any RewriteRequesting` dependency. In production it is always non-nil: `AppServices` constructs one `RewriteCoordinator` unconditionally, which owns the transport, the credential store and the attempt store. Whether a given dictation is rewritten is decided per attempt from an immutable `RewriteSettings` snapshot (see [../data-model.md](../data-model.md), "Rewrite settings"), so the Enable toggle, mode, endpoint, timeout and override changes apply to the next eligible dictation without relaunch, and an admitted attempt keeps its snapshot. The nil dependency is a test configuration only: with it the session flow is byte-for-byte the existing one and no request object is created. SC-001 is verified by running the Feature 001/002 coordinator tests with the dependency nil and, separately, with the coordinator wired to a guard transport that fails the test if called while rewriting is disabled, in Exact mode and for a bypassed dictation.

## Bounds

| Limit | Value | Overflow behavior |
| --- | --- | --- |
| Input | ≤ 20,000 scalars and ≤ 65,536 bytes, non-blank | Pre-admission refusal `input_too_large`; no row; faithful transcript inserted (live) |
| Response body | `min(4 × input_bytes + 8,192, 73,728)` bytes | Stop reading, `oversized_response` |
| Result text | `min(4 × input_bytes, 65,536)` bytes | `oversized_response` (also the client mapping of the server's `output_too_large`) |
| Timeout | 5…60 s, default 20 s; clamped on read | `timed_out`, reached within timeout + ≤ 500 ms of client-side handling; late bytes discarded |
| Connection test timeout | 10 s | `serverUnreachable` |
| Admitted attempts per dictation | 10 | Pre-admission refusal `attempt_limit`: explanation shown, no row, existing attempts kept |
| In flight | 1 per dictation, 2 overall | Pre-admission refusal `concurrency_limit`, identical from dictation and from history: no row, no ordinal. In the live flow the faithful transcript is inserted immediately and the notice reads "Two rewrites are still running. Original text inserted." with Retry; from history the same text is shown and nothing changes. Running attempts are never cancelled to make room and nothing waits. |
| Storage quota | `history_usage.payload_bytes` ≤ 33,554,432 | `begin` throws `capacity_exceeded` inside its transaction; no row |
| Stream line | 8,192 bytes, except `result` | `malformed_response` |
| Credential | ≤ 4,096 bytes | Settings validation error |
| Endpoint | absolute `http`/`https` URL, ≤ 255 bytes origin | Settings validation error |

No queue holds requests. Every refusal above happens before admission ([../data-model.md](../data-model.md), "Admission"): it is immediate, makes no network call, creates no `rewrite_attempts` row, consumes no ordinal, and emits only a content-free refusal counter. Failures after admission are recorded on the attempt row.

## Attempt identity and ordering

- Each attempt id is a fresh UUID and is the protocol `request_id`. Each attempt belongs to exactly one dictation id and receives the next ordinal in one transaction.
- A result is applied only if, on the main actor at delivery time, the attempt is still `pending` and is the newest attempt for its dictation. Otherwise it is recorded `stale` and discarded. This check runs after every await, before persistence and before insertion.
- Cancellation cancels the transport task and records `cancelled` immediately; bytes that arrive afterwards are dropped by the stale check. Control returns to the user within the same run-loop turn; SC-004 measures this.
- Starting a new dictation never cancels another dictation's pending attempt. A pending attempt for an older dictation completes into history with no insertion.
- Settings are snapshotted at admission; later changes affect later attempts only. Disabling rewriting while an attempt is pending does not cancel it.

## Session flow

After `store.commit` succeeds, the coordinator runs the admission sequence from the data model with a fresh settings snapshot. A refusal at any step inserts the faithful transcript immediately with the reason's notice and creates no attempt. After admission:

1. Transition to `rewriting`; indicator shows "Rewriting…" with Cancel; Escape and the indicator button cancel the rewrite only.
2. `RewriteCoordinator.rewrite(dictation:, text:, mode:, settings:)` has already persisted the pending attempt during admission; it now awaits the transport.
3. On `succeeded`: transition to `inserting` and insert `output_text` through `insertOnce` with the session's captured target. On any other terminal state: insert `input_text` the same way and show the failure notice with the category and Retry.
4. Delivery outcome is recorded on the transcription exactly as today, together with `delivered_source` (`faithful` or `rewrite`) and `delivered_rewrite_attempt_id`, and the attempt's `delivered` flag. If the target is no longer valid, the existing `recovery` state applies and both texts are available in history.

The faithful transcript is committed before step 1 and is never modified by any step. Model output never enters `transcriptions.text` or `transcription_quality`.

Delivery policy: `RewriteDeliveryPolicy.waitThenInsert` is the only implemented case. `insertThenReplace` exists as a declared case so the seam is visible; selecting it is a startup precondition failure until the revisit path in [../research.md](../research.md) is completed.

## Latency measurement

Each attempt captures five `ContinuousClock` instants on the main actor: `committed` (store commit returned), `sent` (request body handed to the transport), `firstByte`, `terminal` (result or error parsed, or timeout/cancel), `handedOff` (text passed to `insertOnce` or attempt ended without insertion). Persisted spans and metric cases follow [../data-model.md](../data-model.md). The resource report groups by input-length bucket ([rewrite-quality.md](rewrite-quality.md), "Input-length buckets") and by `backend_model + prompt_version + shield_version`, prints median and p95 per group, and prints "unmeasured" for any group with fewer than 5 samples. The acceptance file `acceptance/latency.md` states, per bucket, the gate, the measured value, the identity block from [rewrite-quality.md](rewrite-quality.md) "Evidence identity", and which span dominates when a gate is missed. SC-011 gates: short bucket median ≤ 1.5 s (binding) with the ≤ 1.0 s optimization target reported beside it as achieved or not achieved; ordinary bucket p95 ≤ 3.0 s (binding); long and Polished-long are reported without a gate. A missed gate is a failed gate, not a footnote; a missed optimization target is not a failure.

## Retry from history

`Retry` (or `Rewrite` on a not-requested dictation) picks a mode, runs the same admission sequence as the live flow with a fresh settings snapshot, then creates a new attempt using the stored `input_text` of the first attempt or, when none exists, `transcriptions.text`. No recognition, no audio, no new dictation. History-initiated attempts have no captured insertion target: they never insert automatically and never trigger fallback insertion. On any terminal state the row is updated and the detail view refreshes; on success it shows the new current rewritten text. Insertion from history is always explicit through `ExplicitInsertionCoordinator`, extended to insert a chosen text (faithful or rewritten) with its existing target selection and confirmation flow. The faithful transcript's explicit Insert here is the "use faithful transcript instead" action of FR-021 for history and recovery.

## Failure to user text

| Category | Notice |
| --- | --- |
| server_unreachable | Rewrite server unreachable. Original text inserted. |
| timeout (state timed_out) | Rewrite took too long. Original text inserted. |
| authentication_failed | Rewrite server rejected the credential. Check Settings. |
| backend_unavailable | Rewrite model is not available on the server. |
| malformed_response, unsupported_schema_version, request_mismatch | Rewrite server sent an unusable reply. |
| empty_response, oversized_response, server_validation_failed | Rewrite result was rejected. |
| missing_credential, insecure_endpoint_blocked, invalid_settings, input_too_large, capacity_exceeded (pre-admission) | Rewriting skipped: <reason>. Original text inserted. |
| attempt_limit (pre-admission) | This dictation already has ten rewrite attempts. |
| concurrency_limit (pre-admission) | Two rewrites are still running. Original text inserted. |
| cancelled | Rewrite cancelled. Original text inserted. |
| interrupted | Rewrite was interrupted by a restart. |

"Original text inserted." is appended only in the live flow; the history variants of the pre-admission notices omit it. Messages never include transcript text, URLs with credentials, or raw error descriptions. Developer diagnostics use `DictationErrorMessage`-style bounded codes.

## Settings

Controls: Enable rewriting (toggle), Endpoint (text), Default mode (Exact/Clean/Polished/Concise), Timeout (5–60 s stepper), Credential (masked field with Set/Reveal/Remove), "Allow unencrypted connection to this server (insecure)" (toggle, shown only for an off-loopback `http://` origin), Test connection (button with result line), and a note that holding Shift on release skips rewriting for one dictation (or that the gesture is unavailable because Shift is in the shortcut).

Rules (FR-016a): HTTPS is the default expectation. Loopback `http://` (`localhost`, `127.0.0.0/8`, `[::1]`) needs neither credential nor override. The toggle cannot turn on while the endpoint is invalid, a required (non-loopback) credential is missing, or the origin is off-loopback `http://` without the insecure override; the reason is shown inline. The override toggle is shown only for an off-loopback `http://` origin, is stored per exact origin, is never read for any other origin, clears when the origin changes, and turning it off while rewriting is enabled turns rewriting off for that endpoint at once. While the override is on, a persistent warning above the controls states: "Transcripts and the credential travel unencrypted to <host>. Authentication does not encrypt them. Use this only on a network you trust." The credential is never displayed by default and never written to UserDefaults, logs or diagnostics exports. Changing the endpoint origin re-reads the credential for the new origin. Every change is read by the next admission snapshot; no relaunch is needed. Test connection reports one of the eight categories in plain language plus server name/version, backend kind/model, prompt versions, shield version and protocol version when connected.

## History and detail

List rows show a rewrite badge from `rewrite_state` (none for `not_requested`). Detail shows the Feature 002 sections unchanged, then a "Rewrite" section: current rewritten text labelled "AI-generated rewrite, not the transcript" beside the saved (faithful) text, with Copy and Insert for each; a "Delivered" line naming what was inserted (faithful, or rewrite attempt N with its mode) and flagging when the current rewrite differs from the delivered one; the attempts list ordered by ordinal with mode, state, duration, first-byte time, failure category, stale and delivered markers, and backend model / prompt version / shield version; Cancel for a pending attempt; Retry or Rewrite with a mode picker; the attempt limit explanation when reached. Delete removes attempts with the dictation. Legacy rows show "Rewrite: not requested" and no attempt rows.

## Observability

Per terminal attempt: the five-instant spans, server-reported spans, request/response byte counts, input scalars and bucket, ordinal, outcome category, fallback used, cancellation/timeout flags, and backend/model/prompt/shield identity, delivered to `ResourceRecorder`. Per pre-admission refusal: one counter with the reason and bucket only. Logger lines use category, attempt id and identity fields only. A test asserts that a full fake acceptance run's log capture and metric export contain neither corpus text nor the credential.

## Accessibility and announcement

`IndicatorPanel.announcement` gains `rewriting` ("Rewriting text. Microphone off.") and the failure notice is announced with its message. The Settings controls carry labels and the warning is announced when it appears.
