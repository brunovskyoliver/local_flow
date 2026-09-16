# Server boundary

The Go flowd executable is currently a version-only scaffold. It does not listen on a socket or load models. The module name `localflow/server` is local until a public repository namespace is chosen.

Future flow-server owns HTTP API, authentication, configuration, an inference adapter, backup, SQLite metadata and filesystem archive. Use Go's standard library first; add a SQLite driver only with the storage feature and document its native/runtime tradeoffs. Run a compiled executable under launchd. Docker is optional and unnecessary for development.

A separately supervised Ollama, MLX or llama.cpp-compatible service owns LLM weights. Prefer an OpenAI-compatible adapter when practical. The client only knows LocalFlow requests and versioned schemas. Candidate routes are rewrite, meetings/{id}/summary, meetings/{id}/ask, backups/meetings/{id} and health under /api/v1. These are future contracts, not implemented endpoints.

Before network exposure, specify authentication, TLS/VPN trust, Keychain credential provisioning, request size limits, deadlines, concurrency bounds and retry behavior. A LAN is not automatically trusted. Avoid speculative accounts, queues or infrastructure. Summarization receives transcript text; audio upload is not an ordinary inference operation. Backup media transfer requires its own consent and specification.

Inference responses must be size-limited and schema-validated, including referenced participant/segment identifiers against the source transcript. Treat transcript instructions as data. Invalid results remain failed/retryable operations, never guessed structured data. SQLite stores bounded job metadata; streaming media goes to files.

## Sotto adaptation

Sotto supplies native presentation only. LocalFlow does not implement its audio-upload or speech-server API. Feature 001 adds no listener, endpoint or readiness probe. Microphone audio and speech recognition stay on the Mac. Future Go text processing is optional, receives text only under its own consent/contract, and preserves the locally saved original if unavailable or disabled. No Go change is required to run the adapted UI with local dictation.
