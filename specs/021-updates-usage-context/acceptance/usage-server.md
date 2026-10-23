# Usage server and dashboard implementation report

Date: 2026-10-23. Local implementation and fixture validation only. No dashboard was hosted, no credentials provisioned, and no artifacts published.

## Changes

- Added strict request, response, control, daily-row and export schemas, plus encrypted `usage`/`usage_reply` session messages and shared fixtures. The existing approved session supplies identity. Client payloads cannot choose a user/device.
- Added a separate bounded SQLite usage store, transactional migrations, per-device consent epochs/grants, account-bound control CAS, cumulative row revisions and all-epoch deletion. Repeated withdrawal/deletion is idempotent. A user deletion remains pending until every affected device control is acknowledged. Revocation reconciliation advances grants after approval is lost, including on restart.
- Added optional single-flight HTTPS export, exact destination-host allowlisting, redirect refusal, bounded bodies/responses, timeouts and retry. Current controls precede data, stale queued snapshots are refused, and acknowledgments clear only the revision actually acknowledged. Dashboard transactions prevent late data from resurrecting deleted epochs. Cross-host propagation is explicitly eventual; inference revocation remains independent.
- Added `flowdash`, with bounded SQLite ingestion, one installation credential, exact Google issuer/subject owner authentication, authorization code + PKCE/state/nonce, secure session cookies, ten-session/eight-hour limits and CSRF-protected logout/deletion. It has no inference administration route. Owner deletion uses a bounded reporting-control queue.
- Added a responsive owner table grouped by user/day, checked sums, local/remote counts, human-readable duration, Complete/Partial coverage, report freshness and 100-row pagination. Directory labels currently use stable opaque user identifiers; names/emails from inference accounts are not exported.
- Added optional loopback operational metrics, fixed service/outcome behavior, duration buckets, worker readiness and sampled speech queues. No analytics SDK was added. The collector configuration is documentation only.
- Isolated optional reporting startup failures: a bad usage database disables its capability, and a bad export configuration disables export. Inference initialization continues. Fixed a shared log-writer race exposed by the broader Go race run: speech and meeting logger instances now share one writer lock.

## Verification

Passed on the local development Mac:

```sh
python3 scripts/validate-foundation.py
cd server
go test -race ./internal/usage ./internal/dashboard ./internal/observability ./internal/remote ./cmd/flowd ./cmd/flowdash
```

The foundation validator accepted 109 remote message examples. The final full targeted race run passed: usage 1.420 s, dashboard 1.678 s, remote 15.448 s, flowd 12.337 s; observability was cached. `cmd/flowdash` compiled and has no separate command tests. A subsequent focused race run for the owner-deletion idempotence correction passed usage and dashboard (dashboard 1.638 s).

Coverage includes cumulative duplicate/conflicting replay, atomic batch rollback, CAS-bound withdrawal and regrant, repeated deletion without revision churn, user-scoped multi-device deletion, retention/capacity, revocation, authenticated TLS export, dashboard control/data races in both arrival orders, no resurrection after deletion, owner subject/issuer refusal, consumed OAuth state, PKCE/nonce presence, session expiry/login bounds, CSRF refusal, strict body limits, template escaping, per-user totals, pagination and arithmetic overflow. Metrics tests reject public binding and scan output for user/device identifiers and private markers. Startup tests cover malformed reporting DB/config and content-free diagnostics.

The parent inspected the loopback fixture at 1280 px and reported a clean accessible table with 12 local and 8 remote fixture dictations. That inspection preceded the final human-duration/pagination/deletion controls; the fixture can be restarted for the final visual pass. The fixture is test-only, uses temporary SQLite, opens no public listener and expires after ten minutes.

## Remaining delivery checks

- The parent runs repository-wide `make check` and the Mac client acceptance; this report does not claim either from the server agent's focused tests.
- Production Google OAuth login, TLS certificates, host configuration, private credentials and deployment remain unperformed by request. The exact-identity authentication boundary was tested with deterministic token-exchange/verifier fixtures and the existing OIDC verifier suite.
- Resource measurements, a real Mac-to-hosted-dashboard run, and production backup restore acceptance were not collected. No memory or latency target is claimed achieved.
- Custom human-readable account-name mapping is not implemented. Current directory projection uses a stable opaque label, avoiding email exposure.
- Backups are not implemented. Operators must preserve latest deletion controls and reapply retention before serving any restored reporting database; the runbook records that prerequisite.
- Operational request counters derive from existing content-free log lines. They are not durable product accounting and retain the log format's coverage limits.

See [the preparation runbook](../../../docs/distribution/usage-dashboard.md) and [ADR 0035](../../../docs/adr/0035-optional-owner-usage-reporting.md).
