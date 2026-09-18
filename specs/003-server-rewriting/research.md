# Research decisions

Research date: 2026-09-17. Evidence comes from the checked-in client (`DictationCoordinator`, `TextInsertionService`, `CapturedTarget`, `TranscriptionStore`, `CorrectionLearner`), the server scaffold, the Feature 001/002 artifacts and the tools present on the owner's machine (`/opt/homebrew/bin/llama-server`, Go 1.23.4). No rewrite latency, quality or memory figure below is a measurement.

## Rewrite runs between save and insertion, not in the background

**Decision:** Reject the "instant faithful insertion + safe background upgrade" interaction for this feature. The dictation flow becomes: faithful transcript committed → `rewriting` state with cancel → rewritten text inserted through the existing `insertOnce` path, or the faithful transcript inserted on failure, timeout or cancellation. This is a recorded planning decision per the specification's assumptions.

**Rationale:**

- The only insertion primitive is `TextInsertionService.insertOnce`: validate the captured target, type the text into the target process with `CGEvent` unicode events, confirm by AX read-back. There is no range-replacement primitive. Replacing an already inserted passage would need a new mutation, setting `kAXSelectedTextRange` over the passage and retyping. Selection writes are unsupported or unreliable in many web views and Electron editors, which are the owner's common targets, and a wrong selection followed by typing destroys user text. That is exactly the "arbitrary target mutation" FR-013 forbids, and the specification only permits it under the same checks as insertion, which cannot be met without the new primitive.
- Passage identity cannot be verified against the target's state, only against the AX string in the original range. The user can keep typing after the faithful text arrives; a later replacement moves the caret to the end of the rewritten text and splits their typing. Undo stacks in the target then contain two LocalFlow edits.
- `CorrectionLearner` already watches the inserted passage for up to 90 seconds to learn one in-place correction. A background replacement would be observed as a user correction and could create dictionary entries from model output.
- Visible text changing one to three seconds after it appears is the interaction the owner's latency target is meant to avoid, not a substitute for it. SC-011 gates the short bucket at a median of 1.5 s with a 1.0 s optimization target, so the user waits roughly as long as the target-app's own confirmation read-back today.

**Revisit path (kept open by design):** the seam stays in the architecture so the decision can be reversed without restructuring. `RewriteDeliveryPolicy` has one shipped case, `waitThenInsert`; `insertThenReplace` is declared, unimplemented and rejected at startup. `DictationCoordinator` already exposes `insertionConfirmed(text, target)`, which a replacement policy would consume. Reopening requires, in order:

1. A latency report under [contracts/client-rewrite.md](contracts/client-rewrite.md) showing ordinary-input p95 above 3 seconds on the reference setup after server-side tuning (warm model, backend streaming, prompt cache).
2. A spike, outside the release path, that measures AX range replacement (`kAXSelectedTextRange` write plus read-back) per target application in the acceptance set, recording success, focus loss and caret position after replacement; results filed under `acceptance/background-replacement-spike.md`.
3. A design for coexistence with `CorrectionLearner` (suspend observation until replacement settles or is abandoned).
4. A clarification round and an ADR (`docs/adr/0014-no-background-text-replacement.md` gets superseded, not edited).

Until all four exist, `insertThenReplace` is not selectable.

**Alternatives considered:** background upgrade as above; confirmation step (rejected in clarification); inserting partial streamed text progressively (each chunk is a separate mutation with its own read-back and cannot be withdrawn on a failed validation).

## Latency is a measured first-class target

**Decision:** Every attempt records five monotonic timestamps: faithful transcript committed, request sent, first response byte, terminal event, text handed to insertion. Derived spans are persisted per attempt (`first_byte_ms`, `network_ms`, `duration_ms`) and the server reports `queue_ms`, `backend_first_token_ms` and `backend_ms` in `result.timing`. The in-app resource report and the corpus runner both bucket by input length (one definition in [contracts/rewrite-quality.md](contracts/rewrite-quality.md), "Input-length buckets") and report median and p95 per bucket; buckets with fewer than 5 samples print "unmeasured". SC-011 is a release gate with its own acceptance file, not a note: short median ≤ 1.5 s and ordinary p95 ≤ 3.0 s are binding; short median ≤ 1.0 s is the optimization target, reported as achieved or not achieved and never a failure. Budget the optimization target as: transport and framing ≤ 50 ms, server queue ≤ 20 ms, backend first token ≤ 300 ms, generation the remainder; a bucket that misses its gate names the span that consumed it.

**Rationale:** A one-second figure is only meaningful if the split is visible, and a gate is only a gate with a number. Per-span timestamps make a miss attributable (model, network, server, client) instead of arguable. The specification says unmeasured latency is reported as unmeasured; the bucket threshold enforces that mechanically.

**Alternatives considered:** end-to-end only (cannot tell a slow model from a slow client); server-side timing only (misses client parse and insertion handoff).

## Transport and protocol: HTTP/1.1, JSON, one NDJSON response stream

**Decision:** The client speaks the LocalFlow rewrite protocol v1 over HTTP/1.1 with JSON bodies. `POST /v1/rewrite` answers with `application/x-ndjson`: optional content-free `accepted` and `progress` events, optional `delta` events only when the client asks for them, and exactly one terminal `result` or `error` event. `GET /v1/rewrite/health` serves the connection test. The contract is [contracts/rewrite-protocol.md](contracts/rewrite-protocol.md).

**Rationale:** Streaming is required by the specification as an architectural capability. Delivering it as a single response stream with a terminal event keeps one code path for streaming and non-streaming servers, lets the client abort early on `error`, and keeps the insertable artifact a single validated `result` event that the client checks for schema version, request identifier, mode, text type and size before any use. Foundation's `URLSession.bytes(for:)` reads the stream line by line with a bounded buffer, and byte counting enforces the response cap before JSON parsing, as `protocol/README.md` already requires. Client v1 never requests `delta` events; it has no safe use for partial text. A future client may request them without a protocol version change.

**Backend streaming is mandatory inside the server.** The adapter always requests a streamed completion from the backend, records time to first token, applies a separate first-token timeout (default 5 s) so a stalled model fails fast, forwards content-free `progress` events as tokens arrive, and assembles the full text before validation and the `result` event. Assembly is bounded while streaming: the adapter checks `accumulated + fragment ≤ min(4 × input_bytes, 65,536)` before appending each fragment and, on overflow, cancels the backend request immediately, discards the partial text and answers `output_too_large` (constitution principles 2 and 6; the invariant is normative in [contracts/rewrite-protocol.md](contracts/rewrite-protocol.md)). Backend error bodies and single SSE lines are read to fixed caps as well. Insertion on the client still waits for the validated `result`; streaming buys early failure detection, live progress on the indicator and the `backend_first_token_ms` measurement, not partial insertion.

**Alternatives considered:** WebSocket (no benefit for one request/response, more connection state); Server-Sent Events (fine, but NDJSON is simpler to bound and parse by line); gRPC (a dependency on both sides for no gain); plain JSON only (loses early failure detection and blocks the streaming requirement).

## Reference backend: an OpenAI-compatible chat completion endpoint behind the Go server

**Decision:** `flowd` gains the rewrite service with one backend adapter that talks to any OpenAI-compatible `/v1/chat/completions` endpoint. The owner selected the already installed MTPLX host on 2026-09-17, starting with `mtplx-qwen35-9b-optimized-speed`. This supersedes the original `llama-server` reference. MTPLX remains a separate inference process; its [documented server API](https://github.com/youssofal/MTPLX/blob/main/README.md#the-server) includes streaming `/v1/chat/completions` and `/v1/models`. The actual port, served model id, constrained-output support and live adapter compatibility remain to be checked in Phase 10. Prompts per mode are versioned templates embedded in the server; the model is asked for the rewritten text only, constrained by a JSON schema or grammar where the backend supports it, and the server re-validates and re-wraps the result into the protocol so the client never parses model output. Backend selection, model and timeouts are server configuration.

**Rationale:** Constitution principle 8 puts inference behind a server adapter and forbids weights in `flowd`. The OpenAI-compatible surface is served by llama.cpp, Ollama, LM Studio, vLLM and `mlx_lm.server`, so one adapter covers the realistic self-hosted options without client changes (FR-019). A warm dedicated model and connection reuse are the two known levers for the 1.0 s optimization target; both live server-side. The specification says the server is specified separately; this plan includes only the thin reference implementation the client needs to be tested and measured end to end, and leaves configuration files, launchd packaging, backup and further endpoints to a server specification.

**Identity for reproducibility.** Every `result` and `health` payload carries `server.name`, `server.version`, `backend.kind` (`openai-compatible`), `backend.model` (the backend's reported model id, ≤ 128 bytes), `prompt_version` (the per-mode template version) and `shield_version`. The client persists all of them on the attempt; the corpus runner writes them into every result and summary. A quality or latency figure without these fields is not comparable and is reported as such.

## Deterministic protected-entity shielding: adopted server-side for pattern classes

**Decision:** Before the prompt is built, the server replaces every match of a versioned detector set (IP addresses, URLs, email addresses, filesystem paths, version strings, currency amounts, explicit numbers, dates and times) with an opaque placeholder token (`⟦E7⟧`), instructs the model to keep placeholders verbatim, and restores the originals after generation. Restoration succeeds only if every placeholder appears exactly once and no unknown placeholder appears; otherwise the attempt fails with `server_validation_failed` and the client inserts the faithful transcript. Names, negation, ownership and commitments are not shielded. The detector set is `shield_version: 1`, its regexes are committed with fixed test cases, and it can be turned off per server (`--shield=off`) for comparison runs. The client-side protected-entity checker in the corpus still runs on the restored output; shielding is a mechanism, the checker is the gate.

**Rationale:** SC-005 demands 100% verbatim preservation and small local models reorder digits, "fix" IP octets and reformat dates. Placeholders make preservation independent of the model for the classes a regex can find deterministically. Names are excluded because Slovak inflects them ("Petrovi", "s Petrom"); a placeholder would freeze the wrong case and the reviewer catches name changes anyway. Placing shielding in the server keeps the client free of language rules (FR-019) and lets the detector set evolve with the server.

**Risks and evaluation:** false-positive matches (a version-looking product name) shield harmless text, which is safe. A model that drops or duplicates placeholders fails the attempt rather than corrupting it; the corpus run reports the shield failure rate per mode so a model that cannot handle placeholders is visible. Placeholder glyphs must survive the backend's tokenizer; the adapter test asserts round-trip through the fake backend and the corpus run through the real one.

**Alternatives considered:** client-side shielding (duplicates detectors in Swift and Go, forces the client to know classes); grammar-constrained decoding only (cannot express "keep these spans"); no shielding, checker only (the checker rejects, it does not prevent).

## Concurrency cap behavior is immediate refusal

**Decision:** When a new dictation completes while two attempts are already in flight (from older dictations), the new dictation does not wait: the cap is a pre-admission refusal (`concurrency_limit`), no attempt row is created and no ordinal is consumed, the faithful transcript is inserted at once, and the notice says "Two rewrites are still running. Original text inserted." with Retry. Retry from history under the cap is refused identically: same reason, same notice text (without "Original text inserted."), no row. In-flight attempts are never cancelled to make room. The indicator shows how many are running only in the notice text.

**Admission rule (applies to every local refusal, reconciled after analysis):** a `rewrite_attempts` row exists only for an attempt that passed all local checks — enabled, not Exact, not bypassed, settings sendable, input within bounds, fewer than ten admitted attempts, nothing in flight for the dictation, global cap not reached, storage quota available. Pre-admission refusals show a notice, emit a content-free counter, send nothing and persist nothing; the ten-attempt limit therefore counts admitted attempts, not button presses. Everything after admission (network, server, timeout, validation, cancellation, restart) is recorded on the row. The sequence is normative in [data-model.md](data-model.md), "Admission". An earlier draft persisted cap hits from the live flow but not from history; that asymmetry is withdrawn.

**Rationale:** FR-007 forbids queues and automatic retries. Waiting would delay insertion by an unbounded amount tied to other dictations' timeouts. Cancelling older attempts would discard work the user may be waiting for in history. Refusal is deterministic and testable (SC-003 overlapping runs). Persisting refusals would make the attempt list describe things that never ran and let local conditions exhaust the per-dictation limit.

**Alternatives considered:** bounded queue of one (still a queue, and hides the timing); cancel the oldest (loses results); raise the cap (server concurrency is the real limit); persist refusals as failed attempts (rejected above).

**Alternatives considered for the backend:** Direct client calls to Ollama or llama.cpp (rejected by principle 8 and FR-019; also exposes backend-specific formats to the client); a Python sidecar (prohibited runtime); no server work in this feature (nothing to measure against SC-011, and the owner cannot use the feature).

## Chunking: none for normal input; long-input splitting is not adopted

**Decision:** Every attempt sends the complete faithful transcript as one unit. Sentence- or paragraph-bounded processing for long inputs is not adopted. It stays a benchmark-gated option recorded here, with bounds to be fixed only if a measured run on the reference setup shows lower end-to-end latency without a reviewed meaning change on the corpus's long items.

**Rationale:** The faithful transcript is at most 65,536 bytes (store limit) and in practice under 180 seconds of speech. Splitting adds ordering, partial-failure and cross-sentence context problems that the modes' "never summarize, keep every commitment" rules make risky. No benchmark exists yet.

## Storage: attempts in a new table, cascading with the dictation

**Decision:** Add migration `rewrite-v4` with a `rewrite_attempts` table keyed by the transcription's UUID with `ON DELETE CASCADE`, a per-dictation ordinal, and a denormalized `rewrite_state` column on `transcriptions` defaulting to `not_requested`. Attempt bytes count toward the existing history payload quota; admission is checked in the same transaction that inserts the pending row. Startup marks any `pending` attempt `failed` with category `interrupted`. Details are in [data-model.md](data-model.md).

**Rationale:** The Feature 002 detail record set the pattern: same database, explicit migration, cascade delete, no BLOBs, quota counted once. A denormalized state makes the history list free of joins and gives legacy rows "not requested" without backfill (FR-015, US5.5). The existing `attempting → uncertain` startup fix-up in `TranscriptionStore.init` is the model for `pending → interrupted`.

**Alternatives considered:** Storing attempts as JSON inside `transcription_quality` (couples rewrite artifacts to transcription evidence and breaks "unchanged and independently inspectable"); a separate SQLite file (two quotas, two journals, breaks the single-owner rule from 002).

## Settings and credentials: UserDefaults plus Keychain

**Decision:** Endpoint URL, enabled flag, default mode and timeout live in `AppPreferences` (UserDefaults). The bearer secret lives in the login Keychain as a generic password item (service `org.localflow.LocalFlow.rewrite`, account = normalized endpoint origin) behind a `RewriteCredentialStoring` protocol with an in-memory fake for tests. The UI masks the secret and offers reveal, replace and remove. Enabling rewriting for a non-loopback endpoint requires a stored credential; loopback (`localhost`, `127.0.0.0/8`, `::1`) does not.

**Off-loopback plain HTTP is an explicit insecure override (adopted into the specification, FR-016a).** HTTPS is the preferred default. Loopback `http://` (`localhost`, `127.0.0.0/8`, `[::1]`) is allowed as is. A non-loopback `http://` origin is refused by default: the enable toggle stays off, the connection test reports `insecureEndpointBlocked` without sending anything, and no request is made. The user must turn on "Allow unencrypted connection to this server (insecure)" for that exact origin; the override is stored per origin in UserDefaults, is never consulted for another origin (so it cannot become a global "allow HTTP" switch), resets when the origin changes, and turning it off makes the endpoint ineligible immediately. With the override on, the credential is mandatory on top of it, and the persistent warning stays visible: transcripts and the credential travel unencrypted, and authentication does not encrypt them. Credential-gated HTTP is not secure transport; the override exists for explicitly trusted development and private-network setups.

**Runtime wiring.** `AppServices` always constructs the `RewriteCoordinator`, its transport and its credential store. Enabled state is not a construction-time decision: every admission reads an immutable `RewriteSettings` snapshot (enabled, mode, origin, timeout, override, credential presence), so Settings changes reach the next dictation without relaunch and never change an admitted attempt. The nil dependency remains a test-only configuration for the Feature 001/002 regression suites.

**Rationale:** Constitution principle 5 puts credentials in Keychain. The app is not sandboxed and has no Keychain entitlement today; generic password items in the login keychain need none. Loopback detection by host literal is deterministic and needs no DNS. The clarification allowed plain HTTP "with a visible warning"; the reconciliation pass after analysis made the deliberate per-origin choice the specification's rule, so a mistyped `http` cannot silently send transcripts and bearer secrets in clear while trusted overlay links remain one checkbox away.

**Alternatives considered:** Storing the secret in UserDefaults (prohibited); requiring TLS everywhere (rejected in clarification); credential-gated only (a credential does not make the link private); mTLS (deferred; the protocol allows adding it without client dictation changes).

## App Transport Security

**Decision:** Add `NSAppTransportSecurity` with `NSAllowsArbitraryLoads = true` to `Info.plist`, with the reason recorded in the plist comment and the plan: the user configures exactly one self-hosted endpoint, plain HTTP over trusted links is explicitly allowed by the specification, and the client enforces its own policy (credential required off-loopback, persistent warning). `NSAllowsLocalNetworking` alone does not reliably cover overlay-network addresses such as NetBird's, which the owner uses.

**Alternatives considered:** `NSAllowsLocalNetworking` only (verified in T073's connection-test walkthrough against the owner's overlay address; if it covers it, narrow to it and record the result in `acceptance/connection-test.md`); per-domain exceptions (impossible for user-chosen numeric hosts).

## Network client bounds and connection reuse

**Decision:** One lazily created `URLSession` with an ephemeral configuration (no cache, no cookies, no credential storage), `waitsForConnectivity = false`, per-request timeout equal to the configured rewrite timeout, HTTP keep-alive on. The session is kept alive while rewriting is enabled and invalidated when disabled. At most two requests in flight overall, one per dictation. The connection test uses the same session with a fixed 10-second timeout.

**Rationale:** Connection reuse is one of the permitted latency levers. Ephemeral configuration keeps transcript bytes out of on-disk caches. An idle `URLSession` costs little; SC-009 is measured, not assumed.

## Bypass gesture: hold Shift while releasing the push-to-talk shortcut

**Decision:** Releasing the dictation shortcut with Shift held marks the session "local only": no rewrite request, state `not_requested`, the faithful transcript is inserted as today. The gesture is unavailable when Shift is part of the configured shortcut; Settings says so next to the rewriting controls. From history, a `Rewrite` action requests rewriting for any complete dictation later (US6.2).

**Rationale:** `ShortcutController` already reads modifier flags at press and release, so the gesture costs no new event tap or permission. A click target on the indicator would need the mouse mid-dictation; a second global shortcut adds configuration and conflicts.

**Alternatives considered:** Indicator button; second shortcut; a "skip next" toggle in the menu (one extra interaction before every sensitive dictation).

## Failure notice and cancel from the indicator

**Decision:** Generalize the indicator's existing notice (`IndicatorPanel.showNotice`, used for "Added to dictionary … Undo") to an action notice: "Rewrite failed: <category>. Original text inserted." with `Retry`, or "Rewriting…" with `Cancel` during the `rewriting` state. Escape cancels the pending rewrite, not the dictation, once the faithful transcript is saved. History detail offers cancel, retry with a mode picker, copy, and explicit insertion of either text through `ExplicitInsertionCoordinator`.

**Rationale:** FR-021 needs exactly these states; the panel and coordinator callbacks exist; SC-007 (recover within three interactions) is met by the notice's Retry or by opening history.

## Language hints

**Decision:** The request's `language_hints` array is present in the protocol and empty in client v1. The pinned Parakeet descriptor uses automatic language with no hint, so there is no local setting to forward. No detection is added.

## Quality corpus and protected-entity checking

**Decision:** A versioned corpus at `fixtures/rewrite/corpus-v1.json` with English, Slovak, mixed and technical items, each annotating protected entities by class, semantic facts (negation, ownership, deadline, commitment, quantity) and expected review properties per mode. `scripts/rewrite-quality.py` runs the corpus against a configured server (development only, opt-in) and writes per-item results with input/output hashes; `scripts/test-rewrite-quality.py` deterministically tests the protected-entity checker and the semantic mutation detectors against fixed inputs and outputs without a server. Review records live under `specs/003-server-rewriting/acceptance/`. See [contracts/rewrite-quality.md](contracts/rewrite-quality.md).

**Semantic mutation detectors** are deterministic heuristics over annotated facts: negation-marker parity per language around an annotated span, owner-and-action co-occurrence within one sentence, day/month-name set equality, quantity value equality after numeral normalization, and commitment count. They are advisory flags that pre-fill the review, except quantity and day/month checks, which are hard because their classes are already verbatim-protected. Each detector ships with mutation fixtures (negation dropped, owner swapped, day shifted, number changed, commitment dropped, language translated) that must be flagged, and with clean rewrites that must not be.

**Rationale:** SC-005 must be automatic and deterministic; SC-006 is human review with hashes. Detectors cannot judge meaning in general, but the specific inversions the specification treats as zero-tolerance (negation, ownership) have cheap signals that catch the common case and focus the reviewer. Separating checker tests from live runs keeps `make check` offline.

## Dependencies

**Decision:** No new client or server dependency. Foundation (`URLSession`, `JSONDecoder`), CryptoKit (SHA-256, already used for content hashes), Security (`SecItem`), and Go's standard library (`net/http`, `encoding/json`) cover the work. No license review is needed. The reference model's license is recorded by the owner in `docs/licenses/` when chosen; the client is model-agnostic.
