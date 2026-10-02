# Architecture

LocalFlow is a native macOS voice application with the approved prototype interface and local speech services. Feature 001 has local dictation implementation and deterministic test evidence; remaining UI work and hardware acceptance are tracked in its tasks. Feature 003 adds optional text rewriting through the separate Go server. Live acceptance is tracked separately from implementation checks.

```text
Prototype-matched SwiftUI / AppKit presentation
    -> DictationCoordinator
        -> bounded AVAudioEngine capture
        -> ModelLifecycleCoordinator -> TranscriptionEngine -> FluidAudio / CoreML
        -> TextInsertionService -> Accessibility / explicit copy
        -> SQLite (GRDB) + filesystem
    -> URLSession -> LocalFlow Go API -> independent LLM process (opt-in rewriting)
```

The client owns audio capture, STT, future meetings, diarization, embeddings, identification and local data. The separate server provides rewriting; summaries and archive/backup remain future work. Core client workflows must not depend on that server.

The Mac app is one Xcode application target. Features own orchestration and UI; Core owns native/AI/storage boundaries. Protocols belong at those boundaries, not around every type. Runtime adapters can only be created through the lifecycle coordinator.

The supported platform is macOS 26+ on Apple Silicon. The build keeps a macOS 14 deployment target, which is below that floor and costs nothing; supported means tested, not merely buildable. Later ScreenCaptureKit microphone integration may require newer APIs or an AVAudioEngine microphone path; that belongs to a later meeting specification.

See [audio](audio-pipeline.md), [lifecycle](model-lifecycle.md), [storage](storage.md), [server](server.md), [ADRs](../adr/README.md), and [budgets](../performance/memory-budget.md). The [roadmap](../roadmap.md) separates future capabilities.

[ADR 0010](../adr/0010-sotto-ui-local-speech.md) records the pinned Sotto source reuse. Views call existing LocalFlow services; upstream server/client, server history and inference workers are outside the app build. Transcriptions and Settings share one window. Recording and transcription do not depend on server availability; Go provides the optional Feature 003 rewrite API.

The HTML prototype in `specs/001-local-dictation/design/approved-prototype.html` now governs appearance. Earlier Sotto appearance choices are superseded; retained adapted code keeps its attribution. This presentation revision adds no service, storage or wire-schema boundary.

## Optional rewriting

After the faithful transcript is committed and the ASR lease is finished, `RewriteCoordinator` admits an eligible attempt using an immutable settings snapshot. The client waits for a validated result, then inserts it once; failure, timeout or cancellation uses the faithful transcript. Disabled rewriting, Exact mode and Shift held on shortcut release make no rewrite transport call. History retries save attempts without inserting automatically.

`RewriteClient` uses an ephemeral URLSession and the shared v1 schemas. At most two attempts run globally and one per dictation; excess work is refused without a queue or attempt row. Flowd shields protected values, streams from a separate inference process and restores placeholders before returning a result. No rewrite model is loaded in the client. See [protocol ADR](../adr/0013-rewrite-protocol-v1.md), [delivery ADR](../adr/0014-no-background-text-replacement.md) and [acceptance tasks](../../specs/003-server-rewriting/tasks.md).

## Shared package and iOS companion (Feature 016)

[ADR 0029](../adr/0029-ios-companion-and-shared-core.md) moves the portable dictation code into one local Swift package, `packages/LocalFlowCore`, with two library targets:

- `LocalFlowSpeech` depends on FluidAudio only: the model descriptor and provisioner, `ModelLifecycleCoordinator`, `FluidAudioEngine`, `AudioSpool`, `ChunkPlanner`, `TranscriptAssembler` and `VocabularyBoost`. The `flowd-speech` worker links it, so the worker still has no GRDB.
- `LocalFlowCore` depends on `LocalFlowSpeech` and GRDB: `WindowedTranscriber`, `TranscriptNormalizer`, `TranscriptionStore`, `VocabularyStore`, `HistoryMigrations`, `LocalFlowPaths` and the value types the migrator and stores reference.

The Mac app and the iOS app link both; the keyboard extension links neither. Platform services come in as parameters rather than `#if os(...)`. `scripts/check-core-imports.sh` keeps AppKit, UIKit, SwiftUI and the other platform frameworks out of the package, and GRDB out of `LocalFlowSpeech`.

`apps/ios` is a separate Xcode project with the `LocalFlowPhone` app and the `LocalFlowKeyboard` extension. The app records, transcribes and stores; the keyboard only exchanges small JSON handoff files with it through the App Group, using code in `apps/ios/Shared`.

```text
LocalFlowKeyboard -> App Group handoff files -> LocalFlowPhone
    LocalFlowPhone -> PhoneServices
        -> bounded AVAudioEngine capture -> AudioSpool
        -> PhoneDictationPipeline -> ModelLifecycleCoordinator -> FluidAudio / CoreML
        -> WindowedTranscriber + TranscriptNormalizer (shared with the Mac)
        -> TranscriptionStore / VocabularyStore (SQLite, GRDB)
```

The phone uses the same windows, assembly, Dictionary rules and History schema as the Mac. See [storage](storage.md#phone-database-feature-016) and [lifecycle](model-lifecycle.md#phone-leases-and-keep-ready-feature-016).

## System entry points on iOS (Feature 017)

[ADR 0030](../adr/0030-ios-system-entry-points.md) adds a third iOS target, `LocalFlowWidgets`, a WidgetKit extension embedded in the app. It holds the dictation control (Control Center, Lock Screen, Action Button) and the Live Activity views for the Lock Screen and the Dynamic Island. It links neither package product and runs no audio.

The intent types live in `apps/ios/Intents/` and are compiled into both the app and the widget, so the system sees one type and routes it to the app. Every intent adopts `LiveActivityIntent`; the dictation toggle also adopts `AudioRecordingIntent`. Without `LiveActivityIntent`, iOS ran `perform()` in the widget extension. `perform()` reaches the app through `IntentHandlers.current`, a static slot that only the app sets at launch; in any other process it is nil and the intent returns an error without recording.

```text
Control / Action Button / Shortcut / Live Activity button
    -> ToggleDictationIntent, EndSessionIntent, CopyLastDictationIntent (apps/ios/Intents)
    -> app process, launched in the background if needed
        -> PhoneIntentHandler -> SessionController (origin = control, one-shot)
            -> same capture, pipeline and lease as a keyboard dictation
            -> onControlResult -> History -> clipboard (or one pending write) -> ResultNotifier
        -> ActivityController -> ActivityKit -> LocalFlowWidgets (Live Activity views)
```

A control recording always has a Live Activity; if Live Activities are off or the request fails, the intent records nothing. iOS drops clipboard writes made while the app is in the background, so the app holds the newest transcript as one pending write and applies it when LocalFlow becomes active. History is written before any delivery, and a save that fails before the first unlock is held, retried, and keeps its spool until it lands.
