# Baseline for Feature 014

Recorded 2026-09-27, before any Feature 014 code.

| Item | Value |
| --- | --- |
| Starting commit | `e39e86c` (docs: amend constitution to 2.0.0 for opt-in remote inference) on `t3code/remote-dictation` |
| Dirty tree at start | Staged: `.claude/skills` replaced by a link (`A .claude/skills`, four `D .claude/skills/*` entries). Untracked: `specs/014-remote-dictation-server/`. No source changes |
| Go | `server/go.mod` said `go 1.23.0`; the local toolchain was go1.23.4. Feature 014 moves `go.mod` to `go 1.26` (`crypto/hpke`); `GOTOOLCHAIN=auto` fetched go1.26.0 |
| Xcode | Xcode 26.4.1 (17E202), Apple Swift 6.3.1; the project builds in Swift 6 language mode |
| FluidAudio | 0.15.7, revision `41540ea237350afe5117a082b5c28eda642d0612` (Package.resolved) |
| Constitution | 2.0.0. The `plan.md` constitution check passes before research and after design, with no exceptions and no new ADR beyond 0028 |
| Server test suite at start | `go test ./...` passed on go1.26.0 after the `go.mod` change, before any new code |

No SC-001 to SC-009 figure has been measured. Every success criterion starts as "not measured".
