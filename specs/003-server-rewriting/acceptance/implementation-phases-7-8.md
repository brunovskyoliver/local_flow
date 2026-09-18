# Phases 7 and 8 implementation checks

Completed T047–T055 on 2026-09-17 by resuming T3 thread `f3c01d6c-ee88-41c5-b09e-c41542b26856` in its existing dirty workspace. This records deterministic implementation checks. It does not establish live-server, signed-app, physical-keyboard, VoiceOver, latency or resource acceptance.

## History and insertion

History shows rewrite badges and ordered attempts alongside the faithful transcript. Detail identifies the current successful, non-stale rewrite and the delivered source, explains differences, and offers a mode picker, Rewrite/Retry and Cancel. Each attempt can be expanded to inspect its input snapshot, output and metadata. Copy and explicit Insert are available for successful, non-stale outputs and the faithful text.

The tests cover restart preservation, interrupted pending attempts, legacy migration, deletion, the ten-attempt limit, history notices, and history retries without automatic insertion. Additional regressions cover exposing Cancel during admission and closing details while a rewrite runs. History tracks at most two active operations; their completion cannot leave another entry busy or attach a notice to it. Completion refreshes list badges even when the original detail has closed.

Explicit insertion uses the existing review, target-selection and confirmation flow. It records the chosen rewrite ID or faithful source. A regression test exposed loss of that identity when outcome persistence failed. Storage retry now retains the delivery metadata and saves it without dispatching the text again. Attempts belonging to another transcription are refused before review.

## Shift bypass

Holding Shift on shortcut release bypasses rewriting for that dictation. Shift does not cancel an existing hold, and the gesture is unavailable when Shift belongs to the configured shortcut. The release handler carries the flag into the dictation session.

Tests cover no transport call, attempt row, notice or refusal metric for bypass; faithful insertion; a later history rewrite starting at ordinal 1 without another insertion; and clearing bypass for the next dictation. These are synthetic event and boundary tests, not observations of physical keyboard input or operating-system sockets. The broader T026 suite-replay task remains unchecked; this phase supplies its bypass-specific coverage.

## Validation and constitution

`make check` passed after the final code changes: Swift formatting, Python checks, shell syntax, foundation validation, plist/project checks, Go tests/vet and XCTest. XCTest reported 449 passed, 0 failed and 10 skipped out of 459 tests. Skipped tests establish no acceptance result. `git diff --check` and the Spec Kit prerequisites check with `--require-spec` passed. The requirements checklist had 16 checked items and none unchecked. No extension hooks were configured.

Result bundle: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.17_19-53-59-+0200.xcresult`.

No architecture exception or dependency was introduced. This remains one native app with the separate Go server and existing shared schemas. Attempts remain bounded to ten per dictation and two in flight overall. Transcript text remains unchanged by rewriting; failed persistence retains the selected delivery metadata for recovery. Phases 9–11 and their live acceptance work remain outstanding.
