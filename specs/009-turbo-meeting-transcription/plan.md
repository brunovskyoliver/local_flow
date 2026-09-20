# Plan: Turbo meeting transcription

## Technical context
Swift/macOS client with a bundled native C++ whisper.cpp helper, existing SQLite transcript store and ModelProvisioner. No server changes. Model weights remain outside the app. Native helper source derives from the pinned Sotto engine; no Sotto application or HTTP server is adopted.

## Architecture
Add a distinct meetingTranscription workload and factory to ModelLifecycleCoordinator. Default speechRecognition retains Parakeet. Finalizer receives explicit Turbo identity and 120-second geometry. Its bounded decoder and persistence batches remain unchanged; assembler receives a separate window bound. Acquire a valid model before replacing an existing final pass. Existing mid-pass replacement behavior is retained and failure remains visible.

WhisperMeetingRuntime writes a bounded temporary WAV, sends one JSONL request, parses bounded native segment output, and exposes TranscriptionWindow. Dedicated blocking IO stays off cooperative executors. Cancellation kills and joins the helper before lease release. Request language is auto; context resets between requests but rolls internally through a request. Detect obvious adjacent phrase loops, retry in two 60-second windows, and fail on repeated failure.

Settings exposes separate Turbo installation and verification. AppServices uses Turbo for finalization only. Model descriptor permits strictly pinned HTTPS Hugging Face source URLs for assets from separate repositories, with SHA-256 and size verification still mandatory.

## Constitution check
Native client: pass, bounded native helper is packaged with app, no Python/Node runtime.
Memory/streaming: pass by design, 1,920,000 samples per request, fixed decoder blocks, existing bounded persistence, capped output, no complete-meeting buffer. Measurements remain separate.
Ownership: pass, coordinator alone constructs runtimes, excludes all heavy workloads, cancellation joins before release.
Privacy/local-first: pass, recordings and recognition remain local; explicit model provisioning only. Logs exclude text/audio.
Persistence/recovery: pass, existing SQLite pass identity; acquire before destructive replacement; stale geometry restarts; source audio preserved.
Dependencies/scope: justified in ADR 0019; preserve actual upstream license texts. No VoiceInk code, server or roadmap work. No constitution exception required.

## Implementation boundaries
Runtime/packaging: new WhisperMeetingRuntime, Sotto worker meeting protocol, build script and Xcode phase.
Lifecycle/finalizer: workload, factory, identity, bounded final assembler and pre-admission acquisition.
Provisioning/UI: ModelDescriptor/ModelProvisioner source URLs, Turbo manifest, AppServices and Settings.
Docs: provenance, notices, ADR, feature artifacts.

## Validation
Focused tests for lifecycle exclusion/cancellation, unavailable-model preservation, larger final windows, helper failure/limits/repetition and pinned URLs. Production-runtime smoke on existing excerpt. make check after integration. Inspect actual diff independently. Hardware RSS and long meeting acceptance remain distinct from automated checks.


### Recovery refinement from the full meeting replay

The first full run encountered a loop at 600 seconds into the second recording
stretch. Both the 120-second request and a 60-second retry repeated a stock phrase;
a 30-second request also lost speech. Isolated 15-second requests recovered spoken
content. Recovery now has two bounded levels: split the main request in half,
then split only a still-repeating half into four pieces. With a 120-second main
window, final pieces are at most 15 seconds. Maximum work is 11 requests and
360 seconds of input including retries. Reject repetition in both pieces and
the combined result. The main window geometry and persisted resume boundaries
remain unchanged, so already successful windows can resume safely.
