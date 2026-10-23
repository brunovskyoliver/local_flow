# Feature 021: Updates, usage reporting and dictation context
Stage: converge
Updated: 2026-10-23

## Decisions

- Public Mac downloads; inference server access remains approval-only.
- Per-user usage requires each device to opt in. Sharing starts disabled and never backfills disabled periods.
- Current field context affects only new dictated text. Existing text is preserved.
- Prepare the dashboard locally; choose hosting later.
- Use the existing Developer ID signing setup for local validation.
- Mac reporting and update controls are implemented. iOS reporting UI is deferred; shared migrations remain compatible.
- Preserve the existing speech-model default. Ultra remains available; no new speed or quality comparison is claimed.

## What changed

Fresh bounded context capture detects inconsistent reads and records availability/truncation diagnostics. Insertion checks the surrounding field again so intervening edits cannot silently receive stale output. Context remains Experimental.

The Mac app has Sparkle update controls, active-work installation deferral and helper build reconciliation. A pinned Sparkle source build includes tested feed/archive size and deadline limits. Packaging and the GitHub release workflow support Developer ID signing, notarization, signed appcasts and Homebrew assets. Production updates remain disabled until feed and key provisioning is complete.

Opt-in usage accounting records the first durable completion once, under the account and consent grant present when recording began. Local and remote totals contain counts and audio duration, never dictation or field text. Bounded persistence, retries, withdrawal and deletion survive restarts. Reporting startup failures do not prevent inference.

The separate Go dashboard accepts authenticated installation exports and limits owner access by exact OIDC issuer/subject. It displays per-user daily totals, coverage and freshness, with deletion controls. Users have opaque labels; account emails are not exported. Consent and deletion propagate asynchronously, with pending status and monotonic controls rejecting stale reports after application. Private service metrics and an optional collector example are included.

## Verification

Final `make check` completed with exit 0 on 2026-10-23. XCTest results: Mac client 1,933 passed and 32 skipped; Server app 43 passed; iPhone 235 passed; shared core 32 passed. Total: 2,243 passed, zero failures, 32 skipped. Repository validation, Go tests, schema fixtures and privacy scans passed. Earlier failures in migration expectations, strict reply decoding and test-name log scanning were resolved before this final run.

Focused Go race tests passed for usage, dashboard, observability, remote, flowd and flowdash. Updater/helper tests, upstream signature verification and actual downloader bounds/deadline/redirect checks passed. See acceptance/usage-server.md and acceptance/updates.md for scope.

Eight native usage settings states were rendered and inspected in light and dark appearance. The dashboard was checked at desktop size and an actual 390-pixel viewport: page width stayed 390 pixels, with horizontal scrolling confined to the table. T3 preview automation timed out twice, so Chrome was used for the remaining browser checks. No main-window presentation policy changed; no live AeroSpace acceptance is claimed.

The local archive `build/distribution/0.99.3/LocalFlow-0.99.3-arm64.zip` passed strict deep signature verification with the existing Developer ID certificate and hardened runtime. Build 10002, 20,366,758 bytes, SHA-256 `d79b8a8ea8a0226c10457e86614939d542bf69e827799989b5454d7fb2ac1ec6`. It includes final production source changes. This is a local test artifact with updates disabled, without notarization or a trusted timestamp.

Final check log and XCTest summaries: `/Users/oliver/agent-runs/2026-10-23-localflow-feature021/`. Native UI evidence: `/Users/oliver/agent-runs/2026-10-23-localflow-usage-ui/`. Browser evidence: `/Users/oliver/agent-runs/2026-10-23-localflow-dashboard-ui/`.

## Remaining work

T009 remains open. The paired context evaluation ran 132 pairs, but backend failures prevent a quality acceptance claim. Identified-model evaluation and live target-app capture/latency checks are still required. T029 remains open because hardware memory and latency measurements were not collected. See acceptance/context.md and acceptance/resources.md.

Production delivery still needs feed/key and protected GitHub environment configuration, notarization, and a real signed bootstrap and N-to-N+1 upgrade test. Dashboard hosting and owner identity configuration are deferred by user choice. Nothing was installed over the current app, published, pushed or deployed.

Convergence found no additional uncovered implementation tasks after fixing optional reporting startup isolation. T028 and T031 are complete; the two acceptance tasks above remain unchecked. The implementation is locally verified, not fully accepted for production delivery.

## Workflow record

Read the referenced audit thread and constitution, then completed specification, clarification, planning, tasks and analysis. Three agents handled context, updates and server/dashboard work; the parent integrated client accounting and verification. Analysis findings were resolved before implementation. The user's standing authorization for reversible local work superseded the skill's normal implementation approval stop. No external publication or hosting action was taken.

## Release preparation, 2026-10-23

The user authorized committing and releasing the Mac app. Preparing version 0.3.0 as a draft without a distributable archive. Existing Developer ID signing is available, but no notarization profile or Sparkle release key was found; the GitHub macos-release environment and repository secrets are not configured. Public installation remains blocked on credential provisioning and the outstanding acceptance gates. A local two-stage notarization setup wizard is at `/Users/oliver/agent-runs/2026-10-23-localflow-release/setup-notarization.command`; it uses Apple's hidden password prompt and stores credentials directly in Keychain. No secret is stored in the repository.
