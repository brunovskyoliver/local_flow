# Storage

SQLite is authoritative for structured client data; GRDB.swift is the Swift wrapper. Use explicit migrations, transactions and foreign keys. WAL is appropriate for concurrent local reads but its sidecars must be included in backup reasoning. Media lives in app-private filesystem directories, never SQLite BLOBs. Credentials live in Keychain.

Feature 001 includes shortcut/appearance/setup preferences and bounded transcription history with independent delivery, recovery and completeness fields. Its schema and paging/search policy are defined in `specs/001-local-dictation/data-model.md`. History retains successful and partial text until confirmed explicit Delete; insertion and Dismiss recovery update status only. Admission reserves capacity before capture; full storage blocks capture without eviction. No database dependency or migration is installed during initialization. Preferences may use UserDefaults; durable recoverable text uses SQLite. Do not log transcript content. Explain text-history retention to users and provide confirmed deletion. Use 20-row pages, at most two resident pages and one selected row; search all retained text without loading the full history.

Future tables may include meetings, meeting_audio, transcript_segments, participants, speaker_profiles, speaker_embeddings, notes, action_items, decisions, summary_artifacts, sync_jobs and model_metadata. This is a vocabulary, not a migration backlog. Embeddings have their own versioned records with model, version, dimension, quality and creation time. Unknown identity is represented explicitly.

Use stable UUIDs, atomic manifest replacement, finalized media fragments and startup inspection for future recordings. Files and SQLite cannot share one transaction: record intermediate states and reconcile incomplete work. Test disk-full and crash boundaries.

Backup uses SQLite's online backup API or another proven consistent snapshot, plus content-addressed media manifests. Never copy an active SQLite main file alone. The client remains authoritative; resumable, idempotent archive transfer is Feature 009. Distributed conflict resolution and true synchronization are Feature 012 only if required.

## Rewrite attempts

Migration `rewrite-v4` adds `rewrite_attempts` and transcription fields for rewrite state and delivered source/attempt. The faithful transcript remains unchanged. Each admitted attempt keeps its input snapshot/hash, ordinal, terminal state, validated output/hash, identity and latency spans. The newest attempt mirrors its state onto the transcription in the same transaction. Current successful output and delivered output are tracked separately.

Admission transactionally checks ten attempts per dictation, one pending attempt per dictation and the shared 33,554,432-byte payload quota. It reserves input bytes plus min(4 × input bytes, 65,536) output bytes. Success adjusts to actual output size; other terminal states release the output reservation. Refusal creates no row and consumes no ordinal. Startup marks pending attempts failed/interrupted and reconciles quota. Confirmed transcription deletion cascades to attempts; delivered-attempt references use `ON DELETE SET NULL`.

Endpoint, mode and timeout preferences live in UserDefaults. Secrets live only in Keychain, keyed by endpoint origin. See [the data model](../../specs/003-server-rewriting/data-model.md) for fields and constraints.
