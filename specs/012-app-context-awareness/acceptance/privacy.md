# Privacy walkthrough

Status on 2026-09-24: **not performed.** Quickstart steps 2 and 4 (default off, excluded app, secure field, revoked Accessibility permission) need the signed app and manual dictation. Deterministic coverage exists and passed: preference defaults and the off path with zero reader calls, excluded app, own app, secure field and permission outcomes on the snapshot builder, the sentinel test that keeps snapshot text and bundle IDs out of logs and metrics, and cascade deletion. Those tests do not replace the walkthrough.
