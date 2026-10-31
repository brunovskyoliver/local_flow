# Feature 027: Server mode and token pairing
Stage: done
Updated: 2026-10-31

## Decisions
- Numbered 027 because 025 and 026 are reserved for the Rust client's follow-ups. Known collision: specs/024 and docs/architecture/cross-platform-gpui.md also use 027 for a Rust feature, so that one takes the next free number.
- Inherited rules: never use the owner's live flowd, data or keys; no push, merge, sign or deploy without asking.

- Gate 1 (owner, 2026-10-31): 1 A, 2 A, 3 A, 4 B, 5 A; listed defaults accepted.
- Gate 2 (owner, 2026-10-31): `go`. Approves constitution 5.0.0 and ADR 0037. Findings 1–6 applied. Tests use loopback, temp data and fake Keychain and launchd runners, to keep prompts off the owner's screen.

## Log
- 2026-10-31 specify: wrote spec.md and checklists/requirements.md after reading flowd accounts, enrollment, listener, Swift and Rust remote flows, ADRs 0028, 0031, 0032, 0036 and T3 Code source at `15fe2832`. Nothing committed.
- 2026-10-31 clarify-gate: five questions sent to the owner.
- 2026-10-31 plan, tasks: plan.md, research.md, data-model.md, contracts/pairing.md, quickstart.md, tasks.md (32 tasks, 8 phases).
- 2026-10-31 analyze: read-only pass done, gate 2 sent.
- 2026-10-31 phase 1: `make check` baseline exit 2 (Error 65) after 811 s: every step up to the LocalFlow XCTest passed, then `MeetingCoordinatorTests.testTranscriptionObserverHooksAndStartOption` and `RemoteRewriteTransportTests.testTheTimeoutAppliesInsideTheTransport` failed, so the later steps did not run. Both passed alone, and in the full run below; the baseline shared the machine with `go test -race` runs, so they look load-sensitive, cause not confirmed. Wrote ADR 0037, amended ADRs 0028 and 0032, constitution 5.0.0, added `pair` and `pairing_token_invalid` to the schema, fixtures and channel contract. `TestMessageFixtures` skips valid/pair.json until T007.
- 2026-10-31 phase 2: schema v3 with the pre-v3 copy, and `accounts/pairing.go`. `go test -race ./...` and `go vet ./...` pass; full `make check` with phases 1 and 2 applied exit 0 after 616 s. No hardware acceptance or resource measurement was run. A v2 fixture device keeps its references and still refreshes.
- 2026-10-31 phase 3: `pair` on flowd, `flowd admin token`, PairingToken and PairingLink, RemoteEnrollment.pair, Mac sheet and link handling, iOS section and link handling. `go test -race ./...`, targeted Mac (30) and iOS (22) XCTest, LocalFlowCore tests and full `make check` pass. Mac link delivery was not run live; no hardware acceptance.
- 2026-10-31 phase 4: `--remote-listen` takes any IP literal, `clientAddress` per R7, proxy test with no token on the wire, FR-012a in `origin` and `channelURL`, `updateAddress`, pasted links, not-TLS notice, iOS ATS keys and T032 (R9), Go-Swift pairing vectors, opt-in `scripts/test-pairing-e2e.sh`. `go test -race ./...`, `swift test`, targeted Mac and iOS tests, the e2e script and `make check` pass.
- 2026-10-31 phase 5: v2 database migration test, new client against an old server keeps a working device and spends no token, `enroll` refuses an `lfp_` value, `install-remote-server.sh --dry-run --dev` shows loopback binds only. Same test commands pass.
- 2026-10-31 phase 6: LocalFlow Server Pairing tab (PairingView, Admin), client TokensView and TokensModel with a fake runner, `flowd admin` runs the data directory's own flowd. Targeted AdminTests (9) and TokensModelTests (7) pass. The client view gets its entry point in T028. No app was opened and no real admin command run.
- 2026-10-31 phase 7: flowd-speech and its FluidAudio bundle go to Contents/Helpers (11.8 MB Release, unsigned); ServerModeController with hash-based ownership, adoption, open-to-network rollback and dev isolation; address classification; ServerModeView with the tokens entry. Tested with a fake launchd only; no agent started, no app opened.
- 2026-10-31 phase 8: docs, `acceptance/hardware.md` (18 owner items, all not run), Rust pairing in 024's Left list. `make check` with the iPhone 18 Pro Simulator exit 0, including the parity inventory check. No hardware acceptance.
- 2026-10-31 converge: T033 to T040. LocalFlow Server's Restart and the install script now run `launchctl enable`, a route without WebSockets is reported as unusable, memory cost is stated, QR codes have a quiet zone and sharp modules and are decoded in tests. Not built: naming a Local Network refusal as such (it reads as unreachable); a dev variant of LocalFlow Server's Pairing tab (ADR 0032); Rust pairing. Offscreen renders of the Mac, Server and iOS views in light and dark are in `~/agent-runs/2026-10-31-remote-pairing/renders/`. Sheets over a shown window, confirmation dialogs and SecureField contents were not rendered.
- 2026-10-31 review: independent security review of `cc31993d`. Fixed: refused enroll and pair close the channel; unknown tokens and bad signatures write no audit row; `Cf-Connecting-Ip` no longer read; IPv6 buckets per /64; busy and internal keep the pair key; rollback reports a failed reload; an open interrupted by quitting is undone at launch; single-IP binds list and probe that IP.

## Report

### What changed
- Phase 1, `38b7d3cf`: constitution 5.0.0, ADR 0037, amendments to ADRs 0028 and 0032, wire schema.
- Phase 2, `8ef25c7b`: schema v3 with a pre-migration copy, pairing token store.
- Phase 3, `66d48eb9`: `pair` operation, `flowd admin token`, pairing on Mac and iOS.
- Phase 4, `5cd04ce3`: any IP bind, client-address rules, FR-012a `http://` rule, address edit without re-pairing.
- Phase 5, `66d6bd76`: migration and old-server tests, shared Go and Swift vectors, opt-in end-to-end script.
- Phase 6, `3c57f471`: tokens view in LocalFlow, Pairing tab in LocalFlow Server.
- Phase 7, `cc31993d`: server mode, adoption of existing servers, bundled `flowd-speech` (11.8 MB, Release arm64, unsigned).
- Converge and docs, `42cb958a`, `604f2b6d`.
- Review fixes: see the last Log line and the commit that follows this report.

### Verified
- `make check`, final tree: exit 0. Log: `~/agent-runs/2026-10-31-remote-pairing/make-check-final.log`.
- `scripts/test-pairing-e2e.sh`: passed before the review fixes, against flowd's serve path on loopback with a fake Keychain; not rerun after them.
- Independent security review of `cc31993d`; its findings were fixed. The fixes themselves had no second review.
- Offscreen renders of the new views: `~/agent-runs/2026-10-31-remote-pairing/renders/`. Sheets and dialogs as presented were not rendered.

### Baseline
`make check` failed once before any feature code on two load-sensitive tests, `MeetingCoordinatorTests.testTranscriptionObserverHooksAndStartOption` and `RemoteRewriteTransportTests.testTheTimeoutAppliesInsideTheTransport`. Both passed in every later run. Cause not confirmed.

### Left
- Everything in `acceptance/hardware.md` is not run: real launchd, firewall and Local Network prompts, a real iPhone and second Mac on each route, latency, RSS, signed build. `ws://` on RFC 1918 and Tailscale addresses on iOS is unproven; only loopback completed.
- Phone meeting handoff is unavailable on app-created servers, because `flowd-meeting` isn't bundled.
- A Local Network refusal reads as "could not be reached". A proxy on another host shares one rate-limit bucket.
- The rightmost `X-Forwarded-For` rule is untested through a real cloudflared or Tailscale Serve.
- Rust pairing is deferred. Implementation status: committed locally on `remote-pairing`. Merge and deployment: not done.

### Process note
While restarting a check, `pkill -f scripts/test.sh` was run. It could have stopped that script in other sessions on this Mac.
