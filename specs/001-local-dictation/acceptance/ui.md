# Visual and accessibility acceptance

**Source: owner attestation, 2026-09-16.** The owner exercised the signed
development build at `/Applications/LocalFlow.app` on the Apple M5 MacBook Pro,
macOS 26.6.2 (25G83), and reported the results below. These are the owner's
observations, recorded as given. They are not itemized run logs, screenshots or
instrument captures, and no numeric measurement is claimed here.

## Reported

- The recording indicator appears during a session without taking keyboard focus
  from the app being dictated into.
- Escape cancels a session; the Cancel control is reachable by pointer and by
  keyboard focus.
- The window, history and Settings presentation were exercised in ordinary use
  and reported as correct.

## Scope of this record

Synthetic light and dark component renders are produced on explicit opt-in by
NativePresentationTests. Screenshot references from earlier revisions are in
`prototype-captures/` and `compact-settings-captures/`.

Not established here: a VoiceOver pass with recorded rotor and announcement
behavior, reduced-motion comparison captures, multi-display and fullscreen focus
checks, or side-by-side comparison against the pinned design at matching window
dimensions. The owner reported the interface as working; no capture set was
produced for this record.
