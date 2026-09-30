# Contract: LocalFlowCore package boundary

`packages/LocalFlowCore` is the only code shared by the Mac app, the `flowd-speech` worker and the iOS app. This contract defines what may live in the package, and what each consumer links.

## Package

- `swift-tools-version: 6.0`. Platforms: `.macOS(.v14)`, `.iOS(.v26)`.
- Dependencies are pinned with `exact:`, matching the Mac project's current pins:
  - GRDB.swift 7.10.0
  - FluidAudio 0.15.7
- Any change to these pins is a separate change with its own licence review, as the constitution's principle 14 requires.

| Product / target | Contains | Depends on | Linked by |
| --- | --- | --- | --- |
| `LocalFlowSpeech` | Speech and model boundaries, the FluidAudio engine, vocabulary boost, meeting language, the lifecycle coordinator, model descriptor and provisioner, dictionary change, chunk planner, transcript assembler, audio spool | FluidAudio | Mac app, `flowd-speech`, iOS app |
| `LocalFlowCore` | `LocalFlowPaths`, the transcription store and entry, history migrations, vocabulary, dictionary usage and term suggestion stores, the correction types they need, the transcript normalizer, provenance, windowed transcriber and pipeline identity (they need `VocabularySnapshot`), and the value types the migrator and stores reference (rewrite attempt models, remote failure reason, app context record, meeting state enums) | `LocalFlowSpeech`, GRDB | Mac app, iOS app |
| `LocalFlowCoreTests` | Tests for code introduced by this feature only | both | `swift test` |

The keyboard extension links neither product.

## Rules (enforced by `scripts/check-core-imports.sh` in `make check`)

1. No `import` of AppKit, UIKit, SwiftUI, Carbon, ApplicationServices, ScreenCaptureKit, ServiceManagement or Cocoa anywhere in `packages/LocalFlowCore/Sources`.
2. No `import GRDB` in `Sources/LocalFlowSpeech`.
3. No `Process`, `NSWorkspace`, `homeDirectoryForCurrentUser` or `CGPreflight*` in package sources.
4. Platform services enter through parameters, never through `#if os(...)` branches:
   - the English-word check is passed to `FluidAudioEngineFactory` as `(Set<String>) -> Set<String>`
   - paths come in as `LocalFlowPaths`
   - spool capacity is an init parameter
   - capture and insertion stay in each app
5. A file moves into the package only if the iOS dictation path needs it, or something it needs does. Meeting runtimes, diarization, identification, intelligence, rewrite transport, remote transport, context reading, insertion and shortcuts stay in the Mac app.

## Compatibility promises to the Mac (FR-002)

- `HistoryMigrations.migrator()` keeps exactly the 16 migrations, with the same identifiers in the same order, from `history-v1` through `dictionary-usage-v16`. A test freezes the list.
- `LocalFlowPaths.mac(identity:)` returns byte-identical URLs to today's `AppIdentity` for the everyday build and for the Dev build. A test pins them.
- `AudioSpool(rootDirectory:sessionID:)` without a capacity argument keeps the 16 MiB cap.
- Public signatures are today's internal signatures made `public`. No behaviour changes ride along with the move.
