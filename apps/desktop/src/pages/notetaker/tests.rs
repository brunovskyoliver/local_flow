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
// parity: NOTE-076
#[flow_ui::gpui::test]
async fn waiting_row_runs_on_this_mac(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.waiting"));
    assert_saw(&["Waiting for your server", "Run on this Mac"]);
    click(cx, &window, sid(format!("notetaker.runOnThisMac.{SEED_IPHONE}")));
    frame(cx, &window);
    assert!(query(cx, |db| db.conn.query_row("SELECT 1 FROM meetings WHERE id=?1", [SEED_IPHONE], |r| r.get::<_, i64>(0)).unwrap_or(0)) == 1);
}

// parity: LIVE-026
#[flow_ui::gpui::test]
async fn active_card_states(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.interrupted-card"));
    assert_saw(&["Recording stopped", "Dismiss", "Microphone", "System audio"]);
}
// parity: LIVE-009
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

// parity: NOTE-071 MEET-006
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

// parity: MEET-057
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

// parity: TRANS-052
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
// parity: NOTE-033
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
// parity: NOTE-034
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
// parity: LIVE-020
#[flow_ui::gpui::test]
async fn panel_shows_controls_title_and_notes(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.panel"));
    assert_saw(&["Recording", "Pause", "Stop Meeting", "Notes", "Microphone", "capturing"]);
}
// parity: LIVE-017
#[flow_ui::gpui::test]
async fn notice_card_shows_storage_and_notice(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.notice-card"));
    assert_saw(&["Less than 2 GB free", "Recorded audio was recovered where possible."]);
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
    let (_, muted, ..) = colors(cx);
    let (size, _, color) = sized("Updating speaker labels…");
    assert_eq!((size, color), (11., muted));
}
// parity: SPK-005
#[flow_ui::gpui::test]
async fn labels_waiting(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.label-waiting"));
    let (_, muted, ..) = colors(cx);
    let (size, _, color) = sized("Waiting to label speakers…");
    assert_eq!((size, color), (11., muted));
}
// parity: SPK-006
#[flow_ui::gpui::test]
async fn labels_running(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.labeling"));
    let percent = read(cx, &window, |p| p.speaker_run.as_ref().unwrap().percent);
    let (_, muted, ..) = colors(cx);
    let (size, _, color) = sized(&format!("Labeling speakers… {percent}%"));
    assert_eq!((size, color), (11., muted));
}
// parity: SPK-007
#[flow_ui::gpui::test]
async fn labels_failed(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.label-failed"));
    let (_, muted, red, ..) = colors(cx);
    let category = read(cx, &window, |p| p.speaker_run.as_ref().unwrap().failure.clone()).unwrap();
    let (size, _, color) = sized(&diarization_failure_text(&category));
    assert_eq!((size, color), (11., red));
    let (size, _, color) = sized("Retry");
    assert_eq!((size, color), (11., muted));
    assert!(has(cx, &window, "meeting.speakers.retry"));
    window.update(cx, |p, _, cx| { p.speaker_run.as_mut().unwrap().failure = Some("os_unsupported".into()); cx.notify() }).unwrap();
    frame(cx, &window);
    assert!(!has(cx, &window, "meeting.speakers.retry"), "macOS too old: nothing to retry");
}
// parity: SPK-021
#[flow_ui::gpui::test]
async fn identify_waiting(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.identify-waiting"));
    let (_, muted, ..) = colors(cx);
    let (size, _, color) = sized("Waiting to identify speakers…");
    assert_eq!((size, color), (11., muted));
}
// parity: SPK-022
#[flow_ui::gpui::test]
async fn identify_running(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.identifying"));
    let percent = read(cx, &window, |p| p.identify_run.as_ref().unwrap().percent);
    let (_, muted, ..) = colors(cx);
    let (size, _, color) = sized(&format!("Identifying speakers… {percent}%"));
    assert_eq!((size, color), (11., muted));
}
// parity: SPK-023
#[flow_ui::gpui::test]
async fn identify_failed(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.identify-failed"));
    let (_, _, red, ..) = colors(cx);
    let category = read(cx, &window, |p| p.identify_run.as_ref().unwrap().failure.clone()).unwrap();
    let (size, _, color) = sized(&format!("Identification failed: {}", identification_failure_text(&category)));
    assert_eq!((size, color), (11., red));
    assert!(has(cx, &window, "meeting.identification.retry"));
    window.update(cx, |p, _, cx| { p.identify_run.as_mut().unwrap().failure = Some("os_unsupported".into()); cx.notify() }).unwrap();
    frame(cx, &window);
    assert!(!has(cx, &window, "meeting.identification.retry"));
}
// parity: SPK-024
#[flow_ui::gpui::test]
async fn identify_enrolling(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.enrolling"));
    let (_, muted, ..) = colors(cx);
    let (size, _, color) = sized("Storing voice sample…");
    assert_eq!((size, color), (11., muted));
}
// parity: SPK-019
#[flow_ui::gpui::test]
async fn past_search_running(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.past-search"));
    let (name, left) = read(cx, &window, |p| p.past_search.clone()).unwrap();
    let (_, muted, ..) = colors(cx);
    let (size, _, color) = sized(&format!("Looking for {name} in past meetings ({left} left)"));
    assert_eq!((size, color), (11., muted));
    let (size, _, color) = sized("Cancel");
    assert_eq!((size, color), (11., muted));
}
// parity: SPK-033
#[flow_ui::gpui::test]
async fn past_search_prompt(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.past-prompt"));
    resize(cx, &window, 1400., 900.);
    let shown = flow_ui::probe::seen().into_iter().find(|s| s.starts_with("Look for this voice in past meetings? ")).unwrap();
    assert!(shown.ends_with(" would be checked."), "{shown}");
    assert_eq!(sized(&shown).0, 12.);
    let (prompt, not_now) = (find(cx, &window, "identity.pastSearchPrompt").bounds(), find(cx, &window, "identity.pastSearch.notNow").bounds());
    assert_eq!(prompt.origin.x + prompt.size.width - (not_now.origin.x + not_now.size.width), px(10.), "padding 10");
    let row = |n: &str| format!("Look for this voice in past meetings? {n} would be checked.");
    window.update(cx, |p, _, cx| { p.past_prompt.as_mut().unwrap().1 = 1; cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_saw(&[&row("1 meeting")]);
    window.update(cx, |p, _, cx| { p.past_prompt.as_mut().unwrap().1 = 3; cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_saw(&[&row("3 meetings")]);
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

// parity: NOTE-015
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
// parity: NOTE-081
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

// parity: LIVE-004
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
// parity: TRANS-031 TRANS-032 TRANS-034
#[flow_ui::gpui::test]
async fn copy_full_writes_or_says_why_not(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    click(cx, &window, "meeting.transcript.copy");
    menu_item(cx, &window, 1);
    assert!(cx.read_from_clipboard().and_then(|c| c.text()).is_some_and(|t| t.contains("hinge samples")));
    let (segments, copied) = (query(cx, |db| db.conn.query_row("SELECT count(*) FROM transcript_segments WHERE meeting_id=?1", [SEED_FULL], |r| r.get::<_, i64>(0)).unwrap()), cx.read_from_clipboard().and_then(|c| c.text()).unwrap());
    assert_eq!(copied.split("\n\n").count() as i64, segments, "the whole transcript, not one page");
    sql(cx, "ALTER TABLE transcript_segments RENAME TO segments_gone;");
    click(cx, &window, "meeting.transcript.copy");
    menu_item(cx, &window, 1);
    fresh(cx, &window);
    assert_saw(&["The transcript could not be copied."]);
}
// parity: TRANS-032 TRANS-033
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
    assert!(cx.read_from_clipboard().is_none(), "nothing is copied past the limit");
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
    let (_, _, red, ..) = colors(cx);
    assert_eq!(sized("The summary couldn't be saved."), (11., 400., red));
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
// parity: SPK-091
#[flow_ui::gpui::test]
async fn enroll_outcomes_read_like_swift(_: &mut TestAppContext) {
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
async fn new_note_is_twenty_nine_points_high(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    assert_eq!(find(cx, &window, "meeting.start").bounds().size.height, px(29.));
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
    let generated = read(cx, &window, |p| generated_text(p.summary.model.as_ref().unwrap().generated_at, 0));
    let shown = crate::pages::notetaker::MENU_TITLES.with(|m| m.borrow().clone());
    assert!(shown.iter().any(|s| s.starts_with("Generated ") && s.ends_with(" · AI-generated") && s.len() == generated.len()), "{shown:?}");
    menu_item(cx, &window, 2);
    fresh(cx, &window);
    assert_saw(&["Remove all edits?", "Remove All Edits", "Cancel", "Your changes to the summary, owners, due dates and items are deleted, and the generated text comes back. This can't be undone."]);
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
    let other = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| s.speaker.name.as_deref() == Some(&taken)).unwrap().speaker.anonymous());
    let (_, muted, ..) = colors(cx);
    let (size, _, color) = sized(&format!("Same name as {other}."));
    assert_eq!((size, color), (12., muted), "the other speaker's anonymous label, not the name just typed");
    assert_eq!(sized("Merge").0, 12.);
    assert_eq!(sized("Merge").1, 500.);
}

// --- Round 4 row review: the library.
fn colors(cx: &mut TestAppContext) -> (Hsla, Hsla, Hsla, Hsla, Hsla) {
    cx.update(|cx| (pal(cx).ink, pal(cx).muted, red(cx), orange(cx), green(cx)))
}
fn sized(text: &str) -> (f32, f32, Hsla) {
    let s = flow_ui::probe::style_of(text).unwrap_or_else(|| panic!("no text {text:?}"));
    (s.size, s.weight, s.color)
}

// parity: NOTE-012 NOTE-013 NOTE-019 NOTE-030 NOTE-031 NOTE-039 NOTE-045 NOTE-062 NOTE-067 NOTE-068 NOTE-069
#[flow_ui::gpui::test]
async fn library_header_and_rows_have_swifts_type_symbols_and_labels(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1180., 3000.);
    fresh(cx, &window);
    let (ink, muted, ..) = colors(cx);
    assert_eq!(sized("Notetaker"), (26., 500., ink));
    assert_labelled(cx, &window, "notetaker.options", "Recording options");
    assert_eq!(flow_ui::probe::symbol_color("gearshape"), Some(ink));
    assert_eq!(flow_ui::probe::symbol_color("plus"), Some(ink));
    assert_labelled(cx, &window, "meeting.start", "New note");
    assert_eq!(sized("TODAY").0, 12.);
    assert_eq!(sized("TODAY").1, 500.);
    assert_labelled(cx, &window, "notetaker.refresh", "Refresh notes");
    assert_eq!(flow_ui::probe::symbol_color("arrow.clockwise"), Some(muted));
    let summary = read(cx, &window, |p| today_summary(None, p.lib.rows.iter().filter(|r| r.id == SEED_FULL).count()));
    assert_eq!(sized(&summary).0, 15.);
    assert!(has(cx, &window, "meeting.today.summary"));
    assert_eq!(sized("Past notes"), (15., 500., ink));
    let row = read(cx, &window, |p| p.lib.rows.iter().find(|r| r.id == SEED_FULL).unwrap().clone());
    let offset = cx.update(|cx| offset_at(row.created_at, cx));
    let today = local_day(now_ms(), offset);
    assert_eq!(sized(&day_heading(row.created_at, offset, today)), (12., 500., muted));
    assert_eq!(sized(&row.display_title(offset)).0, 15.);
    assert_eq!(sized(&time_text(row.created_at, offset)).0, 12.);
    assert_eq!(sized(&time_text(row.created_at, offset)).2, muted);
    assert_eq!(flow_ui::probe::symbol_color("iphone"), Some(muted));
    assert_eq!(sized("From iPhone").0, 12.);
    assert_eq!(sized("From iPhone").2, muted);
}

// parity: NOTE-066
#[flow_ui::gpui::test]
async fn row_glyph_is_a_muted_document(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    fresh(cx, &window);
    let (_, muted, ..) = colors(cx);
    assert_eq!(flow_ui::probe::symbol_color("doc.text"), Some(muted));
}

// parity: NOTE-002 NOTE-016 NOTE-018
#[flow_ui::gpui::test]
async fn each_appearance_copies_the_preference_again_and_a_toggle_persists_nothing(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    cx.update(crate::shell::ensure_session);
    let pref = |cx: &mut TestAppContext| cx.update(|cx| cx.global::<Core>().prefs.bool_or("meetingTranscriptionEnabled", true));
    assert!(read(cx, &window, |p| p.transcribe));
    click(cx, &window, "notetaker.options");
    frame(cx, &window);
    click(cx, &window, "notetaker.transcribeNew");
    frame(cx, &window);
    assert!(!read(cx, &window, |p| p.transcribe), "the local value flips");
    assert!(pref(cx), "nothing persisted");
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = crate::pages::Page::History));
    frame(cx, &window);
    assert!(!read(cx, &window, |p| p.transcribe), "still away");
    sql(cx, &format!("UPDATE meetings SET title='Reread on return' WHERE id='{SEED_FULL}';"));
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = crate::pages::Page::Meetings));
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.transcribe), "the value resets from preferences when the library loads");
    assert!(read(cx, &window, |p| p.lib.rows.iter().any(|r| r.title.as_deref() == Some("Reread on return"))), "and the rows re-read");
}

// parity: NOTE-014
#[flow_ui::gpui::test]
async fn options_popover_has_twenty_points_inside(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    click(cx, &window, "notetaker.options");
    frame(cx, &window);
    let (panel, check) = (find(cx, &window, "notetaker.popover").bounds(), find(cx, &window, "notetaker.transcribeNew").bounds());
    assert_eq!((check.origin.x - panel.origin.x, check.origin.y - panel.origin.y), (px(20.), px(20.)));
}

// parity: NOTE-032
#[flow_ui::gpui::test]
async fn refresh_button_reads_the_rows_again_and_clears_the_notice(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.notice"));
    sql(cx, &format!("UPDATE meetings SET title='Fresh title' WHERE id='{SEED_FULL}';"));
    click(cx, &window, "notetaker.refresh");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.lib.notice.is_none()));
    assert!(read(cx, &window, |p| p.lib.rows.iter().any(|r| r.title.as_deref() == Some("Fresh title"))));
}

// parity: NOTE-041
#[flow_ui::gpui::test]
async fn attention_replaces_the_summary_line(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    assert!(has(cx, &window, "meeting.today.summary"));
    for scenario in ["notetaker.refusal", "notetaker.failed-card", "notetaker.interrupted-card"] {
        let window = open_page(cx, Some(scenario));
        assert!(!has(cx, &window, "meeting.today.summary"), "{scenario}");
    }
}

// parity: NOTE-042
#[flow_ui::gpui::test]
async fn library_notice_is_red(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.notice"));
    let (.., red, _, _) = colors(cx);
    assert_eq!(sized("Meetings could not be loaded. Check app storage.").2, red);
}

// parity: NOTE-049
#[flow_ui::gpui::test]
async fn search_field_is_twelve_under_the_tab_row_at_thirty_seven_high(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    click(cx, &window, "notetaker.searchToggle");
    fresh(cx, &window);
    let (tab, field) = (find(cx, &window, "notetaker.pastNotes").bounds(), find(cx, &window, "notetaker.searchField").bounds());
    assert_eq!(field.origin.y - tab.bottom(), px(12.));
    assert_eq!(field.size.height, px(37.));
}

// parity: NOTE-051
#[flow_ui::gpui::test]
async fn a_hidden_query_keeps_filtering(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    click(cx, &window, "notetaker.searchToggle");
    frame(cx, &window);
    type_in!(cx, &window, |p| p.query.clone(), "budget");
    click(cx, &window, "notetaker.searchToggle");
    fresh(cx, &window);
    assert!(!has(cx, &window, "notetaker.search"));
    assert_saw(&["Budget call"]);
    assert!(!seen("Lamp prototype review"), "Swift filters on the query whether or not the field shows");
}

// parity: NOTE-052 NOTE-053
#[flow_ui::gpui::test]
async fn empty_lines_are_muted_with_sixty_points_around(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.empty"));
    let (_, muted, ..) = colors(cx);
    assert_eq!((sized("No notes yet").0, sized("No notes yet").2), (15., muted));
    assert!(find(cx, &window, "notetaker.emptyLine").bounds().size.height > px(120.));
    let window = open_page(cx, None);
    click(cx, &window, "notetaker.searchToggle");
    frame(cx, &window);
    type_in!(cx, &window, |p| p.query.clone(), "zzzz-nothing");
    fresh(cx, &window);
    assert_eq!((sized("No matches").0, sized("No matches").2), (15., muted));
    assert!(find(cx, &window, "notetaker.emptyLine").bounds().size.height > px(120.));
}

// parity: NOTE-055 NOTE-056
#[flow_ui::gpui::test]
async fn show_newest_appears_only_after_eviction_and_refreshes(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    assert!(!has(cx, &window, "notetaker.showNewest"));
    let window = open_page(cx, Some("notetaker.evicted"));
    let button = find(cx, &window, "notetaker.showNewest").bounds();
    assert!(button.size.height > px(0.));
    click(cx, &window, "notetaker.showNewest");
    frame(cx, &window);
    assert!(!read(cx, &window, |p| p.lib.evicted_newest));
    assert!(!has(cx, &window, "notetaker.showNewest"));
}

// parity: NOTE-057
#[flow_ui::gpui::test]
async fn load_older_sits_twenty_under_the_list(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let last = read(cx, &window, |p| p.lib.rows.last().unwrap().id.clone());
    let row = find(cx, &window, sid(format!("notetaker.rowContainer.{last}"))).bounds();
    assert_eq!(find(cx, &window, "notetaker.loadOlder").bounds().origin.y - row.bottom(), px(23.), "20 plus the stack's spacing of 3");
    sql(cx, &format!("DELETE FROM meetings WHERE id='{last}';"));
    window.update(cx, |p, _, _| p.lib.has_older = false).unwrap();
    window.update(cx, |_, _, cx| cx.notify()).unwrap();
    frame(cx, &window);
    assert!(!has(cx, &window, "notetaker.loadOlder"), "only when hasOlder");
}

// parity: NOTE-070
#[flow_ui::gpui::test]
async fn a_real_tab_press_reaches_a_row_reveals_its_menu_and_previews(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1180., 780.);
    let first = read(cx, &window, |p| p.lib.rows[0].id.clone());
    let note = sid(format!("notetaker.note.{first}"));
    let reveal = sid(format!("notetaker.overflowReveal.{first}"));
    assert!(!find(cx, &window, reveal.clone()).visible(), "opacity 0 before focus");
    let mut reached = false;
    for _ in 0..12 {
        cx.update_window(window.into(), |_, w, cx| w.press("tab", cx)).unwrap();
        frame(cx, &window);
        if find(cx, &window, note.clone()).focused() == Some(true) {
            reached = true;
            break;
        }
    }
    assert!(reached, "Tab walks to the row's button");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.focused_row.clone()), Some(first.clone()));
    assert!(find(cx, &window, reveal.clone()).visible(), "opacity 1 with keyboard focus");
    cx.executor().advance_clock(Duration::from_millis(150));
    cx.run_until_parked();
    assert_eq!(read(cx, &window, |p| p.lib.preview_id.clone()), Some(first), "focus asks for the preview");
    cx.update_window(window.into(), |_, w, cx| w.press("shift-tab", cx)).unwrap();
    frame(cx, &window);
    frame(cx, &window);
    assert_ne!(find(cx, &window, note).focused(), Some(true), "Shift-Tab goes back");
    assert!(!find(cx, &window, reveal).visible(), "the menu hides again");
}

// parity: NOTE-071
#[flow_ui::gpui::test]
async fn row_click_opens_the_thoughts_tab_even_after_another_tab(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    open(cx, &window, SEED_UNTITLED, Tab::Summary);
    click(cx, &window, "meeting.back");
    frame(cx, &window);
    click(cx, &window, sid(format!("notetaker.note.{SEED_FULL}")));
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| (p.tab, p.lib.detail.as_ref().map(|d| d.meeting.id.clone()))), (Tab::Thoughts, Some(SEED_FULL.to_string())));
}

// parity: NOTE-072 NOTE-073 NOTE-074
#[flow_ui::gpui::test]
async fn recording_row_carries_a_green_thirteen_point_badge(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.recording"));
    fresh(cx, &window);
    let (.., green) = colors(cx);
    let (id, elapsed) = read(cx, &window, |p| { let s = p.status.as_ref().unwrap(); (s.id.clone(), s.elapsed_ms) });
    assert_eq!(read(cx, &window, |p| p.lib.rows[0].id.clone()), id, "pinned first");
    assert_eq!(sized(&duration_text(elapsed)), (13., 400., green));
    assert_eq!(flow_ui::probe::symbol_color("waveform"), Some(green));
    let row = find(cx, &window, sid(format!("notetaker.note.{id}"))).bounds();
    let badge = find(cx, &window, "meeting.elapsed").bounds();
    assert!(row.contains(&badge.origin), "the badge is on the row");
    assert_eq!(row.right() - badge.right(), px(6.), "trailing 6");
}

// parity: NOTE-075
#[flow_ui::gpui::test]
async fn paused_badge_is_muted_and_still(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.paused"));
    fresh(cx, &window);
    let (_, muted, ..) = colors(cx);
    assert_eq!(flow_ui::probe::symbol_color("pause.fill"), Some(muted));
    assert!(!has(cx, &window, "meeting.waveform"));
}

// parity: NOTE-076 NOTE-077 NOTE-078
#[flow_ui::gpui::test]
async fn waiting_row_is_muted_labelled_and_moves_to_this_mac(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.waiting"));
    let (_, muted, ..) = colors(cx);
    assert_eq!((sized("Waiting for your server").0, sized("Waiting for your server").2), (12., muted));
    assert_eq!(sized("Run on this Mac").0, 12.);
    let title = read(cx, &window, |p| p.lib.rows.iter().find(|r| r.id == SEED_IPHONE).unwrap().title.clone().unwrap());
    let run = sid(format!("notetaker.runOnThisMac.{SEED_IPHONE}"));
    assert_labelled(cx, &window, run.clone(), &format!("Run {title} on this Mac"));
    assert!(!has(cx, &window, sid(format!("notetaker.runOnThisMac.{SEED_FULL}"))), "only when waiting");
    click(cx, &window, run);
    frame(cx, &window);
    let local: i64 = query(cx, |db| db.conn.query_row("SELECT run_locally FROM meetings WHERE id=?1", [SEED_IPHONE], |r| r.get(0)).unwrap());
    assert_eq!(local, 1);
}

// parity: NOTE-081
#[flow_ui::gpui::test]
async fn state_badge_shows_for_unfinished_rows_unless_waiting(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    fresh(cx, &window);
    let (_, muted, ..) = colors(cx);
    assert_eq!((sized("Interrupted").0, sized("Interrupted").2), (12., muted));
    assert!(!flow_ui::probe::seen().iter().any(|s| s == "Completed"), "a completed row has no badge");
    sql(cx, &format!("UPDATE meetings SET state='interrupted' WHERE id='{SEED_IPHONE}';"));
    window.update(cx, |p, _, cx| { p.waiting.insert(SEED_IPHONE.into()); p.refresh(cx) }).unwrap();
    fresh(cx, &window);
    let label = find(cx, &window, sid(format!("notetaker.note.{SEED_IPHONE}"))).label().unwrap().to_string();
    assert!(label.contains("Waiting for your server") && !label.contains("Interrupted"), "{label}");
}

// parity: NOTE-082
#[flow_ui::gpui::test]
async fn warning_triangle_is_orange_labelled_and_follows_a_pending_deletion(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    fresh(cx, &window);
    let (.., orange, _) = colors(cx);
    assert_eq!(flow_ui::probe::symbol_color("exclamationmark.triangle"), Some(orange));
    let label = |cx: &mut TestAppContext, id: &str| find(cx, &window, sid(format!("notetaker.note.{id}"))).label().unwrap().to_string();
    assert!(label(cx, SEED_INTERRUPTED).contains("Recording needs attention"));
    assert!(!label(cx, SEED_FULL).contains("Recording needs attention"));
    window.update(cx, |p, _, cx| { p.lib.deletion_pending.insert(SEED_FULL.into()); cx.notify() }).unwrap();
    frame(cx, &window);
    assert!(label(cx, SEED_FULL).contains("Recording needs attention"), "deletionPending warns too");
}

// parity: NOTE-084 NOTE-085 NOTE-087
#[flow_ui::gpui::test]
async fn overflow_delete_is_red_inset_eight_and_closes_into_the_dialog(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1180., 780.);
    window.update(cx, |p, _, cx| p.toggle_menu(&format!("row.{SEED_FULL}"), cx)).unwrap();
    fresh(cx, &window);
    let (panel, item) = (find(cx, &window, "notetaker.popover").bounds(), find(cx, &window, "notetaker.overflow.delete").bounds());
    assert_eq!(panel.size.width, px(190.));
    assert_eq!((item.origin.x - panel.origin.x, item.origin.y - panel.origin.y), (px(8.), px(8.)));
    assert_eq!(item.size.width, px(174.));
    let (.., red, _, _) = colors(cx);
    assert_eq!(sized("Delete").0, 14.);
    assert_eq!(sized("Delete").2, red);
    assert_eq!(flow_ui::probe::symbol_color("trash"), Some(red));
    click(cx, &window, "notetaker.overflow.delete");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.menu.is_none()), "the popover closes");
    assert!(read(cx, &window, |p| matches!(p.confirm, Some(Confirm::DeleteRow(..)))), "the library dialog opens");
}

// parity: NOTE-090
#[flow_ui::gpui::test]
async fn delete_cancel_closes_and_keeps_the_row(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.delete-row"));
    let revision = query(cx, |db| meeting(db, SEED_FULL).unwrap().unwrap().revision);
    click(cx, &window, "notetaker.delete.cancel");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.confirm.is_none()));
    assert_eq!(query(cx, |db| meeting(db, SEED_FULL).unwrap().unwrap().revision), revision, "nothing written");
}

// parity: NOTE-097 NOTE-098 NOTE-102
#[flow_ui::gpui::test]
async fn preview_type_limit_and_trimming(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1180., 780.);
    let long = "z".repeat(1300);
    query(cx, |db| db.conn.execute("UPDATE meeting_notes SET text=?1 WHERE meeting_id=?2", [long.as_str(), SEED_FULL]).unwrap());
    window.update(cx, |p, _, cx| { p.lib.preview(db_of(cx).unwrap(), SEED_FULL); cx.notify() }).unwrap();
    fresh(cx, &window);
    let (ink, muted, ..) = colors(cx);
    let row = read(cx, &window, |p| p.lib.rows.iter().find(|r| r.id == SEED_FULL).unwrap().clone());
    let offset = cx.update(|cx| offset_at(row.created_at, cx));
    assert_eq!(sized(&row.display_title(offset)).0, 18., "the preview's title, laid out after the list's");
    assert_eq!(sized(&row.display_title(offset)).1, 500.);
    let meta = format!("{} · {}", date_time_text(row.created_at, offset), duration_text(row.recorded_ms));
    assert_eq!((sized(&meta).0, sized(&meta).2), (14., muted));
    assert_eq!(sized("MY THOUGHTS"), (12., 500., muted));
    assert_eq!(sized(&"z".repeat(1200)), (14., 400., ink), "the first 1200 characters");
    assert!(flow_ui::probe::style_of(&"z".repeat(1201)).is_none());
    let d = read(cx, &window, |p| { let d = p.lib.preview.as_ref().unwrap(); (d.tracks.len(), d.pause_count, d.outcome_count) });
    assert_eq!(d, (0, 0, 0), "tracks, pauses and outcomes are dropped");
}

// parity: NOTE-104
#[flow_ui::gpui::test]
async fn icon_button_is_a_labelled_twenty_eight_square(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let b = find(cx, &window, "notetaker.refresh").bounds();
    assert_eq!((b.size.width, b.size.height), (px(28.), px(28.)));
    assert_labelled(cx, &window, "notetaker.refresh", "Refresh notes");
    flow_ui::probe::clear();
    frame(cx, &window);
    assert_saw(&["symbol:arrow.clockwise"]);
    assert_eq!(flow_ui::probe::symbols().iter().filter(|s| *s == "arrow.clockwise").count(), 1);
}

// --- Round 4 row review: the active card.

// parity: LIVE-001 LIVE-005 LIVE-007 LIVE-012 LIVE-022 LIVE-028 LIVE-033
#[flow_ui::gpui::test]
async fn panel_type_colours_and_frames(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    // Off the rows, so only the card lays out this elapsed text.
    window.update(cx, |p, _, cx| { p.status.as_mut().unwrap().id = "not-on-the-page".into(); cx.notify() }).unwrap();
    fresh(cx, &window);
    let (ink, muted, _, _, green) = colors(cx);
    let (card, notes) = (find(cx, &window, "meeting.card").bounds(), find(cx, &window, "meeting.notes.frame").bounds());
    assert_eq!(notes.origin.x - card.origin.x, px(16.));
    assert_eq!(card.bottom() - notes.bottom(), px(16.));
    assert_eq!(notes.size.height, px(90.));
    assert_eq!(sized("Recording"), (15., 600., ink));
    let elapsed = read(cx, &window, |p| p.status.as_ref().unwrap().elapsed_ms);
    assert_eq!((sized(&duration_text(elapsed)).0, sized(&duration_text(elapsed)).1), (22., 500.));
    assert_eq!(flow_ui::probe::symbol_color("mic.fill"), Some(green));
    assert_eq!(flow_ui::probe::symbol_color("speaker.wave.2.fill"), Some(green));
    assert_eq!((sized("capturing").0, sized("capturing").2), (12., muted));
    assert_eq!(sized("Stop Meeting").2, gpui::white().into());
    assert_labelled(cx, &window, "meeting.stopCard", "Stop Meeting");
    assert_eq!(find(cx, &window, "meeting.title.frame").bounds().size.width, px(360.));
    assert_eq!((sized("Notes").0, sized("Notes").1), (13., 600.));
}

// parity: LIVE-003 LIVE-004
#[flow_ui::gpui::test]
async fn dot_paints_the_states_colour(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    let dot = find(cx, &window, "meeting.dot").bounds();
    assert_eq!(dot.size.width, px(10.));
    cx.update(|cx| {
        assert_eq!(active::dot_color("paused", cx), orange(cx));
        assert_eq!(active::dot_color("finalizing", cx), pal(cx).muted);
    });
}

// parity: LIVE-006
#[flow_ui::gpui::test]
async fn pause_reason_only_shows_while_paused(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    window.update(cx, |p, _, cx| { let s = p.status.as_mut().unwrap(); s.pause_reason = Some("user"); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert!(!seen("(user)"));
}

// parity: LIVE-029
#[flow_ui::gpui::test]
async fn title_field_starts_from_the_stored_title(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    let window = cx.add_window(|w, cx| NotetakerPage::new(w, cx));
    sql(cx, &format!("UPDATE meetings SET title='Kept title' WHERE id='{SEED_UNTITLED}';"));
    window.update(cx, |p, _, cx| { p.status = Some(LiveStatus::scenario("recording")); p.refusal = Some("x".into()); cx.notify() }).unwrap();
    frame(cx, &window);
    let draft = window.read_with(cx, |p, cx| p.active_title.read(cx).value().to_string()).unwrap();
    assert_eq!(draft, "Kept title");
}

// parity: LIVE-008 LIVE-009 LIVE-011 LIVE-013
#[flow_ui::gpui::test]
async fn banners_and_tracks_of_an_ended_card(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.interrupted-card"));
    fresh(cx, &window);
    let (_, muted, red, ..) = colors(cx);
    assert_eq!(sized("Recording stopped"), (13., 600., red));
    assert!(has(cx, &window, "meeting.captureLoss"));
    let (mic, system) = (find(cx, &window, "meeting.track.microphone").bounds(), find(cx, &window, "meeting.track.system").bounds());
    assert_eq!(system.origin.x - mic.right(), px(14.), "14 between");
    assert_eq!(flow_ui::probe::symbol_color("mic.fill"), Some(muted), "finalized is secondary");
    assert_eq!((sized("finalized").0, sized("finalized").2), (12., muted));
    let window = open_page(cx, Some("notetaker.failed-card"));
    fresh(cx, &window);
    assert_eq!(sized("The meeting could not start"), (13., 600., red));
    assert_eq!(flow_ui::probe::symbol_color("exclamationmark.triangle.fill"), Some(red));
}

// parity: LIVE-014 LIVE-015
#[flow_ui::gpui::test]
async fn failed_and_not_started_tracks_have_their_own_colours(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.failed-card"));
    fresh(cx, &window);
    let (_, muted, red, ..) = colors(cx);
    assert_eq!(flow_ui::probe::symbol_color("mic.fill"), Some(red));
    assert_eq!(sized("failed: device lost").2, muted);
    assert_eq!(flow_ui::probe::symbol_color("speaker.wave.2.fill"), Some(rgb(0x8E8E93).into()), ".gray, not secondary");
    assert_saw(&["not started"]);
    let _ = window;
}

// parity: LIVE-010 LIVE-016
#[flow_ui::gpui::test]
async fn storage_warning_and_lost_audio_are_orange(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.notice-card"));
    let (.., orange, _) = colors(cx);
    assert_eq!(sized("Less than 2 GB free").2, orange);
    assert_eq!(flow_ui::probe::symbol_color("externaldrive.badge.exclamationmark"), Some(orange));
    let lost = "Some audio was lost during recording. The transcript may be incomplete.";
    assert_eq!((sized(lost).0, sized(lost).2), (12., orange));
}

// parity: LIVE-017 LIVE-019
#[flow_ui::gpui::test]
async fn settings_button_opens_the_pane_the_refusal_names(cx: &mut TestAppContext) {
    use flow_platform::Permission;
    let window = open_page(cx, Some("notetaker.refusal"));
    assert_labelled(cx, &window, "meeting.openSettings", "Open System Settings");
    assert_eq!(active::refusal_permission("Microphone access is not allowed. Enable LocalFlow in System Settings > Privacy & Security > Microphone."), Permission::Microphone);
    assert_eq!(active::refusal_permission("System audio needs Screen & System Audio Recording. Enable LocalFlow in System Settings > Privacy & Security > Screen & System Audio Recording, then try again."), Permission::SystemAudio);
    window.update(cx, |p, _, cx| { p.refusal = Some("Meeting is busy".into()); cx.notify() }).unwrap();
    frame(cx, &window);
    assert!(!has(cx, &window, "meeting.openSettings"), "only a permission refusal offers it");
}

// parity: LIVE-034 LIVE-035 LIVE-036 LIVE-037
#[flow_ui::gpui::test]
async fn notes_state_reads_twelve_points_and_red_when_failed(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    let (_, muted, red, ..) = colors(cx);
    let mut state = |cx: &mut TestAppContext, dirty, state, text: &str| {
        window.update(cx, |p, _, cx| { let e = p.editor.as_mut().unwrap(); e.is_dirty = dirty; e.state = state; cx.notify() }).unwrap();
        fresh(cx, &window);
        (sized(text).0, sized(text).2)
    };
    assert_eq!(state(cx, true, SaveState::Idle, "Unsaved"), (12., muted));
    assert_eq!(state(cx, true, SaveState::Saving, "Saving…"), (12., muted));
    assert_eq!(state(cx, false, SaveState::Saved, "Saved"), (12., muted));
    assert_eq!(state(cx, true, SaveState::NotSaved, "Not saved"), (12., red));
}

// parity: LIVE-024 LIVE-025
#[flow_ui::gpui::test]
async fn progress_states_are_muted_and_hide_the_buttons(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    let (_, muted, ..) = colors(cx);
    for (state, text) in [("finalizing", "Finalizing…"), ("preparing", "Starting…")] {
        window.update(cx, |p, _, cx| { p.status.as_mut().unwrap().state = state.into(); cx.notify() }).unwrap();
        fresh(cx, &window);
        assert_eq!(sized(text).2, muted);
        assert!(!has(cx, &window, "meeting.stopCard") && !has(cx, &window, "meeting.pause"));
    }
}

// Round 4 row review: the open note.

// parity: MEET-001 MEET-038 MEET-040 MEET-065 MEET-023
#[flow_ui::gpui::test]
async fn note_frames_and_date_read_like_swift(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1400., 900.);
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    let (toolbar, column, tabs, rule, footer) = (find(cx, &window, "meeting.toolbar").bounds(), find(cx, &window, "meeting.column").bounds(), find(cx, &window, "meeting.tabs").bounds(), find(cx, &window, "meeting.rule").bounds(), find(cx, &window, "meeting.footer.frame").bounds());
    assert_eq!((toolbar.size.width, rule.size.width, column.size.width), (px(860.), px(860.), px(660.)));
    assert_eq!(toolbar.origin.y, px(17.), "18 less the panel's 1 pt inset");
    let (back, options) = (find(cx, &window, "meeting.back").bounds(), find(cx, &window, "meeting.options").bounds());
    assert_eq!((back.origin.x, options.origin.y), (toolbar.origin.x, toolbar.origin.y));
    let (previous, next) = (find(cx, &window, "meeting.previous").bounds(), find(cx, &window, "meeting.next").bounds());
    assert_eq!(next.origin.x - previous.origin.x - previous.size.width, px(4.), "toolbar spacing");
    let (first, second) = (find(cx, &window, "meeting.tab.thoughts").bounds(), find(cx, &window, "meeting.tab.transcript").bounds());
    assert_eq!(second.origin.x - first.origin.x - first.size.width, px(20.));
    assert_eq!(tabs.origin.x, column.origin.x + px(30.), "the header and the body share a 600 column");
    let thoughts = find(cx, &window, "meeting.thoughts.frame").bounds();
    assert_eq!(thoughts.size.height, px(420.));
    assert_eq!(thoughts.size.width, px(600.));
    let play = find(cx, &window, "meeting.playback").bounds();
    assert_eq!(play.origin.y - footer.origin.y, px(12.));
    assert_eq!(footer.origin.y + footer.size.height - play.origin.y - play.size.height, px(20.));
    let (_, muted, ..) = colors(cx);
    let created = read(cx, &window, |p| p.lib.detail.as_ref().unwrap().meeting.created_at);
    let date = date_time_text(created, cx.update(|cx| offset_at(created, cx)));
    assert_eq!(sized(&date), (15., 400., muted));
}
// parity: MEET-018
#[flow_ui::gpui::test]
async fn title_field_grows_to_three_lines_and_return_saves(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1400., 900.);
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    let one = find(cx, &window, "meeting.title.frame").bounds().size.height;
    type_in!(cx, &window, |p| p.title.clone(), "one\ntwo\nthree\nfour\nfive");
    frame(cx, &window);
    frame(cx, &window);
    let grown = find(cx, &window, "meeting.title.frame").bounds().size.height;
    assert_eq!(grown, one + px(92.), "three lines of 46, then it scrolls");
    type_in!(cx, &window, |p| p.title.clone(), "By return");
    cx.update_window(window.into(), |_, w, cx| w.press("enter", cx)).unwrap();
    frame(cx, &window);
    assert_eq!(query(cx, |db| meeting(db, SEED_FULL).unwrap().unwrap().title).as_deref(), Some("By return"));
    assert_eq!(read(cx, &window, |p| p.title.clone()).read_with(cx, |s, _| s.value().to_string()), "By return");
}
// parity: MEET-018
#[flow_ui::gpui::test]
async fn title_field_is_one_line(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    resize(cx, &window, 1400., 900.);
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    assert_eq!(find(cx, &window, "meeting.title.frame").bounds().size.height, px(48.), "one line; the date below lands where the detail pair puts it");
    assert_eq!(read(cx, &window, |p| p.title.clone()).read_with(cx, |s, _| s.value().to_string()), "Lamp prototype review");
}
// parity: MEET-002
#[flow_ui::gpui::test]
async fn back_has_its_symbol_and_label(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    assert_labelled(cx, &window, "meeting.back", "Back to past notes");
    assert_symbols(&["chevron.left"]);
}
// parity: MEET-003
#[flow_ui::gpui::test]
async fn back_saves_typing_before_the_debounce(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    type_in!(cx, &window, |p| p.thoughts.clone(), "Just typed.");
    click(cx, &window, "meeting.back");
    frame(cx, &window);
    assert_eq!(query(cx, |db| notes(db, SEED_FULL).unwrap().unwrap().0), "Just typed.");
    assert!(read(cx, &window, |p| p.lib.detail.is_none()));
}
// parity: MEET-007
#[flow_ui::gpui::test]
async fn next_saves_first_and_keeps_the_tab(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    type_in!(cx, &window, |p| p.thoughts.clone(), "Saved by next.");
    click(cx, &window, "meeting.tab.summary");
    click(cx, &window, "meeting.next");
    frame(cx, &window);
    assert_eq!(query(cx, |db| notes(db, SEED_FULL).unwrap().unwrap().0), "Saved by next.");
    assert_ne!(read(cx, &window, |p| p.lib.detail.as_ref().unwrap().meeting.id.clone()), SEED_FULL);
    assert!(read(cx, &window, |p| p.tab == Tab::Summary));
    let id = read(cx, &window, |p| p.lib.detail.as_ref().unwrap().meeting.id.clone());
    refuse(cx, "UPDATE", "meeting_notes");
    click(cx, &window, "meeting.tab.thoughts");
    type_in!(cx, &window, |p| p.thoughts.clone(), "Cannot save.");
    click(cx, &window, "meeting.next");
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.lib.detail.as_ref().unwrap().meeting.id.clone()), id, "a dirty editor stays");
}
// parity: MEET-008
#[flow_ui::gpui::test]
async fn adjacent_buttons_disable_at_the_ends(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let rows: Vec<String> = read(cx, &window, |p| p.lib.rows.iter().map(|r| r.id.clone()).collect());
    open(cx, &window, &rows[0], Tab::Thoughts);
    assert_eq!(find(cx, &window, "meeting.previous").disabled(), Some(true));
    assert_ne!(find(cx, &window, "meeting.next").disabled(), Some(true));
    open(cx, &window, rows.last().unwrap(), Tab::Thoughts);
    assert_ne!(find(cx, &window, "meeting.previous").disabled(), Some(true));
    assert_eq!(find(cx, &window, "meeting.next").disabled(), Some(true));
}
// parity: MEET-019
#[flow_ui::gpui::test]
async fn title_saves_on_enter_and_blur_trims_and_clears(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    let stored = |cx: &mut TestAppContext| query(cx, |db| { let m = meeting(db, SEED_FULL).unwrap().unwrap(); (m.title, m.revision) });
    let (_, start) = stored(cx);
    window.update(cx, |p, w, cx| p.save_title(w, cx)).unwrap();
    assert_eq!(stored(cx).1, start, "untouched saves nothing");
    type_in!(cx, &window, |p| p.title.clone(), "  By enter  ");
    cx.update_window(window.into(), |_, w, cx| w.press("enter", cx)).unwrap();
    frame(cx, &window);
    assert_eq!(stored(cx), (Some("By enter".to_string()), start + 1));
    window.update(cx, |_, w, _| w.activate_window()).unwrap();
    frame(cx, &window);
    type_in!(cx, &window, |p| p.title.clone(), "By blur");
    frame(cx, &window);
    window.update(cx, |p, w, cx| p.thoughts.read(cx).focus_handle(cx).focus(w, cx)).unwrap();
    frame(cx, &window);
    frame(cx, &window);
    assert_eq!(stored(cx), (Some("By blur".to_string()), start + 2));
    type_in!(cx, &window, |p| p.title.clone(), "   ");
    window.update(cx, |p, w, cx| p.save_title(w, cx)).unwrap();
    frame(cx, &window);
    assert_eq!(stored(cx), (None, start + 3), "blank stores NULL");
}
// parity: MEET-024 MEET-025 MEET-026
#[flow_ui::gpui::test]
async fn warnings_and_reason_have_their_type_and_colour(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let (.., red, orange, _) = colors(cx);
    let lost = "Some audio was lost during recording. The transcript may be incomplete.";
    sql(cx, &format!("UPDATE meeting_tracks SET dropped_frames=1, duration_warning=1 WHERE meeting_id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    assert_eq!(sized(lost), (13., 400., orange));
    assert_eq!(flow_ui::probe::symbol_color("exclamationmark.triangle.fill"), Some(orange));
    assert!(has(cx, &window, "meeting.captureLoss"));
    assert!(!has(cx, &window, "meeting.durationWarning"), "else if");
    sql(cx, &format!("UPDATE meeting_tracks SET dropped_frames=0 WHERE meeting_id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    assert_eq!(sized("A recording track does not match the meeting duration. Some audio may be missing."), (13., 400., orange));
    assert_eq!(flow_ui::probe::symbol_color("exclamationmark.triangle.fill"), Some(orange));
    open(cx, &window, SEED_INTERRUPTED, Tab::Thoughts);
    assert_eq!(sized("LocalFlow did not exit cleanly during this meeting. Recorded audio was recovered where possible."), (13., 400., red));
}
// parity: MEET-041 MEET-044 MEET-045
#[flow_ui::gpui::test]
async fn detail_notice_is_red_twelve_with_a_native_retry(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let (.., red, _, _) = colors(cx);
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    sql(cx, "ALTER TABLE meeting_notes RENAME TO notes_gone;");
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    assert_eq!(sized("Meeting details could not be loaded."), (12., 400., red));
    sql(cx, "ALTER TABLE notes_gone RENAME TO meeting_notes;");
    assert!(!has(cx, &window, "meeting.retryDeletion"), "only while deletion is pending");
    window.update(cx, |p, _, cx| { p.lib.deletion_pending.insert(SEED_FULL.to_string()); p.lib.detail_notice = Some("Left".into()); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_eq!(sized("Retry deletion").0, 12.);
    assert_eq!(find(cx, &window, "meeting.retryDeletion").bounds().origin.y - find(cx, &window, "meeting.notice").bounds().origin.y, px(12.), "padding 12");
    let revision = read(cx, &window, |p| p.lib.detail.as_ref().unwrap().meeting.revision);
    assert!(query(cx, |db| meeting(db, SEED_FULL).unwrap().unwrap().revision) == revision);
    click(cx, &window, "meeting.retryDeletion");
    frame(cx, &window);
    assert!(query(cx, |db| meeting(db, SEED_FULL).unwrap().is_none()), "retry deletes with the current revision");
}
// parity: MEET-046 MEET-047
#[flow_ui::gpui::test]
async fn waiting_row_is_muted_twelve_with_a_twelve_point_gap(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.waiting-detail"));
    let (_, muted, ..) = colors(cx);
    assert_eq!(sized("Waiting for your server"), (12., 400., muted));
    assert_eq!(sized("Run on this Mac").0, 12.);
    assert_labelled(cx, &window, "notetaker.detail.runOnThisMac", "Run this meeting on this Mac");
    let (row, button) = (find(cx, &window, "meeting.waiting").bounds(), find(cx, &window, "notetaker.detail.runOnThisMac").bounds());
    assert_eq!(button.origin.y - row.origin.y, px(12.), "padding 12");
}
// parity: MEET-049 MEET-054
#[flow_ui::gpui::test]
async fn provenance_is_muted_twelve_spoken_and_follows_the_transcript_state(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let (_, muted, ..) = colors(cx);
    sql(cx, &format!("UPDATE meeting_transcriptions SET inference_path='server' WHERE meeting_id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    let text = read(cx, &window, |p| p.provenance.clone()).unwrap();
    assert!(text.starts_with("Transcript: your server · Speaker labels:"), "{text}");
    assert_eq!(sized(&text), (12., 400., muted));
    assert_saw(&[&format!("Produced on: {text}")]);
    sql(cx, &format!("UPDATE meeting_transcriptions SET state='finalizing' WHERE meeting_id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    sql(cx, &format!("UPDATE meeting_transcriptions SET inference_path='custom', state='final' WHERE meeting_id='{SEED_FULL}';"));
    cx.executor().advance_clock(Duration::from_secs(6));
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.provenance.clone()).unwrap().contains("your custom server"), "re-read when finalizing ends");
}
// parity: MEET-055 MEET-056
#[flow_ui::gpui::test]
async fn thoughts_placeholder_is_faded_muted_fourteen_at_top_four(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let (_, muted, ..) = colors(cx);
    sql(cx, &format!("UPDATE meeting_notes SET text='' WHERE meeting_id='{SEED_UNTITLED}';"));
    open(cx, &window, SEED_UNTITLED, Tab::Thoughts);
    assert_eq!(sized("Capture your thoughts here"), (14., 400., muted.opacity(0.7)));
    let (frame_b, holder) = (find(cx, &window, "meeting.thoughts.frame").bounds(), find(cx, &window, "meeting.thoughts.placeholder").bounds());
    assert_eq!(holder.origin.y - frame_b.origin.y, px(4.));
    assert_eq!(frame_b.size.height, px(420.));
}
// parity: MEET-057
#[flow_ui::gpui::test]
async fn steady_typing_saves_within_ten_seconds_and_a_failed_save_tries_again(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    for i in 0..11 {
        type_in!(cx, &window, |p| p.thoughts.clone(), &format!("edit {i}"));
        cx.executor().advance_clock(Duration::from_secs(1));
        frame(cx, &window);
    }
    let saved = query(cx, |db| notes(db, SEED_FULL).unwrap().unwrap().0);
    assert!(saved.starts_with("edit "), "forced within 10 s, got {saved:?}");
    assert_ne!(saved, "edit 10", "the debounce never fired");
    cx.executor().advance_clock(Duration::from_secs(3));
    frame(cx, &window);
    assert_eq!(query(cx, |db| notes(db, SEED_FULL).unwrap().unwrap().0), "edit 10", "later edits follow");
    refuse(cx, "UPDATE", "meeting_notes");
    type_in!(cx, &window, |p| p.thoughts.clone(), "Comes back.");
    cx.executor().advance_clock(Duration::from_secs(3));
    fresh(cx, &window);
    assert_saw(&["Notes not saved"]);
    allow(cx, "UPDATE", "meeting_notes");
    cx.executor().advance_clock(Duration::from_secs(3));
    fresh(cx, &window);
    assert_eq!(query(cx, |db| notes(db, SEED_FULL).unwrap().unwrap().0), "Comes back.", "no click needed");
    assert!(!seen("Notes not saved"));
}
// parity: MEET-058 MEET-059
#[flow_ui::gpui::test]
async fn editor_notices_show_on_the_page(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    let huge = "x".repeat(1024 * 1024 + 1);
    type_in!(cx, &window, |p| p.thoughts.clone(), "Short.");
    // Typing a mebibyte through the Kit field in a test takes minutes; this is the Change handler.
    window.update(cx, |p, w, cx| { let input = p.thoughts.clone(); p.thoughts_changed(&huge, input, w, cx) }).unwrap();
    fresh(cx, &window);
    assert_saw(&["Notes are limited to 1 MiB. The last edit was not applied."]);
    assert_eq!(read(cx, &window, |p| p.thoughts.clone()).read_with(cx, |s, _| s.value().to_string()), "Short.", "the field keeps the text");
    window.update(cx, |p, _, cx| p.reveal_note(1, "not-this-hash", cx)).unwrap();
    fresh(cx, &window);
    assert_saw(&["This note has changed"]);
}
// parity: MEET-061 MEET-062 MEET-063
#[flow_ui::gpui::test]
async fn retry_save_is_red_twelve_and_runs_the_flush(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    let (.., red, _, _) = colors(cx);
    refuse(cx, "UPDATE", "meeting_notes");
    type_in!(cx, &window, |p| p.thoughts.clone(), "Stuck.");
    click(cx, &window, "meeting.back");
    fresh(cx, &window);
    assert_eq!(sized("Notes not saved"), (12., 400., red));
    assert_eq!(sized("Retry save").0, 12.);
    allow(cx, "UPDATE", "meeting_notes");
    click(cx, &window, "meeting.retrySave");
    frame(cx, &window);
    assert_eq!(query(cx, |db| notes(db, SEED_FULL).unwrap().unwrap().0), "Stuck.");
}
// parity: MEET-064
#[flow_ui::gpui::test]
async fn leaving_the_page_saves_the_notes(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    cx.update(crate::shell::ensure_session);
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = crate::pages::Page::Meetings));
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    type_in!(cx, &window, |p| p.thoughts.clone(), "Typed, then Settings.");
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = crate::pages::Page::History));
    frame(cx, &window);
    assert_eq!(query(cx, |db| notes(db, SEED_FULL).unwrap().unwrap().0), "Typed, then Settings.");
    assert!(read(cx, &window, |p| p.editor.is_none()));
}
// parity: MEET-066 MEET-068
#[flow_ui::gpui::test]
async fn live_footer_has_pause_and_a_green_stop(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.live"));
    let (ink, _, _, _, green) = colors(cx);
    assert_eq!(flow_ui::probe::symbol_color("pause.fill"), Some(ink));
    assert_eq!(flow_ui::probe::symbol_color("stop.fill"), Some(green));
    assert_labelled(cx, &window, "meeting.pause", "Pause");
    assert_labelled(cx, &window, "meeting.stop", "Stop");
}
// parity: MEET-072
#[flow_ui::gpui::test]
async fn playback_button_has_its_symbol_and_label(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    assert_labelled(cx, &window, "meeting.playback", "Playback");
    assert_symbols(&["play.circle"]);
}
// parity: MEET-078
#[flow_ui::gpui::test]
async fn playback_notice_is_muted_twelve(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.detail"));
    let (_, muted, ..) = colors(cx);
    click(cx, &window, "meeting.playback");
    fresh(cx, &window);
    assert_eq!(sized("No playable audio"), (12., 400., muted));
}
// parity: MEET-039
#[flow_ui::gpui::test]
async fn tab_starts_from_the_request_and_clicks_switch_it(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    open(cx, &window, SEED_FULL, Tab::Transcript);
    assert!(read(cx, &window, |p| p.tab == Tab::Transcript));
    click(cx, &window, "meeting.tab.summary");
    assert!(read(cx, &window, |p| p.tab == Tab::Summary));
    open(cx, &window, SEED_FULL, Tab::Thoughts);
    assert!(read(cx, &window, |p| p.tab == Tab::Thoughts), "not persisted");
}

// Round 4 row review: the transcript tab.

// parity: TRANS-001 TRANS-002 TRANS-012 TRANS-027 TRANS-043
#[flow_ui::gpui::test]
async fn transcript_header_and_bubble_read_like_swift(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    let (_, muted, ..) = colors(cx);
    assert_eq!(find(cx, &window, "meeting.transcript.header").bounds().size.height, px(32.));
    assert_eq!(sized("12:34"), (11., 400., muted));
    assert_symbols(&["clock", "square.on.square", "magnifyingglass", "person.badge.plus"]);
    assert_labelled(cx, &window, "meeting.transcript.copy", "Copy or export transcript");
    assert!(!flow_ui::probe::symbols().iter().any(|s| s == "doc.on.doc"));
    let first = "Let us start with the release date for the desk lamp prototype.";
    assert_eq!(sized(first).0, 13.);
    let bubble = find(cx, &window, sid("meeting.transcript.bubble.0".to_string())).bounds();
    assert_eq!(bubble.size.height, px(13. + 14.), "one 13 pt line and v7");
    click(cx, &window, "meeting.transcript.search.open");
    fresh(cx, &window);
    assert_eq!(find(cx, &window, "meeting.transcript.search.frame").bounds().size.width, px(170.));
}
// parity: TRANS-014 TRANS-018 TRANS-019 TRANS-020 TRANS-021
#[flow_ui::gpui::test]
async fn match_count_shows_each_state_after_a_quarter_second(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    let (_, muted, ..) = colors(cx);
    click(cx, &window, "meeting.transcript.search.open");
    frame(cx, &window);
    let search = |cx: &mut TestAppContext, q: &str| {
        type_in!(cx, &window, |p| p.search.clone(), q);
        cx.executor().advance_clock(Duration::from_millis(200));
        fresh(cx, &window);
        assert_saw(&["Searching…"]);
        cx.executor().advance_clock(Duration::from_millis(100));
        fresh(cx, &window);
    };
    search(cx, "zebra");
    assert_eq!(sized("No matches"), (11., 400., muted));
    assert_eq!(sized("No matches.").0, 15., "and the empty list says so");
    search(cx, "hinge");
    assert_eq!(sized("1 match"), (11., 400., muted));
    search(cx, "the");
    assert_eq!(sized("11 matches"), (11., 400., muted));
    click(cx, &window, "meeting.transcript.search.next");
    click(cx, &window, "meeting.transcript.search.next");
    fresh(cx, &window);
    assert_eq!(sized("2 of 11"), (11., 400., muted));
    assert_eq!(read(cx, &window, |p| p.search.clone()).read_with(cx, |s, _| s.value().to_string()), "the");
    let resident = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().filter(|r| Pager::matches(r, "the")).count());
    assert_eq!(resident, 11, "the rows are filtered on the client too");
}
// parity: TRANS-016
#[flow_ui::gpui::test]
async fn a_jump_centres_the_row_and_the_flash_ends_after_two_seconds(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    resize(cx, &window, 1180., 520.);
    let last = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().last().unwrap().clone());
    window.update(cx, |p, _, cx| p.reveal_segment(&last.id, cx)).unwrap();
    frame(cx, &window);
    frame(cx, &window);
    cx.executor().advance_clock(Duration::from_millis(96));
    frame(cx, &window);
    let early = read(cx, &window, |p| p.scroll.offset().y);
    cx.executor().advance_clock(Duration::from_millis(200));
    frame(cx, &window);
    let settled = read(cx, &window, |p| p.scroll.offset().y);
    assert!(early > settled && early < px(0.), "the jump glides: {early:?} on the way to {settled:?}");
    let view = read(cx, &window, |p| p.scroll.bounds());
    let bubble = find(cx, &window, sid(format!("meeting.transcript.bubble.{}", last.ordinal))).bounds();
    assert!(read(cx, &window, |p| p.scroll.offset().y) < px(0.), "scrolled");
    assert!(bubble.bottom() <= view.bottom() + px(1.) && bubble.top() >= view.top(), "{bubble:?} in {view:?}");
    assert!(read(cx, &window, |p| !p.reveal_pending));
    cx.executor().advance_clock(Duration::from_millis(1600));
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.pager.as_ref().unwrap().highlighted.is_some()));
    cx.executor().advance_clock(Duration::from_millis(200));
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.pager.as_ref().unwrap().highlighted.is_none()));
}
// parity: TRANS-039
#[flow_ui::gpui::test]
async fn a_new_page_keeps_the_row_the_reader_was_on(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    query(cx, |db| {
        let names: Vec<String> = db.conn.prepare("SELECT name FROM pragma_table_info('transcript_segments')").unwrap().query_map([], |r| r.get(0)).unwrap().map(|n| n.unwrap()).collect();
        let copied = names.iter().filter(|c| *c != "id" && *c != "ordinal").cloned().collect::<Vec<_>>().join(",");
        db.conn.execute_batch(&format!("WITH RECURSIVE n(i) AS (SELECT 12 UNION ALL SELECT i+1 FROM n WHERE i<649) INSERT INTO transcript_segments (id, ordinal, {copied}) SELECT lower(hex(randomblob(16))), i, {copied} FROM n, (SELECT * FROM transcript_segments WHERE meeting_id='{SEED_FULL}' AND ordinal=0);")).unwrap();
    });
    open(cx, &window, SEED_FULL, Tab::Transcript);
    let bottom = |cx: &mut TestAppContext| read(cx, &window, |p| { let m = p.scroll.max_offset().y; p.scroll.set_offset(point(px(0.), -m)) });
    bottom(cx);
    frame(cx, &window);
    window.update(cx, |p, _, cx| p.page_on_scroll(cx)).unwrap();
    frame(cx, &window);
    bottom(cx);
    frame(cx, &window);
    let row = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().last().unwrap().ordinal);
    let id = sid(format!("meeting.transcript.bubble.{row}"));
    let before = find(cx, &window, id.clone()).bounds().origin.y;
    window.update(cx, |p, _, cx| p.page_on_scroll(cx)).unwrap();
    frame(cx, &window);
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.pager.as_ref().unwrap().rows().next().unwrap().ordinal), 200, "the first page was evicted");
    assert_eq!(find(cx, &window, id).bounds().origin.y, before);
}
// parity: TRANS-047 TRANS-049 TRANS-050 TRANS-051 TRANS-059
#[flow_ui::gpui::test]
async fn source_labels_and_failure_have_their_colours(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let (ink, muted, red, orange, _) = colors(cx);
    let purple = cx.update(|cx| purple(cx));
    sql(cx, &format!("UPDATE meeting_diarization SET accepted_run_id=NULL WHERE meeting_id='{SEED_FULL}'; UPDATE transcript_segments SET analysis_tracks='mic' WHERE meeting_id='{SEED_FULL}' AND ordinal=0; UPDATE transcript_segments SET analysis_tracks='system' WHERE meeting_id='{SEED_FULL}' AND ordinal=1; UPDATE transcript_segments SET analysis_tracks='both' WHERE meeting_id='{SEED_FULL}' AND ordinal=2;"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    assert_eq!(sized("You"), (12., 500., purple));
    assert_eq!(sized("Others"), (12., 500., orange));
    assert_eq!(sized("Unassigned"), (12., 500., muted));
    assert_eq!((source_explanation("mic"), source_explanation("system"), source_explanation("both")), ("Microphone audio", "System audio; may include multiple people", "Mixed microphone and system audio; speaker unknown"));
    assert_eq!(find(cx, &window, sid("meeting.transcript.bubble.0".to_string())).bounds().origin.y - find(cx, &window, sid("meeting.transcript.source.0".to_string())).bounds().bottom(), px(5.), "spacing 5");
    let text = "Let us start with the release date for the desk lamp prototype.";
    assert_eq!(sized(text).2, ink);
    sql(cx, &format!("UPDATE meeting_transcriptions SET failure_category='engine_failed', state='failed' WHERE meeting_id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    let message = read(cx, &window, |p| p.pager.as_ref().unwrap().row.clone()).unwrap();
    let failure = transcript_failure_text(message.failure_category.as_deref().unwrap(), message.segment_count, false, message.engine.as_deref() == Some("whisper.cpp"));
    assert_eq!(sized(&failure), (15., 400., red));
    sql(cx, &format!("UPDATE meeting_transcriptions SET failure_category=NULL, state='live' WHERE meeting_id='{SEED_FULL}'; UPDATE transcript_segments SET finality='provisional' WHERE meeting_id='{SEED_FULL}';"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    assert_eq!(sized(text).2, muted, "provisional text is muted");
}
// parity: TRANS-055
#[flow_ui::gpui::test]
async fn divider_is_muted_twelve_with_a_mic(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    let (_, muted, ..) = colors(cx);
    let text = flow_ui::probe::seen().into_iter().find(|t| t.starts_with("Microphone changed")).unwrap();
    assert_eq!(sized(&text), (12., 400., muted));
    assert_eq!(flow_ui::probe::symbol_color("mic"), Some(muted));
    assert!(has(cx, &window, "meeting.transcript.microphoneChanged"));
}
// parity: TRANS-056 TRANS-057 TRANS-058
#[flow_ui::gpui::test]
async fn live_rows_are_muted_and_follow_the_search(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.live"));
    let (_, muted, ..) = colors(cx);
    let row = "Let us start with the hinge samples.";
    assert_eq!(sized(row), (13., 400., muted));
    click(cx, &window, "meeting.transcript.search.open");
    type_in!(cx, &window, |p| p.search.clone(), "zzz");
    fresh(cx, &window);
    assert!(!seen(row));
    assert_eq!(sized("Listening…").2, muted);
    window.update(cx, |p, _, cx| { p.status.as_mut().unwrap().transcription_requested = false; cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_eq!(sized("Transcription is off for this note.").2, muted);
}
// parity: TRANS-073 TRANS-085 TRANS-087
#[flow_ui::gpui::test]
async fn section_list_and_rows_read_like_swift(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.section:interrupted"));
    let (_, muted, ..) = colors(cx);
    assert_eq!(sized("Transcript").0, 13.);
    assert_eq!(sized("Transcript").1, 600.);
    assert_eq!(sized("Interrupted"), (12., 400., muted));
    assert_eq!(find(cx, &window, "meeting.section.list").bounds().size.height, px(180.));
    assert_eq!(sized("00:00"), (13., 400., muted));
    assert_eq!(sized("provisional"), (11., 400., muted));
    assert_eq!(flow_ui::probe::symbol_color("circle.fill"), Some(muted));
    let (list, first, second) = (find(cx, &window, "meeting.section.list").bounds(), find(cx, &window, sid("meeting.section.row.0".to_string())).bounds(), find(cx, &window, sid("meeting.section.row.1".to_string())).bounds());
    assert_eq!(second.origin.y - first.bottom(), px(10.));
    assert_eq!(first.origin.x - list.origin.x, px(8.));
    assert_eq!((active::section_timestamp(61_000), active::section_timestamp(3_661_000)), ("01:01".to_string(), "1:01:01".to_string()));
}

// --- Round 4 row review: Assign speakers.

fn section_id(cx: &mut TestAppContext, window: &WindowHandle<NotetakerPage>, i: usize) -> String {
    read(cx, window, |p| p.assign.as_ref().unwrap().model.sections[i].speaker.id.clone())
}

// parity: SPK-046 SPK-047 SPK-048 SPK-050 SPK-057 SPK-061 SPK-062 SPK-092 SPK-095
#[flow_ui::gpui::test]
async fn assign_sheet_has_swifts_frames_type_and_symbols(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    resize(cx, &window, 1400., 1100.);
    fresh(cx, &window);
    let (ink, muted, ..) = colors(cx);
    let surface = cx.update(|cx| pal(cx).surface);
    let sheet = find(cx, &window, "meeting.speakers.assign").bounds();
    assert_eq!(sheet.size.width, px(560.));
    assert_eq!(sized("Assign speakers"), (28., 400., ink));
    let close = find(cx, &window, "meeting.speakers.close").bounds();
    assert_eq!(close.size, size(px(30.), px(30.)));
    assert_eq!(close.origin.y - sheet.origin.y, px(22.));
    assert_eq!(sheet.origin.x + sheet.size.width - (close.origin.x + close.size.width), px(22.));
    assert_labelled(cx, &window, "meeting.speakers.close", "Close");
    assert_symbols(&["xmark"]);
    assert_eq!(find(cx, &window, "meeting.speakers.scroll").bounds().size.height, px(480.));
    assert_eq!(sized("YOU"), (12., 600., ink));
    let quote = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections[0].speaker.quotes[0].clone());
    let (size_, _, color) = sized(&format!("\u{201C}{quote}\u{201D}"));
    assert_eq!((size_, color), (14., ink.opacity(0.85)));
    let field = find(cx, &window, "meeting.speakers.field.1").bounds();
    assert_eq!(field.size.height, px(46.));
    assert_eq!(field.size.width, px(560. - 64.), "padding h32");
    assert_eq!(field.origin.x - sheet.origin.x, px(32.));
    let (cancel, save) = (find(cx, &window, "meeting.speakers.cancel").bounds(), find(cx, &window, "meeting.speakers.save").bounds());
    assert_eq!((cancel.size.height, save.size.height), (px(38.), px(38.)));
    assert_eq!(save.origin.x - (cancel.origin.x + cancel.size.width), px(10.));
    assert_eq!(sheet.origin.x + sheet.size.width - (save.origin.x + save.size.width), px(28.));
    assert_eq!(sheet.origin.y + sheet.size.height - (save.origin.y + save.size.height), px(18.));
    assert_eq!(sized("Save names"), (14., 500., surface));
    assert_eq!(sized("Cancel"), (14., 500., ink));
    window.update(cx, |p, _, cx| { let m = &mut p.assign.as_mut().unwrap().model; m.sections.clear(); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_eq!(find(cx, &window, "meeting.speakers.scroll").bounds().size.height, px(160.), "minimum height");
    assert_eq!(sized("There are no speakers to name."), (14., 400., muted));
}

// parity: SPK-052 SPK-053 SPK-102
#[flow_ui::gpui::test]
async fn sheet_notices_are_red_twelve_point(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let (_, _, red, ..) = colors(cx);
    let id = unnamed(cx, &window);
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), "Jana Horvat");
    refuse(cx, "UPDATE", "meeting_speakers");
    click(cx, &window, "meeting.speakers.save");
    fresh(cx, &window);
    assert_eq!(sized("Names could not be saved."), (12., 400., red));
    allow(cx, "UPDATE", "meeting_speakers");
    window.update(cx, |p, _, cx| { p.assign = None; cx.notify() }).unwrap();
    sql(cx, "ALTER TABLE meeting_speakers RENAME TO speakers_gone;");
    window.update(cx, |p, w, cx| p.open_assign(None, w, cx)).unwrap();
    fresh(cx, &window);
    assert_eq!(sized("Speakers could not be loaded."), (12., 400., red));
    assert_eq!(sized("There are no speakers to name.").0, 14.);
}

// parity: SPK-054
#[flow_ui::gpui::test]
async fn review_row_type_symbol_and_label(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    let run: String = query(cx, |db| db.conn.query_row("SELECT accepted_run_id FROM meeting_diarization WHERE meeting_id=?1", [SEED_FULL], |r| r.get(0)).unwrap());
    sql(cx, &format!("INSERT INTO speaker_corrections (id, meeting_id, run_id, kind, new_value, needs_review, created_at) VALUES ('review-3','{SEED_FULL}','{run}','rename','Marta',1,1);"));
    open(cx, &window, SEED_FULL, Tab::Transcript);
    window.update(cx, |p, w, cx| p.open_assign(None, w, cx)).unwrap();
    fresh(cx, &window);
    let (_, muted, _, orange, _) = colors(cx);
    assert_eq!(flow_ui::probe::symbol_color("exclamationmark.triangle"), Some(orange));
    assert_eq!(sized("Dismiss"), (12., 500., muted));
    let label = find(cx, &window, "meeting.speakers.review.dismiss").label().unwrap().to_string();
    assert!(label.starts_with("Dismiss notice: "), "{label}");
    let text = read(cx, &window, |p| p.assign.as_ref().unwrap().model.reviews[0].1.clone());
    assert_eq!(sized(&text).0, 13.);
}

// parity: SPK-059 SPK-060 SPK-070 SPK-071 SPK-094
#[flow_ui::gpui::test]
async fn merge_and_undo_apply_at_once_and_relabel_the_transcript(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let (_, muted, ..) = colors(cx);
    let (source, target) = read(cx, &window, |p| {
        let m = &p.assign.as_ref().unwrap().model;
        let target = m.sections.iter().position(|s| !s.speaker.is_you() && s.speaker.name.is_some()).unwrap();
        let source = m.sections.iter().position(|s| !s.speaker.is_you() && s.speaker.name.is_none()).unwrap();
        (source, target)
    });
    assert!(target < source, "the earlier section is the one offered");
    let (id, into) = (section_id(cx, &window, source), section_id(cx, &window, target));
    let (anon_source, anon_target, name) = read(cx, &window, |p| {
        let m = &p.assign.as_ref().unwrap().model;
        (m.sections[source].speaker.anonymous(), m.sections[target].speaker.anonymous(), m.sections[target].speaker.name.clone().unwrap())
    });
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), &name);
    fresh(cx, &window);
    assert_labelled(cx, &window, sid(format!("meeting.speakers.merge.{source}")), &format!("Merge into {anon_target}"));
    sheet_click(cx, &window, &format!("meeting.speakers.merge.{source}"));
    fresh(cx, &window);
    let merged_into = |cx: &mut TestAppContext| read(cx, &window, |p| p.pager.as_ref().unwrap().speakers.as_ref().unwrap().1.iter().find(|x| x.id == id).unwrap().merged_into.clone());
    assert_eq!(merged_into(cx), Some(into.clone()), "the pager relabels while the sheet is open");
    assert_eq!(sized(&format!("Includes {anon_source}")), (13., 400., muted));
    assert_eq!(sized("Undo merge").0, 13.);
    assert_eq!(sized("Undo merge").1, 500.);
    let member = sid(format!("meeting.speakers.unmerge.{id}"));
    assert_labelled(cx, &window, member.clone(), &format!("Undo merge of {anon_source}"));
    sheet_click(cx, &window, &member);
    fresh(cx, &window);
    assert_eq!(merged_into(cx), None);
    assert!(!seen("Includes "));
    let unmerges: i64 = query(cx, |db| db.conn.query_row("SELECT count(*) FROM speaker_corrections WHERE kind='unmerge' AND speaker_id=?1", [&id], |r| r.get(0)).unwrap());
    assert_eq!(unmerges, 1);
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), &name);
    fresh(cx, &window);
    sheet_click(cx, &window, &format!("meeting.speakers.merge.{source}"));
    frame(cx, &window);
    click(cx, &window, "meeting.speakers.cancel");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.assign.is_none()));
    let kept: Option<String> = query(cx, |db| db.conn.query_row("SELECT merged_into FROM meeting_speakers WHERE id=?1", [&id], |r| r.get(0)).unwrap());
    assert_eq!(kept, Some(into), "Cancel leaves an applied merge alone");
}

// parity: SPK-003 SPK-063
#[flow_ui::gpui::test]
async fn sheet_focuses_the_first_section_or_the_named_one_scrolled_to_the_top(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let (first, last) = (section_id(cx, &window, 0), read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.last().unwrap().speaker.id.clone()));
    assert_eq!(read(cx, &window, |p| p.assign.as_ref().unwrap().focused.clone()), Some(first.clone()));
    assert_eq!(read(cx, &window, |p| p.assign.as_ref().unwrap().scroll.offset().y), px(0.));
    let area = find(cx, &window, "meeting.speakers.scroll").bounds();
    let count = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.len());
    window.update(cx, |p, _, cx| { p.assign = None; cx.notify() }).unwrap();
    frame(cx, &window);
    window.update(cx, |p, w, cx| p.open_assign(Some(last.clone()), w, cx)).unwrap();
    frame(cx, &window);
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.assign.as_ref().unwrap().focused.clone()), Some(last.clone()));
    assert!(read(cx, &window, |p| p.assign.as_ref().unwrap().scroll.offset().y) < px(0.), "scrolled to the voice");
    let field = find(cx, &window, sid(format!("meeting.speakers.field.{count}"))).bounds();
    assert!(field.origin.y >= area.origin.y && field.origin.y < area.origin.y + area.size.height);
    window.update(cx, |p, _, cx| { p.assign = None; cx.notify() }).unwrap();
    frame(cx, &window);
    window.update(cx, |p, w, cx| p.open_assign(Some("gone".into()), w, cx)).unwrap();
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.assign.as_ref().unwrap().focused.clone()), Some(first), "a stale id falls back");
}

// parity: SPK-093
#[flow_ui::gpui::test]
async fn escape_cancels_from_a_name_field(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    cx.update_window(window.into(), |_, w, cx| w.press("escape", cx)).unwrap();
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.assign.is_none()), "escape closes from the name field");
}

// parity: SPK-068 SPK-069 SPK-096
#[flow_ui::gpui::test]
async fn field_errors_are_red_and_disable_save(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let (_, _, red, ..) = colors(cx);
    let id = unnamed(cx, &window);
    assert_ne!(find(cx, &window, "meeting.speakers.save").disabled(), Some(true));
    window.update(cx, |p, _, cx| { p.assign.as_mut().unwrap().model.set_draft(&id, "A\u{7}"); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_eq!(sized("Remove the control character."), (12., 400., red));
    assert_eq!(find(cx, &window, "meeting.speakers.save").disabled(), Some(true));
    window.update(cx, |p, _, cx| { p.assign.as_mut().unwrap().model.set_draft(&id, &"n".repeat(81)); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert_eq!(sized("Use 80 characters or fewer."), (12., 400., red));
    assert_eq!(find(cx, &window, "meeting.speakers.save").disabled(), Some(true));
}

// parity: SPK-074 SPK-075
#[flow_ui::gpui::test]
async fn local_voice_offer_type_and_branches(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let (ink, muted, ..) = colors(cx);
    assert_eq!(sized("Remember my voice"), (12., 500., ink));
    sheet_click(cx, &window, "identity.rememberLocal");
    fresh(cx, &window);
    assert_eq!(sized("Your voice will be remembered from this Mac's microphone."), (12., 400., muted));
    assert!(!seen("Remember my voice"));
    window.update(cx, |p, _, cx| {
        let m = &mut p.assign.as_mut().unwrap().model;
        m.known.push(KnownSpeaker { id: "me".into(), name: "Me".into(), samples: 1, is_local: true });
        cx.notify();
    }).unwrap();
    fresh(cx, &window);
    assert!(!seen("Remember my voice") && !seen("Your voice will be remembered"), "hidden once remembered");
}

// parity: SPK-076 SPK-078 SPK-082 SPK-100
#[flow_ui::gpui::test]
async fn pickers_list_names_samples_and_re_enrollment(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let (_, _, _, orange, _) = colors(cx);
    let accent = cx.update(|cx| pal(cx).accent);
    let id = section_id(cx, &window, 1);
    window.update(cx, |p, _, cx| {
        let m = &mut p.assign.as_mut().unwrap().model;
        m.known.retain(|k| k.is_local);
        for (i, (name, samples)) in [("Ada", 1), ("Ben", 3), ("Cyr", 0)].into_iter().enumerate() {
            m.known.push(KnownSpeaker { id: format!("k{i}"), name: name.into(), samples, is_local: false });
        }
        cx.notify();
    }).unwrap();
    fresh(cx, &window);
    assert_eq!(sized("Known speakers…").0, 14.);
    assert_eq!(sized("Known speakers…").2, accent);
    menu_clear();
    let block = sid(format!("identity.block.{id}"));
    let (area, target) = (find(cx, &window, "meeting.speakers.scroll").bounds(), find(cx, &window, block.clone()).bounds());
    window.update(cx, |p, _, _| p.assign.as_ref().unwrap().scroll.set_offset(point(px(0.), area.origin.y - target.origin.y + px(20.)))).unwrap();
    frame(cx, &window);
    cx.update_window(window.into(), |_, w, cx| w.within(block.clone()).click("identity.picker", cx)).unwrap();
    frame(cx, &window);
    assert_menu_saw(&["Ada \u{2014} 1 voice sample", "Ben \u{2014} 3 voice samples", "Cyr \u{2014} 0 voice samples · needs re-enrollment"]);
    menu_item(cx, &window, 0);
    let draft = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| s.speaker.id == id).unwrap().draft.clone());
    assert_eq!(draft, read(cx, &window, |p| p.assign.as_ref().unwrap().model.known.iter().find(|k| k.id == "k0").unwrap().name.clone()));
    let input = window.read_with(cx, |p, cx| p.assign.as_ref().unwrap().inputs[&id].read(cx).value().to_string()).unwrap();
    assert_eq!(input, "Ada", "the field follows the pick");
    with_identity(cx, &window, &id, "unknown", None, true);
    assert_eq!(sized("Choose an identity"), (12., 500., orange));
    assert_eq!(sized("Choose a known speaker…").2, accent);
    menu_clear();
    sheet_click(cx, &window, "identity.mergedPicker");
    frame(cx, &window);
    assert_menu_saw(&["Ada", "Ben", "Cyr"]);
    menu_item(cx, &window, 1);
    assert_eq!(read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| s.speaker.id == id).unwrap().action.clone()), IdentityAction::ResolveMerged(Some("k1".into())));
}

// parity: SPK-079 SPK-081 SPK-085
#[flow_ui::gpui::test]
async fn identity_buttons_turn_prominent_when_chosen(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let (ink, ..) = colors(cx);
    let surface = cx.update(|cx| pal(cx).surface);
    let id = unnamed(cx, &window);
    let known = query(cx, |db| known_speakers(db).unwrap().into_iter().find(|k| !k.is_local).unwrap());
    with_identity(cx, &window, &id, "possible", Some((&known.id, &known.name)), false);
    assert_eq!(sized("Confirm"), (14., 500., ink));
    assert_eq!(sized("Keep Unknown"), (14., 500., ink));
    sheet_click(cx, &window, "identity.confirm");
    fresh(cx, &window);
    assert_eq!(sized("Confirm"), (14., 500., surface));
    assert_eq!(sized("Also remember this voice sample").0, 12.);
    sheet_click(cx, &window, "identity.alsoRemember");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| s.speaker.id == id).unwrap().also_remember));
    sheet_click(cx, &window, "identity.keepUnknown");
    fresh(cx, &window);
    assert_eq!(sized("Keep Unknown"), (14., 500., surface));
    assert!(!read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| s.speaker.id == id).unwrap().also_remember), "Keep Unknown clears it");
}

// parity: SPK-083 SPK-084
#[flow_ui::gpui::test]
async fn remember_rows_read_like_swift(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let (ink, muted, ..) = colors(cx);
    let id = read(cx, &window, |p| p.assign.as_ref().unwrap().model.sections.iter().find(|s| !s.speaker.is_you()).unwrap().speaker.id.clone());
    let known = query(cx, |db| known_speakers(db).unwrap().into_iter().find(|k| !k.is_local).unwrap());
    let name = known.name.clone();
    type_in!(cx, &window, |p| p.assign.as_ref().unwrap().inputs[&id].clone(), &name);
    fresh(cx, &window);
    assert_eq!(sized("Remember this voice for future meetings?"), (13., 500., ink));
    assert_eq!(sized("LocalFlow will store data that can recognize this voice in future meetings on this Mac. It stays on this Mac and you can delete it in Settings \u{203A} Known speakers."), (12., 400., muted));
    sheet_click(cx, &window, "identity.remember");
    fresh(cx, &window);
    assert_eq!(sized(&format!("Is this {name} you already remember?")), (13., 500., ink));
    let surface = cx.update(|cx| pal(cx).surface);
    assert_eq!(sized("Same person").2, surface);
    assert_eq!(sized("Someone new").2, ink);
}

// parity: SPK-091 SPK-095
#[flow_ui::gpui::test]
async fn a_failed_enrollment_keeps_the_sheet_open_with_done(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.assign"));
    let (_, muted, ..) = colors(cx);
    let you = section_id(cx, &window, 0);
    window.update(cx, |p, _, cx| p.set_identity(&you, IdentityAction::RememberLocal, cx)).unwrap();
    click(cx, &window, "meeting.speakers.save");
    fresh(cx, &window);
    assert_eq!(sized("The voice sample could not be stored on this Mac."), (12., 400., muted));
    assert!(read(cx, &window, |p| p.assign.is_some()));
    assert_labelled(cx, &window, "meeting.speakers.save", "Done");
    assert_eq!(sized("Done").0, 14.);
    click(cx, &window, "meeting.speakers.save");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.assign.is_none()));
}

// parity: SPK-036 SPK-037
#[flow_ui::gpui::test]
async fn transcript_speaker_label_uses_the_palette(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    let (_, muted, ..) = colors(cx);
    let label = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().find_map(|r| r.label.clone().filter(|l| l.color.is_some() && l.suggested.is_none())).unwrap());
    let color = cx.update(|cx| speaker_text(label.color.unwrap(), cx));
    assert_eq!(sized(&label.text), (12., 500., color));
    assert_symbols(&["checkmark.circle"]);
    assert_eq!(flow_ui::probe::symbol_color("checkmark.circle"), Some(muted));
}

// parity: SPK-107
#[flow_ui::gpui::test]
async fn speaker_palette_matches_swift_and_cycles(cx: &mut TestAppContext) {
    let _window = open_page(cx, None);
    let hsla = |v: u32| -> Hsla { flow_ui::gpui::rgb(v).into() };
    let dots = [(0x1F6FD1, 0x5AA2FF), (0xC2570C, 0xFF9A4D), (0x1E8A4C, 0x4CC983), (0x7B4BD1, 0xA98BFF), (0x0E7C86, 0x3CC6CF), (0xC23B3B, 0xFF7373), (0xB8397D, 0xF07AB8), (0x8A6A1F, 0xD4B25A)];
    let text = [0x1D66C0, 0xA84B0A, 0x187441, 0x7B4BD1, 0x0C717A, 0xB23636, 0xA8346F, 0x7E611C];
    for mode in [flow_ui::tokens::Mode::Light, flow_ui::tokens::Mode::Dark] {
        cx.update(|cx| flow_ui::tokens::set_mode(mode, cx));
        let dark = mode == flow_ui::tokens::Mode::Dark;
        for i in 0..8 {
            let (l, d) = dots[i];
            let dot = if dark { d } else { l };
            let label = if dark { d } else { text[i] };
            cx.update(|cx| {
                assert_eq!(speaker_dot(i, cx), hsla(dot), "dot {i}");
                assert_eq!(speaker_text(i, cx), hsla(label), "text {i}");
                assert_eq!(speaker_dot(i + 8, cx), hsla(dot), "cycles");
            });
        }
    }
}

// --- Round 4 row review: Summary.

// parity: SUM-002 SUM-003 SUM-041 SUM-047 SUM-049
#[flow_ui::gpui::test]
async fn summary_header_and_body_have_swifts_type_and_frames(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    resize(cx, &window, 1400., 900.);
    fresh(cx, &window);
    let (ink, muted, ..) = colors(cx);
    let minutes = read(cx, &window, |p| p.summary.model.as_ref().unwrap().reading_minutes);
    assert_eq!(sized(&format!("{minutes} MIN READ")), (12., 500., muted));
    assert_symbols(&["lightbulb"]);
    let bar = find(cx, &window, "meeting.summary.header").bounds();
    let options = find(cx, &window, "meeting.summary.options").bounds();
    assert_eq!(bar.size.height, px(44.));
    assert_eq!(bar.origin.x + bar.size.width - (options.origin.x + options.size.width), px(6.), "trailing 6");
    assert_eq!(sized("Hinges and supplier"), (15., 600., ink));
    assert_eq!(sized("Two hinge samples are too stiff").0, 15.);
    assert_eq!(sized("•").0, 15.);
    assert_eq!(sized("Action items"), (15., 600., ink));
    let paragraph = flow_ui::probe::seen().into_iter().find(|s| s.starts_with("The order waits")).unwrap();
    assert_eq!(sized(&paragraph).0, 15.);
    let body = read(cx, &window, |p| p.summary.model.as_ref().unwrap().summary.clone());
    assert!(body.contains("\n\n") && !seen(&body), "one element per paragraph");
}

// parity: SUM-005 SUM-009 SUM-011 SUM-012 SUM-015 SUM-018
#[flow_ui::gpui::test]
async fn summary_header_states_read_thirteen_point(cx: &mut TestAppContext) {
    let _w = open_page(cx, Some("notetaker.summary-eligible"));
    let (ink, muted, red, ..) = colors(cx);
    assert_eq!(sized("Generate"), (13., 400., ink));
    assert_eq!(sized("No summary yet.").2, muted);
    assert!(seen("SUMMARY"));
    let _w = open_page(cx, Some("notetaker.summary-pending"));
    assert_eq!(sized("Queued"), (13., 400., muted));
    assert_eq!(sized("Cancel"), (13., 400., ink));
    let _w = open_page(cx, Some("notetaker.summary-running"));
    assert_eq!(sized("Analyzing"), (13., 400., muted));
    let _w = open_page(cx, Some("notetaker.summary-failed"));
    assert_eq!(sized("The server's language model is not running."), (13., 400., red));
    assert_eq!(sized("Retry"), (13., 400., ink));
    let accent = cx.update(|cx| pal(cx).accent);
    let _w = open_page(cx, Some("notetaker.summary-not-finished"));
    assert_eq!(sized("Read transcript").2, accent);
    assert_eq!(sized("The transcript is not finished yet.").2, muted);
}

// parity: SUM-032 SUM-033
#[flow_ui::gpui::test]
async fn copy_writes_the_report_and_says_copied_for_two_seconds(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    fresh(cx, &window);
    assert_symbols(&["square.on.square"]);
    assert_labelled(cx, &window, "meeting.summary.copy", "Copy summary");
    click(cx, &window, "meeting.summary.copy");
    fresh(cx, &window);
    assert_symbols(&["checkmark"]);
    assert_labelled(cx, &window, "meeting.summary.copy", "Copied");
    let copied = cx.update(|cx| cx.read_from_clipboard()).and_then(|c| c.text()).unwrap();
    assert!(copied.ends_with("Generated by LocalFlow from the meeting transcript and notes."), "{copied}");
    assert!(copied.contains("- [ ] Ask the workshop to loosen the hinge tolerance"), "{copied}");
    cx.executor().advance_clock(Duration::from_secs(3));
    fresh(cx, &window);
    assert_labelled(cx, &window, "meeting.summary.copy", "Copy summary");
}

// parity: SUM-038 SUM-082
#[flow_ui::gpui::test]
async fn removing_edits_fails_silently_as_swift_does(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    click(cx, &window, "meeting.summary.status.0");
    frame(cx, &window);
    sql(cx, &format!("UPDATE analysis_overlays SET orphaned_at=1, item_id=NULL WHERE meeting_id='{SEED_FULL}';"));
    window.update(cx, |p, _, cx| { p.summary_refresh(cx); p.menu = Some("summary.edits".into()); cx.notify() }).unwrap();
    frame(cx, &window);
    let edit = read(cx, &window, |p| p.summary.model.as_ref().unwrap().previous_edits[0].id.clone());
    let delete = sid(format!("meeting.summary.previous.delete.{edit}"));
    refuse(cx, "DELETE", "analysis_overlays");
    click(cx, &window, delete.clone());
    frame(cx, &window);
    assert_eq!(read(cx, &window, |p| p.summary.error.clone()), None);
    assert_eq!(read(cx, &window, |p| p.summary.model.as_ref().unwrap().previous_edits.len()), 1);
    window.update(cx, |p, _, cx| p.remove_all_edits(cx)).unwrap();
    assert_eq!(read(cx, &window, |p| p.summary.error.clone()), None);
    allow(cx, "DELETE", "analysis_overlays");
    window.update(cx, |p, _, cx| { p.menu = Some("summary.edits".into()); cx.notify() }).unwrap();
    frame(cx, &window);
    click(cx, &window, delete);
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.summary.model.as_ref().unwrap().previous_edits.is_empty()));
}

// parity: SUM-062 SUM-063 SUM-072
#[flow_ui::gpui::test]
async fn status_toggle_labels_symbols_and_snapshot(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let (_, muted, ..) = colors(cx);
    let item = action_item(cx, &window, 0);
    fresh(cx, &window);
    assert_labelled(cx, &window, "meeting.summary.status.0", "Mark completed");
    assert_eq!(flow_ui::probe::symbol_color("circle"), Some(muted));
    click(cx, &window, "meeting.summary.status.0");
    fresh(cx, &window);
    assert_labelled(cx, &window, "meeting.summary.status.0", "Mark open");
    let ai: Option<String> = query(cx, |db| db.conn.query_row("SELECT ai_value_snapshot FROM analysis_overlays WHERE item_id=?1 AND field='status'", [&item.id], |r| r.get(0)).unwrap());
    assert_eq!(ai.as_deref(), Some("open"));
    open_item_menu(cx, &window, &item);
    menu_item(cx, &window, 3);
    assert_eq!(action_item(cx, &window, 0).status, "dismissed");
    fresh(cx, &window);
    assert_labelled(cx, &window, "meeting.summary.status.0", "Mark completed");
    click(cx, &window, "meeting.summary.status.0");
    frame(cx, &window);
    assert_eq!(action_item(cx, &window, 0).status, "open", "a dismissed item reopens");
}

// parity: SUM-064 SUM-057
#[flow_ui::gpui::test]
async fn done_items_strike_and_editing_keeps_the_status_circle(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let (ink, muted, ..) = colors(cx);
    let item = action_item(cx, &window, 0);
    assert_eq!(sized(&item.text).2, ink);
    click(cx, &window, "meeting.summary.status.0");
    fresh(cx, &window);
    assert_eq!(sized(&item.text).2, muted);
    cx.update_window(window.into(), |_, w, cx| w.double_click(sid(format!("meeting.summary.text.{}.{}", item.kind, item.ordinal)), cx)).unwrap();
    frame(cx, &window);
    assert!(has(cx, &window, "meeting.summary.status.0"), "Swift keeps the circle beside the field");
    assert!(has(cx, &window, "meeting.summary.edit.save"));
}

// parity: SUM-039 SUM-040
#[flow_ui::gpui::test]
async fn stale_banner_type_and_frame(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary-stale"));
    let (ink, ..) = colors(cx);
    let warning = cx.update(|cx| pal(cx).warning);
    assert_eq!(sized("The transcript, speakers or notes changed after this summary."), (12., 400., ink));
    assert_eq!(flow_ui::probe::symbol_color("exclamationmark.triangle"), Some(warning));
    let (banner, button) = (find(cx, &window, "meeting.summary.stale").bounds(), find(cx, &window, "meeting.summary.stale.regenerate").bounds());
    assert_eq!(banner.origin.x + banner.size.width - (button.origin.x + button.size.width), px(10.));
    assert_eq!(button.origin.y - banner.origin.y, px(10.));
}

// parity: SUM-073 SUM-074 SUM-075 SUM-076 SUM-077 SUM-078 SUM-079
#[flow_ui::gpui::test]
async fn owner_chips_and_due_labels_read_like_swift(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    resize(cx, &window, 1400., 2000.);
    fresh(cx, &window);
    let (_, muted, ..) = colors(cx);
    assert_eq!(sized("You").0, 11.);
    assert_eq!(sized("mentioned"), (9., 400., muted));
    assert_eq!(sized("Owner unresolved"), (11., 400., muted));
    assert_eq!(sized("Tomas Novak").0, 11.);
    let suggested = flow_ui::probe::seen().into_iter().find(|s| s.starts_with("might be ")).unwrap();
    assert!(suggested.ends_with('?'), "{suggested}");
    assert_eq!(sized(&suggested), (9., 400., muted));
    assert_eq!(sized("Accept").0, 13., "Swift's default Button ignores the chip's 9 pt");
    assert_eq!(sized("Due: unclear (\"soon\")"), (11., 400., muted));
    let due = flow_ui::probe::seen().into_iter().find(|s| s.starts_with("Due ")).unwrap();
    assert_eq!(sized(&due), (11., 400., muted));
    let item = read(cx, &window, |p| p.summary.model.as_ref().unwrap().action_items.iter().find(|i| matches!(&i.owner, Owner::Mentioned(_, Some(_)))).unwrap().clone());
    let Owner::Mentioned(_, Some((known, _))) = item.owner.clone() else { unreachable!() };
    let linked = read(cx, &window, |p| p.summary.roots.iter().find(|r| r.identity.as_ref().and_then(|i| i.known_id.as_deref()) == Some(known.as_str())).map(|r| r.id.clone()));
    click(cx, &window, "meeting.summary.owner.accept");
    frame(cx, &window);
    let (value, ai): (String, Option<String>) = query(cx, |db| db.conn.query_row("SELECT user_value, ai_value_snapshot FROM analysis_overlays WHERE item_id=?1 AND field='owner'", [&item.id], |r| Ok((r.get(0)?, r.get(1)?))).unwrap());
    assert_eq!(value, owner_value_participant(&linked.unwrap_or(known)), "the linked speaker, else the profile");
    assert_eq!(ai.as_deref(), Some(item.ai_owner.text()));
}

// parity: SUM-067 SUM-069 SUM-070
#[flow_ui::gpui::test]
async fn popover_buttons_are_native_and_due_snapshot_is_the_plain_date(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let item = action_item(cx, &window, 0);
    let roots = read(cx, &window, |p| owner_choices(&p.summary.roots).len());
    open_item_menu(cx, &window, &item);
    submenu_item(cx, &window, 1, roots + 1);
    fresh(cx, &window);
    assert_eq!(sized("Owner name"), (11., 600., colors(cx).0));
    let (panel, save) = (find(cx, &window, "notetaker.popover").bounds(), find(cx, &window, "meeting.summary.owner.save").bounds());
    assert_eq!(panel.origin.x + panel.size.width - (save.origin.x + save.size.width), px(13.), "Save sits right: padding 12 inside the 1 pt border");
    window.update(cx, |p, _, cx| { p.menu = None; p.summary.editing = None; cx.notify() }).unwrap();
    frame(cx, &window);
    open_item_menu(cx, &window, &item);
    submenu_item(cx, &window, 2, 0);
    let (clear, save) = (find(cx, &window, "meeting.summary.due.popover.clear").bounds(), find(cx, &window, "meeting.summary.due.save").bounds());
    let due = find(cx, &window, "meeting.summary.due").bounds();
    assert_eq!(clear.origin.x - due.origin.x, px(12.), "padding 12");
    assert_eq!(due.origin.x + due.size.width - (save.origin.x + save.size.width), px(12.));
    window.update(cx, |p, w, cx| p.summary.due.update(cx, |s, cx| s.set_date(calendar_date("2027-03-09"), w, cx))).unwrap();
    frame(cx, &window);
    click(cx, &window, "meeting.summary.due.save");
    frame(cx, &window);
    let (value, ai): (String, Option<String>) = query(cx, |db| db.conn.query_row("SELECT user_value, ai_value_snapshot FROM analysis_overlays WHERE item_id=?1 AND field='due_date'", [&item.id], |r| Ok((r.get(0)?, r.get(1)?))).unwrap());
    assert_eq!(value, due_value(Some("2027-03-09")));
    assert_eq!(ai, item.ai_due_date, "the raw AI date, as Swift stores it");
}

// parity: SUM-081
#[flow_ui::gpui::test]
async fn previous_edits_panel_type_and_frames(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let (_, _, red, ..) = colors(cx);
    click(cx, &window, "meeting.summary.status.0");
    frame(cx, &window);
    sql(cx, &format!("UPDATE analysis_overlays SET orphaned_at=1, item_id=NULL WHERE meeting_id='{SEED_FULL}';"));
    window.update(cx, |p, _, cx| { p.summary_refresh(cx); p.menu = Some("summary.edits".into()); cx.notify() }).unwrap();
    frame(cx, &window);
    fresh(cx, &window);
    assert_eq!(sized("Previous edits").0, 12.);
    assert_eq!(sized("Previous edits").1, 600.);
    assert_eq!(sized("Delete"), (11., 400., red));
    assert_eq!(find(cx, &window, "notetaker.popover").bounds().size.width, px(280.));
}

// parity: SUM-050 SUM-051 SUM-052 SUM-053 SUM-054
#[flow_ui::gpui::test]
async fn section_titles_read_fifteen_semibold(cx: &mut TestAppContext) {
    let _window = open_page(cx, Some("notetaker.summary"));
    let (ink, ..) = colors(cx);
    assert_eq!(sized("Action items"), (15., 600., ink));
    assert_eq!(sized("Next steps"), (15., 600., ink));
    assert_eq!(sized("Decisions"), (15., 600., ink));
    assert_eq!(sized("Open questions"), (15., 600., ink));
    assert_eq!(sized("Risks"), (15., 600., ink));
    assert!(!seen("Risks / blockers"), "the screen says Risks, only the report says blockers");
}

// parity: SUM-058
#[flow_ui::gpui::test]
async fn attribution_follows_the_item_unless_the_sentence_names_it(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    assert!(seen("Pick the review up again on Friday — You"));
    let item = read(cx, &window, |p| p.summary.model.as_ref().unwrap().next_steps[0].clone());
    query(cx, |db| set_overlay(db, SEED_FULL, OverlayTarget::Item(&item.id), "next_step_text", "you pick it up on Friday", Some(&item.ai_text), Some(&item.ai_text), "", 5).unwrap());
    window.update(cx, |p, _, cx| { p.summary_refresh(cx); cx.notify() }).unwrap();
    fresh(cx, &window);
    assert!(seen("you pick it up on Friday"));
    assert!(!seen("you pick it up on Friday — You"), "case-insensitive, as Swift");
}

// parity: SUM-056
#[flow_ui::gpui::test]
async fn questions_and_risks_have_no_edit_path(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    for (kind, item) in [("open_question", read(cx, &window, |p| p.summary.model.as_ref().unwrap().open_questions[0].clone())), ("risk", read(cx, &window, |p| p.summary.model.as_ref().unwrap().risks[0].clone()))] {
        assert_eq!(item.kind, kind);
        assert!(!has(cx, &window, sid(format!("meeting.summary.editMenu.{kind}.{}", item.ordinal))), "no menu without an edit");
        cx.update_window(window.into(), |_, w, cx| w.double_click(sid(format!("meeting.summary.text.{kind}.{}", item.ordinal)), cx)).unwrap();
        frame(cx, &window);
        assert!(read(cx, &window, |p| p.summary.editing.is_none()), "{kind} does not edit");
    }
}

// parity: SUM-048
#[flow_ui::gpui::test]
async fn topic_summary_is_stored_but_not_shown(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let stored: String = query(cx, |db| db.conn.query_row("SELECT summary FROM analysis_topics WHERE summary<>'' LIMIT 1", [], |r| r.get(0)).unwrap());
    fresh(cx, &window);
    assert!(!flow_ui::probe::seen().iter().any(|s| s.contains(&stored)), "{stored}");
}

// parity: SUM-083
#[flow_ui::gpui::test]
async fn mentions_carry_the_speakers_colour_and_id(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let root = read(cx, &window, |p| p.summary.roots.iter().find(|r| r.color != 0).unwrap().clone());
    let speakers = vec![(root.id.clone(), root.label(), root.color)];
    let text = format!("Ask {} first", root.label());
    let found = speaker_mentions(&text, &speakers);
    assert_eq!(found.len(), 1);
    assert_eq!((found[0].2.as_str(), found[0].3), (root.id.as_str(), root.color));
}

// --- Round 5: spot check 4.

// parity: TRANS-073
#[flow_ui::gpui::test]
async fn section_title_shows_the_mini_progress_only_while_a_window_is_in_flight(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.section:interrupted"));
    let progress = "meeting.section.progress";
    window.update(cx, |p, _, cx| { p.status.as_mut().unwrap().window_in_flight = false; cx.notify() }).unwrap();
    frame(cx, &window);
    assert!(!has(cx, &window, progress));
    assert_eq!(sized("Transcript"), (13., 600., colors(cx).0));
    window.update(cx, |p, _, cx| { p.status.as_mut().unwrap().window_in_flight = true; cx.notify() }).unwrap();
    frame(cx, &window);
    let spinner = find(cx, &window, progress).bounds();
    assert_eq!(spinner.size.height, px(12.));
}

// parity: TRANS-058
#[flow_ui::gpui::test]
async fn live_rows_sit_three_points_apart(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.live"));
    window.update(cx, |p, _, cx| {
        p.status.as_mut().unwrap().segments = vec![("one".to_string(), "mic".to_string()), ("two".to_string(), "mic".to_string())];
        cx.notify();
    }).unwrap();
    fresh(cx, &window);
    let (first, second) = (find(cx, &window, "meeting.transcript.live.0").bounds(), find(cx, &window, "meeting.transcript.live.1").bounds());
    assert_eq!(second.top() - first.bottom(), px(3.));
}
// parity: TRANS-058
#[flow_ui::gpui::test]
async fn live_list_keeps_the_two_hundred_newest(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.section:interrupted"));
    window.update(cx, |p, _, cx| {
        let s = p.status.as_mut().unwrap();
        s.segments = (0..250).map(|i| (format!("line {i}"), "mic".to_string())).collect();
        cx.notify();
    }).unwrap();
    fresh(cx, &window);
    assert!(has(cx, &window, "meeting.section.row.199"));
    assert!(!has(cx, &window, "meeting.section.row.200"), "capacity 200");
    assert!(seen("line 249") && seen("line 50"));
    assert!(!seen("line 49"), "the oldest went first");
}

// parity: LIVE-033
#[flow_ui::gpui::test]
async fn notes_editor_grows_from_ninety_to_two_hundred(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    let height = |cx: &mut TestAppContext| find(cx, &window, "meeting.notes.frame").bounds().size.height;
    assert_eq!(height(cx), px(90.));
    window.update(cx, |p, w, cx| p.thoughts.update(cx, |s, cx| s.set_value("a\nb\nc\nd\ne\nf\ng", w, cx))).unwrap();
    frame(cx, &window);
    assert_eq!(height(cx), px(142.));
    window.update(cx, |p, w, cx| p.thoughts.update(cx, |s, cx| s.set_value("x\n".repeat(40), w, cx))).unwrap();
    frame(cx, &window);
    assert_eq!(height(cx), px(200.));
}

// parity: SUM-043
#[flow_ui::gpui::test]
async fn summary_editor_grows_past_ninety(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    resize(cx, &window, 1400., 900.);
    window.update(cx, |p, w, cx| p.begin_summary_edit(w, cx)).unwrap();
    frame(cx, &window);
    let frame_id = "meeting.summary.edit.frame";
    window.update(cx, |p, w, cx| p.summary.summary_input.update(cx, |s, cx| s.set_value("short", w, cx))).unwrap();
    frame(cx, &window);
    frame(cx, &window);
    assert_eq!(find(cx, &window, frame_id).bounds().size.height, px(90.));
    window.update(cx, |p, w, cx| p.summary.summary_input.update(cx, |s, cx| s.set_value("line\n".repeat(12), w, cx))).unwrap();
    frame(cx, &window);
    frame(cx, &window);
    assert!(find(cx, &window, frame_id).bounds().size.height > px(120.));
}

// parity: SUM-078
#[flow_ui::gpui::test]
async fn due_label_carries_the_original_words_only_when_there_are_some(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let item = action_item(cx, &window, 0);
    let id = sid(format!("meeting.summary.due.label.{}", item.ordinal));
    assert_eq!(item.due_original.is_some(), has(cx, &window, id.clone()));
    assert!(flow_ui::probe::seen().iter().any(|s| s.starts_with("Due ")));
    query(cx, |db| db.conn.execute("UPDATE analysis_items SET due_original='by Friday' WHERE id=?1", [&item.id]).unwrap());
    window.update(cx, |p, _, cx| { p.summary_refresh(cx); cx.notify() }).unwrap();
    frame(cx, &window);
    assert!(has(cx, &window, id), "the tooltip's host appears");
}

// parity: SPK-041
#[flow_ui::gpui::test]
async fn correcting_a_segment_relabels_at_once_and_outdates_the_summary(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.transcript"));
    let row = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().next().unwrap().clone());
    let target = read(cx, &window, |p| p.summary.roots.iter().find(|r| Some(r.label()) != row.label.as_ref().map(|l| l.text.clone())).unwrap().clone());
    assert!(!read(cx, &window, |p| p.summary.model.as_ref().is_some_and(|m| m.stale)));
    window.update(cx, |p, _, cx| p.correct(&row.id, Correction::Speaker(target.id.clone()), cx)).unwrap();
    frame(cx, &window);
    let after = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().next().unwrap().clone());
    assert_eq!(after.label.as_ref().map(|l| l.text.clone()), Some(target.label()), "the pager relabels");
    assert!(read(cx, &window, |p| p.summary.model.as_ref().is_some_and(|m| m.stale)), "evidenceDidChange");
}

// parity: SUM-061
#[flow_ui::gpui::test]
async fn clicking_view_source_opens_transcript_and_scrolls_to_the_segment(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    let item = read(cx, &window, |p| p.summary.model.as_ref().unwrap().action_items.iter().find(|i| matches!(i.sources.first(), Some(SourceRef::Segment(_)))).unwrap().clone());
    let SourceRef::Segment(segment) = item.sources[0].clone() else { unreachable!() };
    let scroll_at = read(cx, &window, |p| p.scroll.offset().y);
    resize(cx, &window, 1180., 420.);
    let row_top = find(cx, &window, sid(format!("meeting.summary.item.{}.{}", item.kind, item.ordinal))).bounds().top();
    let view_top = read(cx, &window, |p| p.scroll.bounds()).top();
    window.update(cx, |p, _, cx| { p.scroll.set_offset(point(px(0.), view_top - row_top)); cx.notify() }).unwrap();
    frame(cx, &window);
    hover(cx, &window, sid(format!("meeting.summary.item.{}.{}", item.kind, item.ordinal)));
    frame(cx, &window);
    click(cx, &window, sid(format!("meeting.summary.source.{}.{}", item.kind, item.ordinal)));
    frame(cx, &window);
    frame(cx, &window);
    cx.executor().advance_clock(Duration::from_millis(300));
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.tab == Tab::Transcript));
    let row = read(cx, &window, |p| p.pager.as_ref().unwrap().rows().find(|r| r.id == segment).unwrap().clone());
    assert_eq!(read(cx, &window, |p| p.pager.as_ref().unwrap().highlighted.clone()).as_deref(), Some(segment.as_str()));
    let (view, bubble) = (read(cx, &window, |p| p.scroll.bounds()), find(cx, &window, sid(format!("meeting.transcript.bubble.{}", row.ordinal))).bounds());
    assert!(bubble.top() >= view.top() && bubble.bottom() <= view.bottom() + px(1.), "{bubble:?} in {view:?}, from {scroll_at:?}");
}

// parity: MEET-073
#[flow_ui::gpui::test]
async fn disabled_playback_fades_glyph_and_label_alike(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.failed"));
    fresh(cx, &window);
    let (ink, ..) = colors(cx);
    assert_eq!(find(cx, &window, "meeting.playback").disabled(), Some(true));
    assert_eq!(sized("Playback"), (13., 500., ink), "the fade is the button's, not the label's");
    assert_eq!(flow_ui::probe::symbol_color("play.circle"), Some(ink));
    assert_eq!(find(cx, &window, "meeting.playback").bounds().size.height, px(29.));
}

// parity: LIVE-024 LIVE-025
#[flow_ui::gpui::test]
async fn finalizing_and_starting_show_the_small_progress(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.panel"));
    assert!(!has(cx, &window, "meeting.progress"), "recording has its buttons");
    window.update(cx, |p, _, cx| { p.status.as_mut().unwrap().state = "preparing".into(); cx.notify() }).unwrap();
    frame(cx, &window);
    assert!(has(cx, &window, "meeting.progress"));
    window.update(cx, |p, _, cx| { p.status.as_mut().unwrap().state = "finalizing".into(); cx.notify() }).unwrap();
    frame(cx, &window);
    assert!(has(cx, &window, "meeting.progress"));
}

// parity: SUM-012
#[flow_ui::gpui::test]
async fn running_header_draws_a_seventy_point_bar_when_a_run_reports_progress(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary-running"));
    assert!(!has(cx, &window, "meeting.summary.progress"));
    assert_eq!(sized("Analyzing").0, 13.);
    let window = open_page(cx, Some("notetaker.summary-progress"));
    assert_eq!(find(cx, &window, "meeting.summary.progress").bounds().size.width, px(70.));
    assert!(seen("Writing the summary"), "the progress label replaces the stage");
    assert!(!seen("Analyzing"));
}

// parity: MEET-057
#[flow_ui::gpui::test]
async fn saving_notes_outdates_the_summary(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.summary"));
    assert!(!read(cx, &window, |p| p.summary.model.as_ref().unwrap().stale));
    window.update(cx, |p, w, cx| { let input = p.thoughts.clone(); p.thoughts_changed("New thoughts for the summary", input, w, cx) }).unwrap();
    frame(cx, &window);
    window.update(cx, |p, _, cx| p.flush_notes(cx)).unwrap();
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.summary.model.as_ref().unwrap().stale), "evidenceDidChange after the save");
}
