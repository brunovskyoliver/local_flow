# Usage reporting and owner dashboard

Research date: 2026-10-23. Status: proposed design for specification and planning, not implemented or deployed.

## Confirmed scope

The owner wants usage associated with approved users, including local processing. Sharing is opt-in per device. The first client is the Mac app. Only account-linked devices report; a local-only installation reports nothing until enrolled and opted in, and enrollment does not upload earlier history. Retention is 90 days. A separate Go service with SQLite serves the owner-only hosted dashboard. Deployment is outside this change.

Use two distinct measurements: client-reported product usage and server-observed operational activity. A dictation processed remotely can appear in both views, but the dashboard must never add those views together. No client analytics SDK is needed.

## Existing implementation

- `server/internal/accounts/store.go` owns approved users, enrolled devices, provider/subject identity and last-seen timestamps in `flowd-remote.sqlite`. User identity must come from the authenticated session, as required by constitution principle 15.
- `server/internal/remote/dictation.go` knows user/device identity and operation outcomes, sample counts and durations. Rewrite, meeting and analysis handlers have corresponding completion boundaries.
- `server/cmd/flowd/admin_api.go` counts requests by parsing log lines. These counters reset on restart and are not durable usage records.
- `apps/macos/LocalFlowServer/Stats.swift` and `LogReader.swift` retain local operational observations for 90 days. `docs/distribution/server-app.md` records that multiple rotations between reads can lose observations. Neither source is suitable for exact product counts.
- ADR 0032 restricts the Server menu bar app to local observation and management, with no listener. Its loopback admin API must remain private. The proposed dashboard is a separate service, not a web view or listener inside a native app.

## Counting contract

For this slice, product usage means completed dictations and successfully processed audio milliseconds. Meeting usage, words, rewrite calls, estimated time saved and detailed failure analytics are not silently included. The UI labels this scope explicitly. Audio duration comes from captured sample frames and sample rate, not wall-clock time while a model is busy. A resumed or retried dictation keeps its logical identifier.

Record one successful dictation when its final text is committed to the client's durable history, regardless of whether automatic insertion succeeds. This measures completed dictation, not successful insertion. A retry of insertion or rewriting does not increment it. A new recording is a new dictation. Empty or failed recognition does not increment successful usage. A remote attempt followed by successful local fallback contributes one local completion. Successful remote ASR with local formatting is remote processing. Freeze this definition in the contract and tests.

The client is the sole source for these product totals, including remote completions, because it observes whether the result was actually committed. The server may separately measure inference attempts and duration without claiming that they are completed product usage. Do not reconstruct product totals from transcripts, logs or history scans.

Add an exactly-once accounting marker to the same client transaction that first commits the final result. The marker must survive history retries. The transaction updates a daily aggregate only when consent was enabled for that operation, the linked account is unchanged, and its consent generation is still active. A revoked/offline device may retain provisional aggregates until reconnect, but the server refuses them once revocation is known. Never delay or fail dictation because reporting storage is unavailable; record a visible completeness gap where possible. A storage failure means counts can be incomplete, not fabricated.

## Consent, identity and local persistence

Store consent as an explicit per-device setting with a policy version and generation. Explain that the server owner can associate daily counts and audio duration with the approved account, including local use. Remote inference consent and usage-sharing consent are independent.

When the user enables sharing, the server issues a random generation identifier bound to the authenticated device. A device needs this acknowledgment before accumulating shareable usage. Subsequent offline completions may accumulate under that generation. Disabling sharing immediately stops collection and clears unsent aggregates. Re-enabling requires a new acknowledged generation; never revive a disabled generation.

Use the existing account ID internally. The reporting service receives a server-scoped opaque user identifier and an approved display label, never OIDC subject claims, provider tokens, device keys or email unless the product explicitly chooses email as the disclosed display label. Keep device attribution as an opaque server-scoped ID. The owner dashboard needs names to distinguish users; pseudonymous IDs alone do not make linked usage anonymous.

Proposed client table: `usage_daily(generation, utc_day, processing_mode, revision, completed_count, audio_ms, incomplete)`. Its primary key is `(generation, utc_day, processing_mode)`. `processing_mode` is the fixed enum `local|remote`. Counts are nonnegative signed 64-bit integers with checked addition; overflow stops accounting and marks incompleteness. Existing history rows get no historical backfill.

## Upload and duplicate handling

Add a versioned usage message to the existing authenticated, application-encrypted LocalFlow channel. Reuse its verified device identity and encryption rather than opening an unauthenticated analytics endpoint. A proposed `usage_snapshot_v1` message carries `generation`, `batch_id`, and at most 32 aggregate rows. Each row contains only `utc_day`, `processing_mode`, `revision`, `completed_count`, `audio_ms` and `incomplete`. The server derives user and device identity; unknown fields are rejected. The maximum decoded message is 16 KiB.

For each key, upsert a cumulative snapshot rather than add deltas. The same revision and identical payload is an idempotent success. An older revision is ignored with the current revision acknowledged. The same revision with different values, or a newer revision that decreases a counter, is a conflict. Validate the entire batch before committing it atomically. The acknowledgment returns accepted/current revisions, allowing the client to clear dirty flags only for revisions actually acknowledged. A completion during an upload leaves the newer row dirty. `batch_id` is diagnostic correlation, not the sole deduplication mechanism.

Use this same revisioned snapshot scheme for flowd-to-dashboard export. Scope keys by server, user, device, generation, day and processing mode. The dashboard recomputes user totals from current device rows; it never adds repeated snapshot deliveries. Collection and export use typed allowlisted structures, not generic attribute dictionaries or forwarded log lines.

## Bounds, offline behavior and retention

These are proposed engineering limits to freeze in the plan, not measured acceptance results:

- Client: 90 UTC days, two modes, at most 180 rows for the active generation; 1 MiB reporting storage budget; one request in flight; upload no more often than every five minutes, with jitter and exponential retry capped at one hour. Updating an aggregate coalesces pending work. No unbounded event queue.
- flowd: at most 100,000 usage rows and 32 MiB of reporting data; dashboard: the same initial limits. Migration, journal and backup disk allowances must be specified separately because payload size is not total SQLite footprint. Expired rows are purged before admission. Capacity refusal returns a typed reporting error and never rejects inference.
- Ingestion: at most 32 rows/16 KiB per batch, one active usage request per device, and a bounded global concurrency limit of four. Rate limiting returns a retry hint. The plan must account for these requests separately from latency-sensitive inference admission.
- UTC dates older than 90 days or later than the receiving server's UTC date plus one day are rejected; future allowance addresses small clock skew, not unrestricted backfill. Clock-related rejection is shown as incomplete reporting. Raw event timestamps are not exported.
- Retention runs at startup, before writes and daily. Every read also excludes expired days, so old data cannot reappear before the next sweep. All replicas and exports use the same cutoff. Backups must expire within the agreed retention period and restore must reapply cutoff and deletion state before serving requests.
- A disconnected client retains only the bounded 90-day aggregates. Expiring unsent rows sets a reporting-gap indicator. A disconnected dashboard does not interrupt dictation, and the UI shows its last successful synchronization time. Do not advertise exact all-time totals.

## Withdrawal, revocation and deletion

Withdrawal stops future collection immediately. Historical deletion is a separate explicit action, available to the account holder for their usage and to the owner for administrative erasure. Explain that an offline deletion has not reached the server yet. Keep one durable pending consent/deletion command per device, send it before any snapshots on reconnect, and retry until acknowledged.

The server invalidates a generation before acknowledging withdrawal or erasure. It rejects snapshots under invalid generations, including delayed requests. Erasure removes matching aggregates locally and schedules deletion on the dashboard. The dashboard needs an acknowledgment before the client can be told all hosted copies are deleted. Server-side revocation immediately refuses uploads; it does not silently imply historical erasure. Administrative erasure remains possible after account/device revocation.

Prevent resurrection without an ever-growing tombstone table: use a server-owned monotonically increasing reporting epoch per device/account alongside generation validity. Dashboard exports carry that epoch. An epoch change invalidates earlier generations and triggers deletion where requested; older epochs are always refused. Persist the current epoch with identity metadata independently of 90-day usage retention. Account removal requires a durable deletion marker until downstream acknowledgment and the maximum accepted snapshot/backup age have elapsed. Specify cleanup bounds and disabled-account behavior in the data model before implementation.

## Dashboard access and transport

The dashboard is a separate Go binary with SQLite and a read-only browser UI. Reuse the existing OIDC verification concepts and provider configuration, but implement a browser authorization-code flow with PKCE, state and nonce validation. Pin the permitted owner's exact `(issuer, subject)` in deployment configuration. An email string or an approved LocalFlow user role is insufficient authorization. Reject all other identities before issuing a session.

Use secure, HttpOnly, SameSite cookies, bounded server-side sessions with idle/absolute expiry, CSRF protection for logout or later mutations, and TLS. No public registration, anonymous dashboards or public sharing links. The ingestion credential is a distinct server credential with write-only reporting scope, not an owner's browser session and not flowd's loopback admin token. Keep credentials in the existing secret-management path. If a third party terminates transport for reporting, assess the identity metadata and use the project's inner-encryption pattern rather than assume TLS termination is private.

A dashboard availability failure only affects reporting. It has no model runtime, inference endpoint, user approval controls or access to transcript storage. Hosting configuration can be delivered locally; opening a host, publishing DNS or deploying remains a separate authorized action.

## Operational telemetry

Start with native Go counters and duration buckets exported from a separate local monitoring interface to an owner-operated collector. Keep the interface private and bounded. A collector may convert/export these signals through OTLP. Do not add a client analytics SDK or send client activity directly to an external analytics vendor. Client usage reporting remains the small authenticated protocol above.

Operational metrics may use fixed labels such as service, result category and worker kind. Avoid user/device/request IDs, names, URLs, prompt text, field context and arbitrary backend strings. Prometheus documents the per-series resource cost of labels and recommends a general-purpose processing system when cardinality grows; per-user reporting therefore belongs in SQLite, not metric labels. [Prometheus instrumentation guidance](https://prometheus.io/docs/practices/instrumentation/)

Collector queues are bounded and can drop records when full or when retry deadlines expire. Persistent queues improve restart recovery but do not provide exact usage accounting. Keep telemetry failure outside the dictation path and show dropped-telemetry counters locally. [OpenTelemetry Collector resilience](https://opentelemetry.io/docs/collector/resiliency/)

Grafana remains an optional operational viewer rather than a dependency of product usage reporting. Its authentication documentation supports external identity providers and recommends an IdP with MFA. The first usage UI remains the separate Go service so it can query its SQLite data without a new datasource plugin. [Grafana authentication](https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/)

## Constitution check and verification

Principles 2 and 6 require explicit capacities and overload policies above. Principle 5 requires optional reporting, disclosed identity linkage, content exclusion and consent; native reporting avoids an external analytics SDK. Principle 7 supports SQLite migrations and transactional accounting. Principles 8 and 14 require the dashboard to remain a small optional service without model ownership or a generic analytics platform. Principle 15 requires verified identity and immediate refusal of revoked devices. ADR 0032 must be supplemented to describe the separate hosted dashboard without widening the existing loopback administration interface. An ADR alone cannot override a mandatory principle.

Required tests include opt-out network silence, no pre-enrollment backfill, local/offline completions, remote-to-local fallback counted once, insertion retries, transaction crash recovery, concurrent revisions, identical/conflicting replay, stale generation/epoch rejection, account switching, revocation during upload, retention at every replica, erasure across delayed exports and backup restoration, row/byte/rate limits, overflow, malformed dates, dashboard owner-only authorization and content-marker exclusion across storage/logs/exports. Run `make check` after implementation. Measure memory, disk and background overhead on target hardware separately; none was measured for this research.

## Work report

Inspected existing account identity, local statistics and remote dictation completion code, the constitution, ADR 0032 and server-app documentation. Checked primary OTel, Prometheus and Grafana documentation. This file proposes contracts and limits; it does not add a dependency, modify runtime code, create hosting, or collect usage. Remaining work is to freeze the spec/data model, resolve the OIDC browser and deletion lifecycle details in planning, implement the client/server/dashboard slices and collect validation evidence.
