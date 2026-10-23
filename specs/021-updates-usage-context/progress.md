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

Implementation committed as `f7b35f5b` and pushed to `origin/main`. Draft release v0.3.0 created at https://github.com/brunovskyoliver/local_flow/releases/tag/untagged-44332866b4a4f2b53114 with no binaries attached. It is unpublished, and no release tag was pushed to trigger CI. The notarization wizard passed `bash -n`; it has not been run because the user must enter their Apple credentials locally.

The user subsequently declined notarization setup and explicitly requested distribution without Developer ID signing. Preparing v0.3.0 with the existing ad-hoc packaging mode, in-app updates disabled, and explicit release notes about manual installation. This supersedes the notarization prerequisite for this manual release only; signed-update and hardware acceptance remain open. The generated auto-updating Homebrew cask and appcast will not be published.

## Published manual release

Published v0.3.0 at https://github.com/brunovskyoliver/local_flow/releases/tag/v0.3.0 from commit `c65e6bd05ef0f8974be9301c03ac1c1e5ea44ae7`, build 10003, using the user-authorized ad-hoc mode. Attached the ZIP and SHA-256 file only. Archive size: 20,300,743 bytes. SHA-256: `9b6bb4e5f43a0ab77da8311b4f06b55912e0d0d556101614202f3067e31e570f`.

The Release build and packaging succeeded. Extracted archive passed strict deep codesign verification, with ad-hoc signing confirmed, version/build checked, Google client ID present and signed updates disabled. GitHub's uploaded archive digest matched the verified local ZIP before publication. Production source is unchanged since the full passing make check; subsequent commits contain release documentation only. Build log: `/Users/oliver/agent-runs/2026-10-23-localflow-release/package-0.3.0.log`.

The app is not notarized and may require manual first-launch approval. No installed app, Homebrew tap, remote server or dashboard deployment was changed. Signed automatic updates and outstanding live/hardware acceptance remain deferred.

## Homebrew tap update

At the user's request, updated `brunovskyoliver/homebrew-tap` to v0.3.0 in commit https://github.com/brunovskyoliver/homebrew-tap/commit/33eca9e5e18587acc7722cb6f993a8b7bc6332e6. The cask checksum matches GitHub's published archive digest. It retains the ad-hoc installation caveats, explicitly describes manual updates, and does not declare `auto_updates`. Ruby syntax validation passed and the published cask was read back and compared with the intended content. No local application installation or upgrade was performed.

## Follow-up: make release nested-signature failure

Reproduced the user's exact `code has no resources but signature indicates they must be present` failure with strict codesign verification of both the Release app and Sparkle's Downloader.xpc. The source-built dependency's nested helpers had only linker-generated ad-hoc signatures; Xcode's CodeSignOnCopy signed the outer framework without sealing its nested bundles. Source and embedded copies exhibited the same failure, ruling out missing copied resources.

Added a final Xcode build phase that signs embedded Mach-O files, then nested XPC/app bundles, then Sparkle.framework, and strictly verifies the result. It uses the active Xcode signing identity and preserves entitlements. It changes only the embedded copy, leaving the shared dependency cache untouched; unsigned builds skip it. The standalone packaging script already performs nested signing, so the published v0.3.0 ZIP is unaffected.

A regression script exercises real source-built Sparkle bundles, unsigned-build skipping and repeated signing, and now runs in make check. The first concurrent check run lost a test-host process during the release installer quit step; it is not counted as passing. After the user closed LocalFlow, make release completed with exit 0, installed and opened /Applications/LocalFlow.app, and strict deep verification of the installed app passed. The final make check run was executed separately from installation and completed with exit 0: Mac client 1,933 passed, Server app 43 passed, iPhone 235 passed and shared core 32 passed, with zero failures and 32 skips. The new nested-signing regression check also passed.

Evidence is in `/Users/oliver/agent-runs/2026-10-23-localflow-release/`: `sparkle-signing-test.log`, `make-release-fix-final.log` and `make-check-signing-fix-final.log`. No window presentation or application behavior changed.

## Follow-up: update settings card

The screenshot exposed missing vertical insets: UpdatesSettingsSection used a bare VStack inside a group that supplies only horizontal padding. Converted the card to the existing SettingsRow layout, matching surrounding typography and 19-point vertical row padding. Manual-update builds now show an active View Downloads link to the project's latest GitHub release, with accurate manual-update copy, instead of a disabled check button and an instruction to install an unpublished signed release. The automatic-update state retains its check button and toggle in separate padded rows.

Native render fixtures cover manual, checking and startup-error states at 390- and 670-point widths in light and dark appearance. The initial narrow checking preview exposed a truncated title; shortened that row title to Latest version. Evidence: `/Users/oliver/agent-runs/2026-10-23-localflow-updates-ui/`. The full make check passed. Final native rendering passed and the narrow automatic-update title fits without truncation. make release then completed successfully, installed and opened /Applications/LocalFlow.app with the corrected card. No main-window sizing or presentation policy changed.
