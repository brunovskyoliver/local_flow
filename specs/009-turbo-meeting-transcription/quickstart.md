# Validation

1. Build the native helper and macOS app with `make macos`.
2. Install the pinned Turbo package through Settings (download or folder import), then verify it.
3. With network disconnected, transcribe a saved meeting. Check final pass identity is Turbo. Check live/dictation remains Parakeet.
4. Attempt retranscription with unavailable model and confirm prior final text remains readable.
5. Cancel an active pass, then retry and verify no orphan helper or temporary audio remains.
6. Run `make check`; keep actual test totals and smoke evidence in acceptance.md.

Do not rewrite original user recordings for validation. Use isolated copies or test fixtures. Hardware memory acceptance requires a separately recorded measurement run.
