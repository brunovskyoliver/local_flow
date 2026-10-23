# Update implementation and acceptance

Date: 2026-10-23. Local implementation; no publication, deployment, installed-app
replacement, notarization submission or production secret creation.

## Changes

- Added native menu/settings update controls with a single Sparkle owner, optional
  checks, disabled automatic installation/profile submission, and disabled checks
  in development or unconfigured artifacts.
- Added active-work installation deferral covering dictation, unsaved text, model
  provisioning, meeting capture/finalization, phone imports and speaker work. The
  termination delegate refuses updater-triggered termination if work starts again.
- Built Sparkle 2.10.0 from pinned source with a reviewed local transport patch.
  Feed buffering is capped at 1 MiB, archive acceptance at 4 GiB; resource deadlines
  are 30 seconds/30 minutes. HTTPS and redirect checks apply in production. Read
  `packaging/sparkle/README.md` for the progress-callback disk-overrun caveat.
- Added bundled-helper reconciliation before work starts. A loopback-only identity
  endpoint captures the executable SHA-256 once at daemon startup. App startup
  compares the running identity and bundled/script hashes, refreshes enabled
  variant-owned services, and verifies the replacement before recording its stamp.
- Added production signing/notarization/appcast packaging, fail-closed credentials,
  protected-release workflow preparation and manual-bootstrap documentation.
  Homebrew remains available, with its automatic-update declaration.

## Verification recorded

- Pinned patched framework and `sign_update` / `generate_appcast` built locally.
- Actual downloader harness passed exact 1 MiB feed, unknown-length streamed
  overflow rejection, check/download deadline configuration, cancellation,
  HTTPS-downgrade rejection, an actual 30-second stalled-feed timeout and archive
  overflow cancellation. The harness makes loopback requests only and
  forbids cache mutation. It does not claim an actual 4 GiB disk measurement.
- Upstream `SUSignatureVerifierTest`: 5 passed, 0 failed, covering valid/invalid
  signatures and keys. Existing upstream fixture keys only; none created.
- Final app updater/helper suite: 8 passed, 0 failed, including installation
  deferral and cancellation.
- `go test ./cmd/flowd` passed, including loopback identity access/failure tests.
- Shell syntax checks passed; production packaging without configuration failed
  immediately with `Production packaging requires LOCALFLOW_SIGNING_IDENTITY.`
- The current Keychain contains a valid Developer ID Application identity for
  e-Net, s.r.o. (team 944A459UC3). No private key was read or exported.

## Open delivery gates

- A local signed artifact was built at
  `build/distribution/0.99.3/LocalFlow-0.99.3-arm64.zip`. Its extracted app passed
  `codesign --verify --deep --strict`; hardened runtime, bundle identifier and
  Developer ID team 944A459UC3 were verified. Update enablement is false. This
  establishes local signing only. The rebuilt final-source artifact includes the
  downloader redirect fix, strict usage-reply decoding and corrected idle retry
  behavior. It is build 10002 and is 20,366,758 bytes. Archive SHA-256:
  `d79b8a8ea8a0226c10457e86614939d542bf69e827799989b5454d7fb2ac1ec6`.
  It remains a local test artifact, not a notarized publication candidate.
- Full `make check` and shared Settings visual review are tracked in the feature progress report.
- Actual Developer ID bootstrap from existing ad-hoc/Apple Development installs,
  notarization/stapling and signed N-to-N+1 feed installation remain unverified.
- Production feed/key provisioning and protected GitHub environment setup are
  not performed. The prepared workflow can publish only when explicitly run
  with its required credentials and compatible-server attestation.
- Hardware resource targets, peak update disk/memory, clean-Mac permission and
  Keychain transitions, live stale-helper recovery and cross-variant isolation
  remain acceptance work. No resource target is claimed as measured or met.
