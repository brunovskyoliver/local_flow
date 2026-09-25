# Contract: context capture and snapshot

Normative for `AppContextReading`, `SystemAppContextReader`, `ContextTermExtractor` and the `dictation_contexts` row. The field shapes are in [data-model.md](../data-model.md).

## Interface

```swift
protocol AppContextReading: Sendable {
  /// Called once per dictation, right after the insertion target is captured.
  /// Never throws; every failure is an outcome. Returns within `deadline` + 20 ms.
  func read(target: CapturedTarget?, settings: ContextSettings, deadline: Duration) async
    -> AppContextCapture   // outcome, snapshot?, bundleID?, durationMs
}
```

The coordinator creates the read task immediately after `insertion.captureTarget()` returns and awaits it only after recognition. The task is cancelled with the dictation. Nothing earlier in `run` waits for it.

## Decision order (first match wins; no text is read before step 6)

1. `settings.enabled == false` → `off`, with no AX call.
2. `AXIsProcessTrusted() == false` → `no_permission`.
3. `target == nil` → `secure_field` if the frontmost focused element's subrole is `AXSecureTextField`, else `no_target`.
4. Bundle ID equals LocalFlow's → `own_app`. Bundle ID in exclusions → `excluded_app`.
5. Set `AXUIElementSetMessagingTimeout` to 0.1 s on the element and window.
6. Read the parts in this order: app name, window title, role/subrole, placeholder, character count, before, selected, after. Each read checks the deadline first. When the deadline is hit → `timed_out` with the parts read so far.
7. Drop field text if the placeholder equals the field's current text. Drop field text if the app is a browser and a parent within 3 levels has role `AXToolbar`.
8. Redact (email, URL, IP, number/amount → `[email]`, `[url]`, `[ip]`, `[number]`), bound each part, extract terms, build canonical JSON and enforce 8,192 bytes.
9. No text part and no title → `nothing_readable` (the snapshot keeps app name, category and field kind). Otherwise → `used`.

## Bounds

| Item | Limit | When exceeded |
| --- | --- | --- |
| Deadline | 250 ms | `timed_out`, partial snapshot |
| AX messaging timeout | 100 ms per call | the call fails, the part is omitted |
| Before cursor | 1,000 characters | keep the part nearest the cursor, cut at a grapheme boundary |
| After cursor | 300 characters | keep the part nearest the cursor |
| Selected text | 2,000 characters | omit the part, add `selected_text` to `truncated` |
| Window title | 200 characters | cut at the end |
| App name | 128 bytes | cut |
| Terms | 40, each ≤ 64 bytes | nearest to the cursor kept |
| Canonical JSON | 8,192 bytes | drop parts in order after, before, selected, title until it fits |
| Toolbar parent walk | 3 levels | stop |

## Never captured

Screenshots or OCR, clipboard, browser address bar, placeholder text, other windows or apps, files, full field values, secure fields, excluded apps, LocalFlow. Browser URLs are never read; the window title is read.

## Term extraction

Follows research D4. Output `Term{text, source, kind}`. A term never matches the redaction patterns and is never in `CorrectionStopwords.commonWords`.

## Privacy and observability

- No snapshot text, title, term or bundle ID in `Logger` output or `ResourceRecorder`.
- Metrics: `context.capture_ms`, `context.outcome` (enum), per-part byte counts, term count, `context.spelling_changes` (count).
- A test runs a capture with sentinel strings and asserts the sentinels never appear in the captured log and metric sinks.

## Row written at commit

One `dictation_contexts` row, in the same transaction as the entry, for every dictation that reaches commit. Outcome `off` rows carry no other data.
