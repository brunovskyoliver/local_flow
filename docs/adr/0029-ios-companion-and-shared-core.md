# 0029: iOS companion app and a shared LocalFlowCore package

## Status

Accepted, 2026-10-01. Amends ADR 0001. The signing and handoff spike passed on the iPhone (Feature 016, `specs/016-ios-dictation-foundation/acceptance/spike.md`).

## Context

ADR 0001 chose one native macOS app and said to "extract packages only when a real boundary appears". Feature 016 adds an iPhone app with a custom keyboard. It must transcribe exactly as the Mac does, keep the same History and Dictionary schema, and apply the same Dictionary rules (FR-001), without changing anything the Mac user sees (FR-002).

The code that does this already exists in the Mac app. The `flowd-speech` worker (Feature 014) compiles part of it by file reference, and `scripts/check-speech-worker-imports.sh` keeps that part free of AppKit, SwiftUI and GRDB. A second platform is the real boundary ADR 0001 was waiting for.

## Decision

- **One local Swift package, `packages/LocalFlowCore`, with two library targets.**
  - `LocalFlowSpeech`: the worker's recognition sources plus the pure transcript code the dictation path needs. It depends on FluidAudio only, so the worker still links no GRDB.
  - `LocalFlowCore`: the History and Dictionary stores, the migrator, the correction types and the value types the migrator and stores reference. It depends on `LocalFlowSpeech` and GRDB.
  - The Mac app links both. `flowd-speech` links `LocalFlowSpeech`. The iOS app links both. The keyboard extension links neither.
- **Files move with `git mv`.** Nothing is rewritten beyond `public` modifiers, explicit `public init`s where a memberwise init crosses the module boundary, and the platform seams below. A type that the migrator or stores need but that lives in a file with Mac-only code is cut into its own file first.
- **Platform services enter through parameters, not `#if os(...)`.** The English-word check is a closure passed to `FluidAudioEngineFactory`. Paths come in as `LocalFlowPaths`. Spool capacity is an `AudioSpool` init parameter.
- **`apps/ios` is a separate Xcode project** with the `LocalFlowPhone` app and the `LocalFlowKeyboard` extension. Code shared only by those two targets (the handoff codec and the Sotto tokens) lives in `apps/ios/Shared` and is compiled into both.
- **`scripts/check-core-imports.sh` enforces the boundary in `make check`:** no AppKit, UIKit, SwiftUI, Carbon, ApplicationServices, ScreenCaptureKit, ServiceManagement or Cocoa in the package, no GRDB in `LocalFlowSpeech`, no `Process`, `NSWorkspace`, `homeDirectoryForCurrentUser` or `CGPreflight`, and no `#if os(`.

## Consequences

- ADR 0001 now describes one macOS app and one iOS companion that share a package. `AGENTS.md` says so, so agents don't treat the phone app as out of scope.
- About 150 declarations become `public`. Mac files that use moved types import the package modules. Mac tests reach package internals with `@testable import`.
- The Mac database, its migrations and its file locations don't change. `MacCompatibilityTests` freezes the migration list and the paths.
- The storage closure is wider than the portable dictation path alone: `TranscriptionStore` also stores rewrite attempts, dictation context rows and remote failure reasons, and the migrator builds CHECK constraints from meeting, diarization, identification and analysis enums. Those value types move with it, each cut from its Mac file. The runtimes that produce them stay in the Mac app.
- The keyboard never links FluidAudio or GRDB, which keeps it inside the extension memory limit.

## Alternatives considered

- **Compile the same files into the iOS target by file reference**, as the worker does. No `public` pass and no Mac churn, but "exists once" would depend on two projects listing the same paths, and an iOS-only edit could break the Mac without any compile-time boundary.
- **One package target.** It would force GRDB onto the worker.
- **A separate dictation-only schema for the phone.** It forks storage and breaks FR-001.
- **A third target for design tokens that the keyboard links.** A whole target for one file, and moving the Mac palette risks visible Mac change.
