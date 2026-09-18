# Design decisions

Use the supplied screenshots as the visual authority. Reuse adaptive app colors, with a softer canvas fill for note rows and transcript bubbles. Avoid adding dependencies or copying other application source.

Existing analysisTracks records mic, system or both. It records contributing capture tracks, not individual speaker identity. Display You (microphone), Others (system audio), or Unassigned (mixed audio), with a visible explanation. Separating mixed speech requires a later capture/transcription change.

Summary and shared-note services do not exist. User confirmed they are outside this pass. Their UI states must explain unavailability. Existing notes are editable in My thoughts, never passed off as an AI summary.
