---

description: "Task list for Feature 012: application context for dictation"
---

# Tasks: application context for dictation

**Input**: Design documents in `specs/012-app-context-awareness/`.
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `quickstart.md` and the three files in `contracts/`. ADR `docs/adr/0023-rewrite-protocol-v2-reference-context.md` already exists.
**Tests**: Required by the plan's validation table and by constitution principle 12. Write each deterministic test before the code it exercises, confirm it fails for the intended reason, then make it pass. Capture latency, live evaluation, rewrite latency and memory evidence are separate acceptance tasks and are never marked done from fakes.
**Organization**: Setup, foundational values/storage/capture, then one phase per user story. Story phases run in the plan's delivery order (US1, US3, US2, US4): Settings consent and history visibility (US3) ship before context leaves the Mac (US2). An evaluation phase gates FR-020, and US4 (P3) starts only after it. All paths are relative to the repository root. New Swift files stay in the existing `LocalFlow` and `LocalFlowTests` targets and are registered with `scripts/register-xcode-sources.py`.

`[P]` marks tasks that touch different files and can run alongside the other `[P]` tasks in the same phase. It never bypasses a phase gate.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story the task belongs to (US1 to US4)
- Every task names the file(s) it changes

## Phase 1: Setup

**Purpose**: Record the starting point and register the files the plan introduces.

- [X] T001 Record the implementation starting commit, dirty-tree state, Go/Xcode/GRDB pins, the reference flowd backend and model, and the constitution scope check in `specs/012-app-context-awareness/acceptance/baseline.md`; state that no capture latency, rewrite latency, quality or memory figure exists yet.
- [X] T002 Register empty placeholders for `apps/macos/LocalFlow/Core/Context/AppContextSnapshot.swift`, `AppContextReader.swift`, `AppCategory.swift`, `ContextTermExtractor.swift`, `ContextSpeller.swift`, `ContextCopyGuard.swift` and `apps/macos/LocalFlowTests/AppContextReaderTests.swift`, `ContextSpellerTests.swift`, `ContextCopyGuardTests.swift`, `AppContextStoreTests.swift`, `DictationContextFlowTests.swift` in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` using `scripts/register-xcode-sources.py`, so `plutil -lint` and the Xcode build stay green.
- [X] T003 [P] Add `build/context-eval/` to `.gitignore` and create `fixtures/context/README.md` describing the corpus item format from `contracts/context-quality.md`, the subset minimums, and the rule that live runner output is never committed.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Snapshot values, redaction, term extraction, preferences, storage and the capture reader that every story needs. With `contextEnabled` false (the default), the app behaves exactly like the pre-feature app.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Snapshot values (delivery step 1)

- [X] T004 [P] Write failing tests in `apps/macos/LocalFlowTests/AppContextReaderTests.swift` for `AppContextSnapshot` per `data-model.md` and `contracts/context-snapshot.md`: `schema_version` is `1`; enum raw values `app_category` ∈ {`email`, `work_chat`, `personal_chat`, `code`, `terminal`, `document`, `other`} and `field_kind` ∈ {`single_line`, `multi_line`, `search`, `code`, `terminal`, `unknown`}; canonical JSON has sorted keys, no whitespace and omits absent parts; `snapshot_hash` is the SHA-256 hex of the canonical bytes; bounds `app_name` "≤ 128 bytes" (cut), `window_title` "≤ 200 characters" (cut at the end), `before_cursor` "≤ 1,000 characters ending at the cursor" (keep the part nearest the cursor, cut at a grapheme boundary), `after_cursor` "≤ 300 characters starting at the selection end" (keep nearest the cursor), `selected_text` "≤ 2,000 characters" (over the bound: omit the part and add `selected_text` to `truncated`); `terms` "≤ 40 entries", each `text` "≤ 64 bytes", `source` ∈ {`window_title`, `before_cursor`, `after_cursor`, `selected_text`}, `kind` ∈ {`name`, `identifier`}; a snapshot over 8,192 bytes drops parts in the order after, before, selected, title until it fits and records each in `truncated`; the bundle ID is never part of the canonical JSON.
- [X] T005 Implement `apps/macos/LocalFlow/Core/Context/AppContextSnapshot.swift`: `AppContextSnapshot`, `ContextTerm`, `FieldKind`, `ContextOutcome` (`used`, `off`, `excluded_app`, `own_app`, `secure_field`, `no_permission`, `nothing_readable`, `timed_out`, `no_target`), `AppContextCapture` (outcome, snapshot?, bundleID?, durationMs), the immutable `ContextSettings` press-time snapshot (`enabled`, `rewriteEnabled`, `styleEnabled`, exclusions, overrides), the bounding functions, the canonical JSON encoder and the CryptoKit SHA-256 hash; make T004 pass.
- [X] T006 [P] Implement `apps/macos/LocalFlow/Core/Context/AppCategory.swift`: the `AppCategory` enum, the built-in bundle-ID map from research D12, the browser bundle-ID list used by the address-bar rule, the default exclusion list from research D11 (`com.apple.Passwords`, `com.apple.keychainaccess`, `com.1password.1password`, `com.agilebits.onepassword7`, `com.bitwarden.desktop`, `com.lastpass.LastPass`, `org.keepassxc.keepassxc`, `com.dashlane.dashlanephonefinal` plus a best-effort macOS banking list), and `category(for:overrides:)`; add tests to `apps/macos/LocalFlowTests/AppContextReaderTests.swift` for the map, override precedence, `other` fallback (browsers included) and that LocalFlow's own bundle ID is always excluded.

### Redaction and terms (FR-006)

- [X] T007 [P] Expose the IPv4, IPv6, URL, e-mail and number/amount token classes in `apps/macos/LocalFlow/Core/Intelligence/ProtectedLiteralDetector.swift` through one internal `protectedClass(of:)` function without changing `violations(in:evidence:excluding:)` behavior, and add a regression test to `apps/macos/LocalFlowTests/ProtectedLiteralDetectorTests.swift` showing the existing fixtures still pass.
- [X] T008 Write failing tests in `apps/macos/LocalFlowTests/AppContextReaderTests.swift` for redaction and term extraction (research D4, D8): email, URL, IP and number/amount spans become `[email]`, `[url]`, `[ip]`, `[number]`; tokenization keeps `_`, `-`, `.` inside identifiers; candidates are 1–3 capitalized-word runs not only sentence-initial (or also capitalized elsewhere), identifiers with internal case change, `_` or letter–digit mix (`fetchUserProfile`, `net_bird`, `k8s`), and words with diacritics outside the common-word list (`Kováčik`); excluded are redaction-pattern matches, `CorrectionStopwords.commonWords` entries and tokens under 3 letters; ordering is nearest to the cursor first, then deduplicated, capped at 40.
- [X] T009 Implement redaction and `ContextTermExtractor` in `apps/macos/LocalFlow/Core/Context/ContextTermExtractor.swift`, reusing `ProtectedLiteralDetector.protectedClass(of:)` and `CorrectionStopwords.commonWords`; make T008 pass.

### Preferences (FR-001, FR-017)

- [X] T010 Add `contextEnabled` (false), `contextRewriteEnabled` (false; "effective only with `contextEnabled` and rewriting on"), `contextStyleEnabled` (false), `contextExcludedBundleIDs` (built-in list from T006; "≤ 200"; own bundle ID always excluded and not removable) and `contextCategoryOverrides` (empty; "≤ 200") to `apps/macos/LocalFlow/Features/Settings/AppPreferences.swift`, plus a `contextSettings()` factory returning `ContextSettings`; extend `apps/macos/LocalFlowTests/AppPreferencesTests.swift` for defaults on a fresh and upgraded profile, the 200-entry caps, own-bundle protection and that a changed value is seen by the next `contextSettings()` call without relaunch.

### Storage (delivery step 2)

- [X] T011 [P] Write failing tests in `apps/macos/LocalFlowTests/AppContextStoreTests.swift` for migration `app-context-v11` per `data-model.md`: `dictation_contexts` with `transcription_id` text PK referencing `transcriptions(id)` ON DELETE CASCADE; `outcome` NOT NULL and one of the capture outcomes; `capture_ms` "NULL or ≥ 0"; `app_bundle_id` "NULL or 1–255 bytes"; `snapshot_json` "NULL or ≤ 8,192 bytes" and NOT NULL when outcome ∈ {`used`, `timed_out`} and a part was read; `snapshot_hash` "NULL or 64 hex; NULL iff `snapshot_json` NULL"; `pre_spelling_text` "NULL or ≤ 65,536 bytes"; `spelling_changes_json` "NULL or ≤ 32,768 bytes; NULL iff `pre_spelling_text` NULL"; `speller_version` "NULL or ≥ 1"; `rewrite_note` "NULL or `server_unsupported`". `rewrite_attempts` rebuilt with `protocol_version IN (1,2)`, `failure_category` admitting the 12 existing codes plus `context_copied`, new `context_hash` "NULL or 64 hex" and the check `(protocol_version = 2) = (context_hash IS NOT NULL)`; existing rows copied unchanged with `context_hash` NULL; unique `(transcription_id, ordinal)` and partial `pending` indexes recreated; `transcriptions.delivered_rewrite_attempt_id` references preserved. Also: the context row commits in the same transaction as the entry; a failing context write fails the whole commit and the existing unsaved-text recovery applies; deleting the entry cascades to zero context rows; a legacy entry has no row and reads as "not recorded"; a store reopen after migration keeps all rows.
- [X] T012 Add migration `app-context-v11` to `apps/macos/LocalFlow/Core/Storage/HistoryMigrations.swift` (new table plus create/copy/drop/rename rebuild of `rewrite_attempts` under GRDB's default deferred foreign-key check), add `DictationContextRecord` and the context row read to `apps/macos/LocalFlow/Core/Storage/TranscriptionEntry.swift`, and extend the entry commit in `apps/macos/LocalFlow/Core/Storage/TranscriptionStore.swift` to write the context row in the same transaction plus a `recordRewriteNote(_:for:)` update; add `context_copied` to `RewriteFailureCategory` persisted codes in `apps/macos/LocalFlow/Core/Rewrite/RewriteProtocol.swift` and `contextHash` to `apps/macos/LocalFlow/Core/Rewrite/RewriteAttempt.swift`; make T011 pass.
- [X] T013 Extend the fake store in `apps/macos/LocalFlowTests/Support/BoundaryFakes.swift` to hold context rows with the same atomic-commit and cascade rules and record every call. *Done as: no shared fake store exists; the context row travels inside `TranscriptionEnvelope`, so tests use the real `TranscriptionStore` (atomic commit, cascade) and the existing faulting stores carry it unchanged. `FakeAppContextReader` records every call.*

### Capture reader (delivery step 3)

- [X] T014 Declare `AppContextReading` (`read(target:settings:deadline:) async -> AppContextCapture`, never throws, returns within deadline + 20 ms) in `apps/macos/LocalFlow/Core/DictationBoundaries.swift`, and add `FakeAppContextReader` to `apps/macos/LocalFlowTests/Support/BoundaryFakes.swift`, scripted per call with a delay, an outcome and a snapshot, counting calls, with a `failOnAnyCall` mode.
- [X] T015 Write failing tests in `apps/macos/LocalFlowTests/AppContextReaderTests.swift` for the snapshot builder behind `SystemAppContextReader`, fed by an injected attribute source (no live AX): the decision order in `contracts/context-snapshot.md` (disabled → `off` with zero attribute reads; untrusted → `no_permission`; nil target → `secure_field` for `AXSecureTextField` subrole else `no_target`; own bundle → `own_app`; excluded bundle → `excluded_app`; no text read before step 6); placeholder equal to field text drops field text; a browser single-line field with an `AXToolbar` parent within 3 levels drops field text and the walk stops at 3; role/subrole mapping to `field_kind` with code/terminal category override; deadline hit mid-read → `timed_out` with the parts read so far; no text and no title → `nothing_readable` keeping app name, category and field kind; ranged before/after reads around `selectedRange`, clamped by the character count.
- [X] T016 Implement `SystemAppContextReader` in `apps/macos/LocalFlow/Core/Context/AppContextReader.swift`: `NSRunningApplication` for app name, `AXUIElementSetMessagingTimeout(…, 0.1)` on element and window, ranged `kAXStringForRangeParameterizedAttribute` reads, the 250 ms deadline checked before each read, redaction, bounding, term extraction and canonical JSON from T005/T009, and content-free `ResourceRecorder` metrics (`context.capture_ms`, `context.outcome`, per-part byte counts, term count); make T015 pass.
- [X] T017 Add the context metric cases (`contextCaptureDuration`, `contextOutcome`, `contextPartBytes`, `contextTermCount`, `contextSpellingChanges`) to `apps/macos/LocalFlow/Core/Observability/ResourceRecorder.swift` and extend `apps/macos/LocalFlowTests/ResourceRecorderTests.swift` to assert the report groups them and carries no string payload.
- [X] T018 Wire capture into `run` in `apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift`: take `ContextSettings` at the press, start a child task calling `AppContextReading.read` right after `captureTarget()` returns, await it only after recognition, cancel it with the dictation, and pass the capture to the entry commit (outcome `off` row when disabled); inject the reader through the coordinator's existing dependency set in `apps/macos/LocalFlow/App/LocalFlowApp.swift`.
- [X] T019 Write tests in `apps/macos/LocalFlowTests/DictationContextFlowTests.swift` with `FakeAppContextReader` delays of 0, 200 and 600 ms: the recording state is reached at the same point regardless of delay (SC-005 ordering); 600 ms yields `timed_out`; a focus change after the press does not alter the snapshot; cancelling the dictation cancels the read; context disabled makes zero reader calls and writes an `off` row; every path that reaches commit writes exactly one context row.

**Checkpoint**: Snapshot, capture, storage and metrics exist with tests. With context off, `make check` passes and the Feature 001/002 suites are unchanged.

---

## Phase 3: User Story 1 - Names on screen are spelled right (Priority: P1) 🎯 MVP

**Goal**: A transcript word that matches a name or term in the snapshot takes its on-screen spelling, offline, with rewriting off.

**Independent Test**: With rewriting off and `contextEnabled` on, dictate names shown in the focused window's title and nearby text; compare output with context off. Deterministically: the `names` corpus subset through `ContextSpeller` on and off.

### Tests for User Story 1

- [X] T020 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/ContextSpellerTests.swift` per research D5: fold key (NFD, strip combining marks, lowercase, remove spaces, `-`, `_`); exact fold match for `Kovacik`→`Kováčik`, `net bird`→`NetBird`, `fetch user profile`→`fetchUserProfile`; near match only for capitalized-name candidates with both keys ≥ 5 characters, same first letter, Levenshtein ≤ 1 up to 7 characters and ≤ 2 above, computed on ≤ 64 bytes; spans of 1–3 words never cross punctuation, digits or protected spans; a word not close to "Peter" is unchanged (Story 1.2); spans containing a `commonWords` entry are unchanged; spans the dictionary pass changed, or matching a dictionary canonical/alias with a different spelling, are unchanged (FR-008); two candidates for one span leave it unchanged; nothing is inserted or reordered; each change records `original` (≤ 256 bytes), `replacement` (≤ 64 bytes), `source_part`, UTF-16 `start`/`length` in the pre-spelling text and `match` ∈ {`exact_fold`, `near_name`}; "At most 64 changes per dictation", then spelling stops and `truncated` includes `spelling`.
- [X] T021 [P] [US1] Create the `names` subset (≥ 30 items, English and Slovak names, products, identifiers) of `fixtures/context/corpus-v1.json` in the format of `contracts/context-quality.md`, and add a deterministic test in `apps/macos/LocalFlowTests/ContextSpellerTests.swift` that runs every `names` item with context on and off and asserts a ≥ 50% drop in missing `expect_spellings` (SC-001, rewrite-off half) and zero changes with context off.

### Implementation for User Story 1

- [X] T022 [US1] Implement `ContextSpeller` version 1 in `apps/macos/LocalFlow/Core/Context/ContextSpeller.swift`; make T020 and T021 pass.
- [X] T023 [US1] Add a `resealed(normalizedText:)` helper to the quality detail in `apps/macos/LocalFlow/Core/Transcription/TranscriptionProvenance.swift` (needed because `addingCompletionReasons` returns early with no reasons) with a unit test in `apps/macos/LocalFlowTests/QualityEvaluationTests.swift`.
- [X] T024 [US1] In `apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift`, apply `ContextSpeller` after `normalizedForDelivery(vocabulary:)` using the awaited snapshot and the session vocabulary, reseal the detail with the spelled text, and store `pre_spelling_text`, `spelling_changes_json` and `speller_version` in the context row (all NULL when nothing changed); record `contextSpellingChanges` as a count only.
- [X] T025 [US1] Extend `apps/macos/LocalFlowTests/DictationContextFlowTests.swift`: with context on, a fake snapshot containing "Kováčik" turns "Kovacik" into "Kováčik" in the committed text with rewriting off and no transport (`FakeRewriteTransport` in `failOnAnyCall` mode); the pre-spelling text and change are stored; with context off the committed text is byte-identical to the Feature 002 path (Story 1.3); rerun `DictationCoordinatorTests` unchanged.
- [X] T026 [US1] Add the spelling-changes part of the history context section to `apps/macos/LocalFlow/Features/Transcriptions/TranscriptionDetailView.swift` and `HistoryViewModel.swift`: each change shows original, replacement and source "on screen", plus a disclosure showing the text before context spelling (Story 1.4); add a view-model test to `apps/macos/LocalFlowTests/HistoryViewModelTests.swift`.

**Checkpoint**: Context spelling works offline with rewriting off; context-off output is unchanged. Do not ship to users until US3's consent UI is in (capture must be opt-in with disclosure, FR-001).

---

## Phase 4: User Story 3 - I control and can see what is read (Priority: P1)

**Goal**: Opt-in with disclosure, exclusions, and the exact snapshot and outcome per dictation in History.

**Independent Test**: Toggle the setting, add an excluded app, dictate into it and into an allowed app, and inspect both history entries.

### Tests for User Story 3

- [X] T027 [P] [US3] Write failing tests in `apps/macos/LocalFlowTests/AppPreferencesTests.swift` and a new section of `apps/macos/LocalFlowTests/DictationContextFlowTests.swift`: fresh install and upgrade capture nothing until enabled (Story 3.1); an excluded bundle yields outcome `excluded_app` with no text (Story 3.2); a secure field yields `secure_field` (Story 3.3); turning context off applies to the next dictation (FR-017).
- [X] T028 [P] [US3] Write a privacy test in `apps/macos/LocalFlowTests/DictationContextFlowTests.swift` that runs a capture and a spelling pass with sentinel strings in every snapshot part and the bundle ID, and asserts the sentinels never appear in the captured `Logger` sink or `ResourceRecorder` output (FR-016).
- [X] T029 [P] [US3] Extend `apps/macos/LocalFlowTests/AppContextStoreTests.swift` with deletion: deleting a dictation removes its context row and snapshot (Story 3.5).

### Implementation for User Story 3

- [X] T030 [US3] Add the context section to `apps/macos/LocalFlow/Features/Settings/SettingsView.swift` and `SettingsViewModel.swift`: the **Use app context** toggle with disclosure text stating what is read (app, field kind, window title, nearby text, selected text), what is never read (screenshots, clipboard, address bar, placeholder text, other windows, secure fields, excluded apps, LocalFlow) and where it goes (only the user's rewrite server, and only with the second toggle); the exclusion editor listing running apps plus manual bundle-ID entry, with LocalFlow shown as fixed.
- [X] T031 [US3] Complete the history context section in `apps/macos/LocalFlow/Features/Transcriptions/TranscriptionDetailView.swift` and `HistoryViewModel.swift`: outcome labels ("Context: off", "Context: excluded app", "context unavailable: permission", "nothing readable", "timed out", "secure field", "not recorded" for legacy rows), and the stored snapshot shown as sent with a source label per part and its terms; extend `apps/macos/LocalFlowTests/HistoryViewModelTests.swift` so every outcome maps to a label (SC-007, Story 3.4).

**Checkpoint**: US1 plus US3 is the shippable MVP: opt-in, visible, excluded where required, deletable.

---

## Phase 5: User Story 2 - The rewrite fits where I'm typing without changing what I said (Priority: P1)

**Goal**: With both toggles and rewriting on, the rewrite gets the snapshot as reference through protocol v2; copied or injected output is rejected and the faithful transcript is inserted.

**Independent Test**: Run the corpus through flowd with v1 (context off) and v2 (context on) and compare the SC-001 to SC-004 metrics, including the adversarial subset.

### Protocol (delivery step 6)

- [X] T032 [P] [US2] Add `protocol/schemas/rewrite-context.schema.json` (closed field set and bounds from `data-model.md`), change `protocol/schemas/rewrite-request.schema.json` to `oneOf` v1 | v2 (v2 = v1 fields plus required `context`), add `context_prompt_version` (present only for v2) to the result in `protocol/schemas/rewrite-event.schema.json`, and document the v2 body in `protocol/openapi.yaml` and `protocol/README.md`.
- [X] T033 [P] [US2] Write failing Go tests in `server/internal/rewrite/protocol_test.go`: v2 with valid `context` decodes; v2 without `context`, v1 with `context`, unknown context fields, wrong context `schema_version`, context over 8,192 bytes, over 40 terms or a term over 64 bytes, and out-of-range enums are `invalid_request`; health reports `protocol_versions: [1, 2]`.
- [X] T034 [US2] Implement v2 decoding in `server/internal/rewrite/protocol.go` and bounds checking plus rendering of the reference block in new `server/internal/rewrite/context.go` (JSON inside `<screen_context>` … `</screen_context>` with every `<` in values escaped); change the rewrite default in `server/internal/rewrite/handler.go` to `[1, 2]` and give the rewrite handler its own versions in `server/cmd/flowd/main.go` (today `c.versions` is shared with the analysis handler, which must keep its current list); make T033 pass.
- [X] T035 [P] [US2] Write failing Go tests in `server/internal/rewrite/prompts/prompts_test.go` and `server/internal/rewrite/handler_test.go`: the system message is mode template + context rules block (context prompt version 1) + delimited context; a value containing `</screen_context>` cannot close the tag; the dictation stays the user message and the shield still applies to it; the result carries `context_prompt_version` only for v2; the log line adds only `context_bytes` and contains no context text; v1 requests produce exactly the Feature 003 prompt.
- [X] T036 [US2] Add the versioned context rules block (normative meaning in `contracts/rewrite-protocol-v2.md`) to `server/internal/rewrite/prompts/prompts.go` and wire it plus `context_prompt_version` into `server/internal/rewrite/handler.go`; make T035 pass.

### Client (delivery step 6)

- [X] T037 [P] [US2] Write failing tests in `apps/macos/LocalFlowTests/RewriteProtocolTests.swift`: a v2 request encodes the v1 fields plus `context` equal to the stored canonical bytes (hash match); a v1 request never has `context`; a v2 result missing `context_prompt_version` is `malformed_response`; `context_copied` is a persisted category with the notice "Rewrite used on-screen text you did not say; inserted your transcript."
- [X] T038 [P] [US2] Write failing tests in `apps/macos/LocalFlowTests/ContextCopyGuardTests.swift` per research D9: reject a result with ≥ 4 consecutive word tokens (NFC, casefolded, punctuation-stripped) present in a context part and absent as a run from the faithful transcript; accept 3-word runs; accept runs the speaker said; reject a candidate term or bracketed redaction token absent from the transcript and not produced by context spelling; accept a context-spelled name; include 3-, 4- and 5-word injection fixtures and a 64 KiB result within bounded work.
- [X] T039 [US2] Implement `ContextCopyGuard` version 1 in `apps/macos/LocalFlow/Core/Context/ContextCopyGuard.swift` (hash set of context 4-grams); make T038 pass.
- [X] T040 [US2] Implement v2 encoding, `context_prompt_version` validation and the `context_copied` notice in `apps/macos/LocalFlow/Core/Rewrite/RewriteProtocol.swift`; make T037 pass.
- [X] T041 [US2] Add the one-entry protocol-version cache keyed by endpoint origin to `apps/macos/LocalFlow/Core/Rewrite/RewriteClient.swift` (fetched from health once per origin per app run, replaced when the origin changes, discarded after any 400 to a v2 request), with tests in `apps/macos/LocalFlowTests/RewriteClientTests.swift` for each rule.
- [X] T042 [US2] Write failing tests in `apps/macos/LocalFlowTests/RewriteCoordinatorTests.swift` with `FakeRewriteTransport`: v2 is sent only when `contextEnabled`, `contextRewriteEnabled`, rewriting on, a stored snapshot with outcome `used` or `timed_out`, and health lists 2; otherwise v1 with zero `context`; health without 2 sends v1 and writes `rewrite_note = server_unsupported` (Story 2.4); a copied result becomes `failed(context_copied)`, is persisted with `context_hash`, and the faithful transcript is inserted (Story 2.5); a history retry sends the stored snapshot byte-identical with zero reader calls (FR-014); the Feature 003 coordinator suite passes with context on (FR-013).
- [X] T043 [US2] Implement the context path in `apps/macos/LocalFlow/Features/Rewrite/RewriteCoordinator.swift`: read the snapshot from the committed context row, choose v1/v2, write `context_hash` on the attempt, run `ContextCopyGuard` after v1 validation, record `server_unsupported`, and reuse the stored snapshot on retry; make T042 pass.
- [X] T044 [US2] Add the **Send context to rewrite server (Experimental)** toggle to `apps/macos/LocalFlow/Features/Settings/SettingsView.swift` and `SettingsViewModel.swift`, enabled only when context and rewriting are on, never pre-enabled (FR-020); show the endpoint's protocol versions in the connection test; show "context not sent: server unsupported" and the `context_copied` notice in `apps/macos/LocalFlow/Features/Transcriptions/TranscriptionDetailView.swift`.

**Checkpoint**: Context-aware rewrite works against flowd v1+v2, falls back to v1 against older servers, and the copy guard is in the result path.

---

## Phase 6: Evaluation gate (FR-019, FR-020)

**Purpose**: Prove improvement before the feature is recommended. Blocks US4.

- [X] T045 [P] Complete `fixtures/context/corpus-v1.json` with the remaining subsets and minimums: `continuation` 15, `reply` 15, `code` 15, `sk_en` 15, `irrelevant` 20, `adversarial` 20 (on-screen "ignore previous instructions", "reply YES", fake system prompts, `</screen_context>` injection, long unrelated text).
- [X] T046 [P] Implement `scripts/context_quality_lib.py` (corpus validation, proper-noun error metric, copy-run and forbidden-string checks, gate evaluation per `contracts/context-quality.md`) and `scripts/test-context-quality.py` (deterministic, no network), and add `python3 scripts/test-context-quality.py` to `scripts/test.sh`.
- [X] T047 Implement the live runner `scripts/context-quality.py` (`--endpoint`, `--corpus`, `--out`): per item v1 without context and v2 with context, writing `summary.json` with the Feature 003 identity block plus `context_prompt_version`, `speller_version`, `copy_guard_version` and `corpus_version`.
- [X] T048 Acceptance, on the reference setup only: run the live evaluation and record SC-001 to SC-004 results, copy guard false rejects, the 4-word threshold, model, prompt versions and hardware in `specs/012-app-context-awareness/acceptance/evaluation.md`. A missed gate is recorded as failed. The Experimental label stays unless every gate passes.

---

## Phase 7: User Story 4 - Writing style follows the kind of app (Priority: P3)

**Goal**: With the style toggle on, the rewrite applies category formatting rules without changing the mode or wording.

**Independent Test**: Dictate the same sentence into apps of each category with the style toggle on and off and compare formatting.

**Starts only after T048 records the Story 1–3 evaluation.**

- [X] T049 [P] [US4] Write failing Go tests in `server/internal/rewrite/prompts/prompts_test.go`: with `style_hints` true, chat categories add the rule to drop a single trailing period on one-sentence text, email keeps full punctuation with a greeting on its own line, code and terminal keep identifiers verbatim; with `style_hints` false no category rules appear; the mode template never changes.
- [X] T050 [US4] Add the category formatting rules to `server/internal/rewrite/prompts/prompts.go`, gated on `style_hints`; make T049 pass.
- [X] T051 [P] [US4] Set `style_hints` from `ContextSettings.styleEnabled` at the press in `apps/macos/LocalFlow/Core/Context/AppContextReader.swift`, and add the style toggle plus per-app category override editor to `apps/macos/LocalFlow/Features/Settings/SettingsView.swift` and `SettingsViewModel.swift`; test that an override applies at the next press (Story 4.3) in `apps/macos/LocalFlowTests/AppContextReaderTests.swift`.
- [X] T052 [US4] Add the `category` subset (≥ 15 items) to `fixtures/context/corpus-v1.json`, extend `scripts/context_quality_lib.py` and `scripts/test-context-quality.py` to score it separately, and record the live result in `specs/012-app-context-awareness/acceptance/evaluation.md`.

---

## Phase 8: Polish and acceptance

- [X] T053 [P] Link ADR 0023 from `specs/003-server-rewriting/spec.md` FR-004 as superseded under Feature 012 rules, and confirm `docs/adr/README.md` lists it.
- [ ] T054 [P] Record capture p95 per listed app (Mail, Slack, Safari/Chrome text area, Notes, a code editor, Terminal; ≥ 20 samples each) from `context.capture_ms` in `specs/012-app-context-awareness/acceptance/capture-latency.md` (SC-005). Unmeasured apps are written as "unmeasured".
- [ ] T055 [P] Rerun the Feature 003 latency protocol with context on and record SC-006 verdicts in `specs/012-app-context-awareness/acceptance/rewrite-latency.md`.
- [ ] T056 [P] Rerun the Feature 001 memory protocol with context on and record idle and recording RSS in `specs/012-app-context-awareness/acceptance/memory.md`.
- [ ] T057 [P] Record the privacy walkthrough (quickstart steps 2 and 4: default off, exclusion, secure field, revoked permission) in `specs/012-app-context-awareness/acceptance/privacy.md`.
- [ ] T058 Run `make check` and walk `specs/012-app-context-awareness/quickstart.md` end to end; record results in `specs/012-app-context-awareness/acceptance/baseline.md`.

---

## Dependencies and execution order

### Phase dependencies

- **Setup (Phase 1)**: none.
- **Foundational (Phase 2)**: after Setup. Blocks every story.
- **US1 (Phase 3)**: after Foundational.
- **US3 (Phase 4)**: after Foundational. T026 and T031 both edit the history detail view; do T026 first.
- **US2 (Phase 5)**: after Foundational. Needs the context row from T012 and the Settings section from T030 (T044 adds to it). Independent of US1 except that the copy guard's "produced by context spelling" rule reads US1's change records when present.
- **Evaluation (Phase 6)**: T045–T047 after US2; T048 needs a running flowd v1+v2.
- **US4 (Phase 7)**: after T048.
- **Polish (Phase 8)**: after the stories being shipped.

### Within each story

Tests first and failing, then values, then services, then coordinator wiring, then UI.

### Parallel opportunities

- Phase 1: T003 alongside T001/T002.
- Phase 2: T004, T006, T007, T011 in parallel; T014 once T005 lands.
- US1: T020 and T021 in parallel.
- US3: T027, T028, T029 in parallel.
- US2: server track (T032–T036) and client track (T037–T041) in parallel; T042–T044 after both.
- Phase 6: T045 and T046 in parallel.
- Phase 8: T053–T057 in parallel.

## Parallel example: User Story 2

```text
Task: "T033 Go v2 decode tests in server/internal/rewrite/protocol_test.go"
Task: "T037 Swift v2 protocol tests in apps/macos/LocalFlowTests/RewriteProtocolTests.swift"
Task: "T038 Copy guard tests in apps/macos/LocalFlowTests/ContextCopyGuardTests.swift"
Task: "T032 Schemas in protocol/schemas/"
```

## Implementation strategy

### MVP

1. Phases 1 and 2.
2. Phase 3 (US1): local spelling, offline.
3. Phase 4 (US3): consent, exclusions, history. Reading other apps' text needs this before any user sees it, so the shippable MVP is US1 + US3.
4. Stop and validate with quickstart steps 1–4.

### Incremental delivery

1. MVP (US1 + US3).
2. US2 behind the Experimental toggle.
3. Evaluation phase; the Experimental label is removed only if every gate passes.
4. US4 after the evaluation.

## Notes

- Hardware, latency, memory and live quality tasks (T048, T052's live half, T054–T057) are never marked done from fakes or `make check`.
- Speech recognition, meetings and `ModelLifecycleCoordinator` are untouched.
- No snapshot text, title, term or bundle ID in logs or metrics, on either side.
