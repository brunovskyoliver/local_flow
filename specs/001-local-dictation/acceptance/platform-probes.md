# Platform probes

## Accessibility insertion probe — 2026-09-16

The standalone harness compiled with Swift on arm64 macOS 14 deployment target from `CapturedTarget.swift` and `TextInsertionService.swift`. It was run only against the dedicated fixtures `/tmp/LocalFlow-AX-Probe.txt` in TextEdit and `/tmp/LocalFlow-AX-Probe.html` in Safari. The harness checked the frontmost bundle and window title before capture or mutation and compared `NSPasteboard.general.changeCount` before and after.

Host: macOS 26.6.2 arm64. TextEdit 1.20; Safari 26.6.2.

Both runs aborted before dispatch:

| Fixture | Bundle/title check | Selected-text writable | Result |
| --- | --- | --- | --- |
| TextEdit `LocalFlow-AX-Probe.txt` | passed (`com.apple.TextEdit`, title contains `LocalFlow-AX-Probe`) | app-level focused element reported `true`; service capture did not reach it | aborted: system-wide focused element returned `kAXErrorNoValue` |
| Safari `LocalFlow-AX-Probe.html` | passed (`com.apple.Safari`, title contains `LocalFlow AX Probe`) | app-level focused element reported `true`; service capture did not reach it | aborted: system-wide focused element returned `kAXErrorNoValue` |

At the time of this probe, `SystemTextAccessibilityAdapter.captureTarget()` queried only `AXUIElementCreateSystemWide()` for `kAXFocusedUIElementAttribute`. On this host the corresponding application AX elements were available and writable, but the system-wide query returned no focused element. No text was dispatched, no fixture content was changed, and clipboard change count remained untested because capture stopped first. This is a blocked CLI probe and does not establish signed-app or production UI behavior.

The subsequent implementation adds a guarded frontmost-application focus fallback,
with PID/launch/window checks and revalidation before mutation. This corrected
adapter has deterministic tests but has not repeated the signed native probe.

## Signed standalone rerun — 2026-09-16

The corrected production adapter was exercised through the reproducible
[`scripts/probe-insertion.swift`](../../../scripts/probe-insertion.swift) harness.
This supersedes the capture blockage above for these runs, but does not establish
production-app acceptance.

Host: MacBook Pro `Mac17,2`, Apple M5, 32 GB, arm64 macOS 26.6.2 (25G83).
TextEdit 1.20, Safari 26.6.2, Google Chrome 153.0.8010.48.
Compiler: Apple Swift 6.3.1 (`swiftlang-6.3.1.1.2`), deployment target macOS 14.
The standalone Mach-O executable was ad-hoc signed with identifier
`local.localflow.insertion-probe`, no TeamIdentifier, no bound Info.plist and no
app bundle. Existing Accessibility permission allowed it to capture targets; no
permission prompt was requested. This signing identity and permission context
are distinct from the production LocalFlow app.

The harness checks the frontmost bundle and exact app-level focused-window title
before calling the actual `SystemTextAccessibilityAdapter.captureTarget()`.
It verifies the known synthetic fixture text with a bounded range read, checks
identity, sets only that fixture's caret/selection, recaptures the same element,
and calls `TextInsertionService.insertOnce` once. It sends no global keystrokes
and never writes the clipboard. Selection mode requests the first nine UTF-16
characters. No user document was targeted.

Fresh dedicated fixtures were created under `/tmp/LocalFlow-AX-Probe-20260916-*`.
Text fixtures contained exactly `LocalFlow insertion probe fixture.` followed by
one newline. Browser fixtures contained that same text in an autofocus textarea.
Safari's exact AX window titles included the `Personal — ` profile prefix;
Chrome's ended with ` - Google Chrome`. An initial Safari title mismatch and an
initial Chrome launch/focus mismatch aborted before dispatch; reruns followed
only after the dedicated fixture window matched.

| Target and fixture | Mode | Actual outcome | Clipboard change count | Acceptance |
| --- | --- | --- | --- | --- |
| TextEdit `LocalFlow-AX-Probe-20260916-caret.txt` | Caret | `confirmed` | 0 | Passed standalone probe |
| TextEdit `LocalFlow-AX-Probe-20260916-selection.txt` | Selection | `confirmed` | 0 | Passed standalone probe |
| Safari `LocalFlow-AX-Probe-20260916-caret.html` | Caret | `uncertain(unsupported)` | 0 | Failed confirmation |
| Safari `LocalFlow-AX-Probe-20260916-selection.html` | Selection | `uncertain(unsupported)` | 0 | Failed confirmation |
| Chrome `LocalFlow-AX-Probe-20260916-chrome-caret.html` | Caret | `uncertain(unsupported)` | 0 | Failed confirmation |
| Chrome `LocalFlow-AX-Probe-20260916-chrome-selection.html` | Selection | Could not establish requested selection; aborted before insertion | Not sampled after abort | Blocked/unrun insertion |

Additional Safari fixtures `-diagnostic.html` and `-delayed.html` isolated the
failed caret result. Bounded readback queries returned AX success but did not
match the inserted text; the reported selection remained `{0, 0}`. The delayed
query, 250 ms after dispatch, gave the same result. Chrome's caret diagnostic
also returned AX success with mismatched inserted text and selection `{0, 0}`.
These observations do not justify upgrading an uncertain result to success or
retrying the mutation. The probe did not collect the setter's AX return code,
which the production adapter deliberately treats as insufficient confirmation.

Build and signature commands, run from the repository root:

```sh
swiftc -parse-as-library -target arm64-apple-macosx14.0 \
  apps/macos/LocalFlow/Core/Insertion/CapturedTarget.swift \
  apps/macos/LocalFlow/Core/Insertion/TextInsertionService.swift \
  scripts/probe-insertion.swift -o /tmp/localflow-insertion-probe
codesign --force --sign - --identifier local.localflow.insertion-probe \
  /tmp/localflow-insertion-probe
codesign -dvv /tmp/localflow-insertion-probe
```

Open a fresh dedicated fixture first, then run the corresponding command without
changing focus:

```sh
/tmp/localflow-insertion-probe com.apple.TextEdit \
  LocalFlow-AX-Probe-20260916-caret.txt caret
/tmp/localflow-insertion-probe com.apple.TextEdit \
  LocalFlow-AX-Probe-20260916-selection.txt selection
/tmp/localflow-insertion-probe com.apple.Safari \
  'Personal — LocalFlow-AX-Probe-20260916-caret' caret
/tmp/localflow-insertion-probe com.apple.Safari \
  'Personal — LocalFlow-AX-Probe-20260916-selection' selection
/tmp/localflow-insertion-probe com.google.Chrome \
  'LocalFlow-AX-Probe-20260916-chrome-caret - Google Chrome' caret
/tmp/localflow-insertion-probe com.google.Chrome \
  'LocalFlow-AX-Probe-20260916-chrome-selection - Google Chrome' selection
```

The final diagnostic harness compiled and passed `swift format lint --strict`.
SHA-256 of that ad-hoc signed executable:
`4497c186eca9ad88116f6b4bb1f497227e3acae2e45d6a2801d5bcf45e1733bc`.
Production source hashes at probe time:

- `CapturedTarget.swift`: `69a661034745396248a971dd29baf1c3f9b6ebe09704da466164715233fff34d`.
- `TextInsertionService.swift`: `3f125fb2081761eae943721fc8248cf06cca821ad4c27a09eff76c8f9539836b`.

There was no Git HEAD commit in this checkout; these hashes identify the tested
sources. The harness gained read-only diagnostics between initial probes and the
final Safari delayed run; the production insertion sources were unchanged.

SC-002 browser support remains failed, and T004/T024 must remain unchecked.
Production signed-app focus, permission revocation, changed/secure targets,
non-activating indicator/confirmation, real shortcut events, and the complete
dictation pipeline remain unrun here. No model assets, consented speech,
accuracy tests, runtime loading or resource measurements were used. A browser
insertion design revision is needed before claiming required browser support;
no clipboard, global typing, whole-field replacement, or relaxed target checks
were added to make the probe pass.

## Closure investigation, 2026-09-16

On the same host, the unchanged production insertion adapter again returned
`uncertain(unsupported)` for Safari textarea caret insertion. A diagnostic build
then recorded the selected-text setter result without changing dispatch behavior:
AX status was `0` (success), bounded readback did not match, selection remained
`{0, 0}`, clipboard delta was zero, and the probe exited 10. Selection replacement
also returned AX success and failed readback even after two seconds, with selection
still `{0, 9}` and clipboard delta zero. The setter therefore cannot establish
support, and a longer readback delay did not resolve this failure.

Dedicated fixtures: `/tmp/LocalFlow-AX-Probe-closure-caret.html` and
`/tmp/LocalFlow-AX-Probe-closure-selection.html`. Diagnostic source copies are
retained under `build/acceptance-us1/browser-diagnostics/`. They differ only in
printing the setter status and, for the delayed harness, the observation delay.
No production insertion source changed. Chrome and an experimental Safari marker
operation aborted at the frontmost-app guard before dispatch during this run;
those attempts establish no additional browser support evidence.

Source investigation found that current WebKit routes selected-text assignment
to `setSelectedText`, whose AccessibilityObject base implementation is empty.
This is consistent with the observed no-op, but the upstream main branch is not
proof of the installed Safari binary's exact implementation. A separate marker
replacement operation exists; it has not been validated for production use.
Sources: [WebKit wrapper](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/accessibility/mac/WebAccessibilityObjectWrapperMac.mm),
[base implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/accessibility/AccessibilityObject.h).
SC-002 and T004/T024 remain open. No retry, clipboard or whole-field fallback was added.

### Apple Development-signed launch

The production app and UI-test runner were built with Apple Development signing,
TeamIdentifier `QUB47S3XTF`, bundle `org.localflow.LocalFlow`, hardened runtime,
on this M5/macOS 26.6.2 host. `LocalFlowPlatformProbes` passed **1 test, 0 failures,
0 skips**, confirming background launch and termination only.

```sh
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj \
  -scheme LocalFlowPlatformProbes -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/SignedAcceptance \
  DEVELOPMENT_TEAM=QUB47S3XTF CODE_SIGN_IDENTITY='Apple Development' test
```

Result bundle: `build/SignedAcceptance/Logs/Test/Test-LocalFlowPlatformProbes-2026.09.16_17-05-26-+0200.xcresult`.
The user explicitly requested tests on this machine only and no macOS 14 testing.
The deployment target remains 14; macOS 14 execution remains unrun.
## Owner acceptance, 2026-09-16

The owner exercised the signed development build on the Apple M5 MacBook Pro,
macOS 26.6.2 (25G83), and reported the results below. Recorded as given; the
measurements and probe results above are unchanged.

- Fn/Globe and recorded alternative bindings all start and stop dictation in the
  signed app, and other Fn combinations continue to reach macOS.
- Target-bound insertion is confirmed in TextEdit and in a browser. The harness
  results above stand as what that standalone probe observed; the signed-app
  behavior is recorded in `us1.md`.
