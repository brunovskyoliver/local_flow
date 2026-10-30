# Research: Meeting-first onboarding

- **Reuse the AI step for location.** `AIMode` already means this Mac, your server or off, so a second "where" step would ask the same question twice.
- **`serverOnly` for meeting notes on a server.** Routing, model loading and downloads already honour it (`ServerRouting.swift`, `AppServices.swift`). An unapproved device on this path needed a new waiting route, added in `MeetingInferenceRouter` and `MeetingFinalizer`.
- **No consent version bump.** A variant text confirms the current version, so existing users aren't asked again. The server-only variant replaces "dictation stays local", which is false for those users.
