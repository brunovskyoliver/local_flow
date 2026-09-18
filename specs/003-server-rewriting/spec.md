# Feature Specification: Feature 003 — Server-Assisted Dictation Rewriting

**Feature Branch**: `main` (existing branch; no branch-creation hook configured)

**Created**: 2026-09-17

**Status**: Planned and tasked 2026-09-17; analysis findings reconciled 2026-09-17; ready for implementation

**Input**: Add an optional, self-hosted rewriting stage that runs after the faithful local transcript from Feature 002 exists and before safe insertion. The user chooses Exact, Clean, Polished or Concise. The rewrite server is user-controlled, speaks a versioned structured protocol, never receives audio, and never becomes part of speech recognition. The faithful transcript survives every rewrite outcome. Meeting features, application-aware context, translation, cloud AI and client-side LLMs are excluded.

## Boundary with Features 001 and 002

The pipeline is:

RAW RECOGNITION → ASSEMBLED → NORMALIZED → PREFERRED SPELLINGS → FAITHFUL LOCAL TRANSCRIPT → **Feature 003 optional rewrite** → SAFE INSERTION

Feature 003 begins only after the faithful local transcript is complete and durably saved. Rewriting is a derivative step, not a transcription stage. Rewritten text is never counted in Feature 002 WER/CER measurements and never conceals recognition, assembly or normalization errors. When rewriting is disabled, the Feature 001/002 behavior is unchanged.

## Clarifications

### Session 2026-09-17

- Q: When a rewrite succeeds, should the rewritten text be inserted automatically, or should the user confirm it first? → A: Auto-insert through the existing safe insertion path; no confirmation step.
- Q: When a rewrite fails, times out or is cancelled, should the faithful transcript be inserted automatically, or shown and left for the user to act on? → A: Auto-insert the faithful transcript on failure, timeout and cancellation, with a visible notice and retry offered.
- Q: When the rewrite server is on another machine, must the client require an encrypted connection and a credential before sending a transcript? → A: Non-local endpoints require a credential; plain HTTP is allowed with a visible warning in Settings.
- Q: For protected content in the quality evaluation, which classes must pass at 100% as hard gates and which are reviewed against a threshold? → A: Pattern-matchable classes (IP addresses, URLs, emails, paths, version strings, numbers, currency, dates, times, listed identifiers) are 100% hard gates checked automatically; names, negation, task ownership, commitments and language mix are reviewed at ≥95% with zero accepted negation or ownership inversions.
- Q: How long should the client wait for a rewrite before giving up and inserting the faithful transcript? → A: 20 s default, adjustable 5–60 s, strictly as the failure/timeout ceiling, not the expected latency. Target very low perceived latency: short common rewrites normally around 1 s where the self-hosted hardware and model permit, ordinary rewrites within a few seconds, longer Polished requests may take longer. The architecture must support streaming server responses and a warm dedicated rewrite model. Planning must evaluate an "instant faithful insertion + safe background upgrade" interaction (insert the faithful transcript immediately, rewrite asynchronously, replace only the exact inserted passage if it is unchanged and the destination is still valid; otherwise keep the rewrite as an alternative, never mutate automatically). No arbitrary chunking for normal short dictations; bounded sentence/paragraph processing for genuinely long inputs only if benchmarks show a latency gain without meaning change. The 20 s timeout stays the final fallback boundary.

### Design reconciliation 2026-09-17 (post-analysis, no new clarification round)

- Off-loopback plain HTTP: the planning decision to gate it behind an explicit per-origin insecure transport override is adopted into the specification. HTTPS is the preferred default. HTTP to a loopback host (`localhost`, `127.0.0.0/8`, `[::1]`) is allowed without the override. HTTP to any other host is blocked until the user turns on the override for that exact origin; with the override on, a credential is additionally mandatory and Settings shows a persistent warning for that origin stating that transcripts travel unencrypted and that authentication does not encrypt them. The override never becomes a global "allow HTTP" switch, and turning it off makes that endpoint ineligible at once. Two local refusal reasons, `missing_credential` and `insecure_endpoint_blocked`, join the normative category set.
- Short-rewrite latency: "about 1 second" is split into a product optimization target (short-bucket median ≤ 1.0 s) and a binding acceptance gate (short-bucket median ≤ 1.5 s). The ordinary-bucket gate (p95 ≤ 3.0 s) is unchanged. See SC-011.
- Attempt persistence: a rewrite attempt row exists only once the attempt has passed every local admission check; pre-admission refusals create no row, consume no ordinal and send nothing. The ten-attempt limit counts admitted attempts.
- Runtime toggle: the rewrite capability is always wired in the production app; every eligibility decision reads an immutable settings snapshot taken for that attempt, so changing Settings affects the next dictation without relaunch.
- History-initiated rewrites never insert automatically; their results are shown in history for explicit Insert or Copy.
- Connection test outcomes: eight, not six (the two local refusals above are added).
- Timeout tolerance: an attempt ends within the configured timeout plus at most 500 ms of client-side handling.
- SC-010a renumbered to SC-011; no evidence had been recorded under the old identifier.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Turn rewriting on or off and keep dictating either way (Priority: P1)

As a person dictating, I can enable or disable AI rewriting globally. With rewriting off, my speech becomes the faithful transcript and is inserted as today. With rewriting on, the faithful transcript is sent to my own rewrite server and the rewritten text is inserted instead. If the server, network or language model is unavailable, dictation keeps working and no completed text is lost.

**Why this priority**: The switch and the safe fallback are the minimum viable slice. Without them, every other story either has nothing to control or risks losing dictated text.

**Independent Test**: Dictate with rewriting off and confirm the existing path is byte-identical. Turn rewriting on with a test double that succeeds, then with one that is unreachable, and confirm the faithful transcript is saved and available in both cases.

**Acceptance Scenarios**:

1. **Given** rewriting is disabled, **When** a dictation completes, **Then** the faithful transcript is inserted through the existing path and no rewrite request is made.
2. **Given** rewriting is enabled and the server responds, **When** a dictation completes, **Then** the faithful transcript is saved first, the rewritten text is inserted, and both texts are retained.
3. **Given** rewriting is enabled and the server is unreachable, times out, or returns an unusable result, **When** a dictation completes, **Then** the faithful transcript is durably saved and inserted through the existing safe path if the target is still valid, the failure is shown, and the user can copy or retry without recording again.
4. **Given** Features 001 and 002 regression suites, **When** they run with rewriting disabled, **Then** they pass unchanged.

---

### User Story 2 - Choose how much the text is rewritten (Priority: P1)

As a person dictating, I choose a rewrite mode: Exact (no rewriting), Clean (punctuation, grammar, capitalization, obvious fillers removed, wording preserved), Polished (natural professional writing, sentences may be restructured, all facts and commitments kept) or Concise (repetition and clutter removed, every actionable and factual detail kept, never a summary).

**Why this priority**: The modes are the product. Distinct, predictable behavior per mode is what makes the feature worth enabling.

**Independent Test**: Send the same faithful transcript in each mode against a test double and confirm the selected mode is transmitted and recorded. Run the quality corpus per mode and review outputs against the mode definitions.

**Acceptance Scenarios**:

1. **Given** Exact is selected, **When** a dictation completes, **Then** no rewrite request is made and the faithful transcript is inserted.
2. **Given** Clean, Polished or Concise is selected, **When** a dictation completes, **Then** the request carries that mode and the stored attempt records it.
3. **Given** the input "Peter can you please move the Odoo deployment to Monday because Friday we have network maintenance" in Polished mode, **When** the result is reviewed, **Then** it reads as natural written English, keeps Peter, Odoo, Monday, Friday and the maintenance reason, and is not shortened to a summary.
4. **Given** Concise mode and a transcript containing two distinct commitments, **When** the result is reviewed, **Then** both commitments remain with their owners and dates.

---

### User Story 3 - Slovak, English and mixed technical language stay in the speaker's language (Priority: P1)

As a person who dictates in Slovak, English or a mix with technical terms, I get rewritten text in the same language mix I spoke. "Na Proxmoxe potrebujeme update-núť ten VM a potom checknúť NetBird configuration." is not turned into all-English or all-Slovak, and technical terms such as Proxmox, VM and NetBird are kept.

**Why this priority**: The owner's daily use is Slovak/English technical dictation. A rewrite that translates or strips terminology is worse than no rewrite.

**Independent Test**: Run the Slovak, English and mixed subsets of the quality corpus and review language preservation and terminology retention per item.

**Acceptance Scenarios**:

1. **Given** a Slovak transcript, **When** rewritten in any mode, **Then** the output is Slovak with diacritics preserved.
2. **Given** a mixed Slovak/English transcript, **When** rewritten, **Then** English technical terms remain English and Slovak sentences remain Slovak.
3. **Given** locally known language hints, **When** a request is built, **Then** the hints may be included but no translation is requested or performed.

---

### User Story 4 - Retry or cancel without recording again (Priority: P2)

As a person dictating, I can retry a failed or unsatisfactory rewrite, in the same or another mode, without speaking again and without re-running recognition. I can cancel a pending rewrite. A late or stale response never replaces a newer result, and retries stay attached to the same dictation.

**Why this priority**: Rewrite quality varies per run and servers fail intermittently. Retry and cancel make the feature usable without punishing the user with re-dictation.

**Independent Test**: With test doubles that delay, fail, then succeed, retry a dictation several times, cancel mid-flight, and deliver a stale response after a newer attempt; confirm attempt ordering, current-result selection and that recognition was never invoked.

**Acceptance Scenarios**:

1. **Given** a failed rewrite, **When** the user retries in Polished mode, **Then** a new attempt uses the same faithful transcript snapshot, no recognition runs, and the attempt is recorded in order under the same dictation. A retry started from history never inserts automatically; its result appears in history for explicit Insert or Copy.
2. **Given** a pending rewrite, **When** the user cancels, **Then** the attempt is marked cancelled, the faithful transcript is inserted through the existing safe path if the target is still valid, the faithful transcript and any earlier successful attempt remain, and a response arriving afterwards is discarded.
3. **Given** two attempts for one dictation, **When** the older attempt's response arrives after the newer one has completed, **Then** the newer result remains current and the late response is recorded as stale, not applied.
4. **Given** the per-dictation limit of ten admitted attempts is reached, **When** the user retries again, **Then** the limit is explained, no attempt row is created and existing attempts are preserved.

---

### User Story 5 - Inspect the faithful transcript and every rewrite separately (Priority: P2)

As a person reviewing history, I can see for each dictation the raw recognition, assembled, normalized and faithful transcripts from Feature 002 unchanged, plus each rewrite attempt with its mode, input snapshot, outcome, timing and output. Rewritten text never overwrites transcription evidence. Deleting a dictation deletes its rewrite artifacts with it.

**Why this priority**: Trust depends on being able to compare what was said with what the model wrote. This is also how quality problems are diagnosed.

**Independent Test**: Complete an AI-assisted dictation with two attempts, restart the application, inspect the entry, then confirm deletion removes all associated attempts.

**Acceptance Scenarios**:

1. **Given** a dictation with a successful rewrite, **When** its details are opened, **Then** the faithful transcript and rewritten text are shown side by side and the rewritten text is labelled as an AI-generated derivative.
2. **Given** a dictation with several attempts, **When** history is viewed, **Then** the dictation appears once with its attempts ordered, each showing mode, state, duration and failure category where applicable.
3. **Given** an application restart, **When** history loads, **Then** all attempts and their input snapshots are intact.
4. **Given** a confirmed deletion, **When** it completes, **Then** no rewrite attempt, snapshot or output for that dictation remains.
5. **Given** pre-existing history from Features 001/002, **When** it loads, **Then** entries show "not requested" rewrite state and no fabricated attempt data.

---

### User Story 6 - Skip rewriting for one dictation (Priority: P2)

As a person dictating with rewriting enabled, I can bypass rewriting for a single dictation so that transcript never leaves the Mac. The gesture is holding Shift while releasing the push-to-talk shortcut (recorded in [research.md](research.md), "Bypass gesture"); it is unavailable when Shift is part of the configured shortcut, and Settings says so.

**Why this priority**: Some dictations are sensitive or short enough that sending them is unwanted. The global switch must not force every transcript to the server.

**Independent Test**: With rewriting enabled, use the bypass for one dictation and confirm no request is sent, the faithful transcript is inserted and the entry records "not requested".

**Acceptance Scenarios**:

1. **Given** rewriting is enabled, **When** the user bypasses it for a dictation, **Then** no request is sent and the faithful transcript is inserted.
2. **Given** a bypassed dictation, **When** the user later chooses Rewrite from history, **Then** rewriting can be requested explicitly for that dictation; the result is shown in history and is not inserted automatically.

---

### User Story 7 - Configure and test the rewrite server (Priority: P2)

As the owner of the rewrite server, I configure its endpoint, enabled state, default mode, timeout, credentials and, for a non-loopback plain-HTTP endpoint, the per-origin insecure transport override in Settings, and run an explicit connection test that tells me whether the server is reachable, authenticated, offering the rewrite service, backed by an available language model, and speaking a compatible protocol version, or whether the endpoint is refused locally for a missing credential or blocked unencrypted transport. Secrets are stored in the system credential store, not as plain preferences. Internal error details are never shown as raw stack traces.

**Why this priority**: The server is self-hosted and may live on another machine. Without clear diagnostics, every failure looks the same.

**Independent Test**: Point Settings at test doubles simulating each outcome category and confirm the displayed status matches. Confirm the credential is absent from preferences storage.

**Acceptance Scenarios**:

1. **Given** a valid endpoint and credential, **When** the test runs, **Then** the status reads Connected and reports server identity/version and protocol version.
2. **Given** a wrong credential, **When** the test runs, **Then** the status reads Authentication failed.
3. **Given** an unreachable host, a server without the rewrite service, a server whose model backend is down, and a server with an unsupported protocol version, **When** the test runs, **Then** each shows its distinct category.
4. **Given** a non-loopback endpoint over plain HTTP with the insecure transport override off, **When** Settings shows it, **Then** the endpoint cannot be enabled, the connection test reports "unencrypted connection blocked" without sending anything, and the override control is offered for that origin only.
4a. **Given** the insecure transport override is on for that origin, **When** Settings shows it, **Then** a persistent warning states that transcripts and the credential travel unencrypted to that host and that authentication does not encrypt them, the endpoint still cannot be enabled until a credential is stored, and turning the override off makes the endpoint ineligible immediately. Changing the origin clears the override.
5. **Given** the app has been restarted, **When** Settings opens, **Then** endpoint, mode and timeout are restored and the credential is available without being displayed in clear text by default.

---

### Edge Cases

- Empty faithful transcript, whitespace-only transcript or a transcript marked incomplete by Feature 002: rewriting is not requested; existing incomplete-result handling applies.
- Faithful transcript above the maximum input size: rewriting is refused locally before admission with an explanation; no attempt row is created and the faithful transcript is inserted per the fallback policy.
- Any other pre-admission refusal (rewriting disabled, Exact, bypass, missing credential, blocked unencrypted endpoint, invalid settings, ten admitted attempts already, an attempt already in flight for the dictation, the global in-flight cap, or storage quota that cannot hold the attempt): same treatment — notice where applicable, content-free metric, no network request, no attempt row, no ordinal consumed. Failures after admission (network, authentication response, timeout, malformed or oversized response, backend unavailable, cancellation, restart) are recorded on the attempt row.
- Response that is empty, malformed, of the wrong schema version, for a different request identifier, larger than the accepted maximum, or missing the rewritten text: treated as a failed attempt with a specific category; nothing from it is inserted.
- Response containing commentary, explanations or multiple candidates: only the validated rewritten-text field is eligible for insertion.
- Response text identical to the input: treated as success; recorded as unchanged.
- Server reachable but slow: the bounded timeout fires, the attempt is timed out, and a later response is discarded.
- User starts a new dictation while a rewrite is pending: the pending attempt remains associated with its own dictation; results never cross.
- Application quits or crashes during a pending rewrite: on restart the attempt is marked failed/interrupted; the faithful transcript remains.
- Insertion fails after a successful rewrite: both texts remain recoverable through the existing explicit insertion and copy paths.
- Non-loopback endpoint configured without a credential: rewriting cannot be enabled and the connection test reports `missing_credential`; no request is sent.
- Non-loopback plain-HTTP endpoint without the insecure transport override: rewriting cannot be enabled and the connection test reports `insecure_endpoint_blocked`; no request is sent. Disabling the override while the endpoint is enabled disables rewriting for that endpoint at once.
- Credential present locally but rejected by the server: `authentication_failed` after the request; no request is retried automatically.
- Settings changed while an attempt is pending: the pending attempt continues with the immutable settings snapshot captured at admission (enabled state, mode, endpoint origin, timeout, insecure override, credential presence); the change applies to later attempts. Turning rewriting on or off in Settings takes effect for the next eligible dictation without relaunching the app.
- Background upgrade (if adopted): the user edits the inserted passage, moves focus, or the destination changes before the rewrite arrives: the text is left as is and the rewrite is stored as an alternative; nothing is replaced.
- Background upgrade (if adopted): the rewrite arrives while the passage is unchanged and the destination valid: only that exact passage is replaced, through the same target checks as insertion, and the faithful transcript stays in history.
- Network disabled and no server: Settings, history and dictation remain usable; the rewrite path reports server unreachable.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Provide a global enabled/disabled setting for rewriting. When disabled or when the mode is Exact, no rewrite request is made and Feature 001/002 behavior is unchanged.
- **FR-002**: Provide Exact, Clean, Polished and Concise as distinct user-selectable modes with a configurable default. Mode definitions: Clean preserves wording and meaning while fixing punctuation, grammar, capitalization and removing obvious fillers; Polished may restructure sentences into natural professional writing; Concise removes repetition and clutter. None may summarize, translate, invent content, or drop factual or actionable content.
- **FR-003**: Start rewriting only after the faithful local transcript is complete and durably saved. Rewriting MUST NOT be applied to incomplete, duration-limited or uncertain results that Feature 002 withholds from automatic insertion.
- **FR-004**: The rewrite request MAY contain only: the faithful transcript text, selected mode, protocol/schema version, a request identifier, locally known language hints, and required feature flags. It MUST NOT contain microphone or system audio, other history entries, meeting data, clipboard contents, active-application contents, surrounding target text or filesystem data. Application-aware context is out of scope.
- **FR-005**: Preserve the language mix of the input. Requests MUST NOT ask for translation and results that change the language of the input MUST be treated as quality failures in evaluation.
- **FR-006**: Communicate through a versioned, structured LocalFlow rewrite protocol. A successful response carries at least schema version, request identifier, mode and rewritten text. The client MUST validate schema version, request identifier match, presence and type of rewritten text, and size before use. Any additional fields or commentary MUST NOT be inserted. Behavior MUST NOT depend on parsing free-form model output.
- **FR-007**: Enforce a finite, user-configurable timeout within a bounded range, a maximum input size, a maximum accepted response size (enforced before parsing), a maximum of ten admitted attempts per dictation, and at most one in-flight rewrite request per dictation. Automatic retries are not performed; retries are user-initiated. No unbounded queue or request accumulation may be introduced.
- **FR-007a**: An attempt is persisted as a rewrite-attempt row, receives its ordinal and becomes `pending` only after it passes every local admission check (rewriting enabled, mode not Exact, not bypassed, settings valid and sendable, input within bounds, fewer than ten admitted attempts, no attempt in flight for the dictation, global in-flight cap not reached, storage quota available). Only then may a network request be made. A pre-admission refusal creates no row, consumes no ordinal, sends nothing, shows the applicable notice and emits a content-free metric. This rule applies identically to live dictation and to history-initiated actions.
- **FR-008**: Allow cancellation of a pending rewrite. Cancellation MUST preserve the faithful transcript and prior successful attempts and MUST cause any later response for that attempt to be discarded.
- **FR-009**: Assign each dictation and each attempt a stable identity. A response MUST be applied only to the attempt it belongs to, and only if that attempt is still the newest for its dictation and still pending. Stale, late, cancelled or mismatched responses MUST be recorded as such and never inserted or shown as current.
- **FR-010**: On any post-admission failure (server unreachable, timeout, authentication failure, transport/security error, model backend unavailable, malformed response, unsupported schema version, request mismatch, empty response, oversized response, server-side validation failure, cancelled, interrupted) and on any pre-admission refusal that occurs during a live dictation (input too large, missing credential, insecure endpoint blocked, invalid settings, concurrency limit, capacity exceeded), the faithful transcript MUST be inserted automatically through the existing safe path when the captured target is still valid, a notice MUST identify the reason, and the transcript MUST remain copyable, retryable and dismissible without loss of history. The exhaustive code list is the failure-category set in [data-model.md](data-model.md); several codes may share one user-facing message. A failed rewrite is not a failed transcription.
- **FR-011**: Allow retry of any dictation's rewrite from the completed state or from history, in the same or a different mode, without recording or recognition. Retries MUST reuse the stored faithful transcript snapshot and MUST be ordered under the same dictation. Automatic insertion and automatic fallback apply only to the live dictation flow that captured an insertion target; a rewrite started from history has no captured target, MUST NOT insert anything automatically, and on success persists its result and shows it in history for explicit Insert or Copy.
- **FR-012**: Allow per-dictation bypass of rewriting while it is globally enabled. A bypassed dictation records rewrite state "not requested" and can be rewritten later on explicit request from history, under the FR-011 no-auto-insert rule.
- **FR-013**: Insert successful rewrite output automatically, without a confirmation step, and only through the existing safe insertion mechanism with its existing target-validity checks. No global typing, clipboard substitution or arbitrary target mutation is introduced. If insertion fails, both texts remain recoverable.
- **FR-014**: Persist each attempt with: dictation identity, attempt order, mode, exact faithful transcript snapshot used as input and its hash, state (not_requested, pending, succeeded, failed, cancelled, timed_out), rewritten output when successful, start timestamp, duration, protocol/schema version, server identity/version where available, failure category, and relationship to prior attempts. Hidden model reasoning MUST NOT be stored. Feature 002 raw, assembled, normalized and faithful representations MUST remain unchanged and independently inspectable.
- **FR-015**: Confirmed deletion of a dictation MUST remove all its rewrite attempts, snapshots and outputs, consistent with existing deletion behavior. Existing history without rewrite data remains readable with state "not requested".
- **FR-016**: Provide Settings for endpoint, enabled state, default mode, timeout and authentication. Credentials MUST be stored in the system credential store, never in plain preferences, logs or exported diagnostics. Where technically distinguishable, the UI MUST separate configured, reachable, authenticated, rewrite service available and model backend available. The rewrite capability MUST be wired whenever the app runs; changing any of these settings takes effect for the next eligible dictation without relaunch, and an attempt already admitted keeps the immutable settings snapshot it was admitted with.
- **FR-016a**: Transport policy. HTTPS is the preferred default. HTTP to a loopback host (`localhost`, `127.0.0.0/8`, `[::1]`) MAY be used, with or without a credential. HTTP to any other host is blocked by default: rewriting cannot be enabled, no request is sent, and the refusal is reported as `insecure_endpoint_blocked`. The user MAY lift the block only through an explicit insecure transport override scoped to that exact endpoint origin; the override MUST NOT act as a global "allow HTTP" switch, MUST clear when the origin changes, and turning it off MUST make the endpoint ineligible immediately. With the override on, a credential is additionally mandatory (a missing one is reported as `missing_credential`, never sent as an unauthenticated request), and Settings MUST show a persistent warning for that origin stating that transcripts and the credential travel unencrypted and that authentication does not encrypt transcript contents in transit. Any non-loopback endpoint, HTTPS included, MUST have a credential before rewriting can be enabled or a request sent. Credential-gated HTTP is never described as secure transport; it exists for explicitly trusted development and private-network setups.
- **FR-017**: Provide an explicit connection test reporting exactly these eight outcomes: Connected, Authentication failed, Server unreachable, Rewrite service unavailable, LLM backend unavailable, Incompatible server/protocol version, Missing credential (local, nothing sent), Unencrypted connection blocked (local, nothing sent). Messages MUST be plain user language; raw internal errors are available only through developer diagnostics.
- **FR-018**: Record content-free local metrics: request duration, network duration where distinguishable, outcome category, request and response byte counts, retry count per dictation, fallback use, and timeout/cancellation counts. Transcript, rewritten text, prompts and credentials MUST NOT appear in logs or metrics.
- **FR-019**: The client MUST NOT load or bundle a language model runtime and MUST NOT depend on any specific inference backend, model or runtime. Changing the server's backend MUST NOT require client dictation changes. Idle client memory MUST NOT materially increase.
- **FR-020**: The rewrite service MUST work when self-hosted on the same Mac or on another trusted machine on the user's network. No third-party hosted AI service is required or contacted.
- **FR-021**: The UI MUST expose: rewriting enabled/disabled, selected mode, rewrite in progress, succeeded, failed with category, retry, cancel, and "use faithful transcript instead". In the live flow, "use faithful transcript instead" is satisfied by the automatic fallback insertion decided in clarification; for history and recovery it is satisfied by the faithful transcript's explicit Insert (and Copy) action in transcription detail. No separate control is added for the wording alone. Rewritten text MUST be labelled as AI-generated, never as faithful transcription. No broader UI redesign is included.
- **FR-022**: Provide deterministic client/server contract tests using test doubles for: successful rewrite, malformed response, wrong schema version, empty response, oversized response, timeout, cancellation, stale response, authentication failure, server unavailable, retry, faithful fallback, deletion, and multiple sequential and concurrent dictations.
- **FR-023**: Provide a small rewrite-quality evaluation corpus covering English, Slovak, mixed Slovak/English, technical language, names, IP addresses, numbers, dates, URLs, email addresses, negation, task ownership and commitments, with an automated check that detects silent mutation of pattern-matchable protected entities and a review record for judgment classes. Model output need not be byte-identical across runs; protected-entity detection and protocol behavior are deterministic.

### Key Entities *(include if feature involves data)*

- **Rewrite settings**: Enabled state, endpoint, default mode, timeout, per-origin insecure transport override, credential reference. The credential itself lives in the system credential store. An immutable snapshot of these (with credential presence, never the value) is captured per admitted attempt.
- **Rewrite attempt**: One admitted request for one dictation: identity, order, mode, input snapshot and hash, state, output, timestamps, duration, protocol version, server identity, failure category, staleness marker. Pre-admission refusals are not attempts.
- **Rewrite state**: not_requested, pending, succeeded, failed, cancelled, timed_out; the transcription's own success is independent of it.
- **Rewrite request/response**: Versioned structured messages; the request carries only the permitted fields; the response is validated before any field is used.
- **Connection test result**: One of eight categories, protocol version, server identity/version, timestamp; content-free.
- **Rewrite quality corpus**: Versioned input texts with language, category, protected-entity annotations and review expectations per mode.
- **Rewrite metric record**: Content-free per-attempt measurements.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With rewriting disabled, all Feature 001 and 002 acceptance and regression suites pass unchanged. Deterministic gate: a guard transport that fails the test on any call proves zero rewrite-transport invocations during dictation, history use and settings use, in Exact mode and for a bypassed dictation. Live evidence (optional, recorded separately): the signed app is observed during the offline walkthrough with a local network observation tool where available; transport-double evidence is never presented as proof that the OS opened zero sockets.
- **SC-002**: In every contract scenario listed in FR-022, the faithful transcript is present and unchanged after the scenario, and no text from an invalid, stale, cancelled or mismatched response is inserted or displayed as current. 100% of scenarios pass deterministically on repeated runs.
- **SC-003**: Across at least 20 sequential and 5 overlapping-in-time dictations with mixed outcomes, zero results are associated with the wrong dictation or attempt.
- **SC-004**: Every attempt reaches a terminal state no later than the configured timeout plus 500 ms of client-side observation and cleanup tolerance (the 500 ms is not permission for the server to exceed the timeout), and never exceeds the maximum response size; cancellation returns control to the user within one second and the attempt is recorded as cancelled.
- **SC-005**: Rewrite quality corpus, exact-match protected entities (IP addresses, URLs, email addresses, filesystem paths, version numbers, explicit numbers, currency values, times, dates and listed technical identifiers): 100% preserved verbatim in every mode, verified automatically. Any mutation is a hard failure.
- **SC-006**: Rewrite quality corpus, reviewed properties (names, negation, task ownership, commitments, language-mix preservation, no summarization): at least 95% of reviewed items pass per mode, with zero accepted negation or ownership inversions. Reviews identify the reviewer and input/output hashes.
- **SC-007**: A user can recover from a failed rewrite—use, copy or retry the faithful transcript—within three interactions and without re-recording.
- **SC-008**: Every attempt is inspectable after restart with its mode, input snapshot, state, output and timing; confirmed deletion leaves zero attempt records for that dictation.
- **SC-009**: Idle client RSS with rewriting enabled remains within the Feature 001 budget and within max(5 MB, 5%) of the rewriting-disabled baseline under the same measured conditions. No model or inference runtime is present in the client process.
- **SC-010**: The connection test distinguishes all eight categories in FR-017 against test doubles (the two local refusals without any transport call), and logs collected during a full acceptance run contain no transcript, rewritten text or credential content.
- **SC-011** (formerly SC-010a): Rewrite latency, measured from faithful transcript saved to rewritten text handed to insertion, on the owner's reference self-hosted setup with a warm dedicated rewrite model, per input-length bucket as defined in [contracts/rewrite-quality.md](contracts/rewrite-quality.md) ("Input-length buckets"):
  - Short bucket, binding acceptance gate: median ≤ 1.5 s. Short bucket, product optimization target: median ≤ 1.0 s. Both are reported; a median of 1.18 s is `acceptance: PASS`, `1.0 s optimization target: NOT ACHIEVED`.
  - Ordinary bucket, binding acceptance gate: p95 ≤ 3.0 s.
  - Long and long-Polished requests are reported separately without a gate.
  The configured timeout (20 s default) is the failure ceiling, never the expected wait. Buckets with fewer than 5 samples are reported as unmeasured. Where the hardware or model cannot reach a gate, the report records a failed gate rather than relaxing it.

## Assumptions

Defaults below are adopted decisions after the clarification session; see the agenda status at the end of this section.

- Rewriting is opt-in: disabled by default until the user configures a server and enables it.
- The default mode after enabling is Clean, the least invasive rewriting mode.
- Decided: a successful rewrite is inserted automatically through the existing safe insertion path when the captured target remains valid, matching current dictation flow; the faithful transcript remains one action away. No confirmation step exists in this feature.
- Decided: on failure, timeout or cancellation, the faithful transcript is inserted automatically if the captured target remains valid, with a visible notice and retry offered; the user is not blocked waiting on explicit action. Cancelling a rewrite cancels only the rewrite, never the dictation.
- Retry attempts appear in history as ordered attempts under one dictation entry; the newest successful attempt is the current rewritten text; earlier attempts remain inspectable.
- Proposed bounds: maximum input 20,000 characters (comfortably above a 180-second dictation), maximum accepted response 4× input length capped at 64 KB, at most 10 admitted attempts per dictation, one in-flight attempt per dictation and at most 2 in-flight attempts overall. Refusals at any of these bounds happen before admission and create no attempt row.
- Decided: timeout default 20 seconds, adjustable 5–60 seconds. This is strictly the failure/timeout ceiling and remains the final fallback boundary regardless of latency optimizations; SC-011 sets the latency gates. Cancellation is available from the dictation indicator and from history for the pending attempt; timeout produces the timed_out state and the same fallback as failure.
- Low perceived latency is a design requirement for planning. The architecture must support streaming server responses and a warm, dedicated rewrite model kept resident on the server. Connection reuse and prompt reuse are permitted. Rewriting partial transcripts before the faithful transcript is complete is not permitted; Feature 003 starts only after the faithful transcript exists.
- Planning must evaluate an "instant faithful insertion + safe background upgrade" interaction: insert the faithful transcript immediately through the existing safe path, run the rewrite asynchronously, and replace only the exact passage originally inserted, only if that passage is still unchanged and the original destination is still valid. If the user has edited the passage or the destination state has changed, the inserted text is never mutated automatically; the rewrite is retained as an available alternative in history. If adopted, this replacement is the single permitted exception to "no target mutation" in FR-013 and must be verified by the same target checks as insertion. Adoption or rejection is a recorded planning decision.
- Normal short dictations are rewritten as one unit; arbitrary chunking is not used. For genuinely long inputs, planning may introduce bounded sentence- or paragraph-based processing only if benchmarks show a latency improvement without meaning change, with the bounds recorded.
- Each attempt stores a full copy of the faithful transcript text it sent plus its hash, so the comparison is possible even if future migrations change how the faithful transcript is stored.
- Decided: authentication is a bearer-style secret entered once in Settings, stored in the system credential store, masked in the UI, and testable through the connection test. It is optional only for same-machine (loopback) endpoints; every other endpoint requires it. Unencrypted non-loopback connections are blocked by default and allowed only through the per-origin insecure transport override with a persistent Settings warning (FR-016a), because trusted LAN and overlay-network links may already be encrypted below the application; the application itself makes no such assumption and never calls credential-gated HTTP secure.
- Decided: hard acceptance gates are SC-001 through SC-005, SC-008, SC-010 and SC-011 (short median ≤ 1.5 s, ordinary p95 ≤ 3.0 s). SC-006 is a reviewed threshold metric whose negation and ownership inversions are zero-tolerance. SC-009 is a measured resource gate. The SC-011 short-bucket ≤ 1.0 s figure is an optimization target reported alongside the gate, not a gate.
- The rewrite service and its protocol are specified separately for the server; this specification constrains only what the client requires from the protocol and what the request may contain.
- Language hints come from existing local recognition settings; no language detection is added.

## Clarification agenda status

Items 3, 4, 7, 9 and 10 were decided in the 2026-09-17 clarification session. Items 1, 2, 5, 6 and 8 keep their proposed defaults as adopted decisions; planning may adjust the numeric bounds in item 6 with recorded rationale but must not change the others without returning to clarification.

1. Opt-in by default — adopted: disabled until configured.
2. Default rewrite mode — adopted: Clean.
3. Auto-insert successful rewrites or require confirmation — decided: auto-insert (see Clarifications).
4. Auto-fallback to faithful text on failure or require explicit action — decided: auto-fallback with notice, including on cancellation (see Clarifications).
5. How retry attempts appear in history — adopted: ordered attempts under one entry.
6. Maximum input/output sizes — adopted: 20,000 characters in; 4× input capped at 64 KB out; planning may tune with rationale.
7. Timeout and cancellation behavior — decided: 20 s default, 5–60 s range, strictly a failure ceiling; cancel from indicator and history; low perceived latency is a design requirement (SC-011), with streaming, a warm dedicated model and the background-upgrade interaction evaluated in planning (background upgrade rejected; see research.md).
8. Exact input snapshot persistence — adopted: full copy plus hash per attempt.
9. Authentication UX — decided: secret in credential store, masked, tested via connection test; required for non-local endpoints; non-loopback plain HTTP blocked unless the per-origin insecure transport override is on, then credential mandatory plus persistent warning (see Clarifications, "Design reconciliation").
10. Hard gates versus review metrics for protected content — decided as proposed (see Clarifications and SC-005/SC-006).

## LocalFlow resource and failure acceptance

The [constitution](../../.specify/memory/constitution.md) and [Feature 001 memory protocol](../../docs/performance/memory-budget.md) remain binding. The client gains no model, runtime or persistent background process. Idle RSS, recording overhead and model release behavior are re-measured with rewriting enabled and compared to the disabled baseline under identical conditions; unmeasured results are not reported as met.

Latency is part of acceptance: measure SC-011 on the reference setup with a warm dedicated rewrite model and report Mac hardware, macOS version, LocalFlow app version/build/commit, flowd version/build/commit, inference backend, model identity/tag, prompt version, shield version, warm/cold state, network topology and dictation lengths. The timeout ceiling is not a latency result. Planning must assign finite capacities and overload behavior to every new element: in-flight request count, per-dictation attempt count, request and response byte limits, response buffering on the client and streamed-output accumulation on the server, metric storage and attempt history. At capacity the client refuses the new attempt before admission with an explanation and preserves existing state; nothing is silently dropped. Server memory (idle, during an ordinary request, settled after repeated requests) is measured separately from the inference backend and compared against the constitution's non-LLM server targets; it is unmeasured until recorded.

Offline behavior: with network disabled or no server running, dictation, history and settings work fully; the rewrite path reports its category and falls back. Permission failures, insertion target loss and storage failures preserve the faithful transcript and every recorded attempt. Interrupted attempts are resolved on restart without inventing results.

User data preservation: no rewrite outcome deletes, replaces or obscures Feature 002 evidence. Save failures never report an attempt as persisted. Credentials never enter preferences, logs, diagnostics or metrics.

Run `make check` for repository validation. Quality corpus review, live-server checks and hardware measurements are separate evidence; skipped or unavailable checks remain explicitly unverified.

## Correction-learning filter (2026-09-17)

The existing local 90-second correction watcher assesses each settled contiguous 1–3-word replacement before dictionary mutation. The assessment is deterministic and exposes autoLearn, suggest or ignore plus content-free reasons. Likely lexical names and technical spellings may auto-learn; English/Slovak function-word edits, ordinary wording/inflection edits, formatting-only changes and protected literals must not. Existing canonical vocabulary increases confidence. Identical borderline lexical observations across separate insertions may increase confidence within bounded session memory.

AutoLearn uses the existing conflict/capacity checks, Added to dictionary notice and Undo. Suggest is internal only in this increment: no write or interruption, with its assessment preserved and candidate digest available for repetition. Ignore writes nothing and shows nothing. No suggestion UI is added to Feature 003. No correction text enters logs, network requests or persistent candidate storage. Settings explains selective learning.

Acceptance: deterministic scorer tables and watcher integration cover the supplied positive/negative examples, repetition/eviction, disabled learning, insertion boundaries, duplicate/conflict/capacity refusal and Undo; the complete Feature 001/002/003 regression suite runs through `make check`.
