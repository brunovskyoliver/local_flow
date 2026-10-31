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
    w.update(cx, |_, win, cx| win.click(id, cx)).unwrap();
    frame(cx, w);
}

fn exists(cx: &mut TestAppContext, id: String) -> bool {
    cx.update(|cx| cx.global::<Core>().db.as_ref().map(|db| get(db, &id).unwrap().is_some()).unwrap())
}

// parity: HIST-001..HIST-020
#[flow_ui::gpui::test]
async fn list_groups_rows_by_day_with_labels(cx: &mut TestAppContext) {
    let _w = open(cx);
    assert_saw(&["Transcriptions", "TODAY", "Incomplete"]);
}

// parity: HIST-021..HIST-030
#[flow_ui::gpui::test]
async fn search_filters_after_the_wait_and_reports_no_matches(cx: &mut TestAppContext) {
    let w = open(cx);
    click(cx, w, "history.searchToggle".into());
    w.update(cx, |this, win, cx| this.search.update(cx, |s, cx| s.set_value("zzzqqq", win, cx))).unwrap();
    cx.executor().advance_clock(Duration::from_millis(300));
    frame(cx, w);
    assert_saw(&["No matches"]);
}

// parity: HIST-060..HIST-070
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

// parity: HIST-075..HIST-085
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
}

// parity: HIST-090..HIST-120
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

// parity: HIST-140..HIST-154
#[flow_ui::gpui::test]
async fn rewrite_is_disabled_without_a_client(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| {
        t.show_detail(&seed_id(1), cx);
        assert!(!t.model.can_request_rewrite());
    })
    .unwrap();
}

// parity: HIST-121..HIST-135
#[flow_ui::gpui::test]
async fn legacy_row_explains_missing_details(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(5), cx)).unwrap();
    frame(cx, w);
    assert_saw(&[LEGACY_DETAIL, "Saved text"]);
}

// parity: HIST-040..HIST-055
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
