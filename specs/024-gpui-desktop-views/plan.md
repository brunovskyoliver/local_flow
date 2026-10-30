# Plan: Feature 024

## Structure

```text
Cargo.toml                 workspace; target dir build/rust (.cargo/config.toml)
crates/flow-ui             tokens, fonts, Txt element (tracking, rich runs, accessible), components
crates/flow-core           paths, preferences, SQLite stores, formatting and page logic, server HTTP
crates/flow-platform       Services trait with macOS and Windows modules and an unavailable fallback
apps/desktop               the localflow binary: shell, pages, pill, tray, seed-free fixtures loader
scripts/check-rust-boundaries.sh   flow-core imports no GPUI or OS API; only flow-ui names gpui_kit component layer
scripts/check-parity-inventory.py  every row has a status and evidence that exists
```

## Constitution check (4.0.0)

- 1 Native client: Rust and GPUI; no web shell. No client LLM and no Python or Node runtime added.
- 2 Memory: list views page through SQLite with bounded page sizes matching Swift; idle RSS is measured in the audit and reported, not assumed.
- 3 Model lifecycle: no model code in this feature. Views show state; `flow-platform` reports the worker as unavailable.
- 4 Local-first, 6 Streaming: the views do not capture audio. No full-file loads: playback rows are `service`.
- 5 Privacy: no secret is stored by this feature except through the platform secret trait. Default data root is separate from the owner's data. Logs carry no transcript text.
- 7 Persistence: `rusqlite`, opening a Swift-migrated database. Swift stays the schema's source of truth; the Rust side refuses a database whose `grdb_migrations` has an unknown migration, rather than migrating it.
- 8 Server: unchanged.
- 9 Recoverability: writes use SQLite transactions. Preferences use write-temp-then-rename.
- 10 Speakers: uncertain identities stay unknown; assignment writes the same tables as Swift.
- 11 Structured output: summaries render from the validated stored JSON, unknown versions show the error state.
- 12 Testability: `flow-platform` is a trait with a test double; views are tested headless.
- 13 Observability: RSS report in `acceptance/`.
- 14 Scope: dependencies are GPUI Kit, `rusqlite`, `serde`, `serde_json`, `tray-icon`, `ureq`. Licenses in `research.md`.
- 15 Server access: the client uses the same sign-in and enrollment flow; signing in needs a provider, so full sign-in stays `not-run`.

Bounds: every list has a page size or window; the pill's and view models' queues don't grow. Overload: not applicable, views hold no queues.

## Validation

`cargo test --workspace` (headless GPUI tests through `gpui_kit::test`), Swift-made fixture database, `flowd` integration test, screenshot audit script, AX and UIA dumps.
