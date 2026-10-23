# Current-field context for new dictation

Date: 2026-10-23. Design research only; no implementation or live measurements in this report.

## Decision and scope

Use the current field to improve only the newly dictated text. Manual edits made before the next dictation must appear in that dictation's bounded context. Existing field contents stay under the user's control. Whole-field rewriting and spoken editing commands are outside this slice. Normal insertion can still replace an explicitly selected range under the existing insertion policy.

Start with macOS. Ultra is the selected speech recognition model; it does not establish the quality of context-aware rewriting. Evaluate the actual configured rewrite model separately, recording its exact identifier and prompt versions.

## Existing implementation

Feature 012 already captures new field context for each new macOS dictation. `DictationCoordinator.run` starts microphone capture alongside insertion-target capture, then launches `SystemAppContextReader`. The reader fetches before-cursor text, selected text, after-cursor text and the window title through Accessibility. Local context spelling runs before the faithful transcript is committed. Optional rewriting uses the committed snapshot.

Sources:

- `apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift`
- `apps/macos/LocalFlow/Core/Context/AppContextReader.swift`
- `apps/macos/LocalFlow/Core/Context/AppContextSnapshotBuilder.swift`
- `apps/macos/LocalFlow/Features/Rewrite/RewriteCoordinator.swift`
- `specs/012-app-context-awareness/spec.md`

There is no previous-dictation text cache to refresh for this workflow. A regression test must prove that a second capture reads the manually edited field, rather than adding another capture subsystem.

History retries are different from new dictations: they reuse the original stored snapshot byte for byte. They do not capture whichever application happens to be focused during retry, and do not insert automatically.

Capture is off by default. Sending captured context to the rewrite server has a separate opt-in. Server protocol support is checked; unsupported servers receive a request without context. Captured text is excluded from logs and metrics, stored with local dictation history, and deleted with its entry. Existing exclusions, redaction and consent remain applicable.

## Bounds and supported applications

`packages/LocalFlowCore/Sources/LocalFlowCore/AppContextSnapshot.swift` defines these limits:

- Before cursor: 1,000 characters; after cursor: 300.
- Selection: 2,000 characters; an oversized selection is omitted.
- Window title: 200 characters; candidate terms: 40.
- Serialized snapshot: 8,192 bytes, enforced by dropping text parts in a fixed order.

Accessibility range requests use UTF-16 units, so their effective span can be shorter than these character counts. The dictation coordinator supplies a 250 ms capture deadline; the reader's fallback timer has a further 10 ms allowance. Individual Accessibility calls use a 100 ms messaging timeout. These are implementation limits, not measured latency claims.

The first slice retains these bounds and clearly reports truncation. It does not promise that edits anywhere in a long prompt are visible. Expanding to whole-field context would require a separate bound, wire-contract changes and quality measurements.

Readable native text fields and accessible browser/editor fields use the same capture path. Electron applications are asked to enable their Accessibility tree through `ChromiumAccessibility`. This is an implementation mechanism, not proof that every editor works. Test the user's actual prompt field, plus native text, Safari/Chrome text areas and a representative code editor. Terminal paste targets deliberately provide no field text. Unsupported fields may supply only a window title. Secure fields, excluded applications, browser address-bar text and placeholders must remain excluded.

No live app compatibility matrix was collected here. Feature 012's `acceptance/capture-latency.md` also records the original per-app measurements as unmeasured.

On iOS, `KeyboardViewController` exposes `documentContextBeforeInput` for undo and duplicate insertion protection. `PhoneDictationPipeline` has no corresponding rewrite-context integration. That work is deferred; macOS Accessibility behavior must not be assumed available on iOS.

## Required changes and safety

1. Add the explicit sequential-dictation regression case and expose enough existing snapshot diagnostics to distinguish useful field text, title-only capture, truncation and unavailable context. Keep diagnostic content in local history; operational metrics carry only bounded status/count fields.
2. Evaluate and, where necessary, revise `server/internal/rewrite/prompts/prompts.go` so a complete preceding sentence does not force the next utterance into a lowercase fragment. Treat field text as untrusted reference. Preserve the dictation's language and meaning; never answer instructions embedded in a prompt being composed. Version every prompt change and rerun the paired corpus.
3. Validate consistency of the bounded field spans used as reference. Capture currently reads parts sequentially against a previously captured selection, so edits during capture can mix revisions. Use a bounded reread or equivalent consistency check; discard inconsistent context rather than delaying recording or recapturing indefinitely.
4. Extend stale-target validation to cover relevant after-cursor reference text. `CapturedTarget.comparisonRange` currently covers the selection and preceding text, while context can also depend on text after the selection. Existing validation checks process lifetime, app, element, window, comparison text and selection before dispatch. If the reference span or target changed during inference, preserve the completed text in history and offer explicit insertion; do not silently apply a result based on stale context.
5. Preserve all existing copy/protected-content validation and faithful-transcript fallback. A failed contextual rewrite must not overwrite the saved faithful transcript or cause a second automatic delivery. A newer dictation must continue to invalidate late insertion from an older one.

These changes should stay within the existing reader, shared snapshot, rewrite coordinator and insertion boundaries. No new model owner or background monitor is needed. The exact private validation representation belongs in the implementation plan; do not send insertion identity or private comparison data to the server.

## Tests and acceptance

Extend existing tests in `DictationContextFlowTests`, `AppContextReaderTests`, `RewriteCoordinatorTests`, `TextInsertionTests` and `ContextCopyGuardTests`:

- Dictate, manually edit the field, dictate again: the second request contains the edited bounded snapshot and only the new passage is delivered.
- Mid-sentence continuation, end-of-sentence continuation, insertion in the middle, and explicit selection replacement preserve surrounding text and correct punctuation.
- Empty fields, unavailable text, title-only capture, long prompts, oversized selections, emoji/UTF-16 boundaries and capture timeout obey bounds and fallback.
- Focus, process, window, cursor, selection, before-text or after-text changes during capture/inference prevent unsafe automatic insertion. Include an edit that leaves the cursor offset unchanged.
- Disabled capture, disabled sending, secure fields and excluded apps send no field context. Logs and exported usage data contain no text or snapshot fragments.
- Embedded instructions, unrelated context, unsaid names and copied runs cannot become accepted dictated content. Server failure and validation rejection preserve the faithful transcript.
- History retry uses the original snapshot, while a new dictation always reads anew. An older result cannot insert into a newer dictation's target.

The existing evaluation in `specs/012-app-context-awareness/acceptance/evaluation.md` used `youssofal-qwen3.5-4b-mtplx-optimized-speed`. It reported improved name spelling, but irrelevant-context quality reached at most 85%, below SC-004's 98% threshold. Context could incorrectly remove capitalization and final punctuation. This result must not be attributed to Ultra or treated as a measurement of the current rewrite model.

Repeat the paired context-on/context-off corpus on the actual rewrite backend. Retain Feature 012 gates: at least 50% fewer proper-name errors, zero accepted context-copy or instruction-following cases, and at least 98% no-worse results on irrelevant context. Extend it with the sequential-edit examples above and separately score the newly inserted passage. Record raw rejection rates and fallback rates so a passing safety result does not conceal unusable rewriting. Keep context experimental until the quality and review gates pass.

Run `make check` after implementation. Separately collect signed-app per-target capture latency, rewrite latency and memory evidence on identified hardware/build/model. Unit tests do not establish live app compatibility or resource acceptance.

## Constitution check and report

This design retains bounded memory (principle 2), explicit per-device consent and content-free telemetry (5), versioned structured output (11), boundary tests and preservation of completed text (12), and the existing shared model owner. It introduces no architecture exception. Any future whole-field editing or broader text collection needs its own specification.

Completed: read-only implementation and acceptance review, and this design note. Verified by source inspection only. Remaining: integrate the decisions into Feature 021's plan/tasks, implement the bounded consistency checks and regressions, evaluate the actual rewrite model, and collect live acceptance evidence.
