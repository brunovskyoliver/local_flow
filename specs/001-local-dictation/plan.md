# Implementation plan: Local push-to-talk dictation

**Feature / setup BRANCH**: `001-local-dictation` | **Git branch**: `main` | **Date**: 2026-09-16 | **Spec**: [spec.md](spec.md)

**Status**: Phase 0 research and Phase 1 design revised for HTML prototype fidelity. Existing implementation evidence is preserved; remaining work is tracked in tasks.md. Hardware acceptance remains outstanding. The setup script resolves its BRANCH field from feature state; this run does not create or switch Git branches.

## Summary

Build one native menu-bar app for offline Slovak/English dictation, including language switches. The Fn/Globe hold shortcut captures the original target, prepares the model, records up to 180 seconds and transcribes bounded audio windows. Save text before a single safe insertion attempt. Retain every nonempty result in searchable local history, including delivered and partial text. Copy preserves all status; confirmed insertion or Dismiss recovery clears recovery only. Confirmed Delete alone removes history. Release ASR after 30 seconds of inactivity. The separate Go server and shared wire schemas remain unchanged and unused.

Reuse selected native presentation from Sotto at commit `c1d5f0bbaff19a1559621943dff49ba89b4a96a0`, with its MIT notice retained in `third_party/sotto`. Bind the adapted window/theme to the existing AppServices and local protocols. Do not add SottoCore, SottoController, ServerClient, its Swift server or its C++ inference worker to the app target. Recording readiness depends on local permissions, model and storage only. Go text processing remains a later optional feature.

## Technical context

| Item | Decision |
|---|---|
| Language and toolchain | Swift 6 language mode; verified local Swift 6.3.1 / Xcode 26.4.1 |
| Platform and app type | Apple Silicon, macOS 26+; one SwiftUI/AppKit menu-bar desktop app |
| Apple frameworks | AVAudioEngine/AVAudioConverter, CoreML, CoreGraphics modifier-event observation, Carbon for alternative hotkeys, Accessibility |
| UI source | Approved HTML visual reference translated into SwiftUI; retained MIT adaptations, no new runtime dependency |
| Dependencies | Exact FluidAudio 0.15.7 with traits disabled; exact GRDB.swift 7.10.0; provenance in research |
| Model | Parakeet TDT v3 CoreML with the pinned quantized encoder, immutable revision and local manifest; automatic language recognition |
| Storage | SQLite transcription history via one GRDB DatabaseQueue; UserDefaults shortcut/appearance/setup; private ephemeral PCM files |
| Tests | XCTest core/integration tests and signed macOS manual/UI checks; injected clocks and external boundaries |
| Performance | Idle RSS <=150 MB; capture-only overhead <=100 MB; model working set measured independently on M5 |
| Accuracy | Aggregate normalized WER <=15% separately across 10 Slovak, 10 English and 10 mixed fixtures |
| Scope | One session, one runtime lease, maximum 180 seconds; no meetings, server calls, diarization or LLM |

Fn/Globe alone is the confirmed default. Observe modifier transitions through a listen-only CoreGraphics event tap, with Input Monitoring permission checked contextually. Retain Carbon registered hotkeys for user-selected alternatives, not for Fn alone. Both bindings require Input Monitoring for reliable listen-only Escape observation throughout preparation and transcription; Accessibility remains optional for Copy-only dictation. Setup explains macOS Globe/Dictation conflicts and the Do Nothing setting; never change system settings automatically. The confirmed duration, cooldown, recovery policy and acceptance thresholds are requirements. There are no unresolved design clarifications; the probe gates below require execution evidence.

## Constitution check

Pre-research assessment and post-design assessment both pass at the design level. Passing this table does not establish runtime or resource acceptance.

| Principle | Pre-research assessment | Post-design evidence |
|---|---|---|
| 1 Native client | Pass: existing native app | SwiftUI/AppKit, Apple capture and hotkeys; no embedded web/interpreter runtime |
| 2 Memory | Pass: bounded design required | Capacity table below; admission reservations; independent capture/model measurements |
| 3 Lifecycle | Pass: existing ADR applies | Exclusive ModelLifecycleCoordinator factory and lease; cancellation joins before release |
| 4 Local-first | Pass: no server dependency | Local-only model construction; provision/import explicitly; offline acceptance |
| 5 Privacy | Pass: local data ownership | No analytics; content-free logs; no automatic clipboard writes; contextual permissions |
| 6 Streaming | Pass: incremental audio required | Bounded raw staging, normalization, spool and decoder windows; terminal/startup cleanup |
| 7 Persistence | Pass: SQLite/files | One migrated history table with independent delivery/recovery/completeness, transactions, private PCM files; no audio BLOBs |
| 8 Server | Pass: separate Go process | No server change or traffic; no LLM loaded in client or server |
| 9 Recovery | Pass: preserve completed text | Commit before insertion; durable attempt marker; no automatic replay after restart |
| 10 Attribution | Not applicable | No speaker entities or embeddings |
| 11 Structured LLM output | Not applicable | No LLM output or new wire schemas |
| 12 Testability | Pass: injectable boundaries | Fake capture/model/AX/store/clock; race, capacity and failure tests |
| 13 Observability | Pass: local measurements | Bounded phase/RSS/queue metrics and real 20-cycle report |
| 14 Scope/dependencies | Pass: existing ADRs | Exact dependencies, license review gate, no copied VoiceInk source or future modules |

No constitution exception is needed. [ADR 0010](../../docs/adr/0010-sotto-ui-local-speech.md) records Sotto presentation reuse. A probe that requires a helper process, retention beyond the approved text history or another architectural change must stop for an ADR and explicit constitution review.

## Project structure

```text
specs/001-local-dictation/
  spec.md
  plan.md
  research.md
  data-model.md
  quickstart.md
  contracts/client-boundaries.md
  contracts/ui-contract.md
  design/                      Approved HTML prototype and native handoff
apps/macos/LocalFlow/
  App/                         composition root, single-window router, menu commands
  Features/Dictation/           coordinator and non-activating indicator
  Features/Transcriptions/      paged history, search and row actions
  Features/Settings/            settings groups and first-run setup
  UI/                          shared native styles and appearance tokens
  Core/Audio/                  capture, conversion and bounded spool
  Core/Transcription/          local FluidAudio adapter and window assembly
  Core/Models/                 provisioning manifest and lifecycle authority
  Core/Insertion/              target capture and AX delivery
  Core/Storage/                history migration, queries and recovery updates
  Core/Observability/          bounded content-free measurements
apps/macos/LocalFlowTests/      deterministic and adapter integration tests
apps/macos/LocalFlowUITests/    signed-app checks where automation permits
fixtures/                      consent/license metadata and fixture guidance
scripts/                       existing checks plus future benchmark driver
```

The planned directories are added with implementation, not as empty packages. `tasks.md` is produced separately by `$speckit-tasks`. Server and protocol directories remain separate existing components.

## Phase 0 research outcome

[research.md](research.md) resolves dependency selection, model provenance, offline loading, decoder windows, hotkey permissions, insertion and persistence. Probe the exact pinned dependencies before wiring the feature: resolve with traits disabled, retain notices, build against the deployment minimum, provision and hash the selected model files, exercise language-switch seams and test cancellation/release. Verify a safe AX path in TextEdit and a named browser's plain-text field. Failure blocks the affected implementation choice; do not substitute cloud inference, clipboard paste or English-only recognition.

## Phase 1 design

The [data model](data-model.md) defines state, history and recovery ownership. [Client contracts](contracts/client-boundaries.md) define operations and failure semantics. DictationCoordinator serializes session decisions; MainActor owns presentation. File IO, inference and bounded AX work run off MainActor. Only ModelLifecycleCoordinator holds concrete heavy runtime references. An engine lease exposes operations, never the runtime itself.

### Capacity and overload policy

MiB/KiB below are binary units; acceptance RSS uses decimal MB. These are implementation bounds, not measured working-set claims.

| Resource | Bound | At capacity or failure |
|---|---|---|
| Active work | One dictation, one ASR lease, one decode operation; no waiting dictation queue | Reject another start visibly |
| Native capture staging | Preallocate 32 slots, each <=4,096 frames x <=8 channels x Float32, total <=4 MiB; accept negotiated rates <=192 kHz | Split callbacks across available slots and publish atomically; reject invalid format or insufficient capacity without partial copying; never allocate to fit |
| Normalized queue | 32 slots x <=1,600 mono Float32 samples at 16 kHz =204,800 payload bytes | Stop with overflow error; do not silently drop speech |
| Audio spool | One 180-second session, 16 MiB aggregate private PCM cap; normal payload <=11,520,000 bytes | Stop; retain useful partial text as incomplete, prohibit automatic insertion |
| Decoder PCM | Two windows x239,360 samples x4 bytes =1,914,880 bytes; 32,000-sample overlap | Pull serially; never accumulate the session in RAM |
| Text/token assembly | <=64 KiB UTF-8 result and <=16,384 token records; one adjacent overlap under review | Stop, persist valid prefix as incomplete, explain truncation |
| History | <=10,000 rows and <=32 MiB UTF-8 payload; reserve one row and 64 KiB before capture | Block capture and offer confirmed Delete; no eviction; Dismiss recovery does not free storage |
| Browsing | 20 rows/page, two resident pages <=2.5 MiB text plus one selected <=64 KiB entry; cursor navigation | Replace old in-memory pages, never delete stored rows |
| Search | Query <=256 Unicode scalars/1 KiB; 250 ms debounce; one active query plus one replaceable pending; <=512 KiB per-row normalization scratch | Cancel stale queries; persistence has priority; no unbounded result/cache array |
| Waveform | 15 scalar bar values, at most 30 visual updates/second while recording; one snapshot, no audio retained for animation | Coalesce updates; reduced motion stops animation |
| SQLite | 128 MiB database page cap; allow 129 MiB journal reserve; one connection, 2 MiB requested page cache, mmap disabled | Read back limits; errors block capture and retain unsaved result in memory |
| Provisioning | One transfer/import, <=1 MiB IO buffers, <=256 KiB manifest, <=512 files; one installed model and one staging set, each <=4 GiB including compiled artifacts | Reject oversized package, clean staging, preserve old verified model; report insufficient disk |
| App event delivery | One coalesced UI snapshot; bounded 32-event control mailbox with terminal/cancel flags outside queue | Fail session safely if control delivery overflows; never lose stop/cancel |
| Measurements | 256 pending records, <=1 KiB each; two 5 MiB rotating local files | Drop metrics with a loss counter; invalidate incomplete acceptance report |

Raw queue values are a supported-format contract, not a claim about every device callback. Negotiate before capture; split bounded blocks off the realtime callback and stop if a callback exceeds its preallocated slot. No callback creates a task, waits for inference or performs disk IO. Third-party internal buffers must be inventoried and exercised with these fixed input limits; CoreML working sets are measured separately. SQLite cache_size is advisory; it is not an RSS cap. The database and journal receive separate disk checks, with SQLITE_FULL handled despite preflight reservations.

Use one spool in an app-private directory. Hold a single-instance file lock before startup cleanup so another process's active audio cannot be deleted. Clean stale audio before admitting capture, and remove audio after success, cancel or failure. A cleanup failure blocks new capture and remains visible. No automatic audio recovery/history is added.

### Session and model lifecycle

Capture the original target on key-down before presenting UI. Reserve history capacity, validate provisioned assets, obtain permissions and prepare the model. Signal ready only after capture is active. Key-up during preparation cancels; it cannot start delayed recording. Ignore repeated key-down, and require key-up after a forced stop before allowing another hold.

Enforce 180 seconds using a monotonic timer and the 2,880,000-sample normalized ceiling. At the limit, stop visibly, transcribe all captured speech, persist `duration_limit`, and offer review only. Normal key-up may permit one insertion after persistence and target revalidation. Device loss, revocation, sleep or overflow stops capture, marks any salvaged text incomplete and requires review. Empty/silent results create no false successful transcript.

Use lease IDs and lifecycle generations for single-flight preparation and stale-completion rejection. Normal completion starts a 30-second inactivity cooldown after session work finishes; a new request cancels it. Requests during release wait for release before loading, within the single admitted session. Cancellation/error joins active work and releases immediately. A stale timer or cancelled caller cannot release another lease. If an in-flight CoreML call is not interruptible, keep the session cancelling until it returns; do not falsely announce release or admit overlapping work.

### Delivery and durability

Commit text and quality/stop metadata before any insertion. Commit `attempting` before one AX dispatch. A verified result transactionally sets delivery_state to confirmed and recovery_state to resolved; a failed or uncertain result stays recoverable. On restart, `attempting` becomes `uncertain` with recovery set to needs_review, and nothing inserts automatically. A crash between real insertion and acknowledgment can leave an already delivered transcript, so the recovery UI explains possible duplication before explicit retry.

Copy changes the clipboard only on user action and retains the row indefinitely. Dismiss recovery and confirmed insertion clear recovery only, leaving text and completeness unchanged. Confirmed Delete is the only history deletion path. Retry uses a newly captured explicit target and the same security/focus rules; it never trusts persisted bundle metadata. Failed persistence retains the bounded text in memory, disables new sessions and automatic insertion, offers Retry save/Copy and explicit Discard unsaved text and warns about loss on quit. Cancellation after commit never removes recovery text.

### Provisioning, privacy and permissions

Show the selected model's verified download size, disk location, license and offline behavior before explicit Download or Import. Stage, hash and atomically install only manifest-listed assets. No runtime download helpers, update checks or server connections run during dictation. Keep private app data directories at mode 0700 and owned files at 0600. Deletion is logical removal, not a forensic secure-erasure claim. No credentials are needed; any later credentials belong in Keychain.

Use a locally signed hardened-runtime app with microphone usage description and the audio-input entitlement where required. Feature 001 uses the existing unsandboxed development app configuration; distribution/notarization remains outside this slice. Accessibility denial still permits microphone capture and Copy. Input Monitoring denial disables Fn/Globe observation and offers an explicit alternative registered shortcut; Accessibility denial must not disable capture when shortcut access is available. Shortcut replacement failure leaves the previous binding intact. The event tap retains no unrelated key content, passes events unchanged and uses the existing bounded control mailbox. Another key during an Fn hold cancels the attempt without automatic insertion, preserving Fn combinations. Tap disablement, permission revocation or lost release cancels safely and requires a fresh hold after release. Verify these behaviors on supported macOS versions and actual Apple keyboards; firmware-only Fn keys on third-party keyboards may not be observable.

## Validation and acceptance

Follow [quickstart.md](quickstart.md). Add meaningful tests for lifecycle races, cancellation, overflow, disk failures, atomic recovery, focus changes, secure fields, clipboard preservation and duration-limit review. Test 29.999/30-second cooldown boundaries and a new session racing an old timer. Test 179.999/180-second stopping, including key-up at the boundary. Every terminal path must join work and clean audio without deleting committed text.

Run the three ten-fixture accuracy sets offline. Normalize Unicode to NFC, lowercase, remove punctuation, collapse whitespace and preserve Slovak diacritics; compute aggregate edit distance divided by reference words separately per set. Review meaning as well as WER. Include switches within windows and at seams; no manual language hint.

Run the 20-cycle M5 protocol in `docs/performance/memory-budget.md`, a rapid cooldown-reuse sequence and capture-only comparison. Every settled unloaded median must be within max(20 MB, 10% baseline). Investigate slope >0.5 MB/cycle or cycles 16-20 minus 1-5 median >10 MB; no unexplained flag may remain. Idle <=150 MB and capture-only overhead <=100 MB remain mandatory. Report model cost separately, plus phase timing, RSS and queue peaks. Collect zero-network and content-free-log evidence. No measurements have been collected by this plan.

## Complexity tracking

No constitution exceptions. Durable history and final UI styling are now explicitly approved Feature 001 scope. Recovery is a status on a history entry, not a second store. No meeting schema, networking layer, generic plugin system, separate Swift package or additional app process is introduced.

## Approved UI implementation design

[UI contracts](contracts/ui-contract.md) map the [HTML visual reference and native mapping](design/README.md) to native views. One SwiftUI main window hosts Transcriptions and Settings; an app-owned router restores that same window from closed/minimized states. Open LocalFlow preserves the selected destination (Transcriptions initially); Settings… and Command-comma select Settings. Closing the window preserves menu-bar operation; Quit exits after handling unsaved text. No separate Settings scene, transcript recovery window or browser runtime.

Use the HTML handoff: 208-point fixed sidebar, 27-point semibold headings, 14-point navigation and neutral light/dark tokens. The content surface starts 38 points below the window top with 8-point trailing/bottom insets and an 18-point radius. Inner padding is 49 points top, 55 horizontal and 65 bottom, with a 940-point maximum width. Use native traffic lights, SF Symbols and system text. Persist System/Light/Dark. Do not ship the prototype's browser chrome, demo controls, sample records or fabricated destinations.

History is newest-first with stable timestamp/UUID ordering, grouped by the current local calendar date. Search runs over all retained entries, including unloaded pages. Full text wraps without truncation; row actions reveal on hover and keyboard focus, while recovery actions remain discoverable. Keep completeness badges separate from recovery badges. Empty history, no matches, full storage and unsaved results have distinct states. Time-zone/day changes regroup visible results without changing stored timestamps.

The indicator is a 118 x 38-point capsule with 15 contrasting bars near the bottom center of the active target display's visible frame, clear of the Dock. A non-activating AppKit panel hosts SwiftUI content and never becomes key. Short static preparation bars, recording waveform only after readiness and a distinct processing pattern distinguish microphone ownership. Normal operation has no visible text/timer; success dismisses the panel without toast or main-window activation. Reduced motion uses distinct static patterns. VoiceOver announces transitions. A small Cancel icon is available on hover/accessibility focus and Escape cancels while dictating. Limit/error/review states stop the recording pattern and leave persistent menu attention and details in the main window without activating it automatically.

Settings uses the approved General, Speech model and Permissions groups. Reflect actual installation, verification, loading and loaded states separately, with known model identity/sizes/location or an explicit unavailable value. Manual Load/Unload route through the lifecycle actor; busy session ownership disables both, and raced commands are rejected. Successful manual Load starts the normal 30-second inactivity countdown. First-run setup stays within the same window, explains retained text and explicit Delete, guides provisioning/permissions/conflicts, and offers a readiness-gated dictation test. Accessibility denial permits a Copy-only test; missing microphone/model/shortcut prerequisites never report ready.

Explicit Insert/Insert again first reviews text and any incomplete/limit/duplicate warning, then arms one destination-selection operation. The user focuses a real eligible field and confirms in a non-activating confirmation surface; revalidate the chosen target after confirmation immediately before dispatch. Changed targets invalidate the operation rather than silently selecting the newly focused field. Cancel has no delivery effect. Keep at most one insertion operation; serialize it with dictation and row mutation. The prototype's destination dropdown is illustrative only.

## Additional acceptance coverage

| Requirements | Implementation evidence |
|---|---|
| FR-006, FR-012–014 / SC-007, SC-011 | History survives every delivery state; independent completeness; confirmed Delete only; full-store reservations; unsaved Copy/Retry; search beyond first page; bounded pages under 10,000-row load |
| FR-015, FR-017 / SC-008, SC-011 | Single-window restore matrix, setup denial/retry and model state controls; manual load cooldown and busy-unload rejection |
| FR-001, FR-016 / SC-009–010 | Light/Dark HTML prototype comparisons at matching native window dimensions, resize/text settings, VoiceOver, keyboard actions, reduced motion, focus-safe waveform |
| FR-018 / SC-002, SC-007 | Real destination selection and confirmation, target-change invalidation, secure-field rejection, uncertain warning, no automatic clipboard change |

Repeat resource acceptance with history near capacity and while paging/searching. No visual, hardware or resource acceptance is claimed by planning. The task generator must include all five user stories and the approved UI contract.

## Sotto migration sequence

T063 records the upstream snapshot and notices. T064 updates the spec and architecture. T065 adapts the native window/theme to existing local services. T066 completes and verifies the remaining history/settings/indicator behavior, together with the original open tasks. T067 checks offline independence and visual/accessibility behavior. Existing task completion and measured evidence remain valid only for the units they originally cover. Importing Sotto does not complete those open tasks.

### Development launch and window follow-up

Use a development-signed bundle at `/Applications/LocalFlow.app` for interactive
runs; retain unsigned isolated tests. Never bypass TCC or report simulated grants.
Re-arm the shortcut after Input Monitoring changes from denied to allowed while
Settings is visible. Debug-only model discovery uses the pinned checkout download
folder when the persistent verified installation is unavailable, then imports
through the existing provisioner and lifecycle coordinator. No runtime is loaded.
Promote the main window to regular app activation for Dock/overview participation;
closing returns to accessory mode and minimizing preserves Dock presence.
Constitution check: native APIs, existing bounded model import, no new dependency,
no server changes, no privacy or model ownership exception.

## Prototype fidelity implementation revision

The HTML supersedes Sotto visual choices in earlier migration notes. Update Appearance.swift, LocalFlowApp.swift and MainWindowRouter.swift for the two-page shell; HistoryView.swift for bounded date groups and hover/focus actions; SettingsView.swift for compact rows and a shortcut sheet. First-run setup remains reachable from Transcriptions. Retain the existing services, Go boundary, wire schemas, SQLite model, queue/page limits, lifecycle ownership, privacy and recovery paths. No new dependency, persistent runtime or architecture exception is needed. Constitution check: all 14 principles remain satisfied by this presentation-only scope; resource targets remain unmeasured.

Validation: make check, native light/dark captures, comparison to the HTML at equal content dimensions, and signed menu-bar open/reopen with AeroSpace geometry. Existing hardware and live speech acceptance tasks remain independent.

## Compact settings and shortcut recording revision

Replace the shortcut sheet with a temporary active event tap owned by SettingsView. One candidate chord, one run-loop source, one 30-second timeout and one focus-loss observer are permitted; release all resources on completion/cancel/disappearance. A pure recorder state supports deterministic tests. Use keyboard-layout translation for key labels. Replace Carbon's restricted registration with exact-match active session filtering when Accessibility is allowed; retain passive Fn-only fallback. Dispatch press/release/cancel through the existing bounded mailbox. Fail replacement before removing a working binding. No model, storage, server or schema changes. Constitution check: no exception; user-authorized shortcut suppression replaces the old pass-through-only behavior. Tests cover recording/cancel, arbitrary keys, repeat/down/up consumption and unrelated-event pass-through. Run make check and signed UI verification.

## Physical modifier implementation

Persist an optional UInt64 deviceModifiers field alongside the existing generic modifier mask. Read Apple's NX_DEVICE modifier flags from CGEventFlags using the system IOKit headers. Share exact side matching between event handling and the lost-release polling backstop. Capture stores at most eight physical modifier bits and uses the existing bounded recorder. Legacy JSON omits this field and retains either-side matching.

Constitution check: this is a correction inside existing shortcut source boundaries. No architecture exception, dependencies outside Apple frameworks, model, audio, server, wire or database changes. Validate recording, side rejection, both-side transitions, persistence compatibility and malformed masks; run make check. Physical keyboard acceptance remains separate from synthetic events.

## Keep model ready implementation amendment

Use one persisted AppPreferences Boolean and a SettingsViewModel action. ModelLifecycleCoordinator owns an idle retention policy; enabling it cancels the current cooldown and rejects stale deadline callbacks. Disabling it schedules a new cooldown for an idle resident runtime. Explicit unload, cancellation, installation and shutdown still join release. AppServices requests one startup load through loadIfIdle when the saved preference is enabled and assets are verified; modelCommandInProgress excludes shortcut admission during that load. Warm after a successful import as well. Ordinary tests and resource benchmarks do not perform preference-driven startup warming.

Constitution check: opt-in preparation is an explicit persisted user request, not unconditional model allocation. Default loading remains lazy; models remain releasable and exclusively lifecycle-owned. No new queue, dependency, server, schema, audio retention or network activity. Residency increases idle memory when opted in; model RSS remains unmeasured by this change. See ADR 0007's amendment.

Analysis: specification, settings contract, lifecycle ownership and T091–T094 agree on opt-in behavior. Prior resource acceptance remains scoped to memory-saving mode. Convergence is limited to this revision; existing unrelated acceptance tasks stay open.

## Input compatibility correction

SystemTextAccessibilityAdapter uses native Unicode keyboard events targeted to the captured process. Revalidate the original target on the main actor immediately before the first event; each later chunk requires the same focused identity plus confirmed prior text and caret. Chunks contain at most 20 UTF-16 units without splitting surrogate pairs; at most one down/up pair is outstanding. Total text remains capped at 64 KiB and dispatch admission stops after ten seconds. Each acknowledgment polls up to 50 times at 10 ms intervals without redelivery. An unconfirmed chunk stops the operation and preserves uncertain delivery. No Return key or clipboard operation is synthesized.

DictationCoordinator.historyChanged notifies the existing bounded HistoryViewModel worker after refreshHistory completes. No observer queue or polling loop is added.

Constitution check: existing native input, storage and privacy boundaries remain intact; no new dependency, network request, runtime or architecture exception. Validation includes deterministic focus/uncertainty/chunk bounds and live T3 Code input using the production adapter. This does not establish universal application compatibility.
