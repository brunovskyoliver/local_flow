# Data model: Feature 025

No schema change. Swift remains the schema's source of truth until cutover.

- **Credentials**: `device-key`, `server-key`, `refresh-token`, `access-token`, in Keychain or Credential Manager. Rust uses the `org.localflow.LocalFlow.rust-dev` service on the Mac until Feature 028.
- **Meeting segments**: existing `meeting_segments` rows and ADR 0015 files. Windows records both tracks at 96 kbit/s, stored in the row's `bitrate`.
- **Handoff**: `Handoff/<id>/` with `bundle.sqlite`, same shape as Swift's (checked by `fixtures/handoff/`).
