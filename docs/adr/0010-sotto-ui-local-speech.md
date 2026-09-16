# ADR 0010: Reuse Sotto UI with local speech

## Status

Accepted, 2026-09-16. Implements the user's explicit choice to keep speech offline on the Mac, reuse Sotto UI, and use Go only for optional text processing.

## Context

[Sotto](https://github.com/davis7dotsh/sotto) has native SwiftUI/AppKit presentation the user wants to reuse. Its client/server recording flow does not match LocalFlow's offline speech requirement. Feature 001 already has local capture, FluidAudio integration, model lifecycle, SQLite history and safe insertion boundaries, with remaining implementation and acceptance work recorded in its task list.

## Decision

Vendor commit `c1d5f0bbaff19a1559621943dff49ba89b4a96a0` in `third_party/sotto` with the upstream MIT license. Adapt selected window/theme and subsequent view source within the existing native application target. Keep LocalFlow identity and bind views to AppServices and existing local protocols. Document copied source and modifications in third-party notices.

Keep AVAudioEngine capture and FluidAudio speech recognition on the Mac. ModelLifecycleCoordinator remains the sole heavy-model owner; existing capture, queue, history and cooldown bounds still apply. Keep safe insertion and local persistence semantics. Do not build SottoController, ServerClient, upstream Swift server, C++ inference worker or upstream server history into LocalFlow.

Use Sotto's native presentation instead of the historical HTML prototype. Keep one window with Dictation, History and Settings destinations. Settings uses local model and permission state. No server connection may gate recording. Go remains separate; optional text processing requires a later specification and versioned shared schema. Feature 001 adds no endpoints or audio upload. Disabled or failed future processing must preserve local originals.

## Constitution check

No exception is required. Principles 1 and 14 are satisfied by native source reuse inside the existing target and pinned MIT provenance. Principles 2, 3 and 6 retain existing bounds and lifecycle ownership. Principles 4, 5 and 7 retain offline speech, local-only audio and SQLite authority. Principles 8 and 11 retain the independent Go service and future versioned text contracts. Recovery, testability and local measurement requirements remain unchanged. No VoiceInk application code is copied. This design check does not establish hardware, memory, speech accuracy or signed UI acceptance.

## Consequences

The downloaded upstream source is a reproducible reference, not a second shipped app or backend. Adapted views need LocalFlow state/actions and accessibility checks. Existing open tasks remain open until their behavior and evidence are complete. Updating the snapshot requires renewed source/license and compatibility review; copying additional files does not authorize new features.

## Alternatives considered

Running Sotto unchanged makes local recording depend on its server. Replacing its server with Go still conflicts with offline Mac recognition. Retaining the old HTML visual direction does not implement the requested UI reuse. Selective native source adaptation preserves the user's chosen appearance and the existing local architecture.
