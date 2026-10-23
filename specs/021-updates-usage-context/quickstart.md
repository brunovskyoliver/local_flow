# Validation guide

These steps describe future implementation acceptance. Only baseline checks are runnable before the tasks are implemented.

1. Run `make check`. Keep generated builds in ignored project build directories and transient logs in the session temporary directory. Record results in progress.md.
2. Context: run new XCTest fixtures for dictate/edit/dictate, mid-field insertion, selection replacement, inconsistent reads, after-cursor edits, inaccessible/secure fields and history retries. Exercise the actual target app using the existing Mac app. Run Feature 012 paired evaluation on the configured rewrite model, recording hardware/model/prompt; Ultra is the ASR model. Keep experimental status if its gates fail.
3. Updates: test busy/idle/error transitions with an updater double; generate local release artifacts without publishing. Verify archive signatures, minimum version and helper version reconciliation. A real Developer ID bootstrap and signed second update need private credentials and explicit installation authorization. Test one existing installation plus a clean Mac/account and document permission reapprovals.
4. Usage: Go and Swift fixtures simulate two users/devices, consent epochs, duplicate snapshots, remote fallback, offline replay, disk full, expiry, withdrawal/deletion while offline and revoked sessions. Assert known totals and no content/identity metric labels.
5. Dashboard: run locally against fixture data and a test identity provider. Use T3 preview to inspect owner login, rejected non-owner access, totals, stale/partial states and narrow layouts. Never expose real user data during fixtures.
6. Optional collector: run against local fixture metrics and verify allowlisted labels. Disconnect it and confirm dictation/reporting continue.
7. Collect context latency, idle RSS, reporting overhead and update disk peak on documented hardware. These measurements are separate from deterministic tests.

Production prerequisites: Developer ID Application identity and notarization authentication, protected update-signing key, public feed/archive ownership, owner-controlled dashboard host/TLS and exact OIDC owner identity. Enter credentials privately with the secrets workflow. Prepare artifacts first; request approval only for concrete external publication/deployment or paid setup. Never put secrets into these files.
