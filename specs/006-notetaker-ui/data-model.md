# Data model

No persistent schema changes. Meeting and MeetingNotes retain their validation and lifecycle. TranscriptSegmentDraft.analysisTracks supplies the source label; speaker identity stays unassigned.

The library owns a previewID and preview detail, independent from selectedID/detail. Before applying an async result, verify it still belongs to the requested ID. View tasks debounce hover by 120 ms and cancel superseded requests. Keep one preview, bounded by the existing detail/notes limits.
