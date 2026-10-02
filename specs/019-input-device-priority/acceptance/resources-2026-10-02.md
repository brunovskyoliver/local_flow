# Feature 019 resources and network check, 2026-10-02

- Date: 2026-10-02
- Mac model: Mac17,2
- macOS: 27.0 (26A428)
- iPhone: not used for this record
- LocalFlow build: uncommitted working tree on `t3code/phone-audio-relay-feasibility`, based on `d034237`

## FR-017: no network code (T066)

Checked by searching the feature diff (changed and new `.swift`, `.c` and `.h` files) for `URLSession`, `URLRequest`, `NWConnection`, `NWPathMonitor`, `import Network`, `socket(` and `CFStream`.

Result: no matches. The only URL the feature adds is the "Apple's requirements ›" link in Settings › Microphones (`https://support.apple.com/HT213244`), which macOS opens in the browser when the user clicks it. LocalFlow opens no connection of its own for this feature.

## SC-001: start latency (T064)

Unmeasured. Needs 50 dictations on this build and 50 on a pre-feature `main` build with a wired or built-in microphone ranked first (quickstart §8).

## SC-006: recording overhead per device kind (T064)

Unmeasured. Needs a 60 s dictation each on the built-in mic, a USB mic and the iPhone Microphone, read from the diagnostics snapshot (quickstart §8).
