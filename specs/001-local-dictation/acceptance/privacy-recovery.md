# Network, privacy and failure acceptance

**Source: owner attestation, 2026-09-16.** The owner exercised the signed
development build at `/Applications/LocalFlow.app` on the Apple M5 MacBook Pro,
macOS 26.6.2 (25G83), and reported the results below. These are the owner's
observations, recorded as given. They are not itemized run logs, screenshots or
instrument captures, and no numeric measurement is claimed here.

## Reported

- The owner checked network behavior and reported that nothing goes out over the
  network during dictation.
- Permission loss and failure handling were exercised; see `us2.md`.

## Scope of this record

The app makes no network request outside explicit model provisioning by
construction: the transcription adapter is local, runtime downloads are
prohibited, and provisioning is an explicit user action. The Go server is not
contacted by the client in Feature 001.

Not established here: a captured traffic log naming the observation tool, its
duration and the process identity under observation. An earlier `nettop` attempt
produced no rows because the signed process had already exited, and privileged
packet tracing was unavailable; that attempt is recorded in `us1.md` and did not
establish anything. This record rests on the owner's check, not on a retained
capture.
