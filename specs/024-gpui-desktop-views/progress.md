# Feature 024: desktop views in Rust and GPUI
Stage: implement
Updated: 2026-10-31

## Log
- 2026-10-31: constitution 4.0.0 applied; inventory committed (about 2,250 rows).

## Report (2026-10-31)
Evidence is under `~/agent-runs/2026-10-31-gpui-views/audit/`. Nothing is merged, pushed, signed or published.

### Owner decisions
- Visual differences that can't match SwiftUI exactly are accepted. They stay recorded on their rows.
- VM testing is dropped and `agent-localflow-win11` is deleted, replaced by the GitHub Actions run below.

### What changed
All desktop views exist in Rust and GPUI: shell, menu, tray, pill, insertion panel, onboarding, Settings, Dictionary, Insights, Transcriptions and Notetaker. The Swift Mac and iOS apps were not removed; `make check` still builds and tests them. Inventory: 2,254 rows, none open.

| Status | Rows |
|---|---:|
| auto | 1,652 |
| live | 302 |
| recorded | 171 |
| service | 116 |
| not-run | 13 |

### Verification
| Check | Commit | Result |
|---|---|---|
| `make check` (includes the parity, token and boundary checks, Swift and Rust tests) | `b6f6b445` | exit 0 |
| `cargo test --workspace`, repeated for two intermittent tests | `b916ab47` before the zone test moved | 12 of 12 runs passed |
| Mac AX sweep, 195 scenarios, reading the tree | `b916ab47` | 0 crashes |
| Mac side-by-side pairs, light and dark | various, last round 6 | Compared by agents; not every pair was opened, and some Rust shots predate the last layout edits |
| Tiling check | 10:02 run, before later shell changes | Passed then; not rerun because it must show a window on the owner's screen |
| RSS, release on M5, Settings, hidden window | `b6f6b445` | about 105 MB RSS, 49 MB footprint. The footprint is not comparable with the earlier visible-window 105 MB |
| Windows arm64 cross build | `b916ab47` | Builds |
| Windows VM captures, debug assertions on | `b916ab47` | 388 PNGs, none blank; a sampled sheet of 8 looked right. Not compared pair by pair with Swift |

Independent spot checks of 100 random rows each, read-only:

| Check | False | Weak |
|---|---:|---:|
| Before rounds 4-5 | 4 | 26 |
| After rounds 4-5 | 4 | 31 |
| Before round 6, stricter definition of weak | 2 | 10 |

The last two rows use different weak definitions. Round 6 fixed those findings, but no spot check has run since, so expect some remaining false or weak rows among the 1,652 auto rows.

### Windows
The VM is deleted. GitHub Actions run 41231247250 at `261eb01d` passed on x64 (`windows-latest`) and arm64 (`windows-11-arm`), with the same results on both:
- `cargo test --workspace`: 729 desktop, 182 flow-core, 16 flow-ui and 2 smaller suites passed, 0 failed. The tests that start a real `flowd` are Unix-only and don't run there.
- Seven page and scenario opens stayed running for 6 seconds, including `onboarding.purpose`. This clears the VM's crash file, which came from the runner killing the process.
- UIA now returns real trees when read twice, because the first read only turns the tree on: for example 85 named elements on Settings. The VM's nearly empty dumps were read too early. Logs and dumps: `audit/windows-ci/`.

Not established on Windows: pixel comparison with Swift, Narrator speech, audio, real services, and flowd. x64 evidence is these tests and opens only, not hardware acceptance. The VM's 388 captures are from `b916ab47`; one VM run stalled at `notetaker-summary-pending` and the cause wasn't found.

### Left
Reviews still list these rows as weak or different: inventory 01: 37, 03: 8, 04: 19, 05: 17. See `audit/review-0N.tsv`. Inventory 02's file has no `weak` label in that column; it reported 11 weak rows plus ONB-268.

Not run, needs the owner or hardware:
- VoiceOver speech (PILL-052) and Narrator speech
- Apple and Google sign-in (SET-063, 064, 065)
- x64 hardware and audio acceptance, including live microphone recording
- A real pill and insertion panel on screen: non-key behaviour, level, clicks and hover (PILL-011, 012, SHELL-157)
- Tiling on the final commit

Needs later features, so it doesn't work yet:
- Model lifecycle (SET-243, 250, 251, 255, 259, 265, 268, 281, 286)
- Keychain removal and the channel pool (ONB-107): the Turn Off path makes the calls, but on a real Mac nothing is deleted yet
- Shortcut capture, dictation sessions and installer outcomes, so a real onboarding test run can't succeed yet
- The capture worker behind live meetings

Owner decision: Rust keeps showing the review straight away from the History detail sheet, where Swift holds it until the sheet closes (HIST-184).
