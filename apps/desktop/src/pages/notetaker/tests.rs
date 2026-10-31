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

// parity: NOTE-001..NOTE-030
#[flow_ui::gpui::test]
async fn library_lists_groups_and_marks_rows(cx: &mut TestAppContext) {
    let window = open_page(cx, None);
    assert_saw(&["Notetaker", "New note", "TODAY", "Past notes", "Lamp prototype review", "From iPhone", "Load older notes"]);
    let rows = read(cx, &window, |p| p.lib.rows.len());
    assert_eq!(rows, PAGE_SIZE as usize);
    cx.update_window(window.into(), |_, w, cx| w.scroll("notetaker.library", ScrollDelta::Pixels(point(px(0.), px(-5000.))), cx)).unwrap();
    frame(cx, &window);
    click(cx, &window, "notetaker.loadOlder");
    frame(cx, &window);
    assert!(read(cx, &window, |p| p.lib.rows.len()) > rows);
}

// parity: NOTE-031..NOTE-050
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

// parity: NOTE-051..NOTE-075
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

// parity: NOTE-076..NOTE-090
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

// parity: NOTE-091..NOTE-107
#[flow_ui::gpui::test]
async fn library_states(cx: &mut TestAppContext) {
    shows(cx, "notetaker.empty", &["No notes yet"]);
}
#[flow_ui::gpui::test]
async fn waiting_row_runs_on_this_mac(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.waiting"));
    assert_saw(&["Waiting for your server", "Run on this Mac"]);
    click(cx, &window, sid(format!("notetaker.runOnThisMac.{SEED_IPHONE}")));
    frame(cx, &window);
    assert!(query(cx, |db| db.conn.query_row("SELECT 1 FROM meetings WHERE id=?1", [SEED_IPHONE], |r| r.get::<_, i64>(0)).unwrap_or(0)) == 1);
}

// parity: LIVE-001..LIVE-045
#[flow_ui::gpui::test]
async fn active_card_states(cx: &mut TestAppContext) {
    shows(cx, "notetaker.interrupted-card", &["Recording stopped", "Dismiss", "Microphone", "System audio"]);
}
#[flow_ui::gpui::test]
async fn failed_card_says_it_could_not_start(cx: &mut TestAppContext) {
    shows(cx, "notetaker.failed-card", &["The meeting could not start", "failed: device lost"]);
}
#[flow_ui::gpui::test]
async fn live_transcript_lists_provisional_rows(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.live"));
    assert_saw(&["Let us start with the hinge samples.", "Stop", "Pause"]);
    click(cx, &window, "meeting.stop");
    frame(cx, &window);
    assert_saw(&["isn't available"]);
}
#[flow_ui::gpui::test]
async fn live_empty_says_listening_or_off(cx: &mut TestAppContext) {
    shows(cx, "notetaker.live-listening", &["Listening…"]);
}
#[flow_ui::gpui::test]
async fn live_off_says_transcription_is_off(cx: &mut TestAppContext) {
    shows(cx, "notetaker.live-off", &["Transcription is off for this note."]);
}

// parity: MEET-001..MEET-040
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

// parity: MEET-041..MEET-060
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

// parity: MEET-061..MEET-083
#[flow_ui::gpui::test]
async fn deleting_the_open_note_returns_to_the_library(cx: &mut TestAppContext) {
    let window = open_page(cx, Some("notetaker.delete"));
    assert_saw(&["This removes the meeting's audio files and notes from this Mac."]);
    click(cx, &window, "notetaker.delete.confirm");
    frame(cx, &window);
    assert!(query(cx, |db| meeting(db, SEED_FULL).unwrap().is_none()));
    assert!(read(cx, &window, |p| p.lib.detail.is_none()));
}
// parity: MEET-089..MEET-093
#[flow_ui::gpui::test]
async fn warnings_show_on_the_untitled_note(cx: &mut TestAppContext) {
    shows(cx, "notetaker.untitled", &["Some audio was lost during recording."]);
}

// parity: TRANS-001..TRANS-040
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

// parity: TRANS-041..TRANS-070
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

// parity: TRANS-071..TRANS-087
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

// parity: SPK-001..SPK-050
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
// parity: SPK-051..SPK-107
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

// parity: SUM-001..SUM-040
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
// parity: SUM-041..SUM-070
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
// parity: SUM-071..SUM-086
#[flow_ui::gpui::test]
async fn summary_states(cx: &mut TestAppContext) {
    shows(cx, "notetaker.summary-stale", &["The transcript, speakers or notes changed after this summary."]);
}
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
