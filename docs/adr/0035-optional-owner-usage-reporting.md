# 0035: Optional usage reporting has a separate owner dashboard

Accepted for local implementation, 2026-10-23. Production hosting requires separate approval.

LocalFlow will report daily completed-dictation counts and successful audio duration only from enrolled devices whose users explicitly enable usage sharing. The existing encrypted LocalFlow session carries these snapshots. Client history commits define completed dictations; server inference attempts remain operational measurements and never inflate those totals. Cumulative revisioned snapshots tolerate offline replay without accumulating duplicate counts.

A separate Go process, `flowdash`, owns a bounded SQLite reporting projection and a browser interface restricted to one configured OIDC issuer and subject. It receives no audio, transcript, field context, inference credential or OIDC identity claim. The native Mac apps do not embed a web server. The dashboard cannot approve inference accounts or operate models. Hosting a separate read-only reporting process costs another deployment, but avoids exposing the existing loopback administration interface or adding a mandatory cloud dependency.

Reporting state uses one monotonic epoch and random grant per device. Withdrawal/revocation closes the grant; deletion cuts off every retained earlier epoch. Coalesced durable controls reserve capacity independently of aggregate rows. One bounded source exporter sends current controls before data. Dashboard transactions serialize control changes with snapshot ingestion. A report already in flight can arrive before its withdrawal control; the client shows propagation pending until acknowledgment, and the applied control rejects delayed older reports. We chose explicit eventual propagation for optional metadata instead of claiming atomic revocation across network partitions. Inference authorization remains independently revocable.

## Constitution check

1. Native clients remain Swift/Apple-framework apps; the optional dashboard is a separate Go server.
2. Reporting has explicit row, identity, byte, request and session ceilings. No unbounded event queue.
3. Reporting creates no model runtime and changes no lifecycle ownership.
4. Reporting failure never blocks dictation; offline snapshots coalesce within retention limits.
5. Sharing is disabled until per-device consent. Exports carry only allowlisted counters and a disclosed account display projection. Logs exclude content and credentials. No external analytics SDK is introduced.
6. Messages are at most 64 KiB, with at most 100 daily rows per batch.
7. SQLite migrations and transactions own durable reporting state; media is absent.
8. Go processes remain separate from inference workers. Dashboard processes load no models.
9. Deletion controls and aggregate replacements commit transactionally. Restore must apply deletion state before serving data.
10. No speaker attribution or biometric data is reported.
11. Reporting is a versioned deterministic schema; it does not parse AI output.
12. Clocks, approval and projection authority have test seams; replay, capacity and revocation races require regression tests.
13. Optional bounded local metrics describe service behavior; hardware resource acceptance remains separately measured.
14. One server installation and one owner dashboard are the scope. No public signup, billing, federation or analytics platform.
15. Source identity comes from the approved authenticated session. Dashboard login uses a distinct exact owner identity. Revoked devices cannot ingest, and dashboard credentials cannot administer inference accounts.

The current implementation uses Go's standard library and the existing `modernc.org/sqlite` dependency. No new runtime dependency or license is introduced. OpenTelemetry Collector configuration is optional operator documentation, not a bundled SDK.

## Approved revision: automatic reporting (2026-10-23)

The user requested removal of the Usage sharing section and all reporting alerts/status displays, with reporting built in. This supersedes the original per-device toggle requirement for new reporting enrollment. New approved identities automatically enroll through the existing authenticated usage endpoint. Local-only, signed-out and pending/revoked devices send nothing. Existing disabled bindings and pending deletion/withdrawal remain authoritative and are never automatically reopened. Switching identities discards unsent old-account aggregates before enrollment; it never forwards those totals to another account. No history backfill. Only daily counts/audio duration are allowed; all existing wire, retention, capacity and owner-access restrictions remain.

No reporting UI or dialogs remain in Settings. Reporting failures are silent and isolated from dictation. An immediate background attempt at startup and bounded retries enroll identities approved later without blocking app startup. Owner-side deletion and account revocation remain available. This behavior is documented in release notes even though the app has no reporting prompts.

Constitution check: principle 5 is explicitly amended for this first-party, approved-account metadata only. Principles 1–4 and 6–15 are unchanged; no mandatory cloud dependency, content collection or external analytics SDK is introduced. A disabled local binding remains after deletion solely to prevent automatic re-enrollment; aggregate rows and completion markers are erased.
