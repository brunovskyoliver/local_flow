# Parity inventory 05: Notetaker

## Library

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| NOTE-001 | view | Library root | MeetingLibraryView.swift | Root font flow 13; ink on surface | ui-only |
| NOTE-002 | behavior | Library load task | MeetingLibraryView.swift `.task` | Copies `preferences.meetingTranscriptionEnabled` into local `transcribe`, then calls `model.refresh()` | core: preferences read; `MeetingStore.page` |
| NOTE-003 | view | Wide layout | MeetingLibraryView.swift | Width >= 800: library, 1pt rule (line), preview column 230 wide | ui-only |
| NOTE-004 | state | Compact layout | MeetingLibraryView.swift | Width < 800: no preview column; overview icon appears | ui-only |
| NOTE-005 | view | Overview icon button | MeetingLibraryView.swift | Icon `sidebar.right`, label "Show note overview", NoteIconButton 13 in 28x28 | ui-only |
| NOTE-006 | behavior | Overview icon click | MeetingLibraryView.swift | Opens a popover 250x380 containing NotePreview; persists nothing | ui-only |
| NOTE-007 | behavior | Preview request | MeetingLibraryView.swift | Row focus change or hover sets previewRequestID, waits 120 ms, then calls `model.preview(id)` | ui-only |
| NOTE-008 | behavior | Leave library | MeetingLibraryView.swift `onDisappear` | Calls `model.releaseDetail()`: closes detail, bumps preview generation, clears preview id, data and notice | ui-only |
| NOTE-009 | behavior | Coordinator version change | MeetingLibraryView.swift | `coordinator.version` change triggers `model.refresh()` | core: `MeetingStore.page` |
| NOTE-010 | behavior | Detail closes | MeetingLibraryView.swift | Resets the notes editor cache | ui-only |
| NOTE-011 | behavior | Main window closes | AppServices.swift `router.mainWindowDidClose` | Calls `meetingLibrary.releaseDetail()`; notes and detail reload on return | ui-only |
| NOTE-012 | view | Page title | MeetingLibraryView.swift | "Notetaker" flow 26 medium, tracking -0.4; header spacing 6, bottom padding 20 | ui-only |
| NOTE-013 | view | Recording options button | MeetingLibraryView.swift | Icon `gearshape`, label "Recording options" | ui-only |
| NOTE-014 | behavior | Recording options click | MeetingLibraryView.swift | Opens a popover, padding 20 | ui-only |
| NOTE-015 | view | Transcribe checkbox | MeetingLibraryView.swift | "Transcribe new recordings" checkbox inside the popover | ui-only |
| NOTE-016 | behavior | Transcribe checkbox toggle | MeetingLibraryView.swift | Writes local @State `transcribe` only; passed to the next `coordinator.start`; nothing persisted | ui-only |
| NOTE-017 | state | Transcribe checkbox disabled | MeetingLibraryView.swift | Disabled when `!coordinator.canStart` | ui-only |
| NOTE-018 | swift-note | Checkbox does not persist | MeetingLibraryView.swift | Label reads as a setting, but the value resets from preferences each time the library loads | ui-only |
| NOTE-019 | view | New note button | MeetingLibraryView.swift | "New note" with plus icon; PrototypeButtonStyle (13 medium, h12 v7, tint, pressed button color, radius 8, disabled opacity .45); id `meeting.start` | ui-only |
| NOTE-020 | behavior | New note click | MeetingLibraryView.swift, MeetingCoordinator.swift | `coordinator.start(options: transcription: transcribe)`; on `.started` refreshes and opens the meeting with tab `.transcript`; creates `meetings`, `meeting_tracks`, transcription row and audio files | mac-service: ScreenCaptureKit system audio, AVCapture microphone, AAC encoder; core: `meetings`, `meeting_tracks`, `meeting_segments`, `meeting_transcriptions` |
| NOTE-021 | state | New note disabled | MeetingLibraryView.swift, MeetingCoordinator.swift | Disabled when `!canStart`; canStart = reconciled and no active meeting and not busy | core: active-meeting state |
| NOTE-022 | state | Start refused: busy | MeetingCoordinator.swift | "Meeting is busy" | core: coordinator gate |
| NOTE-023 | state | Start refused: dictation | MeetingCoordinator.swift | "Dictation in progress" | core: dictation session gate |
| NOTE-024 | state | Start refused: microphone permission | MeetingErrorMessage.swift, MeetingPermissions.swift | "Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone." | mac-service: TCC, AVCaptureDevice authorization |
| NOTE-025 | state | Start refused: screen permission | MeetingErrorMessage.swift, MeetingPermissions.swift | "System audio needs Screen & System Audio Recording. Enable LocalFlow in System Settings > Privacy & Security > Screen & System Audio Recording, then try again." | mac-service: TCC, CGPreflightScreenCaptureAccess |
| NOTE-026 | state | Start refused: disk space | MeetingCoordinator.swift | Free space under 500 MB: "Not enough free space to record (needs at least 500 MB)" | mac-service: volume free-space query |
| NOTE-027 | state | Start warning: disk low | MeetingCoordinator.swift | Free space under 2 GB: "Less than 2 GB free"; recording continues | mac-service: volume free-space query |
| NOTE-028 | state | Start failed: file creation | MeetingErrorMessage.swift | `segment_open_failed`: "The meeting could not start because an audio file could not be created." | core: `meetings.failure_reason` |
| NOTE-029 | view | Today card | MeetingLibraryView.swift | Canvas, radius 16, padding h20 v12, spacing 16, bottom padding 24 | ui-only |
| NOTE-030 | view | Today label | MeetingLibraryView.swift | "TODAY" 12 medium, tracking 1.2 | ui-only |
| NOTE-031 | view | Refresh button | MeetingLibraryView.swift | Icon `arrow.clockwise`, label "Refresh notes", muted | ui-only |
| NOTE-032 | behavior | Refresh click | MeetingLibraryViewModel.swift `refresh` | Reloads first 20 rows, bumps generation so older responses are ignored, sets hasOlder, clears evictedNewest and notice, re-pins active meeting, reloads selected detail | core: `meetings` page query |
| NOTE-033 | state | Today summary: recording | MeetingLibraryView.swift `todaySummary` | created, preparing or recording: "Recording now" | core: active-meeting state |
| NOTE-034 | state | Today summary: paused | MeetingLibraryView.swift | "Recording paused" | core: active-meeting state |
| NOTE-035 | state | Today summary: finalizing | MeetingLibraryView.swift | "Finishing the recording" | core: active-meeting state |
| NOTE-036 | state | Today summary: none | MeetingLibraryView.swift | "No meetings today" | core: loaded rows filtered to today |
| NOTE-037 | state | Today summary: one | MeetingLibraryView.swift | "1 meeting today" | core: loaded rows filtered to today |
| NOTE-038 | state | Today summary: many | MeetingLibraryView.swift | "N meetings today" | core: loaded rows filtered to today |
| NOTE-039 | view | Today summary line | MeetingLibraryView.swift | flow 15, centered, bottom padding 14, id `meeting.today.summary` | ui-only |
| NOTE-040 | swift-note | Today count uses loaded rows | MeetingLibraryView.swift `todayCount` | Counts resident rows only; after older pages evict the newest page the count can read low | core: count query if fixed |
| NOTE-041 | state | Today card needs attention | MeetingLibraryView.swift `needsAttention` | Refusal present or status state failed or interrupted: ActiveMeetingView replaces the summary line | core: active-meeting state |
| NOTE-042 | view | Library notice | MeetingLibraryView.swift | `model.notice ?? detailNotice`, red, bottom padding 12 | ui-only |
| NOTE-043 | state | Page load error | MeetingLibraryViewModel.swift | "Meetings could not be loaded. Check app storage." | core: `meetings` page query |
| NOTE-044 | state | Older page error | MeetingLibraryViewModel.swift | "Older meetings could not be loaded." | core: `meetings` page query |
| NOTE-045 | view | Past notes tab | MeetingLibraryView.swift, NotetakerStyle.swift `NoteTab` | "Past notes", selected: 15 medium ink, v12, 2pt ink bottom bar; bar row spacing 20; 1pt rule overlay at bottom | ui-only |
| NOTE-046 | behavior | Past notes tab click | MeetingLibraryView.swift | No-op | ui-only |
| NOTE-047 | view | Search toggle | MeetingLibraryView.swift | Icon `magnifyingglass`, label "Search loaded notes" | ui-only |
| NOTE-048 | behavior | Search toggle click | MeetingLibraryView.swift | Shows or hides the field; query text is kept when hidden | ui-only |
| NOTE-049 | view | Search field | MeetingLibraryView.swift | Placeholder "Search", plain, flow 14, padding 10, canvas radius 8, top 12 | ui-only |
| NOTE-050 | behavior | Search filter | MeetingLibraryView.swift | Client side: `displayTitle.localizedStandardContains` over loaded rows; no store query | ui-only |
| NOTE-051 | swift-note | Hidden search still filters | MeetingLibraryView.swift | Query is not cleared on toggle; confirm whether a hidden query keeps filtering when porting | ui-only |
| NOTE-052 | state | Empty library | MeetingLibraryView.swift | "No notes yet", flow 15 muted, v padding 60 | ui-only |
| NOTE-053 | state | Filtered empty | MeetingLibraryView.swift | "No matches", flow 15 muted, v padding 60 | ui-only |
| NOTE-054 | view | List container | MeetingLibraryView.swift | Top padding 25, lazy stack spacing 3; library max width 760, padding h30 v32, scroll indicators never | ui-only |
| NOTE-055 | view | Show newest button | MeetingLibraryView.swift | "Show newest", bottom padding 12; only when evictedNewest | ui-only |
| NOTE-056 | behavior | Show newest click | MeetingLibraryViewModel.swift | Calls `refresh()` | core: `meetings` page query |
| NOTE-057 | view | Load older button | MeetingLibraryView.swift | "Load older notes", PrototypeButtonStyle, top 20; only when hasOlder | ui-only |
| NOTE-058 | behavior | Load older click | MeetingLibraryViewModel.swift `loadOlder` | Cursor (createdAt, id) of last row; limit 20; hasOlder = count == 20 | core: `SELECT m.*, EXISTS(... meeting_tracks health IN ('failed','unrecoverable')) AS warning, (SELECT state FROM meeting_transcriptions) AS transcript_state FROM meetings m WHERE (m.created_at,m.id)<(?,?) ORDER BY m.created_at DESC, m.id DESC LIMIT ?` |
| NOTE-059 | state | Load older disabled | MeetingLibraryView.swift | Disabled while isLoading | ui-only |
| NOTE-060 | behavior | Resident row cap | MeetingLibraryViewModel.swift | Max 40 rows; excess removed from the front and evictedNewest set | ui-only |
| NOTE-061 | behavior | Active meeting pin | MeetingLibraryViewModel.swift `refresh` | Active meeting moved to index 0, or fetched by detail and inserted when outside the page | core: `MeetingStore.detail` |
| NOTE-062 | view | Day heading | MeetingLibraryView.swift | 12 medium, tracking 1.2, muted; top 24 (0 for first), bottom 7, leading 4 | ui-only |
| NOTE-063 | state | Day heading: today | MeetingLibraryView.swift | "TODAY, MMM D" uppercased | ui-only |
| NOTE-064 | state | Day heading: yesterday | MeetingLibraryView.swift | "YESTERDAY, MMM D" uppercased | ui-only |
| NOTE-065 | state | Day heading: other | MeetingLibraryView.swift | "EEE, MMM D" uppercased | ui-only |
| NOTE-066 | view | Note row | MeetingLibraryView.swift `NoteListRow` | HStack spacing 12; padding v12, leading 10; `doc.text` 14 muted in 36x36 tint radius 8 | ui-only |
| NOTE-067 | view | Row title | MeetingLibraryView.swift | flow 15, line limit 1; `displayTitle`, falling back to date format "d MMM yyyy, HH:mm" (en_US_POSIX) | ui-only |
| NOTE-068 | view | Row time | MeetingLibraryView.swift | `.dateTime.hour().minute()`, 12 muted; VStack spacing 4 | ui-only |
| NOTE-069 | state | Row from iPhone | MeetingLibraryView.swift | Label "From iPhone" icon `iphone`, 12 muted, when origin == iphone | core: `meetings.origin` |
| NOTE-070 | state | Row hover or focus | MeetingLibraryView.swift | Canvas background radius 10; overflow menu opacity 1 (else 0) | ui-only |
| NOTE-071 | behavior | Row click | MeetingLibraryViewModel.swift `open` | `open(id)` with default tab `.thoughts`, loads detail | core: `MeetingStore.detail` |
| NOTE-072 | state | Row active | MeetingLibraryView.swift | LiveRecordingBadge, trailing 6 | core: active-meeting state |
| NOTE-073 | view | Live badge | NotetakerStyle.swift `LiveRecordingBadge` | Size 13, icon size 12, spacing 8, mono digits; id `meeting.elapsed` | ui-only |
| NOTE-074 | state | Live badge recording | NotetakerStyle.swift | `waveform`, green, variable color iterative animation | ui-only |
| NOTE-075 | state | Live badge paused | NotetakerStyle.swift | `pause.fill`, muted, no animation | ui-only |
| NOTE-076 | state | Row waiting for server | MeetingLibraryView.swift | "Waiting for your server" 12 muted | core: waiting sets in transcription, diarization, identification and intelligence coordinators |
| NOTE-077 | view | Row Run on this Mac | MeetingLibraryView.swift | "Run on this Mac" font 12; a11y "Run <title> on this Mac"; only when waiting | ui-only |
| NOTE-078 | behavior | Row Run on this Mac click | AppServices.swift `runMeetingOnThisMac` | `setRunLocally` writes `meetings.run_locally=1`, then runLocally on transcription, diarization, identification, intelligence | core: `meetings.run_locally`; worker: flowd-meeting, flowd-speech |
| NOTE-079 | state | Run refused: server only | AppServices.swift | "Server only is on, so this Mac doesn't run models. Change it in Settings › Server." | core: preferences.serverOnly |
| NOTE-080 | state | Run refused: store error | AppServices.swift | "This meeting can't be moved to this Mac right now." | core: `meetings.run_locally` |
| NOTE-081 | state | Row badge text | MeetingLibraryView.swift | State not completed and not waiting: state badge 12 muted | core: `meetings.state` |
| NOTE-082 | state | Row warning | MeetingLibraryView.swift | `exclamationmark.triangle` orange, a11y "Recording needs attention"; hasTrackWarning or deletionPending | core: `meeting_tracks.health` |
| NOTE-083 | view | Overflow button | NotetakerStyle.swift `NoteOverflowMenu` | `ellipsis`, "Note options", h padding 8 in rows | ui-only |
| NOTE-084 | view | Overflow popover | NotetakerStyle.swift | Width 190, padding 8, spacing 2, surface; item 14, h10 v9 | ui-only |
| NOTE-085 | view | Overflow Delete item | NotetakerStyle.swift | "Delete" `trash`, red | ui-only |
| NOTE-086 | state | Overflow Delete disabled | MeetingLibraryView.swift, NotetakerStyle.swift | canDelete = state.isTerminal | ui-only |
| NOTE-087 | behavior | Overflow Delete click | MeetingLibraryView.swift | Closes popover and opens the library delete dialog | ui-only |
| NOTE-088 | view | Library delete dialog | MeetingLibraryView.swift | "Delete this note?"; "Delete note" destructive; "Cancel"; message "This removes the recording, transcript and thoughts from this Mac." | ui-only |
| NOTE-089 | behavior | Delete confirm | MeetingLibraryViewModel.swift `delete` | willDelete on diarization, identification, intelligence and coordinator, then `deleteConfirmed`: files, `transcript_usage` decrement, `DELETE FROM meetings`; on complete closes detail and preview and refreshes | core: `meetings` cascade, `transcript_usage`, audio files |
| NOTE-090 | behavior | Delete cancel | MeetingLibraryView.swift | Dismisses; nothing written | ui-only |
| NOTE-091 | state | Delete incomplete | MeetingLibraryViewModel.swift | Row kept; id in deletionPending; "Deletion incomplete: N file(s) remain. Retry after checking the folder." | core: `DeletionOutcome.remainingPaths` |
| NOTE-092 | state | Delete refused: active | MeetingLibraryViewModel.swift | "Stop the meeting before deleting it." | core: `MeetingStore.Error.meetingActive` |
| NOTE-093 | state | Delete refused: stale | MeetingLibraryViewModel.swift | Reloads detail, then "The meeting changed. Try again." | core: `meetings.revision` |
| NOTE-094 | state | Delete failed | MeetingLibraryViewModel.swift | "The meeting could not be deleted." | core: `deleteConfirmed` |
| NOTE-095 | swift-note | Pending deletions lost on relaunch | MeetingLibraryViewModel.swift | `deletionPending` and `pendingPaths` are in memory only | core: persist if wanted |
| NOTE-096 | view | Preview panel | NotetakerStyle.swift `NotePreview` | Surface; id `notetaker.preview`; empty when row is nil | ui-only |
| NOTE-097 | view | Preview header | NotetakerStyle.swift | Title 18 medium; "<date> · <duration>" 14 mono muted; spacing 8; padding 20; 1pt rule below | ui-only |
| NOTE-098 | view | Preview thoughts | NotetakerStyle.swift | "MY THOUGHTS" 12 medium, tracking 1.2 muted; body flow 14, line spacing 6, first 1200 characters; spacing 16, padding 20; never scroller | core: `meeting_notes.text` |
| NOTE-099 | state | Preview no notes | NotetakerStyle.swift | Heading and body hidden when notes are empty | ui-only |
| NOTE-100 | state | Preview missing | MeetingLibraryViewModel.swift | "This note no longer exists." red | core: `MeetingStore.detail` |
| NOTE-101 | state | Preview error | MeetingLibraryViewModel.swift | "The overview could not be loaded." red | core: `MeetingStore.detail` |
| NOTE-102 | behavior | Preview trimming | MeetingLibraryViewModel.swift `previewDetail` | Drops tracks, pauses and outcomes; stale responses ignored by generation | ui-only |
| NOTE-103 | view | Duration text | NotetakerStyle.swift, MeetingModels.swift | `meetingDurationText(ms)`, mono digits | ui-only |
| NOTE-104 | view | Icon button | NotetakerStyle.swift `NoteIconButton` | 13 in 28x28, plain, tooltip and a11y equal to label | ui-only |
| NOTE-105 | behavior | Scroller hiding | NotetakerStyle.swift `hideScrollers` | Removes scrollers on AppKit text views only when preferred style is overlay; "always show" setting is respected | mac-service: NSScroller.preferredScrollerStyle |
| NOTE-106 | view | Page query rows | MeetingStore.swift `page` | Limit 20, newest first; index `meetings_created_at_id` | core: `meetings`, `meeting_tracks`, `meeting_transcriptions` |
| NOTE-107 | swift-note | Unused transcript glyph | MeetingLibraryView.swift `MeetingRowView.transcriptGlyph` | `text.quote` and `text.badge.xmark` glyph helper exists; list row does not show it | ui-only |

## Meeting detail

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| MEET-001 | view | Toolbar | MeetingDetailView.swift | Padding h20, top 18, bottom 16; spacing 4; max width 860 | ui-only |
| MEET-002 | view | Back button | MeetingDetailView.swift | `chevron.left`, "Back to past notes", button background, radius 6 | ui-only |
| MEET-003 | behavior | Back click | MeetingDetailView.swift | leaving = true; flushes notes; closes detail only if the editor is clean | core: `meeting_notes` save |
| MEET-004 | state | Back with failed save | MeetingDetailView.swift | Stays on the note when the editor remains dirty; retry row visible | ui-only |
| MEET-005 | view | Previous note button | MeetingDetailView.swift | `chevron.left`, "Previous note" | ui-only |
| MEET-006 | view | Next note button | MeetingDetailView.swift | `chevron.right`, "Next note" | ui-only |
| MEET-007 | behavior | Previous and next click | MeetingDetailView.swift | Flushes notes, then `open(adjacent, tab: current)` if clean | core: `meeting_notes` save; `MeetingStore.detail` |
| MEET-008 | state | Previous and next disabled | MeetingDetailView.swift | No adjacent resident row, or leaving | ui-only |
| MEET-009 | view | Detail overflow menu | MeetingDetailView.swift, NotetakerStyle.swift | Same popover as library; `arrow.clockwise` transcription item above Delete | ui-only |
| MEET-010 | state | Overflow title: not requested | MeetingDetailView.swift | "Transcribe" | core: `meeting_transcriptions.state` |
| MEET-011 | state | Overflow title: failed or interrupted | MeetingDetailView.swift | "Retry transcription" | core: `meeting_transcriptions.state` |
| MEET-012 | state | Overflow title: final | MeetingDetailView.swift | "Re-transcribe" | core: `meeting_transcriptions.state` |
| MEET-013 | state | Overflow no transcription item | MeetingDetailView.swift | pending, live, finalizing: item absent | core: `meeting_transcriptions.state` |
| MEET-014 | behavior | Transcription item click | MeetingDetailView.swift | `requestFinalization(meetingID, revision)` | worker: flowd-speech; flowd: `meeting_job` kind `transcribe` on `/v1/remote/channel`; core: `meeting_transcriptions` |
| MEET-015 | state | Queue full | MeetingTranscriptionCoordinator.swift | "Too many transcripts waiting"; capacity 100 | core: finalization queue |
| MEET-016 | view | Detail delete dialog | MeetingDetailView.swift | `Delete "<title>"?`; "Delete meeting"; "Cancel"; message "This removes the meeting's audio files and notes from this Mac. Other meetings are kept." | ui-only |
| MEET-017 | behavior | Detail delete confirm | MeetingLibraryViewModel.swift `delete` | Same as NOTE-089 with the meeting's revision | core: `meetings` cascade, audio files |
| MEET-018 | view | Title field | MeetingDetailView.swift | Placeholder "Untitled"; serif (EB Garamond) 38 regular, tracking -0.6, lines 1...3; spacing 8 | ui-only |
| MEET-019 | behavior | Title save | MeetingDetailView.swift, MeetingStore.swift `setTitle` | On submit and focus loss; skipped if draft equals title or displayTitle; trims; empty stores NULL; `revision=revision+1`; notifies coordinator if active; reloads detail and list | core: `meetings.title`, `meetings.revision` |
| MEET-020 | state | Title too long | MeetingLibraryViewModel.swift | "Titles are limited to 256 bytes." | core: `MeetingStore.Error.titleTooLarge` |
| MEET-021 | state | Title stale | MeetingLibraryViewModel.swift | "The meeting changed. Try again." and reload | core: `meetings.revision` |
| MEET-022 | state | Title failed | MeetingLibraryViewModel.swift | "The title could not be saved." | core: `setTitle` |
| MEET-023 | view | Date line | MeetingDetailView.swift | flow 15 muted, header bottom 4 | ui-only |
| MEET-024 | state | Lost audio warning | MeetingDetailView.swift | Orange 13, `exclamationmark.triangle.fill`: "Some audio was lost during recording. The transcript may be incomplete." | core: `meeting_tracks.dropped_frames`, health |
| MEET-025 | state | Duration warning | MeetingDetailView.swift, MeetingStore.swift | "A recording track does not match the meeting duration. Some audio may be missing."; tolerance max(recorded/100, 2000) ms | core: `meeting_tracks.duration_warning` |
| MEET-026 | state | Failure reason | MeetingDetailView.swift, MeetingErrorMessage.swift | Red 13, text from MeetingErrorMessage | core: `meetings.failure_reason` |
| MEET-027 | state | Reason: storage write | MeetingErrorMessage.swift | "Recording stopped: audio could not be written to disk. What was recorded so far was kept." | ui-only |
| MEET-028 | state | Reason: storage unavailable | MeetingErrorMessage.swift | "Recording stopped: the meeting folder is unavailable." | ui-only |
| MEET-029 | state | Reason: encoder | MeetingErrorMessage.swift | "Recording stopped: the audio encoder failed. What was recorded so far was kept." | ui-only |
| MEET-030 | state | Reason: unclean exit | MeetingErrorMessage.swift | "LocalFlow did not exit cleanly during this meeting. Recorded audio was recovered where possible." | ui-only |
| MEET-031 | state | Reason: device lost | MeetingErrorMessage.swift | "The microphone disconnected. The meeting continued with system audio." | ui-only |
| MEET-032 | state | Reason: stream stopped | MeetingErrorMessage.swift | "System audio stopped. The meeting continued with the microphone." | ui-only |
| MEET-033 | state | Reason: permission revoked | MeetingErrorMessage.swift | "<Microphone or System audio or Audio> permission was revoked during the meeting." | ui-only |
| MEET-034 | state | Reason: both failed | MeetingErrorMessage.swift | "Recording stopped because both audio sources failed." | ui-only |
| MEET-035 | state | Reason: record missing | MeetingErrorMessage.swift | "Files were found without a meeting record. They were kept and listed here." | ui-only |
| MEET-036 | state | Reason: file missing | MeetingErrorMessage.swift | "The audio file for this segment is missing." | ui-only |
| MEET-037 | state | Reason: unrecoverable media | MeetingErrorMessage.swift | "This track could not be made playable. The file was kept." | ui-only |
| MEET-038 | view | Tab bar | MeetingDetailView.swift | "My thoughts", "Transcript", "Summary"; NoteTab; spacing 20; rule max width 860 | ui-only |
| MEET-039 | behavior | Tab click | MeetingDetailView.swift | Switches tab; initial tab from `model.openTab`; not persisted | ui-only |
| MEET-040 | view | Reading column | MeetingDetailView.swift | Width 600, h30; scroll content spacing 16, top 20, bottom 24 | ui-only |
| MEET-041 | state | Detail notice | MeetingDetailView.swift | Red `detailNotice`, font 12, padding 12 | ui-only |
| MEET-042 | state | Detail missing | MeetingLibraryViewModel.swift | "This meeting no longer exists." | core: `MeetingStore.detail` |
| MEET-043 | state | Detail load error | MeetingLibraryViewModel.swift | "Meeting details could not be loaded." | core: `MeetingStore.detail` |
| MEET-044 | view | Retry deletion | MeetingDetailView.swift | "Retry deletion" beside the notice; only when deletion pending | ui-only |
| MEET-045 | behavior | Retry deletion click | MeetingLibraryViewModel.swift `delete` | Repeats delete with the current revision | core: `deleteConfirmed` |
| MEET-046 | state | Waiting row | MeetingDetailView.swift | "Waiting for your server" muted, spacing 12, font 12, padding 12 | core: waiting sets in coordinators |
| MEET-047 | view | Run on this Mac (detail) | MeetingDetailView.swift | "Run on this Mac"; a11y "Run this meeting on this Mac" | ui-only |
| MEET-048 | behavior | Run on this Mac (detail) click | AppServices.swift `runMeetingOnThisMac` | Same as NOTE-078 | core: `meetings.run_locally`; worker: flowd-meeting, flowd-speech |
| MEET-049 | view | Provenance line | MeetingDetailView.swift | 12 muted; a11y "Produced on: ..."; "Transcript: your server · Speaker labels: this Mac" | core: `MeetingStore.provenance` |
| MEET-050 | state | Provenance place: server | MeetingDetailView.swift | "your server" | core: `inference_path` |
| MEET-051 | state | Provenance place: custom | MeetingDetailView.swift | "your custom server" | core: `inference_path` |
| MEET-052 | state | Provenance place: fallback | MeetingDetailView.swift | `local_after_server_failure`: "this Mac (server unavailable)" | core: `inference_path` |
| MEET-053 | state | Provenance place: default | MeetingDetailView.swift | "this Mac" | core: `inference_path` |
| MEET-054 | behavior | Provenance reload | MeetingDetailView.swift | Reload key is meeting id + transcription state; reads `meeting_transcriptions` final, `diarization_runs`, `analysis_runs` via accepted_run_id | core: those tables |
| MEET-055 | view | Thoughts editor | MeetingDetailView.swift | NSTextView 14pt, line spacing 6, no background, inset h0 v4, undo on, min height 420 | mac-service: NSTextView equivalent editor |
| MEET-056 | state | Thoughts placeholder | MeetingDetailView.swift | "Capture your thoughts here" 14 muted, opacity 0.7, top 4 | ui-only |
| MEET-057 | behavior | Notes autosave | MeetingNotesEditor.swift | Debounce 2 s; forced after 10 s of edits; one write in flight; later edits coalesced; `evidenceDidChange` after save | core: `meeting_notes.text`, `revision` |
| MEET-058 | state | Notes too large | MeetingNotesEditor.swift | Limit 1 MiB: "Notes are limited to 1 MiB. The last edit was not applied." | core: `meeting_notes` |
| MEET-059 | state | Notes changed elsewhere | MeetingNotesEditor.swift | "This note has changed" reveal | core: `meeting_notes.revision` |
| MEET-060 | behavior | Notes stale revision | MeetingNotesEditor.swift | Re-reads and retries once; local text wins | core: `meeting_notes.revision` |
| MEET-061 | state | Notes save failed | MeetingDetailView.swift, MeetingNotesEditor.swift | "Notes not saved" red, spacing 12 | core: `meeting_notes` |
| MEET-062 | view | Retry save | MeetingDetailView.swift | "Retry save", font 12 | ui-only |
| MEET-063 | behavior | Retry save click | MeetingNotesEditor.swift | Runs flush again | core: `meeting_notes` |
| MEET-064 | behavior | Leave detail | MeetingDetailView.swift `onDisappear` | Stops playback, flushes notes, clears enrollment callback | mac-service: AVQueuePlayer; core: `meeting_notes` |
| MEET-065 | view | Footer | MeetingDetailView.swift | Top 12, bottom 20, width 600, spacing 8 | ui-only |
| MEET-066 | view | Footer Pause | MeetingDetailView.swift | "Pause" `pause.fill` PrototypeButtonStyle; live and recording | ui-only |
| MEET-067 | view | Footer Resume | MeetingDetailView.swift | "Resume" `play.fill` PrototypeButtonStyle; live and paused | ui-only |
| MEET-068 | view | Footer Stop | MeetingDetailView.swift | "Stop" `stop.fill` green icon; id `meeting.stop` | ui-only |
| MEET-069 | behavior | Footer Pause click | MeetingCoordinator.swift | Pause with reason `.user`; writes `meeting_pauses`, state paused | mac-service: audio capture; core: `meeting_pauses`, `meetings.state` |
| MEET-070 | behavior | Footer Resume click | MeetingCoordinator.swift | Resume opens new segments, closes pause | mac-service: audio capture; core: `meeting_segments`, `meeting_pauses` |
| MEET-071 | behavior | Footer Stop click | MeetingCoordinator.swift | Flushes, state finalizing, stages mic then both, then completed or interrupted; starts transcript finalization | mac-service: audio capture; core: `meetings.finalization_stage`; worker: flowd-speech |
| MEET-072 | view | Playback button | MeetingDetailView.swift `FooterPlayer` | "Playback" `play.circle`; when playing "Pause" `pause.circle` | ui-only |
| MEET-073 | state | Playback disabled | MeetingDetailView.swift | Meeting not terminal, or no track | ui-only |
| MEET-074 | behavior | Playback click | TrackPlaybackController.swift | Loads microphone track, else system; `play()` or `pause()`; rebuilds queue when empty | mac-service: AVQueuePlayer |
| MEET-075 | view | Playback position | MeetingDetailView.swift, TrackPlaybackController.swift | "<position> / <duration>", 12 mono muted; updates at 4 Hz | mac-service: AVQueuePlayer time observer |
| MEET-076 | view | Playback Stop | MeetingDetailView.swift | "Stop" | ui-only |
| MEET-077 | behavior | Playback Stop click | TrackPlaybackController.swift `stop` | Pause, rebuild queue, position 0 | mac-service: AVQueuePlayer |
| MEET-078 | state | Playback notice | MeetingDetailView.swift, TrackPlaybackController.swift | 12 muted, line limit 1; `MeetingErrorMessage.noPlayableAudio`: "No playable audio" | core: `meeting_segments` |
| MEET-079 | behavior | Playback queue | TrackPlaybackController.swift `load` | One item per finalized segment by sequence; duration from `meeting_segments.duration_ms`, not the asset; read-only | core: `meeting_segments`; mac-service: AVURLAsset |
| MEET-080 | state | Segment skipped: open | TrackPlaybackController.swift | "Segment N: Not playable: still open" | core: `meeting_segments.state` |
| MEET-081 | state | Segment skipped: file missing or unrecoverable | TrackPlaybackController.swift | "Segment N: " + `notPlayable(reason)` | core: `meeting_segments` |
| MEET-082 | behavior | Playback end | TrackPlaybackController.swift `finished` | isPlaying false; position = duration; queue rebuilt | mac-service: AVPlayerItemDidPlayToEndTime |
| MEET-083 | behavior | Seek | TrackPlaybackController.swift `seek` | Clamped to 0...duration-1; picks segment, rebuilds queue, seeks within item, keeps play state | mac-service: AVQueuePlayer |
| MEET-084 | swift-note | No speed control or scrubber | TrackPlaybackController.swift, MeetingDetailView.swift | No rate API and no slider exist; no track picker either; the only seek entry is "Play from here" | ui-only |
| MEET-085 | swift-note | Skipped segments never shown | TrackPlaybackController.swift | `skipped` texts are stored but no view reads them | ui-only |
| MEET-086 | swift-note | Seek timeline mismatch | TrackPlaybackController.swift, MeetingDetailView.swift | Seek uses the concatenated playable-segment timeline; transcript startMs is transcript time, and skipped segments shift the two apart | core: mapping if fixed |
| MEET-087 | swift-note | URL match by suffix | TrackPlaybackController.swift `rebuildQueue` | Items matched with `hasSuffix(relativePath)` across opened URLs | ui-only |
| MEET-088 | swift-note | Language setter has no UI | MeetingLibraryViewModel.swift `setLanguage` | No caller in the app; message "The language could not be saved." is unreachable; `meetings` still has a language column | core: `meetings` language column |
| MEET-089 | behavior | Finalizing poll | MeetingDetailView.swift | Every 5 s while finalizing, reloads | core: `meeting_transcriptions` |
| MEET-090 | behavior | Sheet dismiss refresh | MeetingDetailView.swift | Assign speakers `onDismiss` refreshes the summary | core: `analysis_*` read model |
| MEET-091 | state | Meeting state: recovering | MeetingCoordinator.swift, MeetingErrorMessage.swift | Reconcile on launch; `canStart` false until reconciled; outcomes in `meeting_recovery_outcomes` ORDER BY ran_at,id | core: `meeting_recovery_outcomes` |
| MEET-092 | behavior | Detail read | MeetingStore.swift `detail` | tracks (microphone first), segments ORDER BY sequence, pauses ORDER BY started_at,id, notes, outcomes | core: `meeting_tracks`, `meeting_segments`, `meeting_pauses`, `meeting_notes`, `meeting_recovery_outcomes` |
| MEET-093 | state | Notice from background work | AppServices.swift `showMeetingNotice` | Transcription, diarization, identification, intelligence notices routed to meeting notice | ui-only |

## Active meeting

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| LIVE-001 | view | Active panel | ActiveMeetingView.swift | Spacing 12, padding 16, tint radius 12 | ui-only |
| LIVE-002 | state | Dot: recording | ActiveMeetingView.swift | Dot 10, red | ui-only |
| LIVE-003 | state | Dot: paused | ActiveMeetingView.swift | Dot 10, orange | ui-only |
| LIVE-004 | state | Dot: other | ActiveMeetingView.swift | Dot 10, secondary | ui-only |
| LIVE-005 | view | State text | ActiveMeetingView.swift | badgeText 15 semibold | ui-only |
| LIVE-006 | state | Pause reason | ActiveMeetingView.swift | "(sleep)" or "(user)" | core: `meeting_pauses` reason |
| LIVE-007 | view | Elapsed | ActiveMeetingView.swift | Rounded 22 medium, mono | ui-only |
| LIVE-008 | state | Banner: interrupted | ActiveMeetingView.swift | Red 13 semibold, `exclamationmark.triangle.fill`: "Recording stopped" | core: `meetings.state` |
| LIVE-009 | state | Banner: failed | ActiveMeetingView.swift | "The meeting could not start" | core: `meetings.state` |
| LIVE-010 | state | Storage warning | ActiveMeetingView.swift | Orange, `externaldrive.badge.exclamationmark`: "Less than 2 GB free" | mac-service: volume free-space query |
| LIVE-011 | view | Track indicators | ActiveMeetingView.swift | Spacing 14 between, 6 within, size 12; `mic.fill`, `speaker.wave.2.fill` | ui-only |
| LIVE-012 | state | Track: capturing | ActiveMeetingView.swift | Green, "capturing" | mac-service: audio capture |
| LIVE-013 | state | Track: finalized | ActiveMeetingView.swift | Secondary, "finalized" | core: `meeting_tracks.health` |
| LIVE-014 | state | Track: not started | ActiveMeetingView.swift | Gray, "not started" | ui-only |
| LIVE-015 | state | Track: failed | ActiveMeetingView.swift | Red, "failed: <reason with spaces>" | core: `meeting_tracks.failure_reason` |
| LIVE-016 | state | Dropped frames | ActiveMeetingView.swift | Orange 12 count | core: `meeting_tracks.dropped_frames` |
| LIVE-017 | state | Permission notice | ActiveMeetingView.swift | 13 secondary, message plus settings button | mac-service: TCC poll at 1 Hz |
| LIVE-018 | view | Open System Settings | ActiveMeetingView.swift | "Open System Settings" | ui-only |
| LIVE-019 | behavior | Open System Settings click | ActiveMeetingView.swift | Opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` or `?Privacy_ScreenCapture` | mac-service: NSWorkspace |
| LIVE-020 | view | Pause or Resume | ActiveMeetingView.swift | "Pause" or "Resume" | ui-only |
| LIVE-021 | behavior | Pause or Resume click | MeetingCoordinator.swift | As MEET-069 and MEET-070 | mac-service: audio capture; core: `meeting_pauses` |
| LIVE-022 | view | Stop Meeting | ActiveMeetingView.swift | "Stop Meeting", bordered prominent, destructive | ui-only |
| LIVE-023 | behavior | Stop Meeting click | MeetingCoordinator.swift | As MEET-071 | mac-service: audio capture; core: `meetings` |
| LIVE-024 | state | Finalizing | ActiveMeetingView.swift | Progress plus "Finalizing…" | ui-only |
| LIVE-025 | state | Starting | ActiveMeetingView.swift | Progress plus "Starting…" | ui-only |
| LIVE-026 | view | Dismiss | ActiveMeetingView.swift | "Dismiss" | ui-only |
| LIVE-027 | behavior | Dismiss click | MeetingCoordinator.swift | `dismiss`: clears status and refusal; nothing stored | ui-only |
| LIVE-028 | view | Title field | ActiveMeetingView.swift | "Title (optional)", rounded, max width 360 | ui-only |
| LIVE-029 | behavior | Title save | MeetingCoordinator.swift | Revision-checked `setTitle` | core: `meetings.title` |
| LIVE-030 | state | Title too long | ActiveMeetingView.swift | "Titles are limited to 256 bytes." | core: `setTitle` |
| LIVE-031 | state | Title failed | ActiveMeetingView.swift | "The title could not be saved." | core: `setTitle` |
| LIVE-032 | view | Refusal row | ActiveMeetingView.swift | `exclamationmark.triangle`, message, settings button, "Dismiss" | ui-only |
| LIVE-033 | view | Notes editor | ActiveMeetingView.swift `MeetingNotesEditorView` | "Notes" 13 semibold; TextEditor 13, min height 90, max 200, surface radius 8 | ui-only |
| LIVE-034 | state | Notes state: unsaved | ActiveMeetingView.swift | "Unsaved" 12 | ui-only |
| LIVE-035 | state | Notes state: saving | ActiveMeetingView.swift | "Saving…" 12 | ui-only |
| LIVE-036 | state | Notes state: saved | ActiveMeetingView.swift | "Saved" 12 | ui-only |
| LIVE-037 | state | Notes state: failed | ActiveMeetingView.swift | "Not saved" 12 red | ui-only |
| LIVE-038 | swift-note | Live panel mostly unreachable | MeetingLibraryView.swift, ActiveMeetingView.swift | Only rendered for refusal, failed or interrupted, so pause, stop, title and notes in this panel cannot appear during recording | ui-only |
| LIVE-039 | behavior | Start order | MeetingCoordinator.swift | busy, alreadyActive, dictation, gate, active row, mic permission, screen permission, storage dir, free space, probe, create, tracks, transcription row, preparing, open files, sources, recording | mac-service: capture, TCC; core: `meetings`, `meeting_tracks` |
| LIVE-040 | state | Both sources failed at start | MeetingCoordinator.swift | State failed: "Recording stopped because both audio sources failed." | core: `meetings.failure_reason` |
| LIVE-041 | behavior | Mac sleep | MeetingCoordinator.swift | Pauses: "Paused because the Mac went to sleep" | mac-service: NSWorkspace sleep notifications |
| LIVE-042 | behavior | Device change | MeetingCoordinator.swift | Rolls to a new segment with openReason `.deviceChanged` | mac-service: AVCapture device notifications; core: `meeting_segments` |
| LIVE-043 | behavior | Status poll | MeetingCoordinator.swift | Status every 250 ms | ui-only |
| LIVE-044 | behavior | Elapsed and permission poll | MeetingCoordinator.swift | Once per second | mac-service: TCC |
| LIVE-045 | view | Live transcript section | TranscriptSectionView.swift | Conditional inside active panel; see TRANS-073 onward | ui-only |

## Transcript

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| TRANS-001 | view | Header | MeetingDetailView.swift | Height 32, canvas radius 6, flow 11 muted, leading 12, trailing 4, spacing 10 | ui-only |
| TRANS-002 | view | Duration | MeetingDetailView.swift `MeetingDurationLabel` | `clock`, mono | ui-only |
| TRANS-003 | state | Header badge | MeetingDetailView.swift | "· <badge>" when not live and state not final | core: `meeting_transcriptions.state` |
| TRANS-004 | state | Badge: not requested | TranscriptLifecycle | "Not requested" | ui-only |
| TRANS-005 | state | Badge: pending | TranscriptLifecycle | "Pending" | ui-only |
| TRANS-006 | state | Badge: live | TranscriptLifecycle | "Live" | ui-only |
| TRANS-007 | state | Badge: finalizing | TranscriptLifecycle | "Finalizing N %" | core: finalization progress |
| TRANS-008 | state | Badge: final | TranscriptLifecycle | "Final" | ui-only |
| TRANS-009 | state | Badge: failed | TranscriptLifecycle | "Failed" | ui-only |
| TRANS-010 | state | Badge: interrupted | TranscriptLifecycle | "Interrupted" | ui-only |
| TRANS-011 | view | Search icon | MeetingDetailView.swift | `magnifyingglass`, "Search transcript" | ui-only |
| TRANS-012 | view | Search field | MeetingDetailView.swift | Max width 170 | ui-only |
| TRANS-013 | behavior | Search keys | MeetingDetailView.swift | Esc closes; blur with empty query closes | ui-only |
| TRANS-014 | behavior | Search query | MeetingDetailView.swift, TranscriptPager.swift | Debounce 250 ms; whole-transcript search limit 1000; resident rows filtered client side | core: `transcript_segments` search |
| TRANS-015 | view | Match navigator | MeetingDetailView.swift | Chevron up and down, 20x20, "Previous match", "Next match" | ui-only |
| TRANS-016 | behavior | Match navigation | TranscriptPager.swift `reveal` | Wraps; loads the page with the match; center-anchored animated scroll; highlight clears after 2 s | core: `transcript_segments` ordinal lookup |
| TRANS-017 | state | Match count: searching | MeetingDetailView.swift | "Searching…" | ui-only |
| TRANS-018 | state | Match count: none | MeetingDetailView.swift | "No matches" | ui-only |
| TRANS-019 | state | Match count: one | MeetingDetailView.swift | "1 match" | ui-only |
| TRANS-020 | state | Match count: many | MeetingDetailView.swift | "N matches" | ui-only |
| TRANS-021 | state | Match count: positioned | MeetingDetailView.swift | "i of N" | ui-only |
| TRANS-022 | state | Match count: truncated | MeetingDetailView.swift | "+" suffix | ui-only |
| TRANS-023 | state | No resident: searching | MeetingDetailView.swift | "Searching the whole transcript…" | ui-only |
| TRANS-024 | state | No resident: none | MeetingDetailView.swift | "No matches." | ui-only |
| TRANS-025 | state | No resident: elsewhere | MeetingDetailView.swift | "No matches in this part of the transcript. Use the arrows to go to the others." | ui-only |
| TRANS-026 | state | Search failed | TranscriptPager.swift | "The transcript could not be searched." | core: search query |
| TRANS-027 | view | Copy menu | MeetingDetailView.swift | `square.on.square` 13, 28x28, help "Copy or export transcript"; not live and count > 0 or segments present | ui-only |
| TRANS-028 | view | Copy selected item | MeetingDetailView.swift | "Copy Selected Segments" or "Copy N Selected Segments" | ui-only |
| TRANS-029 | state | Copy selected disabled | MeetingDetailView.swift | Selection empty | ui-only |
| TRANS-030 | behavior | Copy selected click | MeetingDetailView.swift | Writes selected rows to the pasteboard; persists nothing | mac-service: NSPasteboard |
| TRANS-031 | view | Copy full item | MeetingDetailView.swift | "Copy Full Transcript" | ui-only |
| TRANS-032 | behavior | Copy full click | TranscriptPager.swift | Reads the whole transcript to the pasteboard, subject to length limit | core: `transcript_segments`; mac-service: NSPasteboard |
| TRANS-033 | state | Copy too long | MeetingDetailView.swift | "The transcript is too long to copy. Export it to a file instead." | ui-only |
| TRANS-034 | state | Copy failed | MeetingDetailView.swift | "The transcript could not be copied." | ui-only |
| TRANS-035 | view | Export item | MeetingDetailView.swift | "Export Transcript…" | ui-only |
| TRANS-036 | behavior | Export click | MeetingDetailView.swift, TranscriptPager.swift | NSSavePanel "<title> transcript.txt", plain text; writes in 64 KiB chunks; removes file on failure | mac-service: NSSavePanel; core: `transcript_segments` |
| TRANS-037 | state | Export failed | MeetingDetailView.swift | "The transcript could not be exported." | ui-only |
| TRANS-038 | behavior | Paging | TranscriptPager.swift | Page 200, 2 resident pages; eviction removes selection in evicted rows | core: labeledPage query joining `transcript_segments`, `meeting_diarization`, `diarization_runs`, `speaker_assignments`, `meeting_speakers`, ORDER BY s.ordinal LIMIT 200 |
| TRANS-039 | behavior | Sentinels | MeetingDetailView.swift | 1pt clear views call loadPrevious and loadNext; anchors top and bottom | core: labeledPage |
| TRANS-040 | state | Load failed | TranscriptPager.swift | "The transcript could not be loaded." | core: labeledPage |
| TRANS-041 | behavior | Finality rule | TranscriptPager.swift | final shows final; finalizing, live, pending, not requested show provisional; failed or interrupted show final only when pass kind is final | core: `meeting_transcriptions` |
| TRANS-042 | behavior | Finalizing preview | TranscriptPager.swift | `previewingFinalPass` loads last page of the pass | core: `passSegmentCount`, labeledPage |
| TRANS-043 | view | Bubble | MeetingDetailView.swift | VStack spacing 5; text 13, line spacing 4, selectable; padding h10 v7; radius 8 | ui-only |
| TRANS-044 | state | Bubble default | MeetingDetailView.swift | Canvas | ui-only |
| TRANS-045 | state | Bubble selected | MeetingDetailView.swift | Tint | ui-only |
| TRANS-046 | state | Bubble highlighted | MeetingDetailView.swift | Accent opacity 0.2 | ui-only |
| TRANS-047 | state | Bubble provisional | MeetingDetailView.swift | Muted text | ui-only |
| TRANS-048 | behavior | Group start | TranscriptPager.swift `startsGroup` | Label appears only when a group starts | ui-only |
| TRANS-049 | view | Source label: You | MeetingDetailView.swift | "You", purple, help "Microphone audio" | ui-only |
| TRANS-050 | view | Source label: Others | MeetingDetailView.swift | "Others", orange, help "System audio; may include multiple people" | ui-only |
| TRANS-051 | view | Source label: Unassigned | MeetingDetailView.swift | "Unassigned", muted, help "Mixed microphone and system audio; speaker unknown" | ui-only |
| TRANS-052 | view | Context: select | MeetingDetailView.swift | "Select segment" or "Deselect segment" toggles in-memory selection | ui-only |
| TRANS-053 | view | Context: play | MeetingDetailView.swift | "Play from here" | ui-only |
| TRANS-054 | behavior | Play from here click | MeetingDetailView.swift, TrackPlaybackController.swift | Kind = system if analysisTracks is system, else microphone; requires terminal meeting and a finalized segment; seek then play | mac-service: AVQueuePlayer |
| TRANS-055 | view | Mic divider | MeetingDetailView.swift | "Microphone changed to <name>" or "Microphone changed"; `mic`, 12 muted, 1pt line each side, spacing 10, v8; openReason `.deviceChanged` at startOffset | core: `meeting_segments` |
| TRANS-056 | state | Live empty: off | MeetingDetailView.swift | "Transcription is off for this note." italic muted, v20 | ui-only |
| TRANS-057 | state | Live empty: listening | MeetingDetailView.swift | "Listening…" italic muted, v20 | ui-only |
| TRANS-058 | view | Live list | MeetingDetailView.swift, LiveTranscriptModel.swift | Spacing 3; capacity 200; provisional only; filtered by search | worker: flowd-speech |
| TRANS-059 | state | Failure text container | MeetingDetailView.swift | Red via TranscriptErrorMessage(keptCount, resumesAutomatically: state == finalizing, finalMeeting: engine == "whisper.cpp") | core: `meeting_transcriptions` |
| TRANS-060 | state | Err: model missing (meeting) | TranscriptLifecycle | "Whisper Turbo is not installed. Install the meeting model in Settings to transcribe." | ui-only |
| TRANS-061 | state | Err: model missing (other) | TranscriptLifecycle | "The speech model is not installed. Install it in Settings to transcribe." | ui-only |
| TRANS-062 | state | Err: verify | TranscriptLifecycle | "The speech model could not be verified. Reinstall it in Settings." | ui-only |
| TRANS-063 | state | Err: load | TranscriptLifecycle | "The speech model failed to load. The recording was not affected." | ui-only |
| TRANS-064 | state | Err: decode | TranscriptLifecycle | "A recorded track could not be decoded. The recording was kept." | ui-only |
| TRANS-065 | state | Err: prepare | TranscriptLifecycle | "Audio could not be prepared for transcription. The recording was kept." | ui-only |
| TRANS-066 | state | Err: engine (meeting) | TranscriptLifecycle | "Meeting transcription failed. The recording was kept; choose Retry to try again." | ui-only |
| TRANS-067 | state | Err: engine (live) | TranscriptLifecycle | "Transcription stopped because the speech model failed. The recording continues." | ui-only |
| TRANS-068 | state | Err: interrupted, auto | TranscriptLifecycle | "Finalization was interrupted. It will resume automatically." | ui-only |
| TRANS-069 | state | Err: interrupted, manual | TranscriptLifecycle | "Finalization was interrupted. Choose Retry to finish it." | ui-only |
| TRANS-070 | state | Err: save | TranscriptLifecycle | "Transcript could not be saved. The recording continues; retry later." | ui-only |
| TRANS-071 | state | Err: storage limit | TranscriptLifecycle | "Transcript storage limit reached (N segments kept). Delete old meetings to free space." | core: `transcript_usage` |
| TRANS-072 | state | Waiting for server | MeetingTranscriptionCoordinator.swift, MeetingDetailView.swift | Shows MEET-046 row; retried on network change | flowd: `meeting_job` on `/v1/remote/channel` |
| TRANS-073 | view | Section title | TranscriptSectionView.swift | "Transcript" 13 semibold; mini progress when a window is in flight | ui-only |
| TRANS-074 | state | Section: pending | TranscriptSectionView.swift | "Pending" | ui-only |
| TRANS-075 | state | Section: failed with reason | TranscriptSectionView.swift | "Transcription failed: ..." | ui-only |
| TRANS-076 | state | Section: off | TranscriptSectionView.swift | "Transcription off" | ui-only |
| TRANS-077 | state | Section: final | TranscriptSectionView.swift | "Final" | ui-only |
| TRANS-078 | state | Section: failed | TranscriptSectionView.swift | "Transcription failed" | ui-only |
| TRANS-079 | state | Section: interrupted | TranscriptSectionView.swift | "Interrupted" | ui-only |
| TRANS-080 | state | Section: catching up | TranscriptSectionView.swift | "Catching up" | ui-only |
| TRANS-081 | state | Section: degraded | TranscriptSectionView.swift | "Degraded — some live text skipped; the full transcript is produced when the meeting stops" | ui-only |
| TRANS-082 | state | Section: suspended | TranscriptSectionView.swift | "Live transcription suspended — catching up" | ui-only |
| TRANS-083 | state | Section: preview stopped | TranscriptSectionView.swift | "Live preview stopped" | ui-only |
| TRANS-084 | state | Section: transcribing | TranscriptSectionView.swift | "Transcribing" | ui-only |
| TRANS-085 | view | Section list | TranscriptSectionView.swift | Height 180, spacing 10, padding 8, surface radius 8 | ui-only |
| TRANS-086 | behavior | Auto follow | TranscriptSectionView.swift | Follows while within 190 of the bottom | ui-only |
| TRANS-087 | view | Section row | TranscriptSectionView.swift | Timestamp mono secondary (mm:ss or h:mm:ss); italic text; "provisional" 11 italic plus circle 3 | ui-only |
| TRANS-088 | swift-note | Edited marker not shown | MeetingDetailView.swift | `SegmentLabel.edited` is populated but no view renders it | ui-only |
| TRANS-089 | swift-note | Legacy row created on read | TranscriptStore.swift `transcription` | A read lazily inserts `not_requested` for terminal legacy meetings | core: `meeting_transcriptions` |

## Assign speakers

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SPK-001 | view | Assign button | MeetingDetailView.swift | `person.badge.plus`, "Assign speakers"; showsSpeakerControls and speakers present | ui-only |
| SPK-002 | state | Controls visible | MeetingDetailView.swift | Diarization present, not live, terminal, row final | core: `meeting_diarization` |
| SPK-003 | behavior | Assign click | MeetingDetailView.swift | Presents sheet; loads `speakerSummaries` | core: `meeting_speakers`, `speaker_assignments`, `identity_assignments` |
| SPK-004 | state | Status: updating | MeetingDetailView.swift | "Updating speaker labels…" 11 muted | ui-only |
| SPK-005 | state | Status: waiting | MeetingDetailView.swift | "Waiting to label speakers…" | ui-only |
| SPK-006 | state | Status: running | MeetingDetailView.swift | "Labeling speakers… N%" | worker: flowd-speech diarization |
| SPK-007 | state | Status: failed | MeetingDetailView.swift | Red message plus "Retry" | ui-only |
| SPK-008 | behavior | Diarization Retry | MeetingDetailView.swift | `requestRun(.retry, revision: nil)`; hidden when OS unsupported | worker: diarization; flowd: `meeting_job` kind `diarize`; core: `diarization_runs` |
| SPK-009 | state | Diar err: model | DiarizationRun.swift | "Speaker labeling model isn't installed. Install it in Settings → Models." | ui-only |
| SPK-010 | state | Diar err: OS | DiarizationRun.swift | "Speaker labeling needs macOS 15 or later." | ui-only |
| SPK-011 | state | Diar err: load | DiarizationRun.swift | "The speaker labeling model couldn't be loaded." | ui-only |
| SPK-012 | state | Diar err: audio missing | DiarizationRun.swift | "This meeting's audio isn't available, so speakers can't be labeled." | ui-only |
| SPK-013 | state | Diar err: audio read | DiarizationRun.swift | "This meeting's audio couldn't be read." | ui-only |
| SPK-014 | state | Diar err: stopped | DiarizationRun.swift | "Speaker labeling stopped unexpectedly." | ui-only |
| SPK-015 | state | Diar err: transcript changed | DiarizationRun.swift | "The transcript changed while speakers were being labeled." | ui-only |
| SPK-016 | state | Diar err: save | DiarizationRun.swift | "Speaker labels couldn't be saved." | ui-only |
| SPK-017 | state | Diar err: full | DiarizationRun.swift | "Speaker labels couldn't be saved. Meeting storage is full." | ui-only |
| SPK-018 | state | Diar err: interrupted | DiarizationRun.swift | "Speaker labeling was interrupted." | ui-only |
| SPK-019 | state | Identify: past search | MeetingDetailView.swift | "Looking for <name> in past meetings (N left)" plus "Cancel" | core: `identification_runs` |
| SPK-020 | behavior | Past search Cancel | SpeakerIdentificationCoordinator.swift `cancelPastSearch` | Clears the queue and name; refreshes | ui-only |
| SPK-021 | state | Identify: waiting | MeetingDetailView.swift | "Waiting to identify speakers…" | ui-only |
| SPK-022 | state | Identify: running | MeetingDetailView.swift | "Identifying speakers… N%" | worker: voice embedding |
| SPK-023 | state | Identify: failed | MeetingDetailView.swift | "Identification failed: <msg>" plus "Retry" | worker: voice embedding |
| SPK-024 | state | Identify: enrolling | MeetingDetailView.swift | "Storing voice sample…" | worker: voice embedding; core: `voice_samples` |
| SPK-025 | state | Id err: OS | IdentificationBoundaries.swift | "Speaker identification needs macOS 15 or later." | ui-only |
| SPK-026 | state | Id err: load | IdentificationBoundaries.swift | "The voice model couldn't be loaded." | ui-only |
| SPK-027 | state | Id err: audio | IdentificationBoundaries.swift | "This meeting's audio isn't available, so speakers can't be identified." | ui-only |
| SPK-028 | state | Id err: stopped | IdentificationBoundaries.swift | "Speaker identification stopped unexpectedly." | ui-only |
| SPK-029 | state | Id err: labels changed | IdentificationBoundaries.swift | "Speaker labels changed while speakers were being identified." | ui-only |
| SPK-030 | state | Id err: save | IdentificationBoundaries.swift | "Speaker identities couldn't be saved." | ui-only |
| SPK-031 | state | Id err: full | IdentificationBoundaries.swift | "Speaker identities couldn't be saved. Meeting storage is full." | ui-only |
| SPK-032 | state | Id err: interrupted | IdentificationBoundaries.swift | "Speaker identification was interrupted." | ui-only |
| SPK-033 | view | Past search prompt | MeetingDetailView.swift | "Look for this voice in past meetings? N meeting(s) would be checked." 12; padding 10, canvas radius 6 | core: `meetingsWithUnknownRemoteSpeakers` |
| SPK-034 | behavior | Look click | SpeakerIdentificationCoordinator.swift `startPastSearch` | Queues up to 500 meetings with unknown remote roots, newest first, excluding the active run | core: `meetings`, `meeting_diarization`, `meeting_speakers`, `identity_assignments` |
| SPK-035 | behavior | Not now click | MeetingDetailView.swift | Hides the prompt | ui-only |
| SPK-036 | view | Row speaker label | MeetingDetailView.swift | 12 medium in SpeakerPalette text color, else ink; top 14 | ui-only |
| SPK-037 | view | Confirm icon | MeetingDetailView.swift | `checkmark.circle` 11 muted, help "Confirm this speaker" | ui-only |
| SPK-038 | behavior | Confirm click | TranscriptPager.swift `confirmIdentity` | Confirms identity, then `identitiesDidChange` | core: `identity_assignments` |
| SPK-039 | state | Confirm failed | TranscriptPager.swift | "The speaker could not be confirmed." | core: `identity_assignments` |
| SPK-040 | view | Change speaker submenu | MeetingDetailView.swift | "Change speaker": choices, divider, "Unknown", "New speaker" | ui-only |
| SPK-041 | behavior | Change to speaker | SpeakerStore.swift `correctSegment` | Sets `speaker_assignments.manual_kind='speaker'`, `manual_speaker_id`, `manual_at`; adds `segment` correction; `evidenceDidChange`; relabels | core: `speaker_assignments`, `speaker_corrections` |
| SPK-042 | behavior | Change to Unknown | SpeakerStore.swift | `manual_kind='unknown'`; correction `new_value='unknown'` | core: `speaker_assignments`, `speaker_corrections` |
| SPK-043 | behavior | Change to New speaker | SpeakerStore.swift | Inserts `meeting_speakers` run_id NULL, source remote, origin manual; next remote ordinal; color = row count % 8; first_ms = segment start | core: `meeting_speakers`, `speaker_assignments` |
| SPK-044 | state | Correction capacity | SpeakerDiarizationCoordinator.swift | 10,000 per meeting: "This meeting has too many speaker changes to save more." | core: `speaker_corrections` count |
| SPK-045 | state | Correction failed | SpeakerDiarizationCoordinator.swift | "The speaker change could not be saved." | core: `correctSegment` |
| SPK-046 | view | Sheet | AssignSpeakersView.swift | Width 560 | ui-only |
| SPK-047 | view | Sheet title | AssignSpeakersView.swift | "Assign speakers" serif 28; padding h32, top 28, bottom 12 | ui-only |
| SPK-048 | view | Close button | AssignSpeakersView.swift | `xmark` 15 medium, 30x30, top 22, trailing 22, "Close" | ui-only |
| SPK-049 | behavior | Close click | AssignSpeakersView.swift | Dismisses without saving | ui-only |
| SPK-050 | view | Sheet scroll | AssignSpeakersView.swift | Min 160, max 480; spacing 28; padding h32, top 20, bottom 28 | ui-only |
| SPK-051 | state | Sheet loading | AssignSpeakersView.swift | Spinner | ui-only |
| SPK-052 | state | Sheet empty | AssignSpeakersView.swift | "There are no speakers to name." 14 muted | ui-only |
| SPK-053 | state | Load failed | AssignSpeakersModel.swift | "Speakers could not be loaded." | core: `speakerSummaries` |
| SPK-054 | view | Review notice row | AssignSpeakersView.swift | Padding 12, canvas radius 10, with "Dismiss" | core: `speaker_corrections` needs_review=1, limit 256 |
| SPK-055 | behavior | Review Dismiss click | SpeakerStore.swift `dismissReview` | `needs_review=0` | core: `speaker_corrections` |
| SPK-056 | state | Review dismiss failed | AssignSpeakersModel.swift | "The notice could not be dismissed." | core: `speaker_corrections` |
| SPK-057 | view | Section header | AssignSpeakersView.swift | Spacing 12; dot 10; label uppercase 12 semibold, tracking 1.4 | ui-only |
| SPK-058 | behavior | Section order | AssignSpeakersModel.swift | isYou first, then color_index, manual after engine, first_ms, cluster_key; limit 512 | core: `meeting_speakers` |
| SPK-059 | view | Merged line | AssignSpeakersView.swift | "Includes <label>" plus "Undo merge" | ui-only |
| SPK-060 | behavior | Undo merge click | SpeakerStore.swift `unmerge` | `merged_into=NULL`, clears merged identity, sets `undone_at`, adds `unmerge` correction | core: `meeting_speakers`, `speaker_corrections`, `identity_assignments` |
| SPK-061 | view | Quotes | AssignSpeakersView.swift | Curly quotes, 14, line spacing 4, ink 0.85, line limit 3; 2pt rule; spacing 12 | core: `quoteCandidates` (top 10 by length per third) and QuoteSelector |
| SPK-062 | view | Name field | AssignSpeakersView.swift | "Type a name" 15, h16, height 46, radius 12 | ui-only |
| SPK-063 | state | Name field active | AssignSpeakersView.swift | Stroke ink 2, else rule 1; 0.12 s ease-out | ui-only |
| SPK-064 | behavior | Name submit | AssignSpeakersView.swift | Saves as Save names | core: `meeting_speakers.display_name` |
| SPK-065 | view | Suggestions | AssignSpeakersView.swift | Inline; padding 6, radius 12, stroke; row 15, h12 v10, hover canvas radius 8; a11y "Use name X" | ui-only |
| SPK-066 | behavior | Suggestion query | SpeakerStore.swift `nameSuggestions` | Limit 8; LIKE prefix with escapes; most recently renamed first; empty field shows recent | core: `meeting_speakers`, `speaker_corrections` |
| SPK-067 | swift-note | Suggestions do not float | AssignSpeakersView.swift | Comment says floating; the view is inline | ui-only |
| SPK-068 | state | Name too long | AssignSpeakersModel.swift | "Use N characters or fewer."; N = `SpeakerNames.maxLength` (80) | core: `SpeakerNames.validate` |
| SPK-069 | state | Name control char | AssignSpeakersModel.swift | "Remove the control character." | core: `SpeakerNames.validate` |
| SPK-070 | state | Duplicate name | AssignSpeakersModel.swift | "Same name as X." plus "Merge" | ui-only |
| SPK-071 | behavior | Merge click | SpeakerStore.swift `merge` | Immediate; moves speaker and members to the root, one `merge` correction each; depth stays 1 | core: `meeting_speakers.merged_into`, `speaker_corrections` |
| SPK-072 | state | Merge capacity | AssignSpeakersModel.swift | "This meeting has too many speaker changes to save more." | core: `speaker_corrections` |
| SPK-073 | state | Merge failed | AssignSpeakersModel.swift | "The change could not be saved." | core: `merge` |
| SPK-074 | view | Local user line | AssignSpeakersView.swift | "Your voice will be remembered from this Mac's microphone." | ui-only |
| SPK-075 | view | Remember my voice | AssignSpeakersView.swift | "Remember my voice"; hidden once remembered | ui-only |
| SPK-076 | state | Match needs choice | AssignSpeakersView.swift | Orange 12 medium: "Choose an identity" | core: `identity_assignments` |
| SPK-077 | swift-note | Match labels computed but hidden | AssignSpeakersModel.swift | "Recognized as X", "Possible match: X?", "Confirmed", "Unknown" exist; only needsChoice renders | ui-only |
| SPK-078 | view | Known speakers button | AssignSpeakersView.swift | "Known speakers…" | core: `knownSpeakers` |
| SPK-079 | view | Confirm action | AssignSpeakersView.swift | "Confirm" | ui-only |
| SPK-080 | view | Choose another | AssignSpeakersView.swift | "Choose another…" | ui-only |
| SPK-081 | view | Keep Unknown | AssignSpeakersView.swift | "Keep Unknown" | ui-only |
| SPK-082 | view | Picker | AssignSpeakersView.swift | "Choose a known speaker…"; row "Name — N voice samples · needs re-enrollment" | core: `known_speakers`, `voice_samples` |
| SPK-083 | view | Same person prompt | AssignSpeakersView.swift | "Is this X you already remember?" "Same person" "Someone new" | ui-only |
| SPK-084 | view | Remember prompt | AssignSpeakersView.swift | "Remember this voice for future meetings?" "Remember" "Not now"; "LocalFlow will store data that can recognize this voice in future meetings on this Mac. It stays on this Mac and you can delete it in Settings › Known speakers." | ui-only |
| SPK-085 | view | Also remember | AssignSpeakersView.swift | "Also remember this voice sample" | ui-only |
| SPK-086 | state | Enroll running | AssignSpeakersView.swift | "Storing voice sample…" | worker: voice embedding |
| SPK-087 | state | Enroll one | AssignSpeakersView.swift | "1 sample stored" | core: `voice_samples` |
| SPK-088 | state | Enroll many | AssignSpeakersView.swift | "N samples stored" | core: `voice_samples` |
| SPK-089 | state | Enroll none | AssignSpeakersView.swift | "No usable voice sample was found in this meeting" | ui-only |
| SPK-090 | state | Enroll disabled | AssignSpeakersView.swift | "Speaker identification is turned off." | core: preferences |
| SPK-091 | state | Enroll failed | AssignSpeakersView.swift | Failure message text | ui-only |
| SPK-092 | view | Footer | AssignSpeakersView.swift | Rule; padding h28 v18; spacing 10; notice red 12, line limit 2 | ui-only |
| SPK-093 | view | Cancel | AssignSpeakersView.swift | "Cancel", `.cancelAction` | ui-only |
| SPK-094 | behavior | Cancel click | AssignSpeakersView.swift | Dismisses; merges already applied stay | ui-only |
| SPK-095 | view | Save names | AssignSpeakersView.swift | "Save names", then "Done" after enrollment; `.defaultAction`; style 14 medium, h18, height 38, radius 9; pressed .8, disabled .45 | ui-only |
| SPK-096 | state | Save disabled | AssignSpeakersView.swift | `!canSave && !enrollmentCompleted` | ui-only |
| SPK-097 | behavior | Save click | AssignSpeakersModel.swift, SpeakerStore.swift `saveNames` | Names in one transaction with one `rename` correction per change; then section actions; closes unless enrollments ran | core: `meeting_speakers.display_name`, `speaker_corrections` |
| SPK-098 | behavior | Save action: link | AssignSpeakersModel.swift, IdentityStore.swift | Origins `manual_profile_selection`, `user_confirmation`, `manual_correction` | core: `identity_assignments` |
| SPK-099 | behavior | Save action: reject | AssignSpeakersModel.swift, IdentityStore.swift | keepUnknown or unlink; rejected pair stored | core: `identity_assignments`, `rejected_candidates` |
| SPK-100 | behavior | Save action: merged | AssignSpeakersModel.swift, IdentityStore.swift | `resolveMerged` with knownSpeaker or keepUnknown | core: `identity_assignments` scope merged |
| SPK-101 | behavior | Save action: enroll | AssignSpeakersModel.swift, SpeakerIdentificationCoordinator.swift `enroll` | Requests system track or local microphone track; name falls back to "You" | worker: voice embedding; core: `known_speakers`, `voice_samples` |
| SPK-102 | state | Names failed | AssignSpeakersModel.swift | "Names could not be saved." | core: `saveNames` |
| SPK-103 | state | Rejects capacity | AssignSpeakersModel.swift | "This meeting has too many rejected matches to save more." | core: `rejected_candidates` |
| SPK-104 | state | Identities failed | AssignSpeakersModel.swift | "Speaker identities could not be saved." | core: `identity_assignments` |
| SPK-105 | swift-note | saved() on failure | AssignSpeakersModel.swift | `saved()` callback runs even when the save failed | ui-only |
| SPK-106 | behavior | Carry-over on rerun | SpeakerStore.swift `carryOver` | Names, merges and corrections map onto new clusters; unmapped become `needs_review` | core: `speaker_corrections`, `meeting_speakers` |
| SPK-107 | view | Palette | SpeakerPalette.swift | Dots light/dark: 1F6FD1/5AA2FF, C2570C/FF9A4D, 1E8A4C/4CC983, 7B4BD1/A98BFF, 0E7C86/3CC6CF, C23B3B/FF7373, B8397D/F07AB8, 8A6A1F/D4B25A; light text 1D66C0, A84B0A, 187441, 7B4BD1, 0C717A, B23636, A8346F, 7E611C; dark text same as dot; index cycles | ui-only |

## Summary

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SUM-001 | view | Tab root | SummaryTabView.swift | Spacing 20 | ui-only |
| SUM-002 | view | Header bar | SummaryTabView.swift | Height 44, canvas radius 8, leading 14, trailing 6, 13 muted | ui-only |
| SUM-003 | view | Header label | SummaryTabView.swift | `lightbulb`; 12 medium, tracking 1.2; "N MIN READ" or "SUMMARY" | ui-only |
| SUM-004 | behavior | Read time | SummaryTabView.swift | ceil(words / 200), min 1 | ui-only |
| SUM-005 | state | Not eligible | SummaryTabView.swift, SummaryModel.swift | Empty plus "Read transcript" (accent) | core: `meeting_transcriptions.state` |
| SUM-006 | state | Reason: unfinished | SummaryModel.swift | "The transcript is not finished yet." | ui-only |
| SUM-007 | state | Reason: off | SummaryModel.swift | "Transcription is off for this meeting." | ui-only |
| SUM-008 | behavior | Read transcript click | SummaryTabView.swift | Switches to Transcript tab | ui-only |
| SUM-009 | state | Eligible | SummaryTabView.swift | "Generate" plus "No summary yet." | core: `meeting_analysis` |
| SUM-010 | behavior | Generate click | SummaryModel.swift | Admits an `analysis_runs` row; runs through the server model | flowd: POST `/v1/analysis/meeting`; core: `analysis_runs` |
| SUM-011 | state | Queued | SummaryTabView.swift | "Queued" plus "Cancel" | core: `analysis_runs.state` |
| SUM-012 | state | Running | SummaryTabView.swift | Progress width 70, label (default "Analyzing"), "Cancel" | core: `analysis_runs.state` |
| SUM-013 | behavior | Cancel click | SummaryModel.swift | Cancels the run | core: `analysis_runs` |
| SUM-014 | state | Queue full | MeetingIntelligenceCoordinator.swift | "Summary queue is full"; capacity 100 | core: queue |
| SUM-015 | state | Failed | SummaryTabView.swift | Message red plus "Retry" | core: `analysis_runs.failure_category` |
| SUM-016 | behavior | Retry click | SummaryModel.swift | Admits a new run | flowd: POST `/v1/analysis/meeting` |
| SUM-017 | state | No read model | SummaryTabView.swift | "Summarizing…" | ui-only |
| SUM-018 | state | Fallback text | MeetingDetailView.swift | "No summary yet." | ui-only |
| SUM-019 | state | Fail: not eligible | SummaryModel.swift | Same reason texts as SUM-006, SUM-007 | ui-only |
| SUM-020 | state | Fail: unreachable | SummaryModel.swift | "Your server could not be reached." | ui-only |
| SUM-021 | state | Fail: credential | SummaryModel.swift | "The server rejected the credential." | ui-only |
| SUM-022 | state | Fail: LLM down | SummaryModel.swift | "The server's language model is not running." | ui-only |
| SUM-023 | state | Fail: busy | SummaryModel.swift | "The server is busy with dictation. Try again in a moment." | ui-only |
| SUM-024 | state | Fail: timeout | SummaryModel.swift | "The summary took too long and was stopped." | ui-only |
| SUM-025 | state | Fail: unreadable | SummaryModel.swift | "The server sent a summary LocalFlow could not read." | ui-only |
| SUM-026 | state | Fail: checks | SummaryModel.swift | "The summary did not pass LocalFlow's checks and was not saved." | ui-only |
| SUM-027 | state | Fail: too long | SummaryModel.swift | "This meeting is too long to summarize with the current limits." | ui-only |
| SUM-028 | state | Fail: save | SummaryModel.swift | "The summary couldn't be saved." | ui-only |
| SUM-029 | state | Fail: full | SummaryModel.swift | "The summary couldn't be saved. Meeting storage is full." | ui-only |
| SUM-030 | state | Fail: interrupted | SummaryModel.swift | "The summary was interrupted." | ui-only |
| SUM-031 | state | Cancelled with accepted | SummaryModel.swift | `.cancelled` with an accepted run shows succeeded | core: `meeting_analysis.accepted_run_id` |
| SUM-032 | view | Copy button | SummaryTabView.swift | `square.on.square`, "Copy summary"; after click `checkmark`, "Copied" for 2 s | ui-only |
| SUM-033 | behavior | Copy click | AnalysisReport.swift | Title, date "d MMM yyyy", "Summary", topics, "- [ ] task — Owner (due 21 Sep)", "(owner unresolved)"; dismissed omitted; ends "Generated by LocalFlow from the meeting transcript and notes." | mac-service: NSPasteboard |
| SUM-034 | view | Summary menu | SummaryTabView.swift | "Regenerate", "Previous edits", "Remove all edits…", divider, "Generated d MMM, HH:mm · AI-generated" | ui-only |
| SUM-035 | behavior | Regenerate click | SummaryModel.swift | Admits a run; overlays stay | flowd: POST `/v1/analysis/meeting`; core: `analysis_runs` |
| SUM-036 | view | Remove all dialog | SummaryTabView.swift | "Remove all edits?"; "Remove All Edits"; "Cancel"; "Your changes to the summary, owners, due dates and items are deleted, and the generated text comes back. This can't be undone." | ui-only |
| SUM-037 | behavior | Remove all confirm | AnalysisStore.swift `removeAllOverlays` | Deletes the meeting's overlays | core: `analysis_overlays` |
| SUM-038 | swift-note | Overlay errors swallowed | SummaryModel.swift | `removeAllEdits` and `removeEdit` use `try?`; failure shows nothing | core: `analysis_overlays` |
| SUM-039 | state | Stale banner | SummaryTabView.swift | "The transcript, speakers or notes changed after this summary." warning 0.12, radius 6, padding 10, 12pt, plus "Regenerate" | core: `meeting_analysis.accepted_evidence_version` |
| SUM-040 | state | Edit error | SummaryTabView.swift | 11 red | core: `setOverlay` |
| SUM-041 | view | Summary body | SummaryTabView.swift | Paragraphs split on "\n\n", spacing 10, line spacing 6 | core: `analysis_summaries.text` |
| SUM-042 | behavior | Summary edit start | SummaryTabView.swift | Double click or context "Edit summary"; id `meeting.summary.edit` | ui-only |
| SUM-043 | view | Summary editor | SummaryTabView.swift | TextEditor 14, min 90, radius 4, stroke; "Save", "Cancel" | ui-only |
| SUM-044 | behavior | Summary Save | AnalysisStore.swift `setOverlay` | Upsert single summary overlay; `user_value`, snapshots; cap per meeting | core: `analysis_overlays` |
| SUM-045 | behavior | Show or Hide AI value | SummaryTabView.swift | "Show AI value" or "Hide AI value"; local; only when edited | ui-only |
| SUM-046 | behavior | Remove text edit | AnalysisStore.swift `removeOverlay` | "Remove text edit"; deletes overlay | core: `analysis_overlays` |
| SUM-047 | view | Topic section | SummaryTabView.swift | Title 15 semibold, spacing 9, top 14; bullets only | core: `analysis_topics` |
| SUM-048 | swift-note | Topic summary hidden | SummaryTabView.swift | `analysis_topics.summary` is stored but not displayed | core: `analysis_topics` |
| SUM-049 | view | Bullet | SummaryTabView.swift | "•", spacing 8, leading 6, line spacing 5 | ui-only |
| SUM-050 | view | Section: action items | SummaryTabView.swift | "Action items" | core: `analysis_items` kind action_item |
| SUM-051 | view | Section: next steps | SummaryTabView.swift | "Next steps" | core: `analysis_items` |
| SUM-052 | view | Section: decisions | SummaryTabView.swift | "Decisions" | core: `analysis_items` |
| SUM-053 | view | Section: open questions | SummaryTabView.swift | "Open questions" | core: `analysis_items` |
| SUM-054 | view | Section: risks | SummaryTabView.swift | "Risks"; copy text says "Risks / blockers" | core: `analysis_items` |
| SUM-055 | swift-note | Risk heading differs | SummaryTabView.swift, AnalysisReport.swift | Screen and copied report use different headings | ui-only |
| SUM-056 | swift-note | Questions and risks read-only | SummaryTabView.swift | Only decision and nextStep rows edit | ui-only |
| SUM-057 | behavior | Item edit | SummaryTabView.swift | Decision or next step: double click; field "Edit"; "Save"; Esc cancels | core: `analysis_overlays` |
| SUM-058 | view | Item attribution | SummaryTabView.swift | " — name" | ui-only |
| SUM-059 | view | Item menu | SummaryTabView.swift | `ellipsis` 11, 20x20; hover reveal; "Edit text", "Show AI value" or "Hide AI value", "Remove text edit", "Remove owner edit", "Remove due-date edit", "Remove status edit" | ui-only |
| SUM-060 | view | Source link | SummaryTabView.swift | `arrow.up.right.square` 11, "View source"; hover reveal | core: `analysis_sources` |
| SUM-061 | behavior | Source click | SummaryTabView.swift, TranscriptPager.swift | Opens Transcript and reveals the segment | core: `analysis_sources`, `transcript_segments` |
| SUM-062 | view | Status toggle | SummaryTabView.swift | `circle` or `checkmark.circle.fill` 13, success or muted; "Mark completed", "Mark open" | ui-only |
| SUM-063 | behavior | Status click | SummaryTabView.swift L475 | `status == .open ? .completed : .open`; overlay status | core: `analysis_overlays` |
| SUM-064 | state | Not open | SummaryTabView.swift | Strikethrough, muted | ui-only |
| SUM-065 | view | Owner menu | SummaryTabView.swift | "Someone else…", "No owner" | core: `speakerRoots` |
| SUM-066 | behavior | Owner pick | SummaryModel.swift | Overlay owner | core: `analysis_overlays` |
| SUM-067 | view | Owner popover | SummaryTabView.swift | "Owner name", "Name", "Save"; width 220, padding 12 | ui-only |
| SUM-068 | view | Due menu | SummaryTabView.swift | "Due date": "Pick date…", "Clear" | ui-only |
| SUM-069 | view | Due popover | SummaryTabView.swift | Graphical date picker "Due", "Clear", "Save"; yyyy-MM-dd; width 220, padding 12 | mac-service: date picker equivalent |
| SUM-070 | behavior | Due save | SummaryModel.swift | Overlay due date | core: `analysis_overlays` |
| SUM-071 | view | Dismiss item | SummaryTabView.swift | "Dismiss" or "Reopen" | ui-only |
| SUM-072 | behavior | Dismiss click | SummaryModel.swift | Overlay status dismissed or open | core: `analysis_overlays` |
| SUM-073 | view | Owner chip: participant | SummaryTabView.swift | Dot 8; "You" if local user; 11, h8 v3, button capsule | core: `analysis_items.owner_speaker_id` |
| SUM-074 | view | Owner chip: mentioned | SummaryTabView.swift | "mentioned" 9, outline | core: `analysis_items.owner_name` |
| SUM-075 | state | Owner maybe | SummaryTabView.swift | "might be X?" plus "Accept" | core: `owner_certainty` |
| SUM-076 | behavior | Accept click | SummaryModel.swift | Overlay owner | core: `analysis_overlays` |
| SUM-077 | state | Owner unresolved | SummaryTabView.swift | Dashed [3,2], "Owner unresolved" or anonymous label | core: `ownership_state` |
| SUM-078 | state | Due known | SummaryTabView.swift | "Due 21 Sep" | core: `due_date` |
| SUM-079 | state | Due unclear | SummaryTabView.swift | `Due: unclear ("soon")` | core: `due_original` |
| SUM-080 | state | Due absent | SummaryTabView.swift | No chip | core: `due_state` |
| SUM-081 | view | Previous edits | SummaryTabView.swift | Title 12 semibold; width 280, padding 14, spacing 10; "Delete" red 11 | core: `analysis_overlays.orphaned_at` |
| SUM-082 | behavior | Previous Delete | AnalysisStore.swift `removeOverlay` | Deletes orphan overlay | core: `analysis_overlays` |
| SUM-083 | behavior | Speaker links | SummaryModel.swift | `localflow-speaker://<id>`, color by mention; opens Assign speakers | ui-only |
| SUM-084 | behavior | Label renaming | SummaryModel.swift | Regex rewrites anonymous labels; matcher allows up to 3 trailing lowercase letters | core: speaker names |
| SUM-085 | swift-note | Shared palette links | SummaryModel.swift | Ponytail note: two roots sharing a palette slot link to the first | ui-only |
| SUM-086 | behavior | Read model | AnalysisStore.swift `readModel` | `analysis_summaries`; topics ORDER BY ordinal; items ORDER BY kind, ordinal; sources ORDER BY target_kind, target_id, ordinal; overlays ORDER BY created_at, id | core: those tables |
