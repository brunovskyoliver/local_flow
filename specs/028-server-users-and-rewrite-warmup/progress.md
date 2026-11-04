# 028 progress

## 2026-11-03

**Changed**
- Audit (`audit.md`), spec, plan, research, data model, contracts, quickstart and tasks for feature 028.
- `apps/macos/LocalFlow/Resources/LocalAI/localflow-mtplx`: `MTPLX_WARMUP_LADDER=512` (T006).
- The installed `/Applications/LocalFlow.app` was rebuilt from this branch so the model services run the fixed flowd (da3f15eb) and the new warmup setting (T009). This is a local install, not a release.

**Verified**
- flowd sees a freshly loaded model 20 ms after MTPLX opens its port (was up to 5 s). One run; see `acceptance/rewrite-cold-start.md`.
- `make check` passed (repository checks and deterministic XCTest).

**Build notes**
- `build/Sparkle` had been swept and a nested rebuild inside Xcode's build phase produced a framework without its binary while still writing `ready`. Rebuilt it with `scripts/prepare-sparkle.sh` in a clean environment. The Release configuration also failed inside Sparkle's targets; Debug was used, as `scripts/dev-macos.sh` does by default.

**Left**
- US1: pill "Starting AI…", cold-start timing log, measurement script and series, prefix-reuse measurement (T007-T008, T010-T020).
- US2-US4 not started. US4 waits for the constitution 7.0.0 amendment and ADR 0039 (T050, T051).

## 2026-11-04: US1 code

**Changed**
- `wait_until_ready` reports `Wait { cold, ready, waited }` and calls a `starting` callback once when the model isn't serving.
- The session has a `StartingModel` state between saving and rewriting; the `Rewriter` callback now reports `Progress::StartingModel` or `Progress::Rewriting`.
- The pill shows that state as the rewrite wave at rest, pulsing, with "Starting the on-device AI, microphone off", its own announcement, and "Cancel rewrite", which cancels the wait.
- Each rewrite on this Mac's model appends one line of numbers to `~/Library/Logs/LocalFlow/rewrite-timing.log` (cold, ready, wait, rewrite and total ms, outcome), capped at 256 KB with one older file. No text.
- Deviation from T011/T012: times are measured from the start of the rewrite step, not from key release. Transcription before it is unchanged by this feature, so the cold-start difference shows the same.
- `MTPLX_WARMUP_LADDER=512` also in Swift server mode and `scripts/install-remote-server.sh` (T007, T008).
- Fixed an existing test that failed after midnight: `library_header_and_rows_have_swifts_type_symbols_and_labels` counted the seed as today regardless of the date.

**Verified**: `make check` passed. New unit tests for the wait, the timing line and log rollover, the session state order, and the pill labels.

**Left**: T015-T019 measurement and the prefix-reuse decision, T017 owner run, T020.

## 2026-11-04: US1 measured

- T016, 10 cold and 10 warm runs per side: port open → ready seen 547 ms median (worst 4.8 s) before, 14 ms after; spawn → rewrite result 5.76 s → 5.10 s median, and the 10.7 s worst case is gone. Warm rewrites 527 → 546 ms, within SC-002's 50 ms.
- T018: no prefix reuse with the shipped MTPLX settings (0 cached tokens with or without a session header). T019 skipped.
- What remains of a cold start is MTPLX itself: about 4.5 s from spawn to an open port (Python, MLX and weight load). The model starts on the key press, so speaking hides part of it.
- T017 (owner key-release runs) needs the Rust Dev app rebuilt with this branch; not run.
- T020: `make check` passed at 6e19dcf1; later commits add only the measurement script and documents.

## 2026-11-04: US2, US3, US4 and polish

**Changed**
- US2: the Rust app can be the server. Onboarding asks for the role on an Apple-silicon Mac; the server path shows the model sizes, downloads them, starts flowd and MTPLX under the `.remote` launchd labels (the `.dev` ones in development builds) and installs the language model without the client's agents. A new server listens on 127.0.0.1 until the owner opens it; opening waits 60 s for a working listener and rolls back otherwise. The owner's first token (24 h) is shown as text, link and QR and is never written to disk. Settings › Server mode turns it on and off and shows status, addresses, fingerprint and missing models. A server set up outside the app is adopted and never rewritten. `flowd-meeting` is bundled in both apps.
- US3: flowd schema v4 stores `devices.kind`; `list --json`, `audit --json`, `token list --json`, `user create`, `rename` and status `channels` are new, and `invited_by` is filled for invited devices. Swift and Rust clients send `device_kind` only when the server lists the feature. The Rust app has a Users page (shown only while server mode is on): users with their devices, kind, last seen, connected now and "Added from"; approve, reject, revoke, rename, new user, "Add device for <user>" with token, link and QR; active tokens and recent audit. It polls every 5 s only while visible and reloads after each action. LocalFlow Server (Swift) reads `list --json` and falls back to the text parser.
- US4: an approved device can invite another device to its own user (constitution 7.0.0, ADR 0039). flowd schema v5; invites last 10 minutes, are single use, limited to 3 open per user and 10 per device per hour; the redeemed device stays pending until the inviting device confirms with its device key after the owner compares a 6-digit code shown on both. Unconfirmed invites expire; revoking the inviter or its user revokes what it invited. The Rust app has "Add another device", the confirm/decline sheet and "Your devices" with Remove and "This wasn't me"; the iPhone shows the code while pending and has "Your devices". The code function is checked against `fixtures/remote/device-code.json` in Go, Rust and Swift.
- Docs: remote-server.md, server/README.md, apps/macos/README.md, apps/ios/README.md, flowd-cli.md; parity rows SET-423 to SET-437; acceptance/hardware.md with 9 owner items, all not run.

**Verified**
- `make check` passed after each wave (commits 72dded52, 03be023f, and the final commit).
- `scripts/check-parity-inventory.py` passes.
- `scripts/check-remote-logs.sh` over ~/Library/Logs/LocalFlow (flowd.log, local-ai-setup.log, rewrite-timing.log): no finding. rewrite-timing.log holds numbers only. Findings in the `make check` output are test names, compiler paths and fixture words, not runtime log lines.
- Tests cover the invite rules (single use, expiry, limits, other-user refusal with audit, confirm signature bound to the channel, cascade), the launchctl label guard, preferences unchanged by server mode, and no token on disk.

**Deviations worth knowing**
- Server-mode keys are in `<app data>/server-mode.json` (same key names as Swift), not in preferences.json.
- The Rust server binds 127.0.0.1 until opened; the Swift app still binds 0.0.0.0.
- "Add device" on the Users page is an inline card, not a modal.
- A new device polls every 2 s while it shows the code (Rust); iOS refreshes on its own schedule.
- "This wasn't me" is on the device's own row as a self-revoke (ADR 0039 reading).
- Swift clients can't invite (no `device_invite`/`device_confirm` in Swift); only the Rust app invites.
- A Swift enroll after a relaunch without re-pinning sends no kind; the server keeps "Unknown" until the next pair.

**Left (owner)**
- ADR 0039 and the constitution comment still say "Proposed"; US4 was built on the 2026-11-03 approval in principle. Accept or reject them.
- T017 key-release timing run, and the 9 hardware items in acceptance/hardware.md (fresh Mac end to end, owner time under 5 minutes, firewall prompt on a signed build, phone meeting handoff, server idle and processing memory, Users page RSS, real-device revocation within 2 s, iPhone added from a Mac in under a minute, phone meeting after invite).

## 2026-11-04: owner decisions

- The owner accepted constitution 7.0.0 and ADR 0039; both now say accepted.
- The owner agreed to run T017 and the nine hardware items in acceptance/hardware.md. The Rust Dev app was rebuilt from this branch and installed for that.
