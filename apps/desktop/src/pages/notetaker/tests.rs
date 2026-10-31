use super::*;
use crate::testing::{assert_saw, boot};
use flow_ui::test::{TestAppContext, TestQueryExt, TestWindowExt};
use std::time::Duration;

fn open_page(cx: &mut TestAppContext, scenario: Option<&str>) -> WindowHandle<NotetakerPage> {
    boot(cx, Mode::Light);
    let scenario = scenario.map(String::from);
    cx.update(|cx| cx.global_mut::<Core>().scenario = scenario);
    flow_ui::probe::clear();
    let window = cx.add_window(|w, cx| NotetakerPage::new(w, cx));
    // Tall, so what the tests click is in view; `resize` narrows it where layout matters.
    cx.simulate_window_resize(window.into(), size(px(1180.), px(3000.)));
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
    assert_saw(&["Delete this note?", "Delete note", "Cancel", "This removes the recording, transcript and thoughts from this Mac."]);
    assert!(query(cx, |db| meeting(db, SEED_UNTITLED).unwrap().is_some()), "only the dialog opens first");
    click(cx, &window, "notetaker.delete.confirm");
    frame(cx, &window);
    assert!(query(cx, |db| meeting(db, SEED_UNTITLED).unwrap().is_none()));
    assert!(read(cx, &window, |p| !p.lib.rows.iter().any(|r| r.id == SEED_UNTITLED)));
}

// parity: NOTE-047 NOTE-048
#[flow_ui::gpui::test]
async fn search_toggle_hides_the_field_and_keeps_the_query(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    assert!(!has(cx, &window, "notetaker.search"));
    click(cx, &window, "notetaker.searchToggle");
    frame(cx, &window);
    type_in!(cx, &window, |p| p.query.clone(), "lamp");
    click(cx, &window, "notetaker.searchToggle");
    frame(cx, &window);
    assert!(!has(cx, &window, "notetaker.search"));
    click(cx, &window, "notetaker.searchToggle");
    frame(cx, &window);
    let kept = window.read_with(cx, |p, cx| p.query.read(cx).value().to_string()).unwrap();
    assert_eq!(kept, "lamp");
}

// parity: NOTE-049
#[flow_ui::gpui::test]
async fn search_field_sits_twelve_under_the_tabs_on_the_canvas(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    click(cx, &window, "notetaker.searchToggle");
    fresh(cx, &window);
    assert_eq!(find(cx, &window, "notetaker.searchField").bounds().size.height, px(37.));
}

// parity: NOTE-050 NOTE-053
#[flow_ui::gpui::test]
async fn search_filters_the_loaded_rows_by_title(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    click(cx, &window, "notetaker.searchToggle");
    frame(cx, &window);
    type_in!(cx, &window, |p| p.query.clone(), "budget");
    fresh(cx, &window);
    assert_saw(&["Budget call"]);
    assert!(!seen("Lamp prototype review"), "a row whose title doesn't match leaves the list");
    type_in!(cx, &window, |p| p.query.clone(), "zzzz-nothing");
    fresh(cx, &window);
    assert_saw(&["No matches"]);
}

// parity: NOTE-007 NOTE-096
#[flow_ui::gpui::test]
async fn preview_waits_before_loading_and_is_empty_until_then(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    fresh(cx, &window);
    assert!(!has(cx, &window, "notetaker.preview.title"), "no row, no content");
    window.update(cx, |p, _, cx| p.request_preview(SEED_FULL, cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(100));
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.lib.preview_id.clone()), None, "still inside the 120 ms wait");
    cx.executor().advance_clock(Duration::from_millis(50));
    fresh(cx, &window);
    assert_eq!(read(cx, &window, |p| p.lib.preview_id.clone()).as_deref(), Some(SEED_FULL));
    assert_saw(&["MY THOUGHTS"]);
}

// parity: NOTE-052 NOTE-036
#[flow_ui::gpui::test]
async fn library_states(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.empty"));
    assert_saw(&["No notes yet"]);
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
    let _window = open_page(cx, Some("notetaker.interrupted-card"));
    assert_saw(&["Recording stopped", "Dismiss", "Microphone", "System audio"]);
}
// parity: LIVE-009 LIVE-014 LIVE-015
#[flow_ui::gpui::test]
async fn failed_card_says_it_could_not_start(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.failed-card"));
    assert_saw(&["The meeting could not start", "failed: device lost"]);
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
    let _window = open_page(cx, Some("notetaker.live-listening"));
    assert_saw(&["Listening…"]);
}
// parity: TRANS-056
#[flow_ui::gpui::test]
async fn live_off_says_transcription_is_off(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.live-off"));
    assert_saw(&["Transcription is off for this note."]);
    let (outer, inner) = (find(cx, &window, "meeting.transcript.liveEmpty").bounds(), find(cx, &window, "meeting.transcript.liveEmpty.text").bounds());
    assert_eq!(inner.origin.y - outer.origin.y, px(20.), "v20");
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
    let _window = open_page(cx, Some("notetaker.untitled"));
    assert_saw(&["Some audio was lost during recording."]);
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
    let ordinal = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().next().unwrap().ordinal);
    right_click(cx, &window, sid(format!("meeting.transcript.bubble.{ordinal}")));
    menu_item(cx, &window, 0);
    assert!(read(cx, &window, |p| p.pager.as_ref().unwrap().selection.contains(&first)));
}

// parity: TRANS-027 TRANS-035 TRANS-037
#[flow_ui::gpui::test]
async fn export_and_status_lines_surface_failures(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.label-failed"));
    click(cx, &window, "meeting.transcript.copy");
    fresh(cx, &window);
    assert!(!seen("could not be exported"));
    menu_item(cx, &window, 2);
    fresh(cx, &window);
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
    menu_item(cx, &window, 2);
    assert_saw(&["Remove all edits?"]);
    click(cx, &window, "meeting.summary.removeEdits.confirm");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.summary.model.as_ref().unwrap().action_items[0].status.clone()), "open");
}
// parity: SUM-008 SUM-009
#[flow_ui::gpui::test]
async fn generate_reports_the_missing_worker(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary-eligible"));
    assert_saw(&["No summary yet."]);
    assert!(!has(cx, &window, "meeting.summary.readTranscript"), "only a meeting that can't be summarized offers it");
    click(cx, &window, "meeting.summary.generate");
    frame(cx, &window);
    assert_saw(&["isn't available"]);
    let window = open_page(cx, Some("notetaker.summary-not-finished"));
    click(cx, &window, "meeting.summary.readTranscript");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.tab == Tab::Transcript));
}
// parity: SUM-039
#[flow_ui::gpui::test]
async fn summary_states(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.summary-stale"));
    assert_saw(&["The transcript, speakers or notes changed after this summary."]);
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
    let _window = open_page(cx, Some("notetaker.notice"));
    assert_saw(&["Meetings could not be loaded. Check app storage."]);
}
// parity: NOTE-055
#[flow_ui::gpui::test]
async fn evicted_offers_show_newest(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.evicted"));
    assert_saw(&["Show newest"]);
}
// parity: NOTE-033 NOTE-072 NOTE-073 NOTE-074
#[flow_ui::gpui::test]
async fn recording_row_is_pinned(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.recording"));
    assert_saw(&["Recording now"]);
}
// parity: NOTE-074
#[flow_ui::gpui::test]
async fn recording_badge_pulses_and_paused_does_not(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.recording"));
    assert!(has(cx, &window, "meeting.waveform"));
    let window = open_page(cx, Some("notetaker.live-paused"));
    assert!(!has(cx, &window, "meeting.waveform"));
}
// parity: NOTE-034 NOTE-075
#[flow_ui::gpui::test]
async fn paused_row_says_paused(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.paused"));
    assert_saw(&["Recording paused"]);
}
// parity: NOTE-035
#[flow_ui::gpui::test]
async fn finalizing_row_says_finishing(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.finalizing"));
    assert_saw(&["Finishing the recording"]);
}
// parity: NOTE-024 LIVE-017 LIVE-018 LIVE-032
#[flow_ui::gpui::test]
async fn refusal_shows_the_message_and_settings(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.refusal"));
    assert_saw(&["Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone.", "Open System Settings", "Dismiss"]);
}
// parity: LIVE-002 LIVE-005 LIVE-007 LIVE-012 LIVE-020 LIVE-022 LIVE-028 LIVE-033
#[flow_ui::gpui::test]
async fn panel_shows_controls_title_and_notes(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.panel"));
    assert_saw(&["Recording", "Pause", "Stop Meeting", "Notes", "Microphone", "capturing"]);
}
// parity: LIVE-010
#[flow_ui::gpui::test]
async fn notice_card_shows_storage_and_notice(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.notice-card"));
    assert_saw(&["The meeting folder is running out of space.", "Recorded audio was recovered where possible."]);
}
// parity: MEET-046 MEET-047 TRANS-072
#[flow_ui::gpui::test]
async fn waiting_detail_offers_this_mac(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.waiting-detail"));
    assert_saw(&["Waiting for your server", "Run on this Mac"]);
}
// parity: MEET-049 MEET-023 MEET-065
#[flow_ui::gpui::test]
async fn detail_shows_provenance(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.detail"));
    assert_saw(&["Transcript: this Mac"]);
}
// parity: LIVE-045 TRANS-073 TRANS-079 TRANS-085 TRANS-087
#[flow_ui::gpui::test]
async fn section_interrupted(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.section:interrupted"));
    assert_saw(&["Transcript", "Interrupted", "provisional", "Let us start with the hinge samples."]);
}
// parity: TRANS-081
#[flow_ui::gpui::test]
async fn section_degraded(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.section:live:degraded"));
    assert_saw(&["Degraded — some live text skipped; the full transcript is produced when the meeting stops"]);
}
// parity: SUM-011
#[flow_ui::gpui::test]
async fn summary_queued(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.summary-pending"));
    assert_saw(&["Queued", "Cancel"]);
}
// parity: SUM-012
#[flow_ui::gpui::test]
async fn summary_running(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.summary-running"));
    assert_saw(&["Analyzing", "Cancel"]);
}
// parity: SUM-015
#[flow_ui::gpui::test]
async fn summary_failed(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.summary-failed"));
    assert_saw(&["The server's language model is not running.", "Retry"]);
}
// parity: SUM-005 SUM-006
#[flow_ui::gpui::test]
async fn summary_not_finished(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary-not-finished"));
    assert_saw(&["The transcript is not finished yet."]);
    assert!(has(cx, &window, "meeting.summary.readTranscript"));
}
// parity: SUM-007
#[flow_ui::gpui::test]
async fn summary_off(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.off-summary"));
    assert_saw(&["Transcription is off for this meeting."]);
}
// parity: SPK-004
#[flow_ui::gpui::test]
async fn labels_updating(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.labeling-update"));
    assert_saw(&["Updating speaker labels…"]);
}
// parity: SPK-005
#[flow_ui::gpui::test]
async fn labels_waiting(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.label-waiting"));
    assert_saw(&["Waiting to label speakers…"]);
}
// parity: SPK-006
#[flow_ui::gpui::test]
async fn labels_running(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.labeling"));
    assert_saw(&["Labeling speakers…"]);
}
// parity: SPK-007
#[flow_ui::gpui::test]
async fn labels_failed(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.label-failed"));
    assert_saw(&["Retry"]);
}
// parity: SPK-021
#[flow_ui::gpui::test]
async fn identify_waiting(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.identify-waiting"));
    assert_saw(&["Waiting to identify speakers…"]);
}
// parity: SPK-022
#[flow_ui::gpui::test]
async fn identify_running(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.identifying"));
    assert_saw(&["Identifying speakers…"]);
}
// parity: SPK-023
#[flow_ui::gpui::test]
async fn identify_failed(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.identify-failed"));
    assert_saw(&["Identification failed:", "Retry"]);
}
// parity: SPK-024
#[flow_ui::gpui::test]
async fn identify_enrolling(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.enrolling"));
    assert_saw(&["Storing voice sample…"]);
}
// parity: SPK-019
#[flow_ui::gpui::test]
async fn past_search_running(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.past-search"));
    assert_saw(&["in past meetings", "Cancel"]);
}
// parity: SPK-033
#[flow_ui::gpui::test]
async fn past_search_prompt(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.past-prompt"));
    assert_saw(&["Look for this voice in past meetings?"]);
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
    window.update(cx, |p, _, cx| set(p, cx, true, SaveState::Idle)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Unsaved"]);
    window.update(cx, |p, _, cx| set(p, cx, true, SaveState::Saving)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Saving…"]);
    window.update(cx, |p, _, cx| set(p, cx, false, SaveState::Saved)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Saved"]);
    window.update(cx, |p, _, cx| set(p, cx, true, SaveState::NotSaved)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Not saved"]);
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

// parity: SUM-041 SUM-047 SUM-049 SUM-051 SUM-053 SUM-058 SUM-075 SUM-079 SUM-073 SUM-074 SUM-078
#[flow_ui::gpui::test]
async fn summary_shows_sections_chips_and_attribution(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.summary"));
    assert_saw(&["The order waits until both quotes are in", "Hinges and supplier", "•", "Next steps", "Open questions", "Risks", "Pick the review up again on Friday — You", "Due: unclear (\"soon\")", "might be Tomas Novak?", "Accept", "mentioned", "Owner unresolved", "Due 6 Nov"]);
}
// parity: SPK-001 SPK-003 SPK-048 SPK-049 SPK-057 SPK-061 SPK-075 SPK-078
#[flow_ui::gpui::test]
async fn assign_opens_shows_sections_and_closes(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    click(cx, &window, "meeting.speakers.assign.open");
    frame(cx, &window);
    assert_saw(&["YOU", "SPEAKER 1", "Remember my voice", "Known speakers…"]);
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
    let _window = open_page(cx, Some("notetaker.search"));
    assert_saw(&["Interrupted"]);
}
// parity: MEET-026
#[flow_ui::gpui::test]
async fn interrupted_note_shows_its_reason(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.interrupted"));
    assert_saw(&["LocalFlow did not exit cleanly during this meeting."]);
}

// --- Round 2: rows that had no real test.

fn sql(cx: &mut TestAppContext, text: &str) {
    // Test rows go past schema checks that the Mac workers' writes satisfy by other columns.
    query(cx, |db| db.conn.execute_batch(&format!("PRAGMA ignore_check_constraints=ON; {text}")).unwrap());
}
/// A trigger that refuses a write, the way a full or locked store would.
fn refuse(cx: &mut TestAppContext, event: &str, table: &str) {
    sql(cx, &format!("CREATE TEMP TRIGGER refuse_{event}_{table} BEFORE {event} ON {table} BEGIN SELECT RAISE(ABORT,'refused'); END;"));
}
fn allow(cx: &mut TestAppContext, event: &str, table: &str) {
    sql(cx, &format!("DROP TRIGGER temp.refuse_{event}_{table};"));
}
/// Clicks the open popup menu's item; separators count, as Kit numbers them.
fn menu_item(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, ix: usize) {
    frame(cx, window);
    cx.update_window((*window).into(), |_, w, cx| w.within("popup-menu").click(ix, cx)).unwrap();
    frame(cx, window);
}
/// Hovers a submenu item open and clicks the submenu's item.
fn submenu_item(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, item: usize, ix: usize) {
    frame(cx, window);
    cx.update_window((*window).into(), |_, w, cx| w.within("popup-menu").hover(item, cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(400));
    frame(cx, window);
    cx.update_window((*window).into(), |_, w, cx| w.within("submenu").click(ix, cx)).unwrap();
    frame(cx, window);
}
fn right_click(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, id: impl Into<ElementId>) {
    let id = id.into();
    cx.update_window((*window).into(), |_, w, cx| w.right_click(id, cx)).unwrap();
    frame(cx, window);
}
fn find(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, id: impl Into<ElementId>) -> flow_ui::test::ElementSnapshot {
    let id = id.into();
    cx.update_window((*window).into(), |_, w, _| w.find(id)).unwrap()
}
fn has(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, id: impl Into<ElementId>) -> bool {
    let id = id.into();
    cx.update_window((*window).into(), |_, w, _| w.try_find(id).is_some()).unwrap()
}
fn resize(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, width: f32, height: f32) {
    cx.simulate_window_resize((*window).into(), size(px(width), px(height)));
    frame(cx, window);
}
fn seen(needle: &str) -> bool {
    flow_ui::probe::seen().iter().any(|s| s.contains(needle))
}
/// Renders afresh so `seen` only reports the current frame.
fn fresh(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>) {
    flow_ui::probe::clear();
    frame(cx, window);
}
fn open(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, id: &str, tab: Tab) {
    window.update(cx, |p, w, cx| p.open_note(id, tab, w, cx)).unwrap();
    fresh(cx, window);
}

// parity: NOTE-002
#[flow_ui::gpui::test]
async fn library_load_copies_the_transcription_preference(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("meetingTranscriptionEnabled", false));
    let window = cx.add_window(|w, cx| NotetakerPage::new(w, cx));
    frame(cx, &window);
    assert!(!read(cx, &window, |p| p.transcribe));
    assert!(read(cx, &window, |p| !p.lib.rows.is_empty()), "the load task also refreshes the rows");
}

// parity: NOTE-003 NOTE-004 NOTE-005 NOTE-006
#[flow_ui::gpui::test]
async fn compact_width_trades_the_preview_for_an_overview_popover(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1180., 780.);
    assert!(has(cx, &window, "notetaker.preview"));
    assert!(!has(cx, &window, "notetaker.overview"));
    assert_eq!(find(cx, &window, "notetaker.preview").bounds().size.width, px(230.));
    resize(cx, &window, 780., 780.);
    assert!(!has(cx, &window, "notetaker.preview"));
    let icon = find(cx, &window, "notetaker.overview").bounds();
    assert_eq!((icon.size.width, icon.size.height), (px(28.), px(28.)));
    click(cx, &window, "notetaker.overview");
    frame(cx, &window);
    assert_eq!(find(cx, &window, "notetaker.popover").bounds().size.width, px(250.));
    assert_eq!(find(cx, &window, "notetaker.preview").bounds().size.height, px(380.));
}

// parity: NOTE-008 NOTE-010 MEET-090
#[flow_ui::gpui::test]
async fn leaving_lets_go_of_the_note_and_closing_the_sheet_refreshes_the_summary(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    cx.update(crate::shell::ensure_session);
    open(cx, &window, SEED_FULL, Tab::Transcript);
    window.update(cx, |p, w, cx| p.open_assign(None, w, cx)).unwrap();
    window.update(cx, |p, _, _| p.summary.model = None).unwrap();
    click(cx, &window, "meeting.speakers.close");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.summary.model.is_some()), "MEET-090: dismissing re-reads the summary");
    click(cx, &window, "meeting.back");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.editor.is_none() && p.pager.is_none()), "NOTE-010");
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    window.update(cx, |p, _, cx| { if let Some(db) = db_of(cx) { p.lib.preview(db, SEED_FULL) } }).unwrap();
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = crate::pages::Page::History));
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.lib.detail.is_none() && p.lib.preview_id.is_none() && p.editor.is_none()), "NOTE-008");
}
// parity: NOTE-011
#[flow_ui::gpui::test]
async fn a_new_window_starts_without_the_old_note(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    cx.update_window(window.into(), |_, w, _| w.remove_window()).unwrap();
    cx.run_until_parked();
    let again = cx.add_window(|w, cx| NotetakerPage::new(w, cx));
    frame(cx, &again);
    assert!(read(cx, &again, |p| p.lib.detail.is_none() && p.editor.is_none()));
}
// parity: NOTE-044 NOTE-059
#[flow_ui::gpui::test]
async fn older_page_failure_and_the_loading_guard(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    window.update(cx, |p, _, cx| { p.lib.is_loading = true; cx.notify() }).unwrap();
    frame(cx, &window);
    assert_eq!(find(cx, &window, "notetaker.loadOlder").disabled(), Some(true));
    window.update(cx, |p, _, cx| { p.lib.is_loading = false; cx.notify() }).unwrap();
    frame(cx, &window);
    sql(cx, "ALTER TABLE meetings RENAME TO meetings_gone;");
    click(cx, &window, "notetaker.loadOlder");
    fresh(cx, &window);
    assert_saw(&["Older meetings could not be loaded."]);
}
// parity: NOTE-046
#[flow_ui::gpui::test]
async fn past_notes_tab_does_nothing(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let before = read(cx, &window, |p| (p.lib.rows.len(), p.show_search, p.menu.clone()));
    click(cx, &window, "notetaker.pastNotes");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| (p.lib.rows.len(), p.show_search, p.menu.clone())), before);
}
// parity: NOTE-083 NOTE-084 NOTE-086
#[flow_ui::gpui::test]
async fn overflow_button_popover_and_disabled_delete(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.recording"));
    resize(cx, &window, 1180., 780.);
    flow_ui::probe::clear();
    frame(cx, &window);
    assert_saw(&["symbol:ellipsis"]);
    let snapshot = find(cx, &window, sid(format!("notetaker.overflow.{SEED_FULL}")));
    assert_eq!(snapshot.label().map(|l| l.to_string()).as_deref(), Some("Note options"));
    let button = snapshot.bounds();
    assert_eq!(button.size.width, px(28.));
    let row = find(cx, &window, sid(format!("notetaker.rowContainer.{SEED_FULL}"))).bounds();
    assert_eq!(row.right() - button.right(), px(8.), "horizontal padding 8 in rows");
    window.update(cx, |p, _, cx| p.toggle_menu(&format!("row.{SEED_FULL}"), cx)).unwrap();
    frame(cx, &window);
    assert_eq!(find(cx, &window, "notetaker.popover").bounds().size.width, px(190.));
    assert_ne!(find(cx, &window, "notetaker.overflow.delete").disabled(), Some(true));
    window.update(cx, |p, _, cx| p.toggle_menu(&format!("row.{SEED_UNTITLED}"), cx)).unwrap();
    frame(cx, &window);
    sql(cx, &format!("UPDATE meetings SET state='recording' WHERE id='{SEED_UNTITLED}';"));
    window.update(cx, |p, _, cx| p.refresh(cx)).unwrap();
    frame(cx, &window);
    assert_eq!(find(cx, &window, "notetaker.overflow.delete").disabled(), Some(true));
}
// parity: NOTE-091 MEET-044
#[flow_ui::gpui::test]
async fn files_left_behind_keep_the_row_and_offer_retry(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    let moved: usize = query(cx, |db| db.conn.execute("UPDATE meeting_segments SET relative_path='elsewhere/a.wav' WHERE track_id IN (SELECT id FROM meeting_tracks WHERE meeting_id=?1)", [SEED_FULL]).unwrap());
    assert!(moved > 0);
    let revision = read(cx, &window, |p| p.lib.detail.as_ref().unwrap().meeting.revision);
    window.update(cx, |p, w, cx| p.delete(SEED_FULL, revision, w, cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Deletion incomplete:", "file(s) remain. Retry after checking the folder.", "Retry deletion"]);
    assert!(query(cx, |db| meeting(db, SEED_FULL).unwrap().is_some()));
    assert!(read(cx, &window, |p| p.lib.deletion_pending.contains(SEED_FULL)));
    assert!(has(cx, &window, "meeting.retryDeletion"));
    sql(cx, &format!("UPDATE meeting_segments SET relative_path='{SEED_FULL}/a.wav' WHERE track_id IN (SELECT id FROM meeting_tracks WHERE meeting_id='{SEED_FULL}');"));
    click(cx, &window, "meeting.retryDeletion");
    frame(cx, &window);
    assert!(query(cx, |db| meeting(db, SEED_FULL).unwrap().is_none()));
}
// parity: NOTE-092 NOTE-094
#[flow_ui::gpui::test]
async fn delete_refusals_read_like_swift(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    let revision = read(cx, &window, |p| p.lib.detail.as_ref().unwrap().meeting.revision);
    refuse(cx, "DELETE", "meetings");
    window.update(cx, |p, w, cx| p.delete(SEED_FULL, revision, w, cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["The meeting could not be deleted."]);
    allow(cx, "DELETE", "meetings");
    sql(cx, &format!("UPDATE meetings SET state='recording' WHERE id='{SEED_FULL}';"));
    window.update(cx, |p, w, cx| p.delete(SEED_FULL, revision, w, cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Stop the meeting before deleting it."]);
    assert!(query(cx, |db| meeting(db, SEED_FULL).unwrap().is_some()));
}
// parity: NOTE-097 NOTE-099 NOTE-100 NOTE-101 NOTE-102
#[flow_ui::gpui::test]
async fn preview_states(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1180., 780.);
    window.update(cx, |p, _, cx| p.request_preview(SEED_UNTITLED, cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(50));
    window.update(cx, |p, _, cx| p.request_preview(SEED_FULL, cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(200));
    fresh(cx, &window);
    assert_eq!(read(cx, &window, |p| p.lib.preview_id.clone()).as_deref(), Some(SEED_FULL), "the earlier request is ignored");
    assert!(read(cx, &window, |p| p.lib.preview.as_ref().unwrap().tracks.is_empty()), "the preview drops tracks");
    assert_saw(&["Lamp prototype review", " · ", "MY THOUGHTS"]);
    sql(cx, &format!("UPDATE meeting_notes SET text='' WHERE meeting_id='{SEED_UNTITLED}';"));
    window.update(cx, |p, _, cx| p.request_preview(SEED_UNTITLED, cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(200));
    fresh(cx, &window);
    assert!(!seen("MY THOUGHTS"), "no notes, no heading");
    window.update(cx, |p, _, cx| p.lib.preview(db_of(cx).unwrap(), SEED_FULL)).unwrap();
    sql(cx, &format!("DELETE FROM meetings WHERE id='{SEED_FULL}';"));
    window.update(cx, |p, _, cx| { p.lib.preview(db_of(cx).unwrap(), SEED_FULL); cx.notify() }).unwrap();
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.lib.preview_notice.clone()).as_deref(), Some("This note no longer exists."));
    sql(cx, "ALTER TABLE meeting_notes RENAME TO notes_gone;");
    window.update(cx, |p, _, cx| { p.lib.preview(db_of(cx).unwrap(), SEED_UNTITLED); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_saw(&["The overview could not be loaded."]);
}

// parity: MEET-004 MEET-061 MEET-062
#[flow_ui::gpui::test]
async fn a_failed_save_keeps_the_note_open_until_retry_works(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    refuse(cx, "UPDATE", "meeting_notes");
    type_in!(cx, &window, |p| p.thoughts.clone(), "Keep me.");
    click(cx, &window, "meeting.back");
    fresh(cx, &window);
    assert!(read(cx, &window, |p| p.lib.detail.is_some()), "stays on the note");
    assert_saw(&["Notes not saved", "Retry save"]);
    allow(cx, "UPDATE", "meeting_notes");
    click(cx, &window, "meeting.retrySave");
    fresh(cx, &window);
    assert!(!seen("Notes not saved"));
    assert_eq!(query(cx, |db| notes(db, SEED_FULL).unwrap().unwrap().0), "Keep me.");
}
fn transcription_items(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, state: &str) -> [bool; 3] {
    window.update(cx, |p, _, cx| { p.lib.detail = None; p.pager = None; cx.notify() }).unwrap();
    sql(cx, &format!("UPDATE meeting_transcriptions SET state='{state}' WHERE meeting_id='{SEED_FULL}';"));
    open(cx, window, SEED_FULL, Tab::Thoughts);
    flow_ui::probe::clear();
    click(cx, window, "meeting.options");
    frame(cx, window);
    ["meeting.transcript.transcribe", "meeting.transcript.retry", "meeting.transcript.retranscribe"].map(|id| has(cx, window, id))
}
// parity: MEET-009 MEET-010 MEET-011 MEET-013
#[flow_ui::gpui::test]
async fn overflow_title_follows_the_transcription_state(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let word = |text: &str| flow_ui::probe::seen().iter().any(|t| t == text);
    assert_eq!(transcription_items(cx, &window, "not_requested"), [true, false, false]);
    assert!(word("Transcribe") && !word("Retry transcription") && !word("Re-transcribe"));
    assert_eq!(transcription_items(cx, &window, "failed"), [false, true, false]);
    assert!(word("Retry transcription") && !word("Transcribe"));
    assert_eq!(transcription_items(cx, &window, "interrupted"), [false, true, false]);
    assert!(word("Retry transcription"));
    assert_eq!(transcription_items(cx, &window, "final"), [false, false, true]);
    assert!(word("Re-transcribe") && !word("Transcribe"));
    assert_eq!(transcription_items(cx, &window, "pending"), [false, false, false]);
    assert_eq!(transcription_items(cx, &window, "live"), [false, false, false]);
    assert_eq!(transcription_items(cx, &window, "finalizing"), [false, false, false]);
}
// parity: MEET-022
#[flow_ui::gpui::test]
async fn title_write_failure_reports(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    refuse(cx, "UPDATE", "meetings");
    type_in!(cx, &window, |p| p.title.clone(), "Will fail");
    window.update(cx, |p, w, cx| p.save_title(w, cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["The title could not be saved."]);
}
// parity: MEET-025
#[flow_ui::gpui::test]
async fn duration_warning_shows_for_a_drifting_track(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    sql(cx, &format!("UPDATE meeting_tracks SET dropped_frames=0, duration_warning=1 WHERE meeting_id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    assert_saw(&["A recording track does not match the meeting duration. Some audio may be missing."]);
    assert!(has(cx, &window, "meeting.durationWarning"));
}
// parity: MEET-041 MEET-042 MEET-043
#[flow_ui::gpui::test]
async fn detail_read_failures(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    sql(cx, "ALTER TABLE meeting_notes RENAME TO notes_gone;");
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    assert_saw(&["Meeting details could not be loaded."]);
    assert!(read(cx, &window, |p| p.lib.detail.is_some()), "the open note stays");
    sql(cx, "ALTER TABLE notes_gone RENAME TO meeting_notes;");
    window.update(cx, |p, w, cx| p.open_note("no-such-note", Tab::Thoughts, w, cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["This meeting no longer exists."]);
    assert!(read(cx, &window, |p| p.lib.detail.is_none()));
}
// parity: MEET-050 MEET-051 MEET-052
#[flow_ui::gpui::test]
async fn provenance_names_the_place(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let path = |cx: &mut TestAppContext, path: &str| {
        sql(cx, &format!("UPDATE meeting_transcriptions SET inference_path='{path}' WHERE meeting_id='{SEED_FULL}';"));
        open(cx, &window, SEED_FULL, Tab::Thoughts);
    };
    path(cx, "custom");
    assert_saw(&["Transcript: your custom server"]);
    path(cx, "local_after_server_failure");
    assert_saw(&["Transcript: this Mac (server unavailable)"]);
    path(cx, "server");
    assert_saw(&["Transcript: your server"]);
}
// parity: MEET-056
#[flow_ui::gpui::test]
async fn thoughts_placeholder_only_while_empty(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    sql(cx, &format!("UPDATE meeting_notes SET text='' WHERE meeting_id='{SEED_UNTITLED}';"));
    open(cx, &window, SEED_UNTITLED, Tab::Thoughts);
    assert!(has(cx, &window, "meeting.thoughts.placeholder"));
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    assert!(!has(cx, &window, "meeting.thoughts.placeholder"));
}
// parity: MEET-067
#[flow_ui::gpui::test]
async fn paused_footer_offers_resume_which_reports_the_missing_worker(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.live-paused"));
    assert!(!has(cx, &window, "meeting.pause"));
    click(cx, &window, "meeting.resume");
    fresh(cx, &window);
    assert_saw(&["isn't available"]);
}
// parity: MEET-092
#[flow_ui::gpui::test]
async fn detail_read_orders_tracks_and_segments(cx: &mut TestAppContext) {
    let (kinds, offsets) = {
        open_page(cx, None);
        query(cx, |db| {
            let d = detail(db, SEED_FULL).unwrap().unwrap();
            (d.tracks.iter().map(|t| t.kind.clone()).collect::<Vec<_>>(), d.tracks[0].segments.iter().map(|s| s.start_offset_ms).collect::<Vec<_>>())
        })
    };
    assert_eq!(kinds.first().map(String::as_str), Some("microphone"));
    assert!(offsets.windows(2).all(|w| w[0] <= w[1]), "{offsets:?}");
}

// parity: LIVE-003 LIVE-004
#[flow_ui::gpui::test]
async fn active_title_saves_on_enter_and_reports_failures(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    type_in!(cx, &window, |p| p.active_title.clone(), "Standup");
    cx.update_window(window.into(), |_, w, cx| w.press("enter", cx)).unwrap();
    frame(cx, &window);
    assert_eq!(query(cx, |db| meeting(db, SEED_UNTITLED).unwrap().unwrap().title).as_deref(), Some("Standup"));
    let long = "t".repeat(257);
    type_in!(cx, &window, |p| p.active_title.clone(), &long);
    cx.update_window(window.into(), |_, w, cx| w.press("enter", cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Titles are limited to 256 bytes."]);
    refuse(cx, "UPDATE", "meetings");
    type_in!(cx, &window, |p| p.active_title.clone(), "Refused");
    cx.update_window(window.into(), |_, w, cx| w.press("enter", cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["The title could not be saved."]);
    assert_eq!(query(cx, |db| meeting(db, SEED_UNTITLED).unwrap().unwrap().title).as_deref(), Some("Standup"));
}

// parity: TRANS-003
#[flow_ui::gpui::test]
async fn header_badge_shows_only_when_not_final(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    open(cx, &window, SEED_FULL, Tab::Transcript);
    assert!(!flow_ui::probe::seen().iter().any(|s| s.starts_with("· ")));
    sql(cx, &format!("UPDATE meeting_transcriptions SET state='interrupted' WHERE meeting_id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    assert!(flow_ui::probe::seen().iter().any(|s| s.starts_with("· ")));
}
// parity: TRANS-013 TRANS-015
#[flow_ui::gpui::test]
async fn search_keys_close_and_the_navigator_is_twenty_points(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    click(cx, &window, "meeting.transcript.search.open");
    window.update(cx, |_, w, _| w.activate_window()).unwrap();
    frame(cx, &window);
    window.update(cx, |p, w, cx| p.title.read(cx).focus_handle(cx).focus(w, cx)).unwrap();
    frame(cx, &window);
    frame(cx, &window);
    assert!(read(cx, &window, |p| !p.search_open), "blur with an empty query closes");
    click(cx, &window, "meeting.transcript.search.open");
    frame(cx, &window);
    type_in!(cx, &window, |p| p.search.clone(), "the");
    cx.executor().advance_clock(Duration::from_millis(300));
    frame(cx, &window);
    for id in ["meeting.transcript.search.previous", "meeting.transcript.search.next"] {
        let b = find(cx, &window, id).bounds();
        assert_eq!((b.size.width, b.size.height), (px(20.), px(20.)));
    }
    cx.update_window(window.into(), |_, w, cx| w.press("escape", cx)).unwrap();
    frame(cx, &window);
    assert!(read(cx, &window, |p| !p.search_open), "Esc closes");
}
// parity: TRANS-026 TRANS-040
#[flow_ui::gpui::test]
async fn transcript_read_failures(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    sql(cx, "ALTER TABLE transcript_segments RENAME TO segments_gone;");
    window.update(cx, |p, _, cx| { p.pager.as_mut().unwrap().search(db_of(cx).unwrap(), "hinge"); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_saw(&["The transcript could not be searched."]);
    open(cx, &window, SEED_FULL, Tab::Transcript);
    assert_saw(&["The transcript could not be loaded."]);
}
// parity: TRANS-028 TRANS-029 TRANS-030
#[flow_ui::gpui::test]
async fn copy_menu_selected_item(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    assert_eq!(transcript::copy_selected_title(0), "Copy Selected Segments");
    assert_eq!(transcript::copy_selected_title(2), "Copy 2 Selected Segments");
    click(cx, &window, "meeting.transcript.copy");
    frame(cx, &window);
    menu_item(cx, &window, 0);
    assert!(cx.read_from_clipboard().is_none(), "nothing selected: the item is disabled");
    let first = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().next().unwrap().clone());
    window.update(cx, |p, _, cx| { p.pager.as_mut().unwrap().toggle_selection(&first.id); cx.notify() }).unwrap();
    frame(cx, &window);
    cx.update_window(window.into(), |_, w, cx| w.press("escape", cx)).unwrap();
    frame(cx, &window);
    click(cx, &window, "meeting.transcript.copy");
    menu_item(cx, &window, 0);
    assert!(cx.read_from_clipboard().and_then(|c| c.text()).is_some_and(|t| t.contains(&first.text)));
}
// parity: TRANS-031 TRANS-034
#[flow_ui::gpui::test]
async fn copy_full_writes_or_says_why_not(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    click(cx, &window, "meeting.transcript.copy");
    menu_item(cx, &window, 1);
    assert!(cx.read_from_clipboard().and_then(|c| c.text()).is_some_and(|t| t.contains("hinge samples")));
    sql(cx, "ALTER TABLE transcript_segments RENAME TO segments_gone;");
    click(cx, &window, "meeting.transcript.copy");
    menu_item(cx, &window, 1);
    fresh(cx, &window);
    assert_saw(&["The transcript could not be copied."]);
}
// parity: TRANS-033
#[flow_ui::gpui::test]
async fn copy_too_long_points_to_export(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    sql(cx, "SELECT 1;");
    let huge: String = "x".repeat(FULL_TEXT_LIMIT + 1);
    query(cx, |db| db.conn.execute("UPDATE transcript_segments SET assembled_text=?1, normalized_text=?1, raw_text=?1 WHERE id=(SELECT id FROM transcript_segments WHERE meeting_id=?2 LIMIT 1)", [huge.as_str(), SEED_FULL]).unwrap());
    click(cx, &window, "meeting.transcript.copy");
    menu_item(cx, &window, 1);
    fresh(cx, &window);
    assert_saw(&["The transcript is too long to copy. Export it to a file instead."]);
}
// parity: TRANS-041
#[flow_ui::gpui::test]
async fn finality_rule(_: &mut TestAppContext) {
    let row = |state: &str, segments: i64| Transcription { state: state.into(), segment_count: segments, ..Transcription::default() };
    assert_eq!(finality_for(Some(&row("final", 3))), "final");
    for state in ["finalizing", "live", "pending", "not_requested"] {
        assert_eq!(finality_for(Some(&row(state, 3))), "provisional", "{state}");
    }
    assert_eq!(finality_for(None), "final");
    let failed = |pass: &str| Transcription { state: "failed".into(), pass_kind: Some(pass.into()), ..Transcription::default() };
    assert_eq!(finality_for(Some(&failed("final"))), "final");
    assert_eq!(finality_for(Some(&failed("live"))), "provisional");
}
// parity: TRANS-045 TRANS-046 TRANS-047
#[flow_ui::gpui::test]
async fn bubble_colors_follow_state(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    cx.update(|cx| {
        let p = pal(cx);
        assert_eq!(transcript::bubble_colors(false, false, "final", cx), (p.canvas, p.ink));
        assert_eq!(transcript::bubble_colors(false, true, "final", cx).0, p.tint);
        assert_eq!(transcript::bubble_colors(true, true, "final", cx).0, p.accent.opacity(0.2));
        assert_eq!(transcript::bubble_colors(false, false, "provisional", cx).1, p.muted);
    });
}
// parity: TRANS-050 TRANS-051
#[flow_ui::gpui::test]
async fn source_labels_for_rows_without_speakers(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    sql(cx, &format!("UPDATE meeting_diarization SET accepted_run_id=NULL WHERE meeting_id='{SEED_FULL}'; UPDATE transcript_segments SET analysis_tracks='system' WHERE id=(SELECT id FROM transcript_segments WHERE meeting_id='{SEED_FULL}' ORDER BY ordinal LIMIT 1); UPDATE transcript_segments SET analysis_tracks='both' WHERE meeting_id='{SEED_FULL}' AND id<>(SELECT id FROM transcript_segments WHERE meeting_id='{SEED_FULL}' ORDER BY ordinal LIMIT 1);"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    assert_saw(&["Others", "Unassigned"]);
    assert_eq!(source_explanation("system"), "System audio; may include multiple people");
    assert_eq!(source_explanation("both"), "Mixed microphone and system audio; speaker unknown");
}
// parity: TRANS-052 TRANS-053 TRANS-055
#[flow_ui::gpui::test]
async fn bubble_context_menu_selects_and_plays(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    let row = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().next().unwrap().clone());
    let bubble = sid(format!("meeting.transcript.bubble.{}", row.ordinal));
    right_click(cx, &window, bubble.clone());
    menu_item(cx, &window, 0);
    assert!(read(cx, &window, |p| p.pager.as_ref().unwrap().selection.contains(&row.id)));
    right_click(cx, &window, bubble.clone());
    menu_item(cx, &window, 0);
    assert!(read(cx, &window, |p| !p.pager.as_ref().unwrap().selection.contains(&row.id)), "Deselect");
    query(cx, |db| db.conn.execute("UPDATE meeting_segments SET state='finalized' WHERE track_id IN (SELECT id FROM meeting_tracks WHERE meeting_id=?1)", [SEED_FULL]).unwrap());
    open(cx, &window, SEED_FULL, Tab::Transcript);
    right_click(cx, &window, bubble);
    menu_item(cx, &window, 1);
    assert!(read(cx, &window, |p| p.playing), "Play from here");
}
// parity: TRANS-086
#[flow_ui::gpui::test]
async fn section_list_follows_near_the_bottom_only(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.section:interrupted"));
    window.update(cx, |p, _, cx| {
        let s = p.status.as_mut().unwrap();
        s.segments = (0..60).map(|i| (format!("Row {i}"), "mic".to_string())).collect();
        cx.notify();
    }).unwrap();
    frame(cx, &window);
    frame(cx, &window);
    let at_end = read(cx, &window, |p| (-p.section_scroll.offset().y.as_f32(), p.section_scroll.max_offset().y.as_f32()));
    assert!(at_end.1 > 190., "{at_end:?}");
    assert!((at_end.1 - at_end.0).abs() < 1., "follows: {at_end:?}");
    window.update(cx, |p, _, _| p.section_scroll.set_offset(point(px(0.), px(0.)))).unwrap();
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.section_scroll.offset().y), px(0.), "scrolled away, it stays");
}

// parity: SPK-002
#[flow_ui::gpui::test]
async fn assign_control_needs_a_final_finished_meeting_with_labels(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    open(cx, &window, SEED_FULL, Tab::Transcript);
    assert!(has(cx, &window, "meeting.speakers.assign.open"));
    sql(cx, &format!("UPDATE meeting_transcriptions SET state='interrupted' WHERE meeting_id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    assert!(!has(cx, &window, "meeting.speakers.assign.open"), "row not final");
    sql(cx, &format!("UPDATE meeting_transcriptions SET state='final' WHERE meeting_id='{SEED_FULL}'; UPDATE meeting_diarization SET accepted_run_id=NULL WHERE meeting_id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    assert!(!has(cx, &window, "meeting.speakers.assign.open"), "no diarization");
}
// parity: SPK-037 SPK-038 SPK-039
#[flow_ui::gpui::test]
async fn confirming_a_suggested_speaker(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    assert_saw(&["Tomas Novak?"]);
    refuse(cx, "UPDATE", "identity_assignments");
    refuse(cx, "INSERT", "identity_assignments");
    let confirm = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().find(|r| r.label.as_ref().is_some_and(|l| l.suggested.is_some())).unwrap().ordinal);
    let confirm_in = |cx: &mut TestAppContext| cx.update_window(window.into(), |_, w, cx| w.within(sid(format!("meeting.transcript.row.{confirm}"))).click("speaker.confirm", cx)).unwrap();
    confirm_in(cx);
    fresh(cx, &window);
    assert_saw(&["The speaker could not be confirmed."]);
    allow(cx, "UPDATE", "identity_assignments");
    allow(cx, "INSERT", "identity_assignments");
    confirm_in(cx);
    fresh(cx, &window);
    assert!(!seen("Tomas Novak?"), "the label is no longer a question");
    assert_saw(&["Tomas Novak"]);
}
// parity: SPK-040 SPK-042
#[flow_ui::gpui::test]
async fn change_speaker_submenu_writes_the_correction(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    let row = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().next().unwrap().clone());
    let choices = read(cx, &window, |p| p.pager.as_ref().unwrap().speakers.as_ref().unwrap().1.iter().filter(|x| x.merged_into.is_none()).count());
    right_click(cx, &window, sid(format!("meeting.transcript.bubble.{}", row.ordinal)));
    fresh(cx, &window);
    submenu_item(cx, &window, 2, choices + 1);
    let manual: Option<String> = query(cx, |db| db.conn.query_row("SELECT manual_kind FROM speaker_assignments WHERE segment_id=?1", [&row.id], |r| r.get(0)).unwrap());
    assert_eq!(manual.as_deref(), Some("unknown"));
    let manual_rows = |cx: &mut TestAppContext| -> i64 { query(cx, |db| db.conn.query_row("SELECT count(*) FROM meeting_speakers WHERE meeting_id=?1 AND origin='manual'", [SEED_FULL], |r| r.get(0)).unwrap()) };
    let before = manual_rows(cx);
    right_click(cx, &window, sid(format!("meeting.transcript.bubble.{}", row.ordinal)));
    submenu_item(cx, &window, 2, choices + 2);
    assert_eq!(manual_rows(cx), before + 1, "New speaker follows Unknown in the submenu");
}
// parity: SPK-044 SPK-045 SPK-072 SPK-073
#[flow_ui::gpui::test]
async fn correction_and_merge_failures_surface(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let (first, a, b) = read(cx, &window, |p| {
        let rows = p.pager.as_ref().unwrap();
        let roots: Vec<_> = rows.speakers.as_ref().unwrap().1.iter().filter(|x| x.merged_into.is_none()).map(|x| x.id.clone()).collect();
        (rows.rows().next().unwrap().id.clone(), roots[0].clone(), roots[1].clone())
    });
    refuse(cx, "INSERT", "speaker_corrections");
    window.update(cx, |p, _, cx| p.correct(&first, Correction::Unknown, cx)).unwrap();
    assert_eq!(read(cx, &window, |p| p.transcript_notice.clone()).as_deref(), Some("The speaker change could not be saved."));
    window.update(cx, |p, _, cx| p.merge_into(&a, &b, cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["The change could not be saved."]);
    allow(cx, "INSERT", "speaker_corrections");
    let run: String = query(cx, |db| db.conn.query_row("SELECT accepted_run_id FROM meeting_diarization WHERE meeting_id=?1", [SEED_FULL], |r| r.get(0)).unwrap());
    sql(cx, &format!("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<{CORRECTIONS_PER_MEETING}) INSERT INTO speaker_corrections (id, meeting_id, run_id, kind, created_at) SELECT 'fill'||i, '{SEED_FULL}', '{run}', 'rename', 1 FROM n;"));
    let capacity = "This meeting has too many speaker changes to save more.";
    window.update(cx, |p, _, cx| p.correct(&first, Correction::Unknown, cx)).unwrap();
    assert_eq!(read(cx, &window, |p| p.transcript_notice.clone()).as_deref(), Some(capacity));
    window.update(cx, |p, _, cx| p.merge_into(&a, &b, cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&[capacity]);
}
// parity: SPK-051 SPK-052 SPK-053
#[flow_ui::gpui::test]
async fn sheet_loading_empty_and_failed(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    window.update(cx, |p, _, cx| {
        let a = p.assign.as_mut().unwrap();
        a.model.sections.clear();
        a.model.is_loading = true;
        cx.notify();
    }).unwrap();
    frame(cx, &window);
    assert!(has(cx, &window, "meeting.speakers.loading"), "SPK-051");
    window.update(cx, |p, _, cx| { p.assign.as_mut().unwrap().model.is_loading = false; cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_saw(&["There are no speakers to name."]);
    click(cx, &window, "meeting.speakers.close");
    sql(cx, "ALTER TABLE meeting_speakers RENAME TO speakers_gone;");
    window.update(cx, |p, w, cx| p.open_assign(None, w, cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Speakers could not be loaded."]);
}
// parity: SPK-054 SPK-055 SPK-056
#[flow_ui::gpui::test]
async fn review_notice_dismisses_or_says_it_could_not(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let run: String = query(cx, |db| db.conn.query_row("SELECT accepted_run_id FROM meeting_diarization WHERE meeting_id=?1", [SEED_FULL], |r| r.get(0)).unwrap());
    sql(cx, &format!("INSERT INTO speaker_corrections (id, meeting_id, run_id, kind, new_value, needs_review, created_at) VALUES ('review-1','{SEED_FULL}','{run}','rename','Marta moved to another voice',1,1);"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    window.update(cx, |p, w, cx| p.open_assign(None, w, cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Marta moved to another voice", "Dismiss"]);
    assert!(has(cx, &window, "meeting.speakers.review"));
    refuse(cx, "UPDATE", "speaker_corrections");
    click(cx, &window, "meeting.speakers.review.dismiss");
    fresh(cx, &window);
    assert_saw(&["The notice could not be dismissed."]);
    allow(cx, "UPDATE", "speaker_corrections");
    click(cx, &window, "meeting.speakers.review.dismiss");
    frame(cx, &window);
    assert!(!has(cx, &window, "meeting.speakers.review"));
    let flag: i64 = query(cx, |db| db.conn.query_row("SELECT needs_review FROM speaker_corrections WHERE id='review-1'", [], |r| r.get(0)).unwrap());
    assert_eq!(flag, 0);
}
/// Scrolls the sheet until the element is in view, then clicks it.
fn sheet_click(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, id: &str) {
    let area = find(cx, window, "meeting.speakers.scroll").bounds();
    let target = find(cx, window, sid(id)).bounds();
    let offset = read(cx, window, |p| p.assign.as_ref().unwrap().scroll.offset().y);
    window.update(cx, |p, _, _| p.assign.as_ref().unwrap().scroll.set_offset(point(px(0.), offset - (target.origin.y - area.origin.y) + px(20.)))).unwrap();
    frame(cx, window);
    click(cx, window, sid(id));
}
fn unnamed(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>) -> String {
    read(cx, window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| s.speaker.name.is_none() && !s.speaker.is_you()).unwrap().speaker.id.clone())
}
// parity: SPK-064
#[flow_ui::gpui::test]
async fn enter_in_a_name_field_saves(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let id = unnamed(cx, &window);
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), "Jana Horvat");
    cx.update_window(window.into(), |_, w, cx| w.press("enter", cx)).unwrap();
    frame(cx, &window);
    let saved: Option<String> = query(cx, |db| db.conn.query_row("SELECT display_name FROM meeting_speakers WHERE id=?1", [&id], |r| r.get(0)).unwrap());
    assert_eq!(saved.as_deref(), Some("Jana Horvat"));
    assert!(read(cx, &window, |p| p.assign.is_none()));
}
// parity: SPK-065 SPK-066 SPK-067
#[flow_ui::gpui::test]
async fn suggestions_filter_by_prefix_and_pick(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let id = unnamed(cx, &window);
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), "Mar");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.assign.as_ref().unwrap().model.suggestions.iter().all(|s| s.starts_with("Mar"))));
    assert_eq!(query(cx, |db| name_suggestions(db, "%", 8).unwrap().len()), 0, "LIKE characters are escaped");
    assert!(query(cx, |db| name_suggestions(db, "", 8).unwrap().len()) <= 8);
    sheet_click(cx, &window, "meeting.speakers.suggestion.0");
    frame(cx, &window);
    let name = window.read_with(cx, |p, cx| p.assign.as_ref().unwrap().inputs[&id].read(cx).value().to_string()).unwrap();
    assert!(name.starts_with("Mar"));
}
fn with_identity(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, id: &str, state: &str, known: Option<(&str, &str)>, needs_choice: bool) {
    let (id, state, known) = (id.to_string(), state.to_string(), known.map(|k| (k.0.to_string(), k.1.to_string())));
    window.update(cx, |p, _, cx| {
        let s = p.assign.as_mut().unwrap().model.sections.iter_mut().find(|s| s.speaker.id == id).unwrap();
        let i = s.speaker.identity.get_or_insert_with(Default::default);
        i.state = state;
        i.known_id = known.as_ref().map(|k| k.0.clone());
        i.known_name = known.map(|k| k.1);
        i.needs_choice = needs_choice;
        i.sample_offer = true;
        cx.notify();
    }).unwrap();
    fresh(cx, window);
}
// parity: SPK-076 SPK-082 SPK-100
#[flow_ui::gpui::test]
async fn merged_speaker_must_choose_an_identity(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let id = unnamed(cx, &window);
    with_identity(cx, &window, &id, "unknown", None, true);
    assert_saw(&["Choose an identity", "Choose a known speaker…", "Keep Unknown"]);
    assert!(read(cx, &window, |p| !p.assign.as_ref().unwrap().model.can_save()));
    sheet_click(cx, &window, "identity.mergedKeepUnknown");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| s.speaker.id == id).unwrap().action.clone()), IdentityAction::ResolveMerged(None));
    assert!(read(cx, &window, |p| p.assign.as_ref().unwrap().model.can_save()));
}
// parity: SPK-079 SPK-080 SPK-081 SPK-085 SPK-099
#[flow_ui::gpui::test]
async fn possible_match_offers_confirm_another_and_keep_unknown(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let id = unnamed(cx, &window);
    let known = query(cx, |db| known_speakers(db).unwrap().into_iter().find(|k| !k.is_local).unwrap());
    with_identity(cx, &window, &id, "possible", Some((&known.id, &known.name)), false);
    assert_saw(&["Confirm", "Choose another…", "Keep Unknown"]);
    assert!(has(cx, &window, "identity.chooseAnother"));
    sheet_click(cx, &window, "identity.confirm");
    fresh(cx, &window);
    assert_saw(&["Also remember this voice sample"]);
    sheet_click(cx, &window, "identity.keepUnknown");
    fresh(cx, &window);
    assert!(!seen("Also remember this voice sample"));
    click(cx, &window, "meeting.speakers.save");
    frame(cx, &window);
    let rejected: i64 = query(cx, |db| db.conn.query_row("SELECT count(*) FROM rejected_candidates WHERE meeting_speaker_id=?1 AND known_speaker_id=?2", [id.as_str(), known.id.as_str()], |r| r.get(0)).unwrap());
    assert_eq!(rejected, 1);
}
// parity: SPK-083 SPK-084
#[flow_ui::gpui::test]
async fn typed_name_asks_to_remember_then_about_the_duplicate(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    // The first section with a Remember row: the identity ids repeat per section, as in Swift.
    let id = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| !s.speaker.is_you()).unwrap().speaker.id.clone());
    let known = query(cx, |db| known_speakers(db).unwrap().into_iter().find(|k| !k.is_local).unwrap());
    let name = known.name.clone();
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), &name);
    fresh(cx, &window);
    assert_saw(&[REMEMBER_QUESTION, "Not now", REMEMBER_SENTENCE]);
    sheet_click(cx, &window, "identity.remember");
    fresh(cx, &window);
    assert_eq!(read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| s.speaker.id == id).unwrap().action.clone()), IdentityAction::Remember);
    assert_saw(&[&format!("Is this {name} you already remember?"), "Same person", "Someone new"]);
    assert!(read(cx, &window, |p| !p.assign.as_ref().unwrap().model.can_save()), "unresolved duplicate blocks Save");
    sheet_click(cx, &window, "identity.someoneNew");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| s.speaker.id == id).unwrap().action.clone()), IdentityAction::RememberNew);
}
// parity: SPK-102 SPK-103 SPK-104
#[flow_ui::gpui::test]
async fn sheet_save_failures_keep_it_open(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let id = unnamed(cx, &window);
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), "Jana Horvat");
    refuse(cx, "UPDATE", "meeting_speakers");
    click(cx, &window, "meeting.speakers.save");
    fresh(cx, &window);
    assert_saw(&["Names could not be saved."]);
    assert!(read(cx, &window, |p| p.assign.is_some()));
    allow(cx, "UPDATE", "meeting_speakers");
    let known = query(cx, |db| known_speakers(db).unwrap().into_iter().find(|k| !k.is_local).unwrap());
    window.update(cx, |p, _, cx| p.set_identity(&id, IdentityAction::Pick(known.id.clone()), cx)).unwrap();
    refuse(cx, "INSERT", "identity_assignments");
    refuse(cx, "UPDATE", "identity_assignments");
    click(cx, &window, "meeting.speakers.save");
    fresh(cx, &window);
    assert_saw(&["Speaker identities could not be saved."]);
    allow(cx, "INSERT", "identity_assignments");
    allow(cx, "UPDATE", "identity_assignments");
    sql(cx, &format!("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<{REJECTED_PER_MEETING}) INSERT INTO meeting_speakers (id, meeting_id, run_id, cluster_key, source, origin, label_ordinal) SELECT 'fill'||i, '{SEED_FULL}', (SELECT accepted_run_id FROM meeting_diarization WHERE meeting_id='{SEED_FULL}'), 1000+i, 'remote', 'engine', 1000+i FROM n; INSERT INTO rejected_candidates (meeting_speaker_id, known_speaker_id, rejected_at) SELECT id, '{}', 1 FROM meeting_speakers WHERE id LIKE 'fill%';", known.id));
    with_identity(cx, &window, &id, "possible", Some((&known.id, &known.name)), false);
    sheet_click(cx, &window, "identity.keepUnknown");
    click(cx, &window, "meeting.speakers.save");
    fresh(cx, &window);
    assert_saw(&["This meeting has too many rejected matches to save more."]);
}
// parity: SPK-050
#[flow_ui::gpui::test]
async fn sheet_scroller_shows_more_voices_below(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let scroll = find(cx, &window, "meeting.speakers.scroll").bounds();
    assert_eq!(scroll.size.height, px(480.));
    let handle = read(cx, &window, |p| p.assign.as_ref().unwrap().scroll.max_offset().y);
    assert!(handle > px(0.), "more follows below the fold");
    assert_eq!(find(cx, &window, "meeting.speakers.assign").bounds().size.width, px(560.));
}

// parity: SUM-013 SUM-017 SUM-018
#[flow_ui::gpui::test]
async fn pending_cancel_reports_and_empty_states(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary-pending"));
    click(cx, &window, "meeting.summary.cancel");
    fresh(cx, &window);
    assert_saw(&["isn't available"]);
    window.update(cx, |p, _, cx| { p.summary.model = None; p.summary.forced = Some(SummaryHeader::Running("x".into())); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_saw(&["Summarizing…"]);
    window.update(cx, |p, _, cx| { p.summary.forced = Some(SummaryHeader::Eligible); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_saw(&["No summary yet."]);
}
// parity: SUM-031
#[flow_ui::gpui::test]
async fn cancelled_run_with_an_accepted_summary_reads_succeeded(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    sql(cx, &format!("UPDATE analysis_runs SET state='cancelled' WHERE meeting_id='{SEED_FULL}' AND id<>(SELECT accepted_run_id FROM meeting_analysis WHERE meeting_id='{SEED_FULL}');"));
    assert_eq!(query(cx, |db| summary_header(db, SEED_FULL).unwrap()), SummaryHeader::Succeeded);
    let _ = window;
}
// parity: SUM-040
#[flow_ui::gpui::test]
async fn edit_failure_shows_under_the_header(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    refuse(cx, "INSERT", "analysis_overlays");
    click(cx, &window, "meeting.summary.status.0");
    fresh(cx, &window);
    assert_saw(&["The edit could not be saved."]);
    assert!(has(cx, &window, "meeting.summary.editError"));
}
// parity: SUM-042 SUM-043 SUM-044 SUM-045
#[flow_ui::gpui::test]
async fn summary_text_edits_through_its_context_menu(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let original = read(cx, &window, |p| p.summary.model.as_ref().unwrap().summary.clone());
    cx.update_window(window.into(), |_, w, cx| w.double_click("meeting.summary.text", cx)).unwrap();
    frame(cx, &window);
    type_in!(cx, &window, |p| p.summary.summary_input.clone(), "Rewritten.");
    click(cx, &window, "meeting.summary.edit.save");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.summary.model.as_ref().unwrap().summary.clone()), "Rewritten.");
    right_click(cx, &window, "meeting.summary.text");
    menu_item(cx, &window, 1);
    assert!(read(cx, &window, |p| p.summary.shown_ai.contains("summary")), "Show AI value");
    fresh(cx, &window);
    assert_saw(&[original.split('\n').next().unwrap()]);
    right_click(cx, &window, "meeting.summary.text");
    menu_item(cx, &window, 1);
    assert!(read(cx, &window, |p| !p.summary.shown_ai.contains("summary")), "Hide AI value");
    right_click(cx, &window, "meeting.summary.text");
    menu_item(cx, &window, 2);
    assert_eq!(read(cx, &window, |p| p.summary.model.as_ref().unwrap().summary.clone()), original, "Remove text edit");
}
fn action_item(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, ordinal: usize) -> Item {
    read(cx, window, |p| p.summary.model.as_ref().unwrap().action_items[ordinal].clone())
}
fn open_item_menu(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, item: &Item) {
    click(cx, window, sid(format!("meeting.summary.editMenu.{}.{}", item.kind, item.ordinal)));
    frame(cx, window);
}
// parity: SUM-057 SUM-060
#[flow_ui::gpui::test]
async fn item_double_click_edits_and_escape_cancels(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let item = action_item(cx, &window, 0);
    let menu = find(cx, &window, sid(format!("meeting.summary.editMenu.{}.{}", item.kind, item.ordinal))).bounds();
    assert_eq!((menu.size.width, menu.size.height), (px(20.), px(20.)));
    assert!(has(cx, &window, sid(format!("meeting.summary.source.{}.{}", item.kind, item.ordinal))));
    cx.update_window(window.into(), |_, w, cx| w.double_click(sid(format!("meeting.summary.text.{}.{}", item.kind, item.ordinal)), cx)).unwrap();
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.summary.editing.is_some()));
    cx.update_window(window.into(), |_, w, cx| w.press("escape", cx)).unwrap();
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.summary.editing.is_none()), "Esc cancels");
    assert_eq!(action_item(cx, &window, 0).text, item.text);
    cx.update_window(window.into(), |_, w, cx| w.double_click(sid(format!("meeting.summary.text.{}.{}", item.kind, item.ordinal)), cx)).unwrap();
    frame(cx, &window);
    type_in!(cx, &window, |p| p.summary.item_input.clone(), "Changed item");
    click(cx, &window, "meeting.summary.edit.save");
    frame(cx, &window);
    assert_eq!(action_item(cx, &window, 0).text, "Changed item");
}
// parity: SUM-065 SUM-066 SUM-067
#[flow_ui::gpui::test]
async fn owner_submenu_picks_someone_else_or_no_owner(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let item = action_item(cx, &window, 0);
    let roots = read(cx, &window, |p| owner_choices(&p.summary.roots).len());
    open_item_menu(cx, &window, &item);
    submenu_item(cx, &window, 1, roots + 1);
    let popover = find(cx, &window, "notetaker.popover").bounds();
    assert_eq!(popover.size.width, px(220.));
    assert_eq!(find(cx, &window, "meeting.summary.owner.save").disabled(), Some(true), "a blank name can't save");
    type_in!(cx, &window, |p| p.summary.item_input.clone(), "Petra");
    frame(cx, &window);
    click(cx, &window, "meeting.summary.owner.save");
    frame(cx, &window);
    assert_eq!(action_item(cx, &window, 0).owner.text(), "Petra");
    open_item_menu(cx, &window, &item);
    submenu_item(cx, &window, 1, roots + 2);
    assert_eq!(query(cx, |db| db.conn.query_row::<String, _, _>("SELECT user_value FROM analysis_overlays WHERE field='owner' AND item_id=?1", [&item.id], |r| r.get(0)).unwrap()), OWNER_VALUE_NONE);
}
// parity: SUM-068 SUM-069 SUM-070 SUM-080
#[flow_ui::gpui::test]
async fn due_date_picks_from_the_calendar_and_clears(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let item = action_item(cx, &window, 0);
    open_item_menu(cx, &window, &item);
    submenu_item(cx, &window, 2, 0);
    assert!(has(cx, &window, "meeting.summary.due"));
    window.update(cx, |p, w, cx| p.summary.due.update(cx, |s, cx| s.set_date(calendar_date("2027-03-09"), w, cx))).unwrap();
    frame(cx, &window);
    click(cx, &window, "meeting.summary.due.save");
    frame(cx, &window);
    assert_eq!(action_item(cx, &window, 0).due_date.as_deref(), Some("2027-03-09"));
    fresh(cx, &window);
    assert_saw(&["Due 9 Mar"]);
    open_item_menu(cx, &window, &item);
    submenu_item(cx, &window, 2, 1);
    assert_eq!(action_item(cx, &window, 0).due_date, None);
    fresh(cx, &window);
    assert!(!seen("Due 9 Mar"), "no date, no chip");
}
// parity: SUM-071 SUM-072
#[flow_ui::gpui::test]
async fn dismiss_then_reopen(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let item = action_item(cx, &window, 0);
    open_item_menu(cx, &window, &item);
    menu_item(cx, &window, 3);
    assert_eq!(action_item(cx, &window, 0).status, "dismissed");
    open_item_menu(cx, &window, &item);
    menu_item(cx, &window, 3);
    assert_eq!(action_item(cx, &window, 0).status, "open");
}
// parity: SUM-076
#[flow_ui::gpui::test]
async fn accept_writes_the_suggested_owner(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let before = query(cx, |db| db.conn.query_row::<i64, _, _>("SELECT count(*) FROM analysis_overlays WHERE field='owner'", [], |r| r.get(0)).unwrap());
    click(cx, &window, "meeting.summary.owner.accept");
    frame(cx, &window);
    assert_eq!(query(cx, |db| db.conn.query_row::<i64, _, _>("SELECT count(*) FROM analysis_overlays WHERE field='owner'", [], |r| r.get(0)).unwrap()), before + 1);
}
// parity: SUM-081
#[flow_ui::gpui::test]
async fn previous_edits_list_and_delete(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let run: String = query(cx, |db| db.conn.query_row("SELECT accepted_run_id FROM meeting_analysis WHERE meeting_id=?1", [SEED_FULL], |r| r.get(0)).unwrap());
    let _ = run;
    click(cx, &window, "meeting.summary.status.0");
    sql(cx, &format!("UPDATE analysis_overlays SET orphaned_at=1 WHERE meeting_id='{SEED_FULL}';"));
    window.update(cx, |p, _, cx| { p.summary_refresh(cx); p.menu = Some("summary.edits".into()); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_saw(&["Previous edits"]);
    assert_eq!(find(cx, &window, "notetaker.popover").bounds().size.width, px(280.));
}
// parity: SUM-083
#[flow_ui::gpui::test]
async fn speaker_mentions_open_assign_speakers(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let bounds = find(cx, &window, "meeting.summary.text").bounds();
    let mut x = 2.;
    while x < bounds.size.width.as_f32() && read(cx, &window, |p| p.assign.is_none()) {
        for y in [8., 30., 52., 74.] {
            cx.update_window(window.into(), |_, w, cx| w.click_at("meeting.summary.text", point(px(x), px(y)), cx)).unwrap();
        }
        frame(cx, &window);
        x += 12.;
    }
    assert!(read(cx, &window, |p| p.assign.is_some()), "a mention opened the sheet");
}

// --- Round 3: rows that were false or weak.

fn hover(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, id: impl Into<ElementId>) {
    let id = id.into();
    cx.update_window((*window).into(), |_, w, cx| w.hover(id, cx)).unwrap();
    frame(cx, window);
}

// parity: NOTE-070
#[flow_ui::gpui::test]
async fn hovering_a_row_reveals_its_menu(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let row = sid(format!("notetaker.rowContainer.{SEED_UNTITLED}"));
    let reveal = sid(format!("notetaker.overflowReveal.{SEED_UNTITLED}"));
    assert!(!find(cx, &window, reveal.clone()).visible(), "opacity 0 until the pointer arrives");
    hover(cx, &window, row);
    assert!(find(cx, &window, reveal.clone()).visible(), "opacity 1 under the pointer");
    hover(cx, &window, sid(format!("notetaker.rowContainer.{SEED_FULL}")));
    assert!(!find(cx, &window, reveal).visible(), "hidden again when the pointer leaves");
}

// parity: NOTE-070
#[flow_ui::gpui::test]
async fn keyboard_focus_on_a_row_reveals_its_menu_and_previews(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1180., 780.);
    let note = sid(format!("notetaker.note.{SEED_UNTITLED}"));
    let reveal = sid(format!("notetaker.overflowReveal.{SEED_UNTITLED}"));
    assert!(!find(cx, &window, reveal.clone()).visible());
    window.update(cx, |p, w, cx| p.row_focus[SEED_UNTITLED].focus(w, cx)).unwrap();
    frame(cx, &window);
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.focused_row.clone()).as_deref(), Some(SEED_UNTITLED));
    assert!(find(cx, &window, reveal.clone()).visible(), "opacity 1 with keyboard focus");
    cx.executor().advance_clock(std::time::Duration::from_millis(150));
    cx.run_until_parked();
    assert_eq!(read(cx, &window, |p| p.lib.preview_id.clone()).as_deref(), Some(SEED_UNTITLED), "focus asks for the preview");
    window.update(cx, |p, w, cx| p.query.read(cx).focus_handle(cx).focus(w, cx)).unwrap();
    frame(cx, &window);
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.focused_row.is_none()));
    assert!(!find(cx, &window, reveal).visible(), "opacity 0 once focus leaves");
}
// parity: NOTE-074
#[flow_ui::gpui::test]
async fn waveform_layers_light_one_after_another(_cx: &mut TestAppContext) {
    use super::library::variable_color;
    assert_eq!(variable_color(0, 0.0), 1.0, "the first layer leads");
    assert!(variable_color(3, 0.0) < 0.4, "the others are dimmed");
    assert_eq!(variable_color(3, 3.0 / 8.0), 1.0, "the lit layer moves on");
    assert!(variable_color(0, 3.0 / 8.0) < 0.4);
}
// parity: NOTE-088 MEET-016
#[flow_ui::gpui::test]
async fn delete_dialog_has_swifts_geometry_and_a_translucent_fill(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.delete"));
    resize(cx, &window, 1180., 780.);
    let panel = find(cx, &window, "notetaker.confirm.panel").bounds();
    assert_eq!(panel.size.width, px(260.));
    let action = find(cx, &window, "notetaker.delete.confirm").bounds();
    assert_eq!((action.size.width, action.left() - panel.left()), (px(228.), px(16.)));
    assert_eq!(panel.bottom() - find(cx, &window, "notetaker.delete.cancel").bounds().bottom(), px(16.));
    assert!(cx.update(|cx| super::dialog_fill(cx).a) < 1.);
    assert_eq!(panel.left(), px(460.), "centred in the window");
    assert_saw(&["Delete meeting", "Cancel", "Other meetings are kept."]);
}
// parity: NOTE-022 NOTE-023
#[flow_ui::gpui::test]
async fn start_refuses_while_busy_or_dictating(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    cx.update(crate::shell::ensure_session);
    window.update(cx, |p, w, cx| { p.busy = true; p.start_note(w, cx) }).unwrap();
    assert_eq!(read(cx, &window, |p| p.refusal.clone()).as_deref(), Some("Meeting is busy"));
    cx.update(|cx| crate::shell::update_session(cx, |s| s.dictation = Some(crate::shell::Dictation { state: crate::shell::DictState::Recording, busy: true, status: String::new(), unsaved: None, storage_blocked: false, capacity_blocked: false, cleanup_blocked: false })));
    window.update(cx, |p, w, cx| { p.busy = false; p.start_note(w, cx) }).unwrap();
    assert_eq!(read(cx, &window, |p| p.refusal.clone()).as_deref(), Some("Dictation in progress"));
}
// parity: NOTE-025
#[flow_ui::gpui::test]
async fn start_refuses_without_the_screen_permission(cx: &mut TestAppContext) {
    use flow_platform::{Fake, Permission, PermissionState};
    let window = open_page(cx, None);
    let fake = Fake::default();
    fake.permissions.borrow_mut().push((Permission::SystemAudio, PermissionState::Denied));
    cx.update(|cx| cx.global_mut::<Core>().services = Box::new(fake));
    click(cx, &window, "meeting.start");
    fresh(cx, &window);
    assert_saw(&["System audio needs Screen & System Audio Recording."]);
}
// parity: NOTE-026 NOTE-027
#[flow_ui::gpui::test]
async fn start_checks_free_space(_: &mut TestAppContext) {
    assert_eq!(start_refusal(false, false, false, false, Some(499_999_999)), Some("Not enough free space to record (needs at least 500 MB)"));
    assert_eq!(start_refusal(false, false, false, false, Some(500_000_000)), None);
    assert_eq!(low_space_warning(Some(1_999_999_999)), Some("Less than 2 GB free"));
    assert_eq!(low_space_warning(Some(2_000_000_000)), None);
}
// parity: NOTE-017 NOTE-021 MEET-091
#[flow_ui::gpui::test]
async fn start_controls_wait_for_reconciliation_and_the_active_meeting(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    assert_ne!(find(cx, &window, "meeting.start").disabled(), Some(true));
    cx.update(|cx| cx.global_mut::<Core>().reconciled = false);
    window.update(cx, |_, _, cx| cx.notify()).unwrap();
    frame(cx, &window);
    assert_eq!(find(cx, &window, "meeting.start").disabled(), Some(true), "not reconciled yet");
    cx.update(|cx| cx.global_mut::<Core>().reconciled = true);
    window.update(cx, |p, _, cx| { p.status = Some(LiveStatus::scenario("recording")); p.toggle_menu("options", cx) }).unwrap();
    frame(cx, &window);
    assert_eq!(find(cx, &window, "meeting.start").disabled(), Some(true), "a meeting is active");
    assert_eq!(find(cx, &window, "notetaker.transcribeNew").disabled(), Some(true));
}
// parity: NOTE-009
#[flow_ui::gpui::test]
async fn a_changed_active_meeting_refreshes_the_library(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    cx.update(crate::shell::ensure_session);
    sql(cx, &format!("DELETE FROM meetings WHERE id='{SEED_UNTITLED}';"));
    assert!(read(cx, &window, |p| p.lib.rows.iter().any(|r| r.id == SEED_UNTITLED)));
    cx.update(|cx| crate::shell::update_session(cx, |s| s.meeting = Some(crate::shell::MeetingStatus { id: "m".into(), title: None, state: crate::shell::MeetingState::Recording, elapsed_ms: 0 })));
    frame(cx, &window);
    assert!(read(cx, &window, |p| !p.lib.rows.iter().any(|r| r.id == SEED_UNTITLED)));
}
// parity: NOTE-079 NOTE-080
#[flow_ui::gpui::test]
async fn run_on_this_mac_refusals_come_from_the_store_and_preference(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.waiting"));
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("serverOnly", true));
    click(cx, &window, sid(format!("notetaker.runOnThisMac.{SEED_IPHONE}")));
    fresh(cx, &window);
    assert_saw(&["Server only is on, so this Mac doesn't run models. Change it in Settings › Server."]);
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("serverOnly", false));
    refuse(cx, "UPDATE", "meetings");
    click(cx, &window, sid(format!("notetaker.runOnThisMac.{SEED_IPHONE}")));
    fresh(cx, &window);
    assert_saw(&["This meeting can't be moved to this Mac right now."]);
}
// parity: MEET-015
#[flow_ui::gpui::test]
async fn transcript_request_refused_when_the_queue_is_full(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    window.update(cx, |p, _, cx| { p.transcript_queue = (0..100).map(|i| format!("q{i}")).collect(); p.request_transcript(cx) }).unwrap();
    assert_eq!(read(cx, &window, |p| p.transcript_notice.clone()).as_deref(), Some("Too many transcripts waiting"));
    assert_eq!(read(cx, &window, |p| p.transcript_queue.len()), 100);
}
// parity: SUM-014
#[flow_ui::gpui::test]
async fn summary_request_refused_when_the_queue_is_full(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary-eligible"));
    window.update(cx, |p, _, cx| { p.summary_queue = (0..100).map(|i| format!("q{i}")).collect(); cx.notify() }).unwrap();
    frame(cx, &window);
    click(cx, &window, "meeting.summary.generate");
    fresh(cx, &window);
    assert_saw(&["Summary queue is full"]);
}
// parity: MEET-073
#[flow_ui::gpui::test]
async fn playback_needs_a_finished_meeting_with_a_track(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    open(cx, &window, SEED_FAILED, Tab::Thoughts);
    assert_eq!(find(cx, &window, "meeting.playback").disabled(), Some(true), "no track");
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    assert_ne!(find(cx, &window, "meeting.playback").disabled(), Some(true));
    sql(cx, &format!("UPDATE meetings SET state='recording' WHERE id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    assert_eq!(find(cx, &window, "meeting.playback").disabled(), Some(true), "not terminal");
}
// parity: MEET-076 MEET-078
#[flow_ui::gpui::test]
async fn playback_without_files_says_so_and_stop_clears_it(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    assert!(!has(cx, &window, "meeting.playback.stop"));
    click(cx, &window, "meeting.playback");
    fresh(cx, &window);
    assert_saw(&["No playable audio", "0:00 / 0:00"]);
    click(cx, &window, "meeting.playback.stop");
    fresh(cx, &window);
    assert!(!seen("No playable audio"));
    assert!(!has(cx, &window, "meeting.playback.stop"));
}
// parity: MEET-080 MEET-081
#[flow_ui::gpui::test]
async fn playback_queue_skips_what_it_cannot_play(_: &mut TestAppContext) {
    let dir = std::env::temp_dir().join(format!("lf-queue-{}", new_id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("c.aac"), b"x").unwrap();
    let segment = |sequence, path: &str, state: &str, reason: Option<&str>| Segment { sequence, relative_path: path.into(), state: state.into(), start_offset_ms: 0, duration_ms: 1000, open_reason: "start".into(), failure_reason: reason.map(String::from), input_device_name: None };
    let track = Track { kind: "microphone".into(), health: "finalized".into(), failure_reason: None, dropped_frames: 0, duration_warning: false, segments: vec![segment(4, "c.aac", "finalized", None), segment(1, "a.aac.part", "open", None), segment(2, "b.aac", "finalized", None), segment(3, "d.aac", "unrecoverable", Some("unrecoverable_media"))] };
    let q = playback_queue(&track, &dir);
    assert_eq!(q.skipped, vec!["Segment 1: Not playable: still open", "Segment 2: Not playable: The audio file for this segment is missing.", "Segment 3: Not playable: This track could not be made playable. The file was kept."]);
    assert_eq!((q.items.len(), q.duration_ms, q.notice), (1, 1000, None));
    std::fs::remove_dir_all(dir).unwrap();
}
// parity: MEET-089
#[flow_ui::gpui::test]
async fn finalizing_transcript_reloads_every_five_seconds(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    sql(cx, &format!("UPDATE meeting_transcriptions SET state='finalizing' WHERE meeting_id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    sql(cx, &format!("UPDATE meeting_transcriptions SET state='final' WHERE meeting_id='{SEED_FULL}';"));
    cx.executor().advance_clock(Duration::from_secs(4));
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.pager.as_ref().unwrap().row.as_ref().unwrap().state.clone()), "finalizing");
    cx.executor().advance_clock(Duration::from_secs(2));
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.pager.as_ref().unwrap().row.as_ref().unwrap().state.clone()), "final");
}
// parity: MEET-093
#[flow_ui::gpui::test]
async fn launch_notices_go_to_the_pill(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    cx.update(crate::shell::ensure_session);
    cx.update(|cx| cx.global_mut::<Core>().meeting_notices = vec!["1 transcript was interrupted; choose Retry to finish it".into()]);
    let window = cx.add_window(|w, cx| NotetakerPage::new(w, cx));
    frame(cx, &window);
    assert_eq!(cx.update(|cx| cx.global::<crate::shell::Session>().pill.action.as_ref().map(|a| a.message.clone())).as_deref(), Some("1 transcript was interrupted; choose Retry to finish it"));
    assert!(cx.update(|cx| cx.global::<Core>().meeting_notices.is_empty()));
}
// parity: LIVE-002 LIVE-003 LIVE-004
#[flow_ui::gpui::test]
async fn state_dot_is_ten_points_and_follows_the_state(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    let dot = find(cx, &window, "meeting.dot").bounds();
    assert_eq!((dot.size.width, dot.size.height), (px(10.), px(10.)));
    cx.update(|cx| {
        assert_eq!(active::dot_color("recording", cx), red(cx));
        assert_eq!(active::dot_color("paused", cx), orange(cx));
        assert_eq!(active::dot_color("finalizing", cx), pal(cx).muted);
    });
}
// parity: LIVE-006
#[flow_ui::gpui::test]
async fn pause_reason_reads_sleep_or_user(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    for (state, reason, text) in [("paused", Some("user"), "(user)"), ("paused", Some("sleep"), "(sleep)")] {
        window.update(cx, |p, _, cx| { let s = p.status.as_mut().unwrap(); s.state = state.into(); s.pause_reason = reason; cx.notify() }).unwrap();
        fresh(cx, &window);
        assert_saw(&[text]);
    }
}
// parity: LIVE-024 LIVE-025
#[flow_ui::gpui::test]
async fn panel_says_finalizing_or_starting(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    window.update(cx, |p, _, cx| { p.status.as_mut().unwrap().state = "finalizing".into(); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_saw(&["Finalizing…"]);
    window.update(cx, |p, _, cx| { p.status.as_mut().unwrap().state = "preparing".into(); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_saw(&["Starting…"]);
}
// parity: LIVE-043
#[flow_ui::gpui::test]
async fn status_poll_reads_the_stored_state_every_250ms(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.recording"));
    sql(cx, &format!("UPDATE meetings SET state='paused' WHERE id='{SEED_UNTITLED}';"));
    cx.executor().advance_clock(Duration::from_millis(200));
    assert_eq!(read(cx, &window, |p| p.status.as_ref().unwrap().state.clone()), "recording");
    cx.executor().advance_clock(Duration::from_millis(100));
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.status.as_ref().unwrap().state.clone()), "paused");
}
// parity: LIVE-029 LIVE-030 LIVE-031
#[flow_ui::gpui::test]
async fn active_title_is_revision_checked_with_swifts_messages(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    let before = query(cx, |db| meeting(db, SEED_UNTITLED).unwrap().unwrap().revision);
    type_in!(cx, &window, |p| p.active_title.clone(), "Standup");
    cx.update_window(window.into(), |_, w, cx| w.press("enter", cx)).unwrap();
    frame(cx, &window);
    let after = query(cx, |db| meeting(db, SEED_UNTITLED).unwrap().unwrap());
    assert_eq!((after.title.as_deref(), after.revision), (Some("Standup"), before + 1));
    assert!(matches!(query(cx, |db| set_title(db, SEED_UNTITLED, "stale", before, 1)), Err(MeetingError::Stale)), "an old revision is refused");
    type_in!(cx, &window, |p| p.active_title.clone(), &"t".repeat(257));
    cx.update_window(window.into(), |_, w, cx| w.press("enter", cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Titles are limited to 256 bytes."]);
    refuse(cx, "UPDATE", "meetings");
    type_in!(cx, &window, |p| p.active_title.clone(), "Refused");
    cx.update_window(window.into(), |_, w, cx| w.press("enter", cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["The title could not be saved."]);
}
// parity: SPK-034
#[flow_ui::gpui::test]
async fn look_queues_meetings_with_unknown_remote_speakers(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.past-prompt"));
    sql(cx, &format!("DELETE FROM identity_assignments WHERE meeting_id='{SEED_FULL}';"));
    assert_eq!(query(cx, |db| past_search_candidates(db, Some(SEED_FULL)).unwrap().len()), 0, "the open meeting is excluded");
    let open_id = query(cx, |db| past_search_candidates(db, None).unwrap());
    assert_eq!(open_id, vec![SEED_FULL.to_string()]);
    window.update(cx, |p, _, _| p.lib.detail.as_mut().unwrap().meeting.id = "another".into()).unwrap();
    frame(cx, &window);
    click(cx, &window, "identity.pastSearch");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.past_queue.clone()), vec![SEED_FULL.to_string()]);
    assert_eq!(read(cx, &window, |p| p.past_search.clone().map(|s| s.1)), Some(1));
}
// parity: SPK-087 SPK-088 SPK-089 SPK-091
#[flow_ui::gpui::test]
async fn enroll_outcomes_read_like_swift(_: &mut TestAppContext) {
    assert_eq!(EnrollOutcome::Stored(1).text(), "1 sample stored");
    assert_eq!(EnrollOutcome::Stored(3).text(), "3 samples stored");
    assert_eq!(EnrollOutcome::NoUsableSample.text(), "No usable voice sample was found in this meeting");
    assert_eq!(EnrollOutcome::Failed("Could not read.".into()).text(), "Could not read.");
}
// parity: SPK-090
#[flow_ui::gpui::test]
async fn enrolling_with_identification_off_says_so(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("speakerIdentificationEnabled", false));
    let id = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| s.speaker.is_you()).unwrap().speaker.id.clone());
    window.update(cx, |p, _, cx| p.set_identity(&id, IdentityAction::RememberLocal, cx)).unwrap();
    click(cx, &window, "meeting.speakers.save");
    fresh(cx, &window);
    assert_saw(&["Speaker identification is turned off."]);
}

// parity: NOTE-097 NOTE-098
#[flow_ui::gpui::test]
async fn preview_keeps_twenty_point_padding_around_header_and_notes(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1180., 780.);
    window.update(cx, |p, _, cx| p.request_preview(SEED_FULL, cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(200));
    fresh(cx, &window);
    let (preview, header) = (find(cx, &window, "notetaker.preview").bounds(), find(cx, &window, "notetaker.preview.header").bounds());
    let title = find(cx, &window, "notetaker.preview.title").bounds();
    assert_eq!((title.origin.x - header.origin.x, title.origin.y - header.origin.y), (px(20.), px(20.)));
    assert_eq!(header.size.width, preview.size.width);
    let notes = find(cx, &window, "notetaker.preview.notes").bounds();
    assert_eq!(notes.origin.x - preview.origin.x, px(20.));
    assert_eq!(notes.size.width, preview.size.width - px(40.));
}

// parity: SPK-054
#[flow_ui::gpui::test]
async fn review_notice_row_has_twelve_point_padding(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let run: String = query(cx, |db| db.conn.query_row("SELECT accepted_run_id FROM meeting_diarization WHERE meeting_id=?1", [SEED_FULL], |r| r.get(0)).unwrap());
    sql(cx, &format!("INSERT INTO speaker_corrections (id, meeting_id, run_id, kind, new_value, needs_review, created_at) VALUES ('review-2','{SEED_FULL}','{run}','rename','Marta',1,1);"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    window.update(cx, |p, w, cx| p.open_assign(None, w, cx)).unwrap();
    fresh(cx, &window);
    let row = find(cx, &window, "meeting.speakers.review").bounds();
    let dismiss = find(cx, &window, "meeting.speakers.review.dismiss").bounds();
    assert_eq!(row.origin.x + row.size.width - (dismiss.origin.x + dismiss.size.width), px(12.));
}

// parity: SPK-065
#[flow_ui::gpui::test]
async fn suggestions_sit_six_points_inside_their_outline(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let id = unnamed(cx, &window);
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), "Mar");
    fresh(cx, &window);
    let (list, row) = (find(cx, &window, "meeting.speakers.suggestions").bounds(), find(cx, &window, "meeting.speakers.suggestion.0").bounds());
    assert_eq!(row.origin.x - list.origin.x, px(6.));
    assert_eq!(row.origin.y - list.origin.y, px(6.));
    assert_eq!(row.size.width, list.size.width - px(12.));
}

// parity: SUM-043
#[flow_ui::gpui::test]
async fn summary_editor_is_ninety_points_high(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    cx.update_window(window.into(), |_, w, cx| w.double_click("meeting.summary.text", cx)).unwrap();
    frame(cx, &window);
    assert_eq!(find(cx, &window, "meeting.summary.edit.frame").bounds().size.height, px(90.));
}

// parity: SUM-069
#[flow_ui::gpui::test]
async fn due_popover_is_two_hundred_twenty_wide(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let item = action_item(cx, &window, 0);
    open_item_menu(cx, &window, &item);
    submenu_item(cx, &window, 2, 0);
    assert_eq!(find(cx, &window, "meeting.summary.due").bounds().size.width, px(220.));
}

// parity: NOTE-019
#[flow_ui::gpui::test]
async fn new_note_is_twenty_eight_points_high(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    assert_eq!(find(cx, &window, "meeting.start").bounds().size.height, px(28.));
}

// parity: SUM-059
#[flow_ui::gpui::test]
async fn item_menu_is_twenty_points_square(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let item = action_item(cx, &window, 0);
    let b = find(cx, &window, sid(format!("meeting.summary.editMenu.{}.{}", item.kind, item.ordinal))).bounds();
    assert_eq!((b.size.width, b.size.height), (px(20.), px(20.)));
}

// parity: SUM-077
#[flow_ui::gpui::test]
async fn unresolved_owner_gets_the_outlined_chip(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    assert_saw(&["Owner unresolved"]);
    assert!(has(cx, &window, "meeting.summary.owner.unresolved"));
}

// parity: LIVE-016
#[flow_ui::gpui::test]
async fn dropped_frames_warn_that_audio_was_lost(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.interrupted-card"));
    assert!(has(cx, &window, "meeting.captureLoss"));
    window.update(cx, |p, _, cx| { p.status.as_mut().unwrap().dropped_frames = 0; cx.notify() }).unwrap();
    frame(cx, &window);
    assert!(!has(cx, &window, "meeting.captureLoss"));
}

fn menu_clear() {
    crate::pages::notetaker::MENU_TITLES.with(|m| m.borrow_mut().clear());
}
fn assert_menu_saw(titles: &[&str]) {
    let shown = crate::pages::notetaker::MENU_TITLES.with(|m| m.borrow().clone());
    for title in titles {
        assert!(shown.iter().any(|s| s == title), "no menu item {title:?} in {shown:?}");
    }
}
fn assert_labelled(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, id: impl Into<ElementId>, label: &str) {
    assert_eq!(find(cx, window, id).label().map(|l| l.to_string()).as_deref(), Some(label));
}
fn assert_symbols(names: &[&str]) {
    let symbols = flow_ui::probe::symbols();
    for name in names {
        assert!(symbols.iter().any(|s| s == name), "no symbol {name:?} in {symbols:?}");
    }
}

// parity: NOTE-005 NOTE-047
#[flow_ui::gpui::test]
async fn library_icon_buttons_name_their_symbol_and_label(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 780., 780.);
    fresh(cx, &window);
    assert_labelled(cx, &window, "notetaker.overview", "Show note overview");
    assert_labelled(cx, &window, "notetaker.searchToggle", "Search loaded notes");
    assert_symbols(&["sidebar.right", "magnifyingglass"]);
}
// parity: MEET-005 MEET-006 MEET-056
#[flow_ui::gpui::test]
async fn detail_header_names_previous_and_next(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    sql(cx, &format!("UPDATE meeting_notes SET text='' WHERE meeting_id='{SEED_UNTITLED}';"));
    open(cx, &window, SEED_UNTITLED, Tab::Thoughts);
    assert_labelled(cx, &window, "meeting.previous", "Previous note");
    assert_labelled(cx, &window, "meeting.next", "Next note");
    assert_symbols(&["chevron.left", "chevron.right"]);
    assert_saw(&["Capture your thoughts here"]);
}
// parity: MEET-047
#[flow_ui::gpui::test]
async fn run_on_this_mac_has_swifts_label(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.waiting-detail"));
    assert_labelled(cx, &window, "notetaker.detail.runOnThisMac", "Run this meeting on this Mac");
}
// parity: MEET-067 LIVE-020
#[flow_ui::gpui::test]
async fn paused_controls_read_resume(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.live-paused"));
    assert_saw(&["Resume"]);
    assert_symbols(&["play.fill"]);
    let window = open_page(cx, Some("notetaker.panel"));
    assert_saw(&["Pause"]);
    window.update(cx, |p, _, cx| { p.status.as_mut().unwrap().state = "paused".into(); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_saw(&["Resume"]);
}
// parity: MEET-076
#[flow_ui::gpui::test]
async fn playback_stop_reads_stop(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    click(cx, &window, "meeting.playback");
    fresh(cx, &window);
    assert_saw(&["Stop"]);
}
// parity: NOTE-098
#[flow_ui::gpui::test]
async fn preview_heads_the_notes_my_thoughts(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1180., 780.);
    window.update(cx, |p, _, cx| p.request_preview(SEED_FULL, cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(200));
    fresh(cx, &window);
    assert_saw(&["MY THOUGHTS"]);
}
// parity: LIVE-032
#[flow_ui::gpui::test]
async fn refusal_row_carries_the_warning_triangle(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.refusal"));
    assert_symbols(&["exclamationmark.triangle"]);
}
// parity: TRANS-011 TRANS-015 SPK-001
#[flow_ui::gpui::test]
async fn transcript_icon_buttons_name_their_symbol_and_label(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    assert_labelled(cx, &window, "meeting.transcript.search.open", "Search transcript");
    assert_labelled(cx, &window, "meeting.speakers.assign.open", "Assign speakers");
    assert_symbols(&["magnifyingglass", "person.badge.plus"]);
    click(cx, &window, "meeting.transcript.search.open");
    frame(cx, &window);
    type_in!(cx, &window, |p| p.search.clone(), "the");
    cx.executor().advance_clock(Duration::from_millis(300));
    fresh(cx, &window);
    assert_labelled(cx, &window, "meeting.transcript.search.previous", "Previous match");
    assert_labelled(cx, &window, "meeting.transcript.search.next", "Next match");
    assert_symbols(&["chevron.up", "chevron.down"]);
}
// parity: TRANS-028 TRANS-031 TRANS-035
#[flow_ui::gpui::test]
async fn copy_menu_reads_like_swift(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    menu_clear();
    click(cx, &window, "meeting.transcript.copy");
    frame(cx, &window);
    assert_menu_saw(&["Copy Selected Segments"]);
    assert_menu_saw(&["Copy Full Transcript"]);
    assert_menu_saw(&["Export Transcript\u{2026}"]);
}
// parity: TRANS-052 SPK-040
#[flow_ui::gpui::test]
async fn segment_menu_reads_select_or_deselect_and_change_speaker(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    let row = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().next().unwrap().clone());
    let bubble = sid(format!("meeting.transcript.bubble.{}", row.ordinal));
    let choices = read(cx, &window, |p| p.pager.as_ref().unwrap().speakers.as_ref().unwrap().1.iter().filter(|x| x.merged_into.is_none()).count());
    menu_clear();
    right_click(cx, &window, bubble.clone());
    assert_menu_saw(&["Select segment", "Change speaker"]);
    cx.update_window(window.into(), |_, w, cx| w.within("popup-menu").hover(2usize, cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(400));
    frame(cx, &window);
    assert_menu_saw(&["Unknown", "New speaker"]);
    assert!(choices > 0);
    cx.update_window(window.into(), |_, w, cx| w.press("escape", cx)).unwrap();
    frame(cx, &window);
    cx.update_window(window.into(), |_, w, cx| w.press("escape", cx)).unwrap();
    frame(cx, &window);
    window.update(cx, |p, _, cx| { p.pager.as_mut().unwrap().toggle_selection(&row.id); cx.notify() }).unwrap();
    frame(cx, &window);
    menu_clear();
    right_click(cx, &window, bubble);
    assert_menu_saw(&["Deselect segment"]);
}
// parity: SPK-065 SPK-093
#[flow_ui::gpui::test]
async fn assign_sheet_labels_suggestions_and_cancel(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    assert_saw(&["Cancel"]);
    let id = unnamed(cx, &window);
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), "Mar");
    fresh(cx, &window);
    let label = find(cx, &window, "meeting.speakers.suggestion.0").label().unwrap().to_string();
    assert!(label.starts_with("Use name "), "{label}");
}
// parity: SUM-005 SUM-009
#[flow_ui::gpui::test]
async fn summary_empty_states_read_generate_and_read_transcript(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.summary-not-finished"));
    assert_saw(&["Read transcript"]);
    let _window = open_page(cx, Some("notetaker.summary-eligible"));
    assert_saw(&["Generate"]);
}
// parity: SUM-034 SUM-036
#[flow_ui::gpui::test]
async fn summary_options_menu_and_remove_all_dialog_read_like_swift(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    click(cx, &window, "meeting.summary.status.0");
    frame(cx, &window);
    menu_clear();
    click(cx, &window, "meeting.summary.options");
    frame(cx, &window);
    assert_menu_saw(&["Regenerate", "Previous edits", "Remove all edits\u{2026}"]);
    menu_item(cx, &window, 2);
    fresh(cx, &window);
    assert_saw(&["Remove all edits?", "Remove All Edits", "Cancel", "Your changes to the summary, owners, due dates and items are deleted"]);
}
// parity: SUM-042 SUM-043 SUM-046
#[flow_ui::gpui::test]
async fn summary_text_menu_and_editor_read_like_swift(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    menu_clear();
    right_click(cx, &window, "meeting.summary.text");
    assert_menu_saw(&["Edit summary"]);
    cx.update_window(window.into(), |_, w, cx| w.press("escape", cx)).unwrap();
    frame(cx, &window);
    cx.update_window(window.into(), |_, w, cx| w.double_click("meeting.summary.text", cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Save", "Cancel"]);
    type_in!(cx, &window, |p| p.summary.summary_input.clone(), "Rewritten.");
    click(cx, &window, "meeting.summary.edit.save");
    frame(cx, &window);
    menu_clear();
    right_click(cx, &window, "meeting.summary.text");
    assert_menu_saw(&["Show AI value", "Remove text edit"]);
}
// parity: SUM-057 SUM-060
#[flow_ui::gpui::test]
async fn item_editor_and_source_read_like_swift(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let item = action_item(cx, &window, 0);
    fresh(cx, &window);
    assert_labelled(cx, &window, sid(format!("meeting.summary.source.{}.{}", item.kind, item.ordinal)), "View source");
    assert_symbols(&["arrow.up.right.square"]);
    cx.update_window(window.into(), |_, w, cx| w.double_click(sid(format!("meeting.summary.text.{}.{}", item.kind, item.ordinal)), cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["Save"]);
    let field = cx.update_window(window.into(), |_, w, _| w.find_by_label("Edit").label().map(|l| l.to_string())).unwrap();
    assert_eq!(field.as_deref(), Some("Edit"));
}
// parity: SUM-059 SUM-065 SUM-067 SUM-068 SUM-069 SUM-071
#[flow_ui::gpui::test]
async fn item_menus_and_popovers_read_like_swift(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let item = action_item(cx, &window, 0);
    let roots = read(cx, &window, |p| owner_choices(&p.summary.roots).len());
    menu_clear();
    open_item_menu(cx, &window, &item);
    assert_menu_saw(&["Edit text", "Owner", "Due date", "Dismiss"]);
    assert_symbols(&["ellipsis"]);
    submenu_item(cx, &window, 1, roots + 1);
    assert_menu_saw(&["Someone else\u{2026}", "No owner"]);
    fresh(cx, &window);
    assert_saw(&["Owner name", "Save"]);
    type_in!(cx, &window, |p| p.summary.item_input.clone(), "Petra");
    frame(cx, &window);
    click(cx, &window, "meeting.summary.owner.save");
    frame(cx, &window);
    menu_clear();
    open_item_menu(cx, &window, &item);
    submenu_item(cx, &window, 2, 0);
    assert_menu_saw(&["Pick date\u{2026}"]);
    fresh(cx, &window);
    assert_saw(&["Due", "Clear", "Save"]);
    window.update(cx, |p, w, cx| p.summary.due.update(cx, |s, cx| s.set_date(calendar_date("2027-03-09"), w, cx))).unwrap();
    frame(cx, &window);
    click(cx, &window, "meeting.summary.due.save");
    frame(cx, &window);
    open_item_menu(cx, &window, &item);
    menu_item(cx, &window, 3);
    menu_clear();
    open_item_menu(cx, &window, &item);
    assert_menu_saw(&["Reopen", "Remove owner edit", "Remove due-date edit", "Remove status edit"]);
}
// parity: SUM-081
#[flow_ui::gpui::test]
async fn previous_edits_rows_read_delete(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    click(cx, &window, "meeting.summary.status.0");
    frame(cx, &window);
    sql(cx, &format!("UPDATE analysis_overlays SET orphaned_at=1, item_id=NULL WHERE meeting_id='{SEED_FULL}';"));
    window.update(cx, |p, _, cx| { p.summary_refresh(cx); p.menu = Some("summary.edits".into()); cx.notify() }).unwrap();
    frame(cx, &window);
    fresh(cx, &window);
    assert_saw(&["Delete"]);
    let edit = read(cx, &window, |p| p.summary.model.as_ref().unwrap().previous_edits[0].id.clone());
    click(cx, &window, sid(format!("meeting.summary.previous.delete.{edit}")));
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.summary.model.as_ref().unwrap().previous_edits.is_empty()), "Delete removes the row");
}
// parity: SPK-070
#[flow_ui::gpui::test]
async fn a_name_another_speaker_has_offers_to_merge(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let id = unnamed(cx, &window);
    let taken = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find_map(|s| (s.speaker.id != id).then(|| s.speaker.name.clone()).flatten()).unwrap());
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), &taken);
    fresh(cx, &window);
    assert_saw(&[&format!("Same name as {taken}."), "Merge"]);
}
