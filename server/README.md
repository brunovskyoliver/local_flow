# Go server scaffold

`go run ./cmd/flowd` prints a development version and exits. It opens no ports and loads no models. Go 1.23 is the initial build baseline matching the available toolchain; select a supported release before deploying a network service.

Later specifications add internal/api, config, auth, llm, backup and storage plus migrations as needed. Keep a single process and use launchd; the LLM runtime is separate. No placeholder handlers, authentication scheme or database driver is selected in initialization.

Sotto UI reuse does not add a speech server. LocalFlow captures and recognizes speech offline on the Mac; no Sotto audio upload endpoint is implemented. Go is reserved for optional text processing in a later feature, without gating dictation or replacing local originals. See [ADR 0010](../docs/adr/0010-sotto-ui-local-speech.md).
