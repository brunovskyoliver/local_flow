# 0001: Native Swift macOS client

## Status

Accepted, 2026-09-16. Amended 2026-09-16 to target Apple Silicon macOS 26+.
Future capabilities remain deferred.

## Context

macOS integration and idle memory constrain the UI runtime.

## Decision

Use one Swift/SwiftUI Xcode application, AppKit where required, native capture and Accessibility. Initially target Apple Silicon macOS 14.

## Amendment, 2026-09-16: supported platform is macOS 26+

The owner confirmed that the development machine is the targeted device and that
support covers macOS 26 and later. macOS 14 was never a device anyone tested or
intended to ship to, so requiring macOS 14 execution as acceptance evidence was
asking for proof about an unsupported platform.

The `MACOSX_DEPLOYMENT_TARGET` build setting stays at 14.0. Nothing in the app
needs a newer API, and lowering the compiler floor below the supported floor
costs nothing. Raising it is a separate decision, needed only when the code
adopts an API introduced after macOS 14.

Constitution check: this narrows the supported platform range. It adds no
dependency, package, target, server endpoint or shared schema, and changes no
source boundary. No constitution principle is affected.

Recorded acceptance artifacts keep the deployment target in force when they ran;
they are historical measurements and were not rewritten.

## Consequences

Native permissions and signing need device tests. No Electron, browser shell, Python or Node runtime. Extract packages only when a real boundary appears.

## Alternatives considered

Electron; cross-platform web shells; early multi-package design.
