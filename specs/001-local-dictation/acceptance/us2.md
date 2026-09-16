# US2 acceptance: recover text and resolve permissions

**Source: owner attestation, 2026-09-16.** The owner exercised the signed
development build at `/Applications/LocalFlow.app` on the Apple M5 MacBook Pro,
macOS 26.6.2 (25G83), and reported the results below. These are the owner's
observations, recorded as given. They are not itemized run logs, screenshots or
instrument captures, and no numeric measurement is claimed here.

## Reported

- Permission paths were exercised. Denied or revoked permissions produced
  specific guidance naming which permission was missing, not a generic error.
- The app was force-quit during a session and relaunched. Text handling across
  that boundary behaved correctly and nothing re-inserted itself on restart.
- Failure and recovery paths were used, including Copy and the recovery actions,
  and the text was recoverable.

## Scope of this record

The owner reported these paths as working without itemizing each scenario in
`quickstart.md`. Deterministic coverage for the same transactions is in
StorageRecoveryTests, UnsavedResultTests, ExplicitInsertionTests and
TranscriptionStoreTests, which run in `make check`.

Not established here: disk-full injection at each individual write point, and
the stale-revision and duplicate-warning matrix beyond what the deterministic
suites already cover.
