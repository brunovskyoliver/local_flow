# Data model

Reuse ContextSnapshot and CapturedTarget; add only bounded capture diagnostics and a reference fingerprint needed to validate the captured after-cursor span. No whole-document persistence or extra model runtime.

Release descriptor: version, increasing build, minimum OS, immutable archive URL, archive byte length, Ed25519 signature. States idle/checking/available/downloading/ready/deferred/installing/failed. One descriptor/download active. Development builds cannot install production updates.

UsageConsent: verified user/device, monotonic epoch and random grant UUID, enabled flag, effective time, withdrawal/deletion status. A new grant advances the epoch; withdrawn grants never reopen.

UsageDay: verified user/device, consent epoch, UTC day, revision, local/remote completion counts, audio milliseconds and coverage. Key and validation follow [contract](contracts/usage.md). SQLite migration and transactional completion writes are required. Cumulative snapshots replace lower revisions, never add them.

CompletionLedger: logical UUID, day and counting outcome, without content. Durable deduplication survives retry and history deletion within bounded retention. On exhaustion, surface incomplete usage rather than silently double-count.

ReportingInstallation: server-generated ID, dedicated credential reference and configured dashboard host. Secrets stay in Keychain or protected host secret storage; database stores only references/hashes where possible.

DeletionTombstone: installation/user/device/epoch scope, monotonically increasing generation, pending/acknowledged state and expiry after the accepted reporting horizon. Persist before removing rows so retries cannot resurrect them.

DashboardSession: bounded server-side sessions tied to exact configured owner issuer/subject, short expiry, secure HttpOnly SameSite cookie and CSRF protection. Maximum 10 sessions, 8-hour absolute lifetime; logout removes the session. Ordinary user approval grants no dashboard access.

Final control model: one monotonic epoch/grant/control slot per reporting device, including retired devices until acknowledgment and replay expiry. Maximum 1,000 slots across 100 users; no per-grant append-only tombstone queue. Deletion cutoff covers all retained epochs in its scope. Directory projection is capped at 100 rows and 128-scalar/512-byte display labels. Normative transaction, overflow and grant-admission rules are in contracts/usage.md.
