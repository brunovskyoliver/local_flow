# Compact settings and recorded shortcuts

Verified 2026-09-16 on macOS 26.6.2, Apple Silicon, signed Debug app at `/Applications/LocalFlow.app`.

Settings now hides granted permissions and their heading. A revoked or undetermined permission reappears. Removed model path, version, verification status and standing explanatory text. Installed models show one Load/Unload row; missing models retain Download/Import and bounded progress/cancellation. Download size appears only when the user explicitly requests installation.

Click the shortcut button to record inline. Standard letter, number, function, navigation and keypad keys may be combined with modifiers; modifier-only holds and Fn/Globe are supported. Escape cancels recording. Release the captured chord to install and persist it. Reclick, navigation, app focus loss and a 30-second timeout cancel. A failed install retains the old binding. Function/navigation event flags are normalized so ordinary function keys do not acquire an artificial Fn requirement. The OS keyboard layout supplies printable labels. New recordings distinguish left/right Option, Command, Control and Shift. Older saved bindings retain either-side matching until rerecorded. Media/power keys and Escape as a recorded binding are not supported.

The recorder owns one temporary active event tap, one chord, one timer and one focus observer. The ordinary dictation tap bypasses recognition while recording. The priority tap consumes only exact matching shortcut events; unrelated key contents are never read or logged. Passive Fn-only dictation remains available without Accessibility; recording and priority interception require Accessibility.

## Checks

- Final `make check` passed: 170 XCTest cases passed, zero failed, three opt-in tests skipped. Format, shell, foundation, seven accuracy-script tests, plist and Go checks passed.
- A separate opt-in rendering run passed and produced [light settings](compact-settings-captures/settings-light.png) and dark settings. The synthetic permission example shows only denied Accessibility.
- Live signed UI recorded Option+Shift+9, displayed its actual label and persisted it. Escape and navigation cancellation retained that binding. The original Control+Option+Space binding was restored through the same recorder and remains selected in the final installed build.
- A temporary native probe compiled against the production shortcut sources installed a downstream observer and the priority filter. The matched down/up pair produced exactly one pressed/released sequence and zero downstream matching events. An unrelated down/up pair produced two downstream events. The probe did not start audio capture or save preferences.
- Inspected the [final signed settings window](compact-settings-captures/window-settings.png): approved permissions and model metadata are absent. Opened through the menu-bar Settings command; AeroSpace placed the window in TilingContainer using the existing local rule. No routing or AeroSpace configuration change was needed.

## Priority limits

Apple's [head-insert placement](https://developer.apple.com/documentation/coregraphics/cgeventtapplacement/headinserteventtap) puts a tap before existing taps at the same location. The [event callback](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback) can delete an event. This provides downstream priority, not absolute precedence over macOS reservations, Secure Input, hardware remapping or another app's earlier interception. No universal “priority 1” promise is made. Physical keyboard and full third-party conflict coverage remain distinct from the synthetic-event probe.

## Spec Kit review

T084–T087 cover the user-requested settings and shortcut changes. Spec, plan, design and client/UI contracts record the superseding behavior and platform limits. The active filter changes the earlier pass-through-only shortcut contract with explicit user authorization. Constitution review found no exception: no storage, server, model ownership, audio, dependency or wire-schema changes; temporary resources are bounded and callbacks use the existing bounded control path. Scoped implementation is complete; existing broader accessibility, speech and hardware acceptance tasks remain open.

## Physical modifier verification

The follow-up make check passed with 197 XCTest cases passed, zero failed and three opt-in cases skipped. Regression coverage includes each left/right modifier, opposite-side rejection, both-side cancellation/release, key chords, labels, JSON compatibility and invalid masks. The signed app was rebuilt and installed. A synthetic Right Option press/release through the live inline recorder saved a binding displayed as Right Option; this is now the selected shortcut. Physical keyboard acceptance was not performed. T088–T090 are complete; the existing layout and priority limits still apply.
