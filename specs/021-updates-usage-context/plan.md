# Implementation plan: Updates, usage reporting and dictation context

**Branch**: `main` | **Date**: 2026-10-23 | **Spec**: [spec.md](spec.md)

## Summary

Ship three independent Mac-first slices: improve existing fresh-field context, add verified in-app updates, and add optional account-linked usage reporting plus an owner-only hosted dashboard. Preserve current application and model boundaries. No publication or deployment is authorized by this plan.

## Technical context

Use the repository's pinned Swift/Xcode and Go toolchains. Native SwiftUI/AppKit client, existing shared Swift package, Go server and SQLite. Sparkle supplies update installation and signature verification. Go reporting uses existing identity verification and storage conventions. A separate Go command serves a small server-rendered owner dashboard; no web server is embedded in a native app. Existing Go operational counters are exposed through a bounded scrape endpoint for an optional owner-operated OpenTelemetry Collector, avoiding an external analytics SDK in the client/server.

Test with XCTest, Go tests, contract fixtures and `make check`. Browser testing covers owner access and display; Mac interaction covers context and updater controls. Signing and actual-model resource/quality acceptance are separate from fixture tests. Initial reporting capacity is 100 users, 10 devices each, 90 days; capacity exhaustion marks a gap and never blocks dictation. No clustering or generalized analytics platform.

## Constitution check

Pre-research and post-design assessment: no intended exception. Native clients stay native (1); bounded queues below (2,6); existing lifecycle coordinator and server workers retain exclusive model ownership (3,8); dictation remains offline-capable (4); context and usage sharing remain opt-in, content-free metrics and owner-operated endpoints only (5); SQLite migrations/transactions remain storage authority (7,9); no diarization changes (10); existing structured rewrite validation retained (11); boundary doubles and failure tests required (12); hardware measurements reported separately (13); three independently deliverable stories avoid speculative infrastructure (14); identity comes from verified tokens and revocation applies on ingestion (15).

No external analytics SDK is introduced. The optional collector runs outside the app/server. Sparkle is an updater, with pinned source and bundled license review required before adding it. The hosted reporting command is a separate optional Go process; it does not add a listener to the native Server app. Record this placement and threat model in an ADR before code. Supplied AGENTS wording conflicts with ADR 0032 about existing Mac app count; preserve both existing apps, add none, and report that discrepancy.

## Project structure

- `apps/macos/LocalFlow/Core/Context/`, `Core/Insertion/`, `Features/Dictation/`, `Features/Rewrite/`: extend current context and target validation.
- `apps/macos/LocalFlow/Core/Updates/`: new small updater wrapper with test doubles; app/settings own its lifecycle.
- `apps/macos/LocalFlow/Core/Usage/`: optional aggregate producer/exporter, using existing persistence and account session boundaries.
- `packages/LocalFlowCore/`: shared reporting wire values only where consumed by both clients/server contracts; no new package.
- `server/internal/usage/`, `server/internal/remote/`: authenticated consent and aggregates.
- `server/cmd/flowdash/`, `server/internal/dashboard/`: owner-only reporting process and HTML templates.
- `server/internal/observability/`: bounded operational metric exposition.
- `protocol/schemas/`: versioned usage contract following existing schema naming/layout.
- `.github/workflows/release.yml`, `scripts/package-macos.sh`, `packaging/homebrew/`: production update artifacts.
- `specs/021-updates-usage-context/`: spec, research, contracts, tasks, validation and report.

New paths above are proposed ownership boundaries, not existing implementation claims.

## Design and bounds

Context retains 1,000 before / 300 after / 2,000 selected characters, 40 terms, 8,192 serialized bytes and the existing 250 ms capture deadline. Capture must detect inconsistent reads and fall back. Automatic insertion additionally validates the after-cursor reference actually used, without expanding to whole-document reads. Capture cannot delay recording. Keep the old snapshot for history retry. Diagnostics distinguish unavailable, withheld and truncated context. Actual model gates in Feature 012 remain mandatory before recommending experimental rewrite context.

Updater has one operation, streamed staging, one pending archive, one staging set, a proposed 1 MiB feed/4 GiB archive cap and 30 s check/30 min download deadlines. Verify enforcement against the pinned Sparkle API before enabling production checks. Abort cleanup preserves existing data. Defer on active work. On launch, compare bundled and running helper builds, refresh only owned helpers, then check health. Do not automatically downgrade an installed app/database on a helper failure. Current builds require one manual signed bootstrap; signing-identity permission changes must be tested and documented.

Usage design is specified in `contracts/usage.md`; `research-usage.md` records earlier alternatives. The client is authoritative for completed logical dictation usage (local or remote), so a remote operation is not counted again from server attempt metrics. Server counters separately describe attempts and latency. One in-flight client export and one server-to-dashboard export, 64 KiB/100-row bodies, 30 s request deadline, bounded exponential retry from 30 s to 1 h. Coalesce daily aggregates instead of queuing events. Client retains at most 90 daily rows per device for its active grant; backend capacity and deduplication details belong in the contract. Never run a network request on the recording path. Disk or capacity failure surfaces a coverage gap.

Retain 90 days. Authenticate client to existing approved-user server; authenticate server-to-dashboard with an installation-bound key kept out of the client. Dashboard login uses OIDC with exact configured issuer/subject owner allowlist, secure server-side sessions, CSRF protection, no anonymous/signup route. Use TLS throughout. A TLS-terminating third party sees only approved metadata; audio and field text remain under existing inner-encryption rules. Identity display names are administrative metadata and must be separately disclosed. Do not export provider tokens.

## Validation and delivery

Implement setup and contracts, then context (MVP), updates, usage/dashboard, and integration. Each story has independent failure tests. The full planned scope includes local usage, not merely server traffic. Deployment configuration remains disabled without explicit host, owner identity and credentials. Prepare local fixtures and release artifacts before requesting external actions. Read the research files for current signing bootstrap and quality evidence.

Resource measurements must identify M5/OS/build/model and include context latency, unloaded RSS, reporting storage/export overhead, update staging peak and optional dashboard idle RSS. No target is claimed as met by this design. Existing 150 MB client / 100 MB idle server targets remain; investigate regressions before delivery.
