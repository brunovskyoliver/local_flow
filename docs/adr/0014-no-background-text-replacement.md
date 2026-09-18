# 0014: No background text replacement

Status: Accepted for Feature 003, 2026-09-17.

## Context

The existing insertion service validates a captured target, inserts once and checks the result. It does not provide a safe range-replacement operation across supported applications. Users may type or move focus while rewriting runs. Correction learning also watches the inserted passage.

## Decision

Ship `waitThenInsert`: save the faithful transcript, wait for a validated rewrite, then insert once. Failure, timeout or cancellation selects the faithful transcript. History retries never insert automatically. Keep `insertThenReplace` declared but unimplemented and rejected as a selectable policy.

Reopening this decision requires all four steps, in order:

1. Measure ordinary-input p95 above 3 seconds on the reference setup after warm-model, backend-streaming and prompt-cache tuning.
2. Run an isolated AX range-replacement spike per supported target, recording success, focus loss and caret position in `acceptance/background-replacement-spike.md`.
3. Design coexistence with `CorrectionLearner`, suspending observation until replacement settles or is abandoned.
4. Complete a clarification round and supersede this ADR with a new decision.

## Consequences

Users wait before insertion, with a cancel action and faithful fallback. No late response changes already delivered text. The measured latency gate remains binding; a slow model does not authorize background replacement.

## Alternatives considered

Inserting faithful text and replacing it later risks overwriting user edits, moving the caret and teaching model changes as user corrections. Confirmation adds an interaction rejected during clarification. Inserting streamed fragments creates several mutations before validation finishes.

## Constitution check

Complies with principles 4, 9 and 12: completed text survives failures, delivery stays recoverable, and cancellation/stale-response boundaries remain testable. No architecture exception. See [the research decision](../../specs/003-server-rewriting/research.md).
