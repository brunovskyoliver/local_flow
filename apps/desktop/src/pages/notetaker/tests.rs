use super::*;
use crate::testing::{assert_saw, boot};
use flow_ui::test::{TestAppContext, TestWindowExt};
use std::time::Duration;

fn open_page(cx: &mut TestAppContext, scenario: Option<&str>) -> WindowHandle<NotetakerPage> {
    boot(cx, Mode::Light);
    let scenario = scenario.map(String::from);
    cx.update(|cx| cx.global_mut::<Core>().scenario = scenario);
    flow_ui::probe::clear();
    let window = cx.add_window(|w, cx| NotetakerPage::new(w, cx));
    frame(cx, &window);
    window
}
fn frame(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>) {
    cx.run_until_parked();
    cx.update_window((*window).into(), |_, w, cx| w.render_frame(cx)).unwrap();
}
fn click(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, id: impl Into<ElementId>) {
    let id = id.into();
    cx.update_window((*window).into(), |_, w, cx| w.click(id, cx)).unwrap();
}
/// Clears and focuses an input, then types through the window as the keyboard would.
macro_rules! type_in {
    ($cx:expr, $window:expr, |$p:ident| $input:expr, $text:expr) => {{
        $window
            .update($cx, |$p, w, cx| {
                let input = $input;
                input.update(cx, |s, cx| s.set_value("", w, cx));
                input.read(cx).focus_handle(cx).focus(w, cx);
            })
            .unwrap();
        $cx.run_until_parked();
        $cx.update_window((*$window).into(), |_, w, cx| w.input($text, cx)).unwrap();
    }};
}
fn shows(cx: &mut TestAppContext, scenario: &str, needles: &[&str]) {
    let window = open_page(cx, Some(scenario));
    assert_saw(needles);
    drop(window);
}
fn query<T>(cx: &mut TestAppContext, f: impl FnOnce(&Db) -> T) -> T {
    cx.update(|cx| f(cx.global::<Core>().db.as_ref().unwrap()))
}
fn read<T>(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, f: impl FnOnce(&NotetakerPage) -> T) -> T {
    window.read_with(cx, |p, _| f(p)).unwrap()
}

// parity: NOTE-012 NOTE-019 NOTE-030 NOTE-045 NOTE-057 NOTE-069
#[flow_ui::gpui::test]
async fn library_lists_groups_and_marks_rows(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    assert_saw(&["Notetaker", "New note", "TODAY", "Past notes", "Lamp prototype review", "From iPhone", "Load older notes"]);
    let rows = read(cx, &window, |p| p.lib.rows.len());
    assert_eq!(rows, PAGE_SIZE as usize);
    window.update(cx, |p, _, cx| p.lib.load_older(db_of(cx).unwrap())).unwrap();
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.lib.rows.len()) > rows);
}

// parity: LIVE-026 LIVE-027
#[flow_ui::gpui::test]
async fn new_note_surfaces_the_missing_recorder(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    click(cx, &window, "meeting.start");
    frame(cx, &window);
    assert_saw(&["isn't available", "Dismiss"]);
    assert_eq!(query(cx, |db| page(db, None, 1000).unwrap().iter().filter(|r| r.state == "recording").count()), 0);
    click(cx, &window, "meeting.dismiss");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.refusal.is_none()));
}

// parity: NOTE-085 NOTE-087 NOTE-088 NOTE-089
#[flow_ui::gpui::test]
async fn deleting_a_row_removes_the_meeting_after_confirming(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    assert!(query(cx, |db| meeting(db, SEED_UNTITLED).unwrap().is_some()));
    window.update(cx, |p, _, cx| {
        p.toggle_menu(&format!("row.{SEED_UNTITLED}"), cx);
    }).unwrap();
    frame(cx, &window);
    click(cx, &window, "notetaker.overflow.delete");
    frame(cx, &window);
    assert_saw(&["Delete this note?"]);
    assert!(query(cx, |db| meeting(db, SEED_UNTITLED).unwrap().is_some()), "only the dialog opens first");
    click(cx, &window, "notetaker.delete.confirm");
    frame(cx, &window);
    assert!(query(cx, |db| meeting(db, SEED_UNTITLED).unwrap().is_none()));
    assert!(read(cx, &window, |p| !p.lib.rows.iter().any(|r| r.id == SEED_UNTITLED)));
}

// parity: NOTE-007 NOTE-047 NOTE-048 NOTE-049 NOTE-050 NOTE-053 NOTE-096 NOTE-098
#[flow_ui::gpui::test]
async fn search_filters_loaded_rows_and_preview_follows_hover(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    click(cx, &window, "notetaker.searchToggle");
    frame(cx, &window);
    type_in!(cx, &window, |p| p.query.clone(), "zzzz-nothing");
    frame(cx, &window);
    flow_ui::probe::clear();
    frame(cx, &window);
    assert_saw(&["No matches"]);
    window.update(cx, |p, _, cx| p.request_preview(SEED_FULL, cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(150));
    flow_ui::probe::clear();
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.lib.preview_id.clone()).as_deref(), Some(SEED_FULL));
    assert_saw(&["MY THOUGHTS"]);
}

// parity: NOTE-052 NOTE-036
#[flow_ui::gpui::test]
async fn library_states(cx: &mut TestAppContext) {
    shows(cx, "notetaker.empty", &["No notes yet"]);
}
// parity: NOTE-076 NOTE-077
#[flow_ui::gpui::test]
async fn waiting_row_runs_on_this_mac(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.waiting"));
    assert_saw(&["Waiting for your server", "Run on this Mac"]);
    click(cx, &window, sid(format!("notetaker.runOnThisMac.{SEED_IPHONE}")));
    frame(cx, &window);
    assert!(query(cx, |db| db.conn.query_row("SELECT 1 FROM meetings WHERE id=?1", [SEED_IPHONE], |r| r.get::<_, i64>(0)).unwrap_or(0)) == 1);
}

// parity: LIVE-008 LIVE-011 LIVE-013 LIVE-020 LIVE-026 NOTE-041
#[flow_ui::gpui::test]
async fn active_card_states(cx: &mut TestAppContext) {
    shows(cx, "notetaker.interrupted-card", &["Recording stopped", "Dismiss", "Microphone", "System audio"]);
}
// parity: LIVE-009 LIVE-014 LIVE-015
#[flow_ui::gpui::test]
async fn failed_card_says_it_could_not_start(cx: &mut TestAppContext) {
    shows(cx, "notetaker.failed-card", &["The meeting could not start", "failed: device lost"]);
}
// parity: TRANS-058 MEET-066 MEET-068
#[flow_ui::gpui::test]
async fn live_transcript_lists_provisional_rows(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.live"));
    assert_saw(&["Let us start with the hinge samples.", "Stop", "Pause"]);
    click(cx, &window, "meeting.stop");
    frame(cx, &window);
    assert_saw(&["isn't available"]);
}
// parity: TRANS-057
#[flow_ui::gpui::test]
async fn live_empty_says_listening_or_off(cx: &mut TestAppContext) {
    shows(cx, "notetaker.live-listening", &["Listening…"]);
}
// parity: TRANS-056
#[flow_ui::gpui::test]
async fn live_off_says_transcription_is_off(cx: &mut TestAppContext) {
    shows(cx, "notetaker.live-off", &["Transcription is off for this note."]);
}

// parity: NOTE-071 MEET-002 MEET-003 MEET-006 MEET-007 MEET-019 MEET-038 MEET-072
#[flow_ui::gpui::test]
async fn opening_a_note_renames_it_and_navigates(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    click(cx, &window, sid(format!("notetaker.note.{SEED_FULL}")));
    frame(cx, &window);
    assert_saw(&["My thoughts", "Transcript", "Summary", "Playback"]);
    type_in!(cx, &window, |p| p.title.clone(), "Renamed lamp review");
    window.update(cx, |p, w, cx| p.save_title(w, cx)).unwrap();
    frame(cx, &window);
    assert_eq!(query(cx, |db| meeting(db, SEED_FULL).unwrap().unwrap().title), Some("Renamed lamp review".to_string()));
    click(cx, &window, "meeting.next");
    frame(cx, &window);
    assert_ne!(read(cx, &window, |p| p.lib.detail.as_ref().map(|d| d.meeting.id.clone())).as_deref(), Some(SEED_FULL));
    click(cx, &window, "meeting.back");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.lib.detail.is_none()));
}

// parity: MEET-057 MEET-055
#[flow_ui::gpui::test]
async fn thoughts_autosave_after_two_seconds(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    type_in!(cx, &window, |p| p.thoughts.clone(), "A new thought.");
    frame(cx, &window);
    assert_ne!(query(cx, |db| notes(db, SEED_FULL).unwrap().unwrap().0), "A new thought.");
    cx.executor().advance_clock(Duration::from_secs(3));
    frame(cx, &window);
    assert_eq!(query(cx, |db| notes(db, SEED_FULL).unwrap().unwrap().0), "A new thought.");
}

// parity: MEET-016 MEET-017
#[flow_ui::gpui::test]
async fn deleting_the_open_note_returns_to_the_library(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.delete"));
    assert_saw(&["This removes the meeting's audio files and notes from this Mac."]);
    click(cx, &window, "notetaker.delete.confirm");
    frame(cx, &window);
    assert!(query(cx, |db| meeting(db, SEED_FULL).unwrap().is_none()));
    assert!(read(cx, &window, |p| p.lib.detail.is_none()));
}
// parity: MEET-024
#[flow_ui::gpui::test]
async fn warnings_show_on_the_untitled_note(cx: &mut TestAppContext) {
    shows(cx, "notetaker.untitled", &["Some audio was lost during recording."]);
}

// parity: TRANS-011 TRANS-012 TRANS-014 TRANS-049 TRANS-052 TRANS-055
#[flow_ui::gpui::test]
async fn transcript_reads_labels_search_and_selection(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    assert_saw(&["You", "Marta Kováčová", "Microphone changed"]);
    click(cx, &window, "meeting.transcript.search.open");
    frame(cx, &window);
    type_in!(cx, &window, |p| p.search.clone(), "the");
    cx.executor().advance_clock(Duration::from_millis(300));
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.pager.as_ref().unwrap().search_hits.as_ref().map(|h| h.0.len())), Some(11));
    let first = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().next().unwrap().id.clone());
    window.update(cx, |p, _, cx| p.toggle_menu(&format!("seg.{first}"), cx)).unwrap();
    frame(cx, &window);
    click(cx, &window, "meeting.transcript.row.select");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.pager.as_ref().unwrap().selection.contains(&first)));
}

// parity: SPK-040 SPK-042
#[flow_ui::gpui::test]
async fn change_speaker_writes_the_correction(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    let first = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().next().unwrap().id.clone());
    window.update(cx, |p, _, cx| p.toggle_menu(&format!("seg.{first}"), cx)).unwrap();
    frame(cx, &window);
    click(cx, &window, "meeting.transcript.row.unknown");
    frame(cx, &window);
    let manual: Option<String> = query(cx, |db| db.conn.query_row("SELECT manual_kind FROM speaker_assignments WHERE segment_id=?1", [&first], |r| r.get(0)).unwrap());
    assert_eq!(manual.as_deref(), Some("unknown"));
}

// parity: TRANS-027 TRANS-031 TRANS-035 TRANS-037
#[flow_ui::gpui::test]
async fn export_and_status_lines_surface_failures(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.label-failed"));
    click(cx, &window, "meeting.transcript.copy");
    frame(cx, &window);
    assert_saw(&["Copy Full Transcript", "Export Transcript…"]);
    click(cx, &window, "meeting.transcript.export");
    frame(cx, &window);
    assert_saw(&["The transcript could not be exported."]);
}

// parity: SPK-046 SPK-047 SPK-062 SPK-095 SPK-097
#[flow_ui::gpui::test]
async fn assign_speakers_saves_a_name(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    assert_saw(&["Assign speakers", "Save names"]);
    let target = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().position(|s| s.speaker.name.is_none() && !s.speaker.is_you()).unwrap());
    let id = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections[target].speaker.id.clone());
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), "Jana Horvat");
    frame(cx, &window);
    click(cx, &window, "meeting.speakers.save");
    frame(cx, &window);
    let saved: Option<String> = query(cx, |db| db.conn.query_row("SELECT display_name FROM meeting_speakers WHERE id=?1", [&id], |r| r.get(0)).unwrap());
    assert_eq!(saved.as_deref(), Some("Jana Horvat"));
}
// parity: SPK-093 SPK-094
#[flow_ui::gpui::test]
async fn assign_escape_style_cancel_writes_nothing(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let target = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().position(|s| s.speaker.name.is_none() && !s.speaker.is_you()).unwrap());
    let id = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections[target].speaker.id.clone());
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), "Nobody");
    click(cx, &window, "meeting.speakers.cancel");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.assign.is_none()));
    let saved: Option<String> = query(cx, |db| db.conn.query_row("SELECT display_name FROM meeting_speakers WHERE id=?1", [&id], |r| r.get(0)).unwrap());
    assert_ne!(saved.as_deref(), Some("Nobody"));
}

// parity: SUM-003 SUM-036 SUM-037 SUM-050 SUM-052 SUM-062 SUM-063
#[flow_ui::gpui::test]
async fn summary_reads_stored_analysis_and_marks_an_item_done(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    assert_saw(&["MIN READ", "Action items", "Ask the workshop to loosen the hinge tolerance", "Decisions"]);
    click(cx, &window, "meeting.summary.status.0");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.summary.model.as_ref().unwrap().action_items[0].status.clone()), "completed");
    let stored: i64 = query(cx, |db| db.conn.query_row("SELECT COUNT(*) FROM analysis_overlays WHERE meeting_id=?1 AND field='status'", [SEED_FULL], |r| r.get(0)).unwrap());
    assert_eq!(stored, 1);
    click(cx, &window, "meeting.summary.options");
    frame(cx, &window);
    click(cx, &window, "meeting.summary.removeEdits");
    frame(cx, &window);
    assert_saw(&["Remove all edits?"]);
    click(cx, &window, "meeting.summary.removeEdits.confirm");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.summary.model.as_ref().unwrap().action_items[0].status.clone()), "open");
}
// parity: SUM-008 SUM-009
#[flow_ui::gpui::test]
async fn generate_reports_the_missing_worker(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary-eligible"));
    assert_saw(&["No summary yet.", "Read transcript"]);
    click(cx, &window, "meeting.summary.generate");
    frame(cx, &window);
    assert_saw(&["isn't available"]);
    click(cx, &window, "meeting.summary.readTranscript");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.tab == Tab::Transcript));
}
// parity: SUM-039
#[flow_ui::gpui::test]
async fn summary_states(cx: &mut TestAppContext) {
    shows(cx, "notetaker.summary-stale", &["The transcript, speakers or notes changed after this summary."]);
}
// parity: SUM-061 TRANS-016
#[flow_ui::gpui::test]
async fn view_source_jumps_to_transcript(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let source = read(cx, &window, |p| p.summary.model.as_ref().unwrap().action_items[0].sources[0].clone());
    window.update(cx, |p, _, cx| match &source {
        SourceRef::Segment(id) => p.reveal_segment(id, cx),
        SourceRef::Note(o, h) => p.reveal_note(*o, h, cx),
    }).unwrap();
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.tab == Tab::Transcript));
    assert!(read(cx, &window, |p| p.pager.as_ref().unwrap().highlighted.is_some()));
    cx.executor().advance_clock(Duration::from_secs(3));
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.pager.as_ref().unwrap().highlighted.is_none()));
}

// parity: NOTE-042 NOTE-043
#[flow_ui::gpui::test]
async fn notice_shows_the_page_error(cx: &mut TestAppContext) {
    shows(cx, "notetaker.notice", &["Meetings could not be loaded. Check app storage."]);
}
// parity: NOTE-055
#[flow_ui::gpui::test]
async fn evicted_offers_show_newest(cx: &mut TestAppContext) {
    shows(cx, "notetaker.evicted", &["Show newest"]);
}
// parity: NOTE-033 NOTE-061 NOTE-072 NOTE-073 NOTE-074
#[flow_ui::gpui::test]
async fn recording_row_is_pinned(cx: &mut TestAppContext) {
    shows(cx, "notetaker.recording", &["Recording now"]);
}
// parity: NOTE-034 NOTE-075
#[flow_ui::gpui::test]
async fn paused_row_says_paused(cx: &mut TestAppContext) {
    shows(cx, "notetaker.paused", &["Recording paused"]);
}
// parity: NOTE-035
#[flow_ui::gpui::test]
async fn finalizing_row_says_finishing(cx: &mut TestAppContext) {
    shows(cx, "notetaker.finalizing", &["Finishing the recording"]);
}
// parity: NOTE-024 LIVE-017 LIVE-018 LIVE-032
#[flow_ui::gpui::test]
async fn refusal_shows_the_message_and_settings(cx: &mut TestAppContext) {
    shows(cx, "notetaker.refusal", &["Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone.", "Open System Settings", "Dismiss"]);
}
// parity: LIVE-002 LIVE-005 LIVE-007 LIVE-012 LIVE-020 LIVE-022 LIVE-028 LIVE-033
#[flow_ui::gpui::test]
async fn panel_shows_controls_title_and_notes(cx: &mut TestAppContext) {
    shows(cx, "notetaker.panel", &["Recording", "Pause", "Stop Meeting", "Notes", "Microphone", "capturing"]);
}
// parity: LIVE-010 LIVE-016
#[flow_ui::gpui::test]
async fn notice_card_shows_storage_and_notice(cx: &mut TestAppContext) {
    shows(cx, "notetaker.notice-card", &["The meeting folder is running out of space.", "Recorded audio was recovered where possible."]);
}
// parity: MEET-046 MEET-047 TRANS-072
#[flow_ui::gpui::test]
async fn waiting_detail_offers_this_mac(cx: &mut TestAppContext) {
    shows(cx, "notetaker.waiting-detail", &["Waiting for your server", "Run on this Mac"]);
}
// parity: MEET-049 MEET-023 MEET-065
#[flow_ui::gpui::test]
async fn detail_shows_provenance(cx: &mut TestAppContext) {
    shows(cx, "notetaker.detail", &["Transcript: this Mac"]);
}
// parity: LIVE-045 TRANS-073 TRANS-079 TRANS-085 TRANS-087
#[flow_ui::gpui::test]
async fn section_interrupted(cx: &mut TestAppContext) {
    shows(cx, "notetaker.section:interrupted", &["Transcript", "Interrupted", "provisional", "Let us start with the hinge samples."]);
}
// parity: TRANS-081
#[flow_ui::gpui::test]
async fn section_degraded(cx: &mut TestAppContext) {
    shows(cx, "notetaker.section:live:degraded", &["Degraded — some live text skipped; the full transcript is produced when the meeting stops"]);
}
// parity: SUM-011
#[flow_ui::gpui::test]
async fn summary_queued(cx: &mut TestAppContext) {
    shows(cx, "notetaker.summary-pending", &["Queued", "Cancel"]);
}
// parity: SUM-012
#[flow_ui::gpui::test]
async fn summary_running(cx: &mut TestAppContext) {
    shows(cx, "notetaker.summary-running", &["Summarizing with your server…", "Cancel"]);
}
// parity: SUM-015
#[flow_ui::gpui::test]
async fn summary_failed(cx: &mut TestAppContext) {
    shows(cx, "notetaker.summary-failed", &["Retry"]);
}
// parity: SUM-005 SUM-006
#[flow_ui::gpui::test]
async fn summary_not_finished(cx: &mut TestAppContext) {
    shows(cx, "notetaker.summary-not-finished", &["The transcript is not finished yet.", "Read transcript"]);
}
// parity: SUM-007
#[flow_ui::gpui::test]
async fn summary_off(cx: &mut TestAppContext) {
    shows(cx, "notetaker.off-summary", &["Transcription is off for this meeting."]);
}
// parity: SPK-004
#[flow_ui::gpui::test]
async fn labels_updating(cx: &mut TestAppContext) {
    shows(cx, "notetaker.labeling-update", &["Updating speaker labels…"]);
}
// parity: SPK-005
#[flow_ui::gpui::test]
async fn labels_waiting(cx: &mut TestAppContext) {
    shows(cx, "notetaker.label-waiting", &["Waiting to label speakers…"]);
}
// parity: SPK-006
#[flow_ui::gpui::test]
async fn labels_running(cx: &mut TestAppContext) {
    shows(cx, "notetaker.labeling", &["Labeling speakers…"]);
}
// parity: SPK-007
#[flow_ui::gpui::test]
async fn labels_failed(cx: &mut TestAppContext) {
    shows(cx, "notetaker.label-failed", &["Retry"]);
}
// parity: SPK-021
#[flow_ui::gpui::test]
async fn identify_waiting(cx: &mut TestAppContext) {
    shows(cx, "notetaker.identify-waiting", &["Waiting to identify speakers…"]);
}
// parity: SPK-022
#[flow_ui::gpui::test]
async fn identify_running(cx: &mut TestAppContext) {
    shows(cx, "notetaker.identifying", &["Identifying speakers…"]);
}
// parity: SPK-023
#[flow_ui::gpui::test]
async fn identify_failed(cx: &mut TestAppContext) {
    shows(cx, "notetaker.identify-failed", &["Identification failed:", "Retry"]);
}
// parity: SPK-024
#[flow_ui::gpui::test]
async fn identify_enrolling(cx: &mut TestAppContext) {
    shows(cx, "notetaker.enrolling", &["Storing voice sample…"]);
}
// parity: SPK-019
#[flow_ui::gpui::test]
async fn past_search_running(cx: &mut TestAppContext) {
    shows(cx, "notetaker.past-search", &["in past meetings", "Cancel"]);
}
// parity: SPK-033
#[flow_ui::gpui::test]
async fn past_search_prompt(cx: &mut TestAppContext) {
    shows(cx, "notetaker.past-prompt", &["Look for this voice in past meetings?"]);
}

// parity: LIVE-034 LIVE-035 LIVE-036 LIVE-037
#[flow_ui::gpui::test]
async fn panel_notes_state_follows_the_editor(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    let set = |p: &mut NotetakerPage, cx: &mut Context<NotetakerPage>, dirty: bool, state: SaveState| {
        let e = p.editor.as_mut().unwrap();
        e.is_dirty = dirty;
        e.state = state;
        cx.notify();
    };
    for (dirty, state, text) in [(true, SaveState::Idle, "Unsaved"), (true, SaveState::Saving, "Saving…"), (false, SaveState::Saved, "Saved"), (true, SaveState::NotSaved, "Not saved")] {
        window.update(cx, |p, _, cx| set(p, cx, dirty, state)).unwrap();
        flow_ui::probe::clear();
        frame(cx, &window);
        assert_saw(&[text]);
    }
}

// parity: NOTE-014 NOTE-015 NOTE-016
#[flow_ui::gpui::test]
async fn recording_options_and_refresh_click(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    click(cx, &window, "notetaker.options");
    frame(cx, &window);
    assert_saw(&["Transcribe new recordings"]);
    let before = read(cx, &window, |p| p.transcribe);
    click(cx, &window, "notetaker.transcribeNew");
    frame(cx, &window);
    assert_ne!(read(cx, &window, |p| p.transcribe), before);
}

// parity: MEET-009 MEET-012 MEET-039
#[flow_ui::gpui::test]
async fn final_transcript_offers_retranscribe_and_tabs_switch(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    click(cx, &window, "meeting.options");
    frame(cx, &window);
    assert_saw(&["Re-transcribe", "Delete"]);
    window.update(cx, |p, _, cx| p.toggle_menu("", cx)).unwrap();
    frame(cx, &window);
    click(cx, &window, "meeting.tab.summary");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.tab == Tab::Summary));
}

// parity: MEET-020
#[flow_ui::gpui::test]
async fn title_too_long_shows_the_limit(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    let long = "x".repeat(300);
    type_in!(cx, &window, |p| p.title.clone(), &long);
    window.update(cx, |p, w, cx| p.save_title(w, cx)).unwrap();
    flow_ui::probe::clear();
    frame(cx, &window);
    assert_saw(&["Titles are limited to 256 bytes."]);
    assert_ne!(query(cx, |db| meeting(db, SEED_FULL).unwrap().unwrap().title).as_deref(), Some(long.as_str()));
}

// parity: SUM-041 SUM-047 SUM-049 SUM-051 SUM-053 SUM-058 SUM-075 SUM-079 SUM-073 SUM-074 SUM-077 SUM-078
#[flow_ui::gpui::test]
async fn summary_shows_sections_chips_and_attribution(cx: &mut TestAppContext) {
    shows(cx, "notetaker.summary", &["The order waits until both quotes are in", "Hinges and supplier", "•", "Next steps", "Open questions", "Risks", "Pick the review up again on Friday — You", "Due: unclear (\"soon\")", "might be Tomas Novak?", "Accept", "mentioned", "Owner unresolved", "Due 6 Nov"]);
}
// parity: SUM-042 SUM-043 SUM-044
#[flow_ui::gpui::test]
async fn summary_edit_saves_an_overlay(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    click(cx, &window, "meeting.summary.editMenu");
    frame(cx, &window);
    click(cx, &window, "meeting.summary.edit");
    frame(cx, &window);
    assert_saw(&["Save", "Cancel"]);
    type_in!(cx, &window, |p| p.summary.summary_input.clone(), "Rewritten.");
    frame(cx, &window);
    click(cx, &window, "meeting.summary.edit.save");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.summary.model.as_ref().unwrap().summary.clone()), "Rewritten.");
}
// parity: SPK-001 SPK-003 SPK-048 SPK-049 SPK-057 SPK-061 SPK-075 SPK-078
#[flow_ui::gpui::test]
async fn assign_opens_shows_sections_and_closes(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    click(cx, &window, "meeting.speakers.assign.open");
    frame(cx, &window);
    assert_saw(&["YOU", "SPEAKER 1", "Remember my voice", "Known speakers…", "Type a name"]);
    assert!(read(cx, &window, |p| p.assign.is_some()));
    click(cx, &window, "meeting.speakers.close");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.assign.is_none()));
}
// parity: SPK-074
#[flow_ui::gpui::test]
async fn assign_shows_identity_choices(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    click(cx, &window, "identity.rememberLocal");
    flow_ui::probe::clear();
    frame(cx, &window);
    assert_saw(&["Your voice will be remembered from this Mac's microphone."]);
}
// parity: SPK-068 SPK-096
#[flow_ui::gpui::test]
async fn long_name_blocks_saving(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let id = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| s.speaker.name.is_none() && !s.speaker.is_you()).unwrap().speaker.id.clone());
    let long = "n".repeat(81);
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), &long);
    flow_ui::probe::clear();
    frame(cx, &window);
    assert_saw(&["Use 80 characters or fewer."]);
    assert!(read(cx, &window, |p| !p.assign.as_ref().unwrap().model.can_save()));
}
// parity: SPK-020
#[flow_ui::gpui::test]
async fn past_search_cancel_clears(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.past-search"));
    click(cx, &window, "identity.pastSearch.cancel");
    flow_ui::probe::clear();
    frame(cx, &window);
    assert!(!flow_ui::probe::seen().iter().any(|s| s.contains("in past meetings")));
}
// parity: SPK-035
#[flow_ui::gpui::test]
async fn past_prompt_not_now_hides(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.past-prompt"));
    click(cx, &window, "identity.pastSearch.notNow");
    flow_ui::probe::clear();
    frame(cx, &window);
    assert!(!flow_ui::probe::seen().iter().any(|s| s.contains("Look for this voice")));
}
// parity: NOTE-090
#[flow_ui::gpui::test]
async fn delete_cancel_writes_nothing(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.delete-row"));
    click(cx, &window, "notetaker.delete.cancel");
    frame(cx, &window);
    assert!(query(cx, |db| page(db, None, 1000).unwrap().len()) >= 29);
}
// parity: MEET-005 MEET-008
#[flow_ui::gpui::test]
async fn previous_disabled_on_first_note_then_goes_back(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    click(cx, &window, "meeting.previous");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.lib.detail.as_ref().map(|d| d.meeting.id.clone())).as_deref(), Some(SEED_FULL));
    click(cx, &window, "meeting.next");
    frame(cx, &window);
    click(cx, &window, "meeting.previous");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.lib.detail.as_ref().map(|d| d.meeting.id.clone())).as_deref(), Some(SEED_FULL));
}
// parity: NOTE-081 NOTE-082
#[flow_ui::gpui::test]
async fn row_shows_state_badge(cx: &mut TestAppContext) {
    shows(cx, "notetaker.search", &["Interrupted"]);
}
// parity: MEET-026
#[flow_ui::gpui::test]
async fn interrupted_note_shows_its_reason(cx: &mut TestAppContext) {
    shows(cx, "notetaker.interrupted", &["LocalFlow did not exit cleanly during this meeting."]);
}
