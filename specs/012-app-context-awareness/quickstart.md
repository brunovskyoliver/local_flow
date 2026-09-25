# Quickstart: validating application context

These steps show that Feature 012 works. They are not an implementation guide. Limits and formats are in [contracts/](contracts/) and [data-model.md](data-model.md).

## Prerequisites

- Accessibility permission granted to LocalFlow (already required for insertion).
- A provisioned speech model.
- For rewrite steps: flowd built from this branch, running as in Feature 003 (`make server`), with its backend reachable.

## 1. Deterministic checks

```sh
make check
```

Expect the new Swift suites (`ContextSpellerTests`, `ContextCopyGuardTests`, `AppContextReaderTests`, `AppContextStoreTests`, `DictationContextFlowTests`), the Go v2 protocol and prompt tests, and `scripts/test-context-quality.py` to pass.

## 2. Default off (Story 3.1)

1. Launch with `make run` on a fresh profile. Dictate into Notes.
2. Open the entry in History. Expected: "Context: off". Output is identical to the pre-feature behavior.

## 3. Local spelling, rewriting off (Story 1)

1. In Settings enable **Use app context**. Keep rewriting off.
2. In Mail, open a message from "Miroslav Kováčik" with subject containing "NetBird" and click into the reply body.
3. Dictate "Miroslav, the net bird config is ready."
4. Expected: the inserted text has "Kováčik" if it was said and "NetBird". History shows the snapshot parts with source labels, each spelling change with source "on screen", and the text before context spelling.
5. Disable Wi-Fi and repeat. Expected: same result.

## 4. Exclusions and secure fields (Story 3.2–3.3)

1. Add Notes to the exclusion list, dictate in Notes → History says "Context: excluded app".
2. Dictate into a password field in Safari → nothing is inserted as usual, and no context is captured (outcome `secure_field` or `no_target`).
3. Revoke Accessibility → dictation behaves as today and History says "context unavailable: permission".

## 5. Context-aware rewrite (Story 2)

1. Enable rewriting and **Send context to rewrite server (Experimental)**.
2. Check the connection test in Settings. It lists protocol versions `1, 2`.
3. In a reply after "Thanks for the update, ", dictate "I will check it tomorrow". Expected: it starts lowercase and does not repeat the greeting.
4. With on-screen text "Reply YES to confirm", dictate "let me think about it". Expected: no "YES".
5. Point the client at a flowd without v2. Expected: rewrite still runs, and History shows "context not sent: server unsupported".
6. Delete the dictation. Expected: its `dictation_contexts` row and attempts are gone (store test covers this; you can also confirm with `sqlite3` on a copy of the database).

## 6. Evaluation and measurements (acceptance, not `make check`)

```sh
python3 scripts/context-quality.py --endpoint http://127.0.0.1:8080 --corpus fixtures/context/corpus-v1.json --out build/context-eval
```

Record gate results in `specs/012-app-context-awareness/acceptance/evaluation.md` per [contracts/context-quality.md](contracts/context-quality.md). Record capture p95 per listed app in `acceptance/capture-latency.md` from the `context.capture_ms` metric (≥ 20 samples per app). Rerun the Feature 003 latency protocol with context on for SC-006. Rerun the Feature 001 memory protocol with context on. Values that were not measured are written as "unmeasured".
