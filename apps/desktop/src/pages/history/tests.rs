use super::*;
use crate::testing::{assert_saw, boot, saw};
use flow_ui::test::{TestAppContext, TestWindowExt};

fn open(cx: &mut TestAppContext) -> WindowHandle<HistoryPage> {
    boot(cx, Mode::Light);
    let w = cx.add_window(|w, cx| HistoryPage::new(w, cx));
    frame(cx, w);
    w
}

fn frame(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>) {
    cx.run_until_parked();
    flow_ui::probe::clear();
    cx.update_window(w.into(), |_, w, cx| w.render_frame(cx)).unwrap();
}

fn click(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>, id: String) {
    let id = SharedString::from(id);
    cx.update_window(w.into(), |_, win, cx| win.click(id, cx)).unwrap();
    frame(cx, w);
}

fn exists(cx: &mut TestAppContext, id: String) -> bool {
    cx.update(|cx| cx.global::<Core>().db.as_ref().map(|db| get(db, &id).unwrap().is_some()).unwrap())
}

// parity: HIST-008 HIST-034
#[flow_ui::gpui::test]
async fn list_groups_rows_by_day_with_labels(cx: &mut TestAppContext) {
    let _w = open(cx);
    assert_saw(&["Transcriptions", "TODAY", "Incomplete"]);
}

// parity: HIST-009 HIST-010 HIST-012 HIST-013 HIST-028
#[flow_ui::gpui::test]
async fn search_filters_after_the_wait_and_reports_no_matches(cx: &mut TestAppContext) {
    let w = open(cx);
    click(cx, w, "history.searchToggle".into());
    cx.update_window(w.into(), |_, win, cx| win.input("zzzqqq", cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(300));
    frame(cx, w);
    assert_saw(&["No matches"]);
}

// parity: HIST-050 HIST-051
#[flow_ui::gpui::test]
async fn copy_writes_the_clipboard_and_shows_a_check(cx: &mut TestAppContext) {
    let w = open(cx);
    let (id, text) = w.update(cx, |t, _, _| (t.model.entries[0].id.clone(), t.model.entries[0].text.clone())).unwrap();
    click(cx, w, format!("history.copy.{id}"));
    assert_eq!(cx.read_from_clipboard().and_then(|c| c.text()), Some(text));
    w.update(cx, |t, _, _| assert!(t.copied.contains(&id))).unwrap();
    cx.executor().advance_clock(Duration::from_millis(1300));
    frame(cx, w);
    w.update(cx, |t, _, _| assert!(!t.copied.contains(&id))).unwrap();
}

// parity: HIST-060 HIST-061 HIST-062 HIST-065
#[flow_ui::gpui::test]
async fn delete_asks_then_removes_the_row(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = cx.update(|cx| {
        let db = cx.global::<Core>().db.as_ref().unwrap();
        let _ = db;
        seed_id(40)
    });
    w.update(cx, |t, _, cx| {
        let e = t.model.entries.iter().find(|e| !e.is_attempting()).unwrap().clone();
        t.ask_delete(&e, cx);
    })
    .unwrap();
    frame(cx, w);
    assert_saw(&["Delete this transcription?", "This can't be undone."]);
    click(cx, w, "history.deleteDialog.cancel".into());
    assert!(!saw("Delete this transcription?"));
    assert!(exists(cx, seed_id(1)) && exists(cx, id));
    let victim = w
        .update(cx, |t, _, cx| {
            let e = t.model.entries.iter().find(|e| !e.is_attempting()).unwrap().clone();
            t.ask_delete(&e, cx);
            e.id
        })
        .unwrap();
    frame(cx, w);
    click(cx, w, "history.deleteDialog.confirm".into());
    assert!(!exists(cx, victim));
}

// parity: HIST-059 HIST-090 HIST-091 HIST-103 HIST-104 HIST-107 HIST-109 HIST-124 HIST-130 HIST-157
#[flow_ui::gpui::test]
async fn details_show_status_stages_and_processing(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    frame(cx, w);
    assert_saw(&["Details", "Completeness: ", "Recognized: ", "Delivery: ", "Stopped: ", "Normalized", "Raw recognition", "Processing details", "App context", "Rewrite", "Attempt 1"]);
    click(cx, w, "history.detail.stage.raw".into());
    assert_saw(&["Exact received windows in order."]);
    click(cx, w, "history.detail.processing".into());
    assert_saw(&["Engine", "Evidence hashes"]);
    click(cx, w, "history.detail.close".into());
    assert!(!saw("Completeness: "));
}

// parity: HIST-147
#[flow_ui::gpui::test]
async fn rewrite_is_disabled_without_a_client(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| {
        t.show_detail(&seed_id(1), cx);
        assert!(!t.model.can_request_rewrite());
    })
    .unwrap();
}

// parity: HIST-102
#[flow_ui::gpui::test]
async fn legacy_row_explains_missing_details(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(5), cx)).unwrap();
    frame(cx, w);
    assert_saw(&[LEGACY_DETAIL, "Saved text"]);
}

// parity: HIST-068 HIST-069 HIST-076 HIST-079 HIST-081 HIST-082 HIST-084
#[flow_ui::gpui::test]
async fn pending_rows_save_failure_and_discard(cx: &mut TestAppContext) {
    let w = open(cx);
    let dir = std::env::temp_dir().join(format!("lf-hist-{}", std::process::id()));
    w.update(cx, |t, _, cx| {
        let db = cx.global::<Core>().db.as_ref().unwrap();
        seed_pending(db, &dir);
        t.model.refresh_pending(db);
        cx.notify();
    })
    .unwrap();
    cx.update(|cx| cx.global_mut::<Core>().paths = flow_core::paths::Paths::new(dir.clone()));
    frame(cx, w);
    assert_saw(&["WAITING FOR SERVER", "Recognize Locally", "Save Audio…", "Discard"]);
    let id = seed_id(9201);
    click(cx, w, format!("history.pending.save.{id}"));
    assert_saw(&[PENDING_ERROR]);
    click(cx, w, format!("history.pending.discard.{id}"));
    assert_saw(&["Discard this recording?", "Its audio is deleted and it will not be recognized."]);
    click(cx, w, "history.discardDialog.cancel".into());
    assert!(!saw("Discard this recording?"));
    let _ = std::fs::remove_dir_all(dir);
}

fn open_scenario(cx: &mut TestAppContext, scenario: &str) -> WindowHandle<HistoryPage> {
    boot(cx, Mode::Light);
    cx.update(|cx| cx.global_mut::<Core>().scenario = Some(scenario.to_string()));
    let w = cx.add_window(|w, cx| HistoryPage::new(w, cx));
    frame(cx, w);
    w
}

// parity: HIST-027 HIST-029 HIST-030 HIST-031
#[flow_ui::gpui::test]
async fn empty_and_error_states(cx: &mut TestAppContext) {
    let _w = open_scenario(cx, "history.empty");
    assert_saw(&["No transcriptions yet"]);
    let _w = open_scenario(cx, "history.error");
    assert_saw(&["History could not be read. Your saved text has not been deleted. Try again.", "Retry"]);
    click(cx, _w, "history.retry".into());
    assert!(!saw("History could not be read."));
    assert_saw(&["TODAY"]);
}

// parity: HIST-014 HIST-011
#[flow_ui::gpui::test]
async fn cmd_f_opens_search_and_escape_closes_it(cx: &mut TestAppContext) {
    let w = open(cx);
    cx.update_window(w.into(), |_, win, cx| win.press("cmd-f", cx)).unwrap();
    frame(cx, w);
    w.update(cx, |t, _, _| assert!(t.searching)).unwrap();
    cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
    frame(cx, w);
    w.update(cx, |t, _, _| assert!(!t.searching)).unwrap();
}
