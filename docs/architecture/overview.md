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

Start with one Xcode application target. Features own orchestration and UI; Core owns native/AI/storage boundaries. Protocols belong at those boundaries, not around every type. No separate Swift packages yet. Runtime adapters can only be created through the lifecycle coordinator.

The supported platform is macOS 26+ on Apple Silicon. The build keeps a macOS 14 deployment target, which is below that floor and costs nothing; supported means tested, not merely buildable. Later ScreenCaptureKit microphone integration may require newer APIs or an AVAudioEngine microphone path; that belongs to a later meeting specification.

See [audio](audio-pipeline.md), [lifecycle](model-lifecycle.md), [storage](storage.md), [server](server.md), [ADRs](../adr/README.md), and [budgets](../performance/memory-budget.md). The [roadmap](../roadmap.md) separates future capabilities.

[ADR 0010](../adr/0010-sotto-ui-local-speech.md) records the pinned Sotto source reuse. Views call existing LocalFlow services; upstream server/client, server history and inference workers are outside the app build. Transcriptions and Settings share one window. Recording and transcription do not depend on server availability; Go provides the optional Feature 003 rewrite API.

The HTML prototype in `specs/001-local-dictation/design/approved-prototype.html` now governs appearance. Earlier Sotto appearance choices are superseded; retained adapted code keeps its attribution. This presentation revision adds no service, storage or wire-schema boundary.

## Optional rewriting

After the faithful transcript is committed and the ASR lease is finished, `RewriteCoordinator` admits an eligible attempt using an immutable settings snapshot. The client waits for a validated result, then inserts it once; failure, timeout or cancellation uses the faithful transcript. Disabled rewriting, Exact mode and Shift held on shortcut release make no rewrite transport call. History retries save attempts without inserting automatically.

`RewriteClient` uses an ephemeral URLSession and the shared v1 schemas. At most two attempts run globally and one per dictation; excess work is refused without a queue or attempt row. Flowd shields protected values, streams from a separate inference process and restores placeholders before returning a result. No rewrite model is loaded in the client. See [protocol ADR](../adr/0013-rewrite-protocol-v1.md), [delivery ADR](../adr/0014-no-background-text-replacement.md) and [acceptance tasks](../../specs/003-server-rewriting/tasks.md).
