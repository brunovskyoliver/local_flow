# US5 acceptance: configure the same app window

**Source: owner attestation, 2026-09-16.** The owner exercised the signed
development build at `/Applications/LocalFlow.app` on the Apple M5 MacBook Pro,
macOS 26.6.2 (25G83), and reported the results below. These are the owner's
observations, recorded as given. They are not itemized run logs, screenshots or
instrument captures, and no numeric measurement is claimed here.

## Reported

- Opening from the menu bar restored the same window from both the closed and
  the minimized state, rather than creating a second window.
- Closing the window did not stop dictation; the shortcut still started a
  session afterwards. Close is not Quit.
- The appearance choice persisted across a quit and relaunch.
- The explicit model Load and Unload controls in Settings worked and reported
  truthful loaded state.

## Scope of this record

Routing, activation policy, minimized restore, close-versus-route and appearance
mapping are covered deterministically by MainWindowRouterTests and
AppPreferencesTests. Model-control admission is covered by SettingsTests.

Not established here: the full signed UI-test matrix in
`apps/macos/LocalFlowUITests/WindowAndSettingsTests.swift`, which does not exist,
and the 30-second manual cooldown observed against a wall clock.
