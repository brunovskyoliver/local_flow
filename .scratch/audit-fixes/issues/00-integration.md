# 00 Audit fixes: integration

Source: audit at `~/agent-runs/2026-10-22-localflow-audit/` (commit `5f2479d`). Six workstreams ran in parallel, each on its own branch. Their reports are tickets 01–06 in this folder. All six were merged into the local branch `audit-fixes`; `main` is unchanged and nothing was pushed.

| Ticket | Workstream | Branch |
| --- | --- | --- |
| 01 | Optional Parakeet Ultra CoreML, FluidAudio 0.15.7 → 0.17.7 | `worktree-agent-ac7bf2de8e5aacb72` |
| 02 | iPhone recovery, bounded handoff transfers, capped checksum retries | `worktree-agent-ac344867e67e45c70` |
| 03 | Server model retention, iPhone Dictate model gating, idle polling, process stats | `worktree-agent-abf7f5b0da2c2733e` |
| 04 | Whole-transcript search/copy/export (Mac), long-text reader (iPhone) | `worktree-agent-a353b8a99cbed51ed` |
| 05 | macOS and Server UI findings, test-root hygiene | `worktree-agent-ae979b801a5c4006c` |
| 06 | iOS app, keyboard and widget UI findings | `worktree-agent-a7972808d63c56e9d` |

## Integration changes

- Shared tokens: warning light `0xB43C0B` and muted light `0x686865` on both platforms; no `warningText` token. `scripts/check-sotto-tokens.py` passes (39 colours).
- `apps/ios/App/Features/History/HistoryView.swift`: kept 04's row-to-reader navigation together with 06's delete confirmation, wrapping metadata and row action style.
- `apps/ios/App/Features/Settings/SettingsView.swift`: Settings shows the number of kept unrecovered recordings and confirms deleting all of them, because 02 keeps up to eight.
- `apps/macos/LocalFlow.xcodeproj/project.pbxproj`: group children union (one file reference from 01, one from 05).

## Verification

`make check` on the merged branch: exit 0. Log: `~/agent-runs/2026-10-22-localflow-audit-fixes/make-check.log`.

- LocalFlow (Mac): 1,911 passed, 0 failed, 31 skipped
- LocalFlowServer: 43 passed, 0 failed
- LocalFlowPhone: 235 passed, 0 failed
- LocalFlowCore: 25 passed
- Go tests, vet, token parity and repository checks passed

These are deterministic tests. No app was run by hand.

## What is left

- Parakeet Ultra quality A/B on held-out English, Slovak and mixed clips (steps in ticket 01). Measure the SDK upgrade (v3 on `main` vs v3 on this branch) separately from the model change.
- Memory, load time and energy for Ultra and for the resource changes in 02/03. Nothing was measured.
- Battery-aware residency setting: needs a short spec first (proposal in ticket 03).
- Manual UI pass: Mac onboarding server path, hover actions with keyboard/VoiceOver, speaker sheet, Settings › Models download/switch; iPhone light/dark, largest text, keyboard in a host app, Lock Screen and Dynamic Island.
- Deferred items listed in tickets 05 and 06 (60 Hz animation rate, Mac UI-15 theme decision, orphan audio export, Increase Contrast variant).
- Physical iPhone: forced quit during recovery, large handoff memory.
