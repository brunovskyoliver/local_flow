# Feature 001 client boundary contracts

These are Swift behavioral contracts for implementation, not existing public APIs. No server endpoint or shared wire schema changes. All async completions carry session/lease identity; stale callbacks have no effect. Resource limits are in [plan.md](../plan.md), record definitions in [data-model.md](../data-model.md).

## Shortcut controller

Install/update/remove one hold binding. Fn/Globe uses an active head-insert session tap when Accessibility is allowed, with a passive Input Monitoring fallback for Copy-only use. Standard key combinations and modifier-only holds use the active filter; no Carbon registration or preset key list is required. Match modifiers exactly, consume the matched down/repeat/up, and pass unrelated events unchanged. Failed replacement retains the existing tap and preference. Accessibility is required for priority interception. Priority is best effort against downstream handling, not a claim to override macOS reservations, Secure Input or earlier interception.

Inline recording owns one temporary tap, one candidate chord, one 30-second timeout and one focus observer. While the app is active, this tap consumes recording input so neither dictation nor app commands fire. The main shortcut callback bypasses recognition during recording, even if its tap was reinstalled after the recorder. Release all captured keys to save; Escape, timeout, focus loss, another click and navigation cancel. Cleanup precedes installation. Never retain or log unrelated key content.

Keep repeated-press suppression, physical-release rearming, sleep/tap-loss cancellation and lost-release polling. Escape remains observed during preparation/transcription and cancels the session without suppressing unrelated Escape handling. Callbacks must not block and feed the existing bounded control mailbox.

## AudioCaptureService

`permissionStatus`, contextual `requestPermission`, `start(session, sink)`, `stop(session)` and `cancel(session)` are injectable operations. Start returns ready only after the device, format, fixed staging and normalized sink are active. A consumer receives bounded mono Float32 blocks at 16 kHz with monotonically increasing sample offsets.

The realtime callback only copies into preallocated storage and updates bounded state. Conversion and spooling use a single consumer. Full queue, unsupported format, oversize callback, revocation and device loss produce typed terminal errors. No speech is silently dropped. Stop drains accepted blocks; cancel joins callbacks before freeing buffers. Duration enforcement clips to the last permitted sample. Storage failure stops capture and prohibits a normal success result. Stop/cancel are idempotent.

## ModelProvisioner

Show manifest provenance, total download size and location, then accept explicit Download or Import. One bounded transfer stages only allowlisted files. Verify sizes/hashes and licenses before atomic promotion; no traversal or symlink escape. Interrupted staging is cleaned at restart. Offline missing/corrupt model errors explain how to provision; they never invoke network fallback.

`verifiedLocalDescriptor` provides local paths and immutable identity. It does not instantiate runtime objects. Runtime creation belongs exclusively to ModelLifecycleCoordinator.

## ModelLifecycleCoordinator and TranscriptionEngine

`acquire(session) -> lease`, `transcribe(lease, boundedWindow)`, `finish(lease)`, `cancelAndJoin(lease)` and `releaseIfIdle(generation)` expose no concrete engine. Single-flight load creates at most one runtime. Duplicate starts are rejected by the coordinator; a request racing release waits within the one admitted session, without an unbounded waiter list.

Construct the pinned FluidAudio/CoreML runtime from verified local model URLs. Use v3 assets and automatic language recognition (`language: nil`); do not select an English-only streaming path. Transcribe serial 239,360-sample windows with 32,000-sample overlap and fresh decoder state. Pad a nonempty tail below 4,800 samples and clamp output timestamps to actual audio. Results contain bounded text and timestamped tokens. Merge by time and overlap evidence, preserving repeated words; uncertain seams yield incomplete text.

On normal finish, schedule one 30-second inactivity deadline. New acquisition invalidates it. A cooldown callback must match generation and no active lease. Cancel/error stops further windows, joins the in-flight call, invokes cleanup and drops models/buffers. Never admit another heavy runtime until release is complete. An uninterruptible call remains cancelling until it returns. SDK asynchronous cache cleanup is included in release validation; calling cleanup is not evidence of settled RSS.

Manual `loadIfIdle` and `unloadIfIdle` commands use the same lifecycle authority. Check ownership atomically, reject busy operations and disable UI controls accordingly. Manual Load enters the ordinary 30-second cooldown after preparation. Settings reads state without creating a runtime.

## TextInsertionService

`captureTarget` runs before app UI changes focus. `evaluate(target)` returns eligible or a typed reason such as secure, stale process, focus changed, unsupported or Accessibility denied. Validate the same process launch, AX element, focus and selection again immediately before dispatch. Do not activate a different app implicitly.

`insertOnce(attemptID, target, text)` performs at most one target-bound selected-text mutation if the target exposes a tested writable capability. No clipboard writes, synthetic global typing or whole-field read/modify/write fallback. Query bounded ranges for verification. Return:

- `confirmed`: expected inserted range and resulting selection are verified on the same target.
- `notInserted(reason)`: no mutation was dispatched or the adapter can establish no mutation occurred.
- `uncertain(reason)`: a mutation may have occurred but cannot be verified.

An AX return code alone is not confirmation. Focus can change between AX calls; avoid global dispatch entirely and treat uncertain target state conservatively. Required TextEdit and named browser plain-text support must pass real probes. If this capability path cannot meet SC-002, stop and revise the design before claiming Feature 001 support.

Explicit Insert/Insert again follows review -> select real field -> non-activating confirmation -> same-target revalidation -> one dispatch. Capture occurs when the user selects the external field, not when clicking a fabricated destination name. Target changes invalidate confirmation. Only one explicit insertion may be pending; serialize it with dictation.

`copy(text)` is a separate explicit user action. It writes the clipboard but does not acknowledge delivery. Explicit retry captures a fresh user-selected target after a duplicate warning for uncertain rows. No automatic retry across process restart.

## TranscriptionStore

`reserve(maxBytes)`, `commit(admission,result)`, `page(query,cursor,direction)`, `get(id)`, `beginAttempt`, `recordOutcome`, `dismissRecovery`, `deleteConfirmed(id,revision)` and `releaseReservation` are serialized. Save precedes insertion; beginAttempt commits before dispatch. All nonempty results become history, including successful and partial results. Capacity includes reservations and uses the [data-model limits](../data-model.md).

Confirmed insertion updates delivery/recovery; it never deletes text. Dismiss recovery changes only recovery_state; Copy changes neither. Quality survives both. Only user-confirmed Delete removes the selected saved row and frees capacity. Delete cancellation changes nothing. Startup changes attempting to uncertain/needs_review. No age expiry, automatic pruning, or separate recovery quota.

Pages contain <=20 full-text rows with timestamp/ID keyset cursors; the UI retains <=40 rows and one selected row. Search covers all retained text with literal case-insensitive NFC matching and preserved diacritics. Bound query size and scratch, cancel superseded searches, ignore stale generations, and prioritize saves. Date grouping is presentation-only. Storage errors retain old data, block capture and expose the bounded unsaved result with Retry save/Copy/explicit Discard. A failed attempt-marker commit prohibits delivery; a failed delete does not hide the row as deleted.

## DictationCoordinator and UI

Serialize one session through preparing, recording, transcribing, persisting and optional inserting. Present clear readiness and an accessible Cancel action. Failure to obtain microphone access prevents capture; denial of Accessibility permits dictation and Copy. Cancel joins work and cleans audio, preserving any nonempty produced partial text as incomplete history; cancel after a durable result never deletes it.

Normal key release before the limit permits automatic insertion only for complete text and a safe target. At exactly 180 seconds, duration-limit handling wins over a simultaneous key release. Stop visibly, persist duration_limited quality and offer review, Copy, explicit Insert and Dismiss. Any incomplete result follows the same review-only policy. Silence shows no-speech; errors cannot appear as complete text.

Recovery UI shows saved results without automatically focusing or inserting into old targets. Copy retains them. Explicit Insert lets the user choose a fresh target. Full history storage blocks preparation/capture before resources are acquired and offers review/confirmed deletion. Persistence failure keeps text visible, offers save retry/Copy and warns before explicit discard or quit.

## Native presentation

Follow [ui-contract.md](ui-contract.md) for the single-window router, history actions, model controls, first-run setup, appearance and non-activating waveform. Dictation completion/failure updates data and attention state without opening or selecting a window. Normal indicator states have no visible labels, timer or success toast; status and Cancel remain accessible. Escape must cancel while the target retains focus.

## ResourceRecorder

Record fixed fields for phase timing, queue occupancy, RSS and model identity to bounded local files. Never pass content or arbitrary error descriptions into logs. Metrics overload may drop records only with a loss counter; control/audio paths never wait for logging. Acceptance export identifies missing samples and cannot mark an incomplete run passed.

## Contract validation

Use fake clocks, runtime factories, audio sources, target adapters and stores. Cover stale generations, cancelled preparation, key-up races, queue limits, model-load failure, uninterruptible cancellation, duration-limit review, malformed manifests, full history storage, disk-full during save/attempt/acknowledgment, crash around insertion and Copy retention. Integration tests establish dependency compatibility; signed-app tests establish native permissions and target support. See [quickstart.md](../quickstart.md) for execution and acceptance evidence.

## Sotto adaptation boundary

Sotto presentation does not change this contract. LocalFlow owns local history, model state, capture and insertion. Do not adopt upstream server history or connection state as storage/readiness authority. No wire entity or network audio transfer is added to Feature 001. Optional Go text processing remains a separate future specification.

### Native text delivery

The system TextAccessibilityAdapter retains Accessibility validation/readback but uses process-targeted Unicode input for mutation. AXDispatchResult continues to express whether any mutation may have occurred; it does not promise which native input API was used. Never redispatch when readback is pending or uncertain. Text, selection and focus confirmation must precede a subsequent chunk.
