# Mac baseline before the extraction (T007)

- Date: 2026-10-01
- Build: `e37c861` (branch `016-ios-dictation-foundation`, no source changes yet)
- Machine: MacBook Pro (Mac17,2), macOS 27.0 (26A428), Xcode 27.0 (27A266a)
- Command: `make check`

## Result

| Step | Result |
| --- | --- |
| `swift format lint`, script syntax, import checks, Python quality tests | pass |
| Go server tests and vet | pass |
| Mac XCTest (`LocalFlow` scheme) | **1697 passed, 30 skipped, 0 failed** (from the `.xcresult` summary) |
| Remote log scan | pass |
| Standalone `flowd-speech` build | **fail**, before any change |

The standalone worker build failed with:

```text
error: failed creating index directory failed to create directory
'-I/Users/oliver/Programming/local-flow/build/SpeechWorker/Debug/include/v5/records': Read-only file system
```

Xcode 27 passes a malformed index-store path to clang for this legacy `-target … SYMROOT=…` build. It is an environment issue, not a code issue: the same command with `COMPILER_INDEX_STORE_ENABLE=NO` builds cleanly. `scripts/test.sh` now passes that setting for the worker build. The index store is only for editor indexing, and the worker build is only a compile check.

The Mac test count to beat after the extraction is **1697 passed**.
