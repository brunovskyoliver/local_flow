# Feature 001 data model

Design only. Implementation will add an explicit initial SQLite history migration. Capacity values are defined in [plan.md](plan.md); operations are defined in [client-boundaries.md](contracts/client-boundaries.md).

## Dictation session

An in-memory session owns:

| Field | Type and rule |
|---|---|
| id | UUID; reused as transcription entry ID for idempotent persistence |
| state | idle, preparing, recording, transcribing, persisting, inserting, cancelling, recovery or failed |
| target | Optional captured target, never serialized |
| reservation | Exclusive store admission token for one row and 64 KiB |
| lease | Opaque lifecycle lease ID and generation, never a model reference |
| audio | Owned private spool URL, normalized sample count and byte count |
| startedAt/deadline | Monotonic times; recording limit 180 seconds |
| stopReason | key_release, duration_limit, cancel, overflow, device_loss, permission_revoked, sleep or failure |
| quality | complete, duration_limited or incomplete |
| text | Bounded UTF-8 assembly, at most 64 KiB |

Normal transition: idle -> preparing -> recording -> transcribing -> persisting -> inserting -> idle. A duration limit bypasses automatic inserting and enters recovery after persistence. Unsupported/changed targets likewise enter recovery. Cancellation stops capture, joins work, persists any nonempty produced partial text as incomplete, removes audio and relinquishes ownership; a committed row survives. Release during preparation cancels the pending session. Late callbacks must match both session and generation before changing state.

At the recording limit, quality is duration_limited even if transcription of the retained audio succeeds. Overflow, a failed window or ambiguous stitching yields incomplete quality. Neither may be presented as a complete ordinary dictation. Silence produces a visible no-speech outcome without insertion or an empty recovery row. A persistence error keeps bounded text in memory and blocks new capture until saved or explicitly discarded; Copy alone does not make it durable.

## Captured target

Ephemeral process ID plus process-launch identity, bundle ID, AX element reference, focused-window identity, selected UTF-16 range and bounded comparison context. Capture before LocalFlow changes focus. Secure, inaccessible or unsupported elements are ineligible. Limit retained comparison text to 4 KiB and query bounded ranges; reject an operation requiring an unbounded field snapshot. Bound verification reads by the 64 KiB result limit. Never serialize AX objects or reuse process ID alone after restart.

For explicit Insert/Retry, let the user arm insertion and select a target before capturing a fresh identity. Do not treat the main window itself as the destination. An uncertain previous attempt requires a visible duplicate warning and an explicit user action to try again.

## Transcription entry

SQLite table `transcriptions` replaces the planned `pending_dictations` outbox. No migration or dependency is installed yet; create this schema in the initial migration. If an intermediate development database contains pending_dictations, provide a transactional preserving migration rather than dropping its rows.

| Field | Storage and validation |
|---|---|
| id | TEXT UUID primary key; stable per session |
| text | TEXT, nonempty UTF-8, <=65,536 bytes |
| created_at | INTEGER UTC milliseconds; indexed with id descending for stable paging |
| delivery_state | TEXT enum not_attempted, attempting, confirmed, not_inserted, uncertain |
| recovery_state | TEXT enum needs_review, resolved |
| quality | TEXT enum complete, duration_limited, incomplete |
| stop_reason | TEXT session stop reason, independent of delivery/recovery |
| target_bundle_id | Nullable TEXT <=255 UTF-8 bytes; informational only |
| attempt_id | Nullable TEXT UUID for the latest attempt |
| attempt_started_at | Nullable INTEGER UTC milliseconds |
| revision | Nonnegative INTEGER incremented on updates; rejects stale row actions |

Each nonempty produced result is saved, including partial text produced before failure/cancellation. Empty audio, cancelled preparation or failure without text creates no row. Commit initializes not_attempted/needs_review; only safe ordinary completion may proceed to automatic insertion. Incomplete or duration_limited quality remains unchanged when recovery resolves. Explicit Insert again updates the latest delivery result, not text/timestamp/quality. No audio, target field contents, speaker tables, full attempt history or credentials are stored.

### Capacity and transactions

One store actor serializes writes and reserves one row plus 64 KiB before capture. Current rows plus reservation must be <=10,000 and total UTF-8 payload plus reservation <=33,554,432 bytes. A single-row `history_usage` table tracks count/bytes transactionally with inserts/deletes; migration verifies it against stored rows. Updates to delivery/recovery do not change usage. There is no separate recovery cap. Copy, Dismiss recovery and confirmed insertion cannot release storage capacity.

Commit consumes the in-memory reservation in one transaction, with limits rechecked. Same-ID/same-content save retry returns the existing row without resetting resolved status; conflicting content fails. Startup has no outstanding capture reservation. Use one GRDB DatabaseQueue, explicit migrations, DELETE journal mode, synchronous FULL/fullfsync, mmap off and a 2 MiB advisory page cache. Verify a 128 MiB database page cap; allow 129 MiB separately for rollback journaling. Handle disk errors even after preflight. Never reset a damaged database automatically.

A preserving migration maps old pending to not_attempted/needs_review, attempting to uncertain/needs_review and uncertain to uncertain/needs_review. Preserve IDs/text/timestamps/quality. It cannot reconstruct text previously deleted by an old implementation and must not invent it.

### Delivery and recovery transitions

| Event | Result |
|---|---|
| Durable nonempty result commit | New history row, not_attempted / needs_review |
| Authorized beginAttempt commits | attempting / needs_review; new attempt ID |
| Verified insertion acknowledgment commits | confirmed / resolved; row and quality retained |
| Definitely no mutation | not_inserted / needs_review |
| Ambiguous mutation, interrupted attempt or restart from attempting | uncertain / needs_review |
| Copy | No row/status/quality change |
| Dismiss recovery | recovery_state becomes resolved; delivery and quality unchanged |
| Confirmed Delete | Delete only selected row and update usage in one transaction |
| Time passes | No expiry or eviction |

Uncertain delivery remains recorded after Dismiss recovery, so a later Insert again still warns about duplication. No automatic replay. A failed acknowledgment leaves attempting/uncertain recoverable, even if the external insertion occurred. Delete and Dismiss are disabled during that row's active insertion and the store enforces the same rule. Compare revision/attempt IDs to prevent stale actions from modifying another attempt. Failed delete commits leave the row visible with an error.

### Paging and search

Request 20 rows ordered by created_at DESC, id DESC; use a timestamp/ID cursor, not an offset into a mutable list. Retain at most two pages and one selected row. Previous/next navigation re-fetches discarded pages from SQLite. Hold only two page cursors plus an initial-query watermark; do not accumulate every visited cursor. Mutations invalidate affected pages; new results can reset to newest on explicit user navigation, never force window activation.

Search matches literal case-insensitive NFC text while preserving diacritics. A native SQLite comparison function normalizes one bounded row at a time with <=512 KiB scratch. Query is <=256 Unicode scalars and <=1 KiB; all retained rows are eligible, not just visible pages. One active query and one replaceable pending request, debounced 250 ms, carry a generation ID. Cancel stale work, prioritize pending saves, and ignore stale completions. Full history remains accessible with bounded pages; no FTS or semantic-search schema is needed.

Store UTC dates; compute Today/Yesterday/older headings and localized time in the current calendar/time zone. Regroup on date/time-zone changes without changing stored timestamps. Rows display full wrapped text; UI memory still follows page bounds.

## Unsaved result

At most one <=64 KiB result with session ID, timestamp, quality and stop reason remains in memory after save failure. It is explicitly not durable, disables capture/automatic insertion, and offers Retry save, Copy and explicit Discard unsaved text. Copy preserves this state. Quit requires a loss warning while it exists. Save retry preserves ID and metadata; success produces one history entry. No ephemeral error label may falsely imply saved history.

## Navigation, appearance and setup

One MainActor route is Transcriptions or Settings; setup is a temporary flow in the same window. Window visibility/minimization is independent of app/service lifetime. UserDefaults stores appearance (system/light/dark) and setup completion/version, alongside shortcut preferences. Permission status and model verification are rechecked, never inferred from the setup flag. First-run states are introduction/retention -> model installation -> permissions/shortcut guidance -> readiness-gated test -> complete, with retry states. Accessibility denial permits a Copy-only test. Appearance applies to every surface and follows OS changes only in system mode.

Explicit insertion holds at most one ephemeral operation: reviewing -> selecting target -> awaiting confirmation -> dispatching -> outcome/cancelled. Keep selected entry ID/revision, bounded text and captured target. Changing target invalidates confirmation. No destination list is persisted or fabricated.

## Shortcut preference

Versioned UserDefaults value with binding kind (`fn_globe` or `key_combination`) and enabled state. The default is `fn_globe`, with no required Command/Control modifier. Alternative key combinations include physical key code and modifier mask and require Command or Control for Carbon registration. Reject detected conflicts and retain the previous binding if replacement fails. Permission status is queried from macOS, not persisted as authorization. Held state, Fn-combination cancellation and release-required state are ephemeral. Repeated modifier events do not start another session. Another key during an Fn hold cancels the attempt; a new session requires Fn release followed by a fresh press.

## Model descriptor and provisioning state

One bounded JSON manifest records schema version, model ID, immutable source revision, SDK compatibility, automatic-language capability, license/attribution and a list of relative file paths, byte sizes and SHA-256 digests. Paths cannot be absolute, escape their root or traverse symlinks. Hash every file of each compiled model directory. The selected v3 bundle includes Preprocessor, quantized Encoder, Decoder, JointDecisionv3 and vocabulary assets.

Provisioning state is absent -> staging -> verifying -> installed, or staging/verifying -> failed. Only a fully verified directory becomes installed through atomic promotion on the same volume. Keep the previous installed directory until promotion succeeds; retain no extra historical versions. Startup deletes abandoned staging, not the last verified installation. Models are persistent files, never database BLOBs; no runtime loads during provisioning merely to display settings.

Settings observes actual model ID/version, manifest download bytes, installed bytes/location and verification state separately from runtime state. Unknown sizes are unavailable, not placeholder measurements. Download/import is disabled while the current model is leased.

## Lifecycle state

unloaded -> preparing -> active -> cooling -> releasing -> unloaded. Preparation failure or cancellation joins work then enters releasing; a recoverable failure is shown separately from ownership state. Store a monotonically increasing generation, opaque lease ID, active-operation count (maximum one), and at most one cooldown deadline. New activity invalidates the previous deadline. Releasing owns all remaining references until cleanup and outstanding work finish. SDK cleanup can schedule asynchronous cache clearing; absence of references and settled RSS require separate verification.

Manual Load is a coordinator request allowed only when no session owns the model; on success it enters cooling with a fresh 30-second deadline. Manual Unload releases from idle/cooling only and fails safely if a session won the race. Merely visiting Settings never loads a model.

## Measurement sample

Versioned local record with monotonic timestamp, phase, cycle ID, build/model ID, RSS bytes, queue depth/capacity/high-water mark and durations. Run headers identify hardware, OS and conditions. No transcript, audio, target content, credential or arbitrary exception payload is allowed. Fixed enums and bounded identifiers keep every record <=1 KiB. Overflow increments a loss counter; a report with lost samples cannot claim acceptance. These records use bounded rotating files rather than the recovery database.

## Sotto adaptation boundary

Sotto presentation does not change this contract. LocalFlow owns local history, model state, capture and insertion. Do not adopt upstream server history or connection state as storage/readiness authority. No wire entity or network audio transfer is added to Feature 001. Optional Go text processing remains a separate future specification.

Keep model ready adds one UserDefaults Boolean, `keepModelReady`, default false. It is explicit local user preference, not transcript data or a wire field. No SQLite migration is needed.
