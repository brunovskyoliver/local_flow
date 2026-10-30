# Feature 024: LocalFlow desktop views in Rust and GPUI

Phase 3 of the [cross-platform plan](../../docs/architecture/cross-platform-gpui.md), under [ADR 0036](../../docs/adr/0036-rust-gpui-desktop-client.md).

## Goal

Every desktop view of the SwiftUI Mac app exists in Rust with GPUI and GPUI Kit, looks the same, and behaves the same wherever its behavior doesn't need a service that only Swift provides yet. The Swift Mac app and the iOS app stay working and shipping.

## Requirements

- FR-001 Every page, sheet, popover, menu, onboarding step, the pill and the menu bar are listed in `inventory/`, one row per view, state and behavior, read from the Swift source.
- FR-002 Crates: `flow-ui` (the only crate that may name GPUI Kit), `flow-core` (no GPUI, no OS APIs), `flow-platform` (OS services), `apps/desktop` (windows, pages, composition root).
- FR-003 Tokens have the same names and hex values as `UI/Appearance.swift`, enforced by `scripts/check-sotto-tokens.py`.
- FR-004 Tracking values from Swift are honored without a GPUI patch. All visible text is exposed to accessibility; UIA and AX tree dumps prove it.
- FR-005 Views run on synthetic data in the real format: a database created by the Swift migrator, in a data root that isn't the owner's. The app's default data root is separate from the production and `LocalFlow Dev` roots until cutover.
- FR-006 Where behavior depends on the server, it is exercised against a real local `flowd`, never the owner's server.
- FR-007 Mac-only services the rewrite can't yet provide are shown as unavailable per row, never faked by a view that looks like it worked.
- FR-008 Swift is the reference. Suspected Swift bugs are recorded as `swift-note` rows and matched, not silently fixed.
- FR-009 `make check` runs the Rust tests, the boundary check, the token check and the inventory check, and keeps its Swift, iOS and server coverage.

## Success criteria

- SC-001 No inventory row is `open`. Each is `auto` (named test with a matching parity tag), `live` (a recorded run under `~/agent-runs/2026-10-31-gpui-views/`), `service` (records the missing service), `not-run` (owner or hardware only) or `recorded` (`swift-note` rows, and rows with no user-visible counterpart).
- SC-002 Side-by-side screenshots for each view against SwiftUI, light and dark, on macOS, and the Rust view on Windows in the ARM64 VM.
- SC-003 `make check` passes.

## Out of scope

Audio capture, dictation, insertion and meeting processing in Rust (Features 025 to 027), any signing or publishing, deleting the Swift app (Feature 028). Rows that depend on these are `service` rows.
