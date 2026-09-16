# Sotto reuse checkpoint

Date: 2026-09-16.

The source snapshot is pinned to `c1d5f0bbaff19a1559621943dff49ba89b4a96a0` in `third_party/sotto`, with upstream license and provenance metadata. The existing native application adapts Sotto's sidebar, palette and dark sidebar material, including reduced-transparency and increased-contrast behavior. LocalFlow identity uses the system waveform; upstream picture assets and brand icon were not adopted.

The initial shell has Dictation, History and Settings destinations backed by AppServices. Open LocalFlow preserves the selected destination (Dictation initially); Settings selects Settings. Existing local setup, history and recovery actions remain connected. The upstream audio client/server and inference worker are outside the app target. Go remains a separate version-only scaffold.

Validation reported by the integration run: `make check` passed, including repository checks, seven Python tests, deterministic XCTest, Go test/vet and unsigned Xcode build. The upstream MIT notice was verified in the built app's Resources. The local integration log is `/tmp/localflow-sotto-check.log` and is not a durable repository artifact.

This checkpoint completes T063–T065 only. Advanced history/settings/first-run/indicator work remains tracked in T066 and the original open tasks. Signed routing/focus, rendered appearance, accessibility interaction and observed offline microphone recording acceptance have not been established by this build. T067 remains open. No new hardware, resource or speech-accuracy measurement is claimed.
