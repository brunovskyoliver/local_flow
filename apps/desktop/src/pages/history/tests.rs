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
    frame(cx, w);
    w.update(cx, |t, _, _| assert!(!t.searching)).unwrap();
}

fn session(cx: &mut TestAppContext) {
    cx.update(|cx| {
        let s = Session::new(cx.global::<Core>());
        cx.set_global(s);
    });
}

fn delete_all(cx: &mut TestAppContext) {
    cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute_batch("DELETE FROM transcriptions").unwrap());
}

// parity: HIST-004 HIST-005 HIST-006
#[flow_ui::gpui::test]
async fn leaving_clears_detail_and_coming_back_reloads(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    session(cx);
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::History));
    let w = cx.add_window(|w, cx| HistoryPage::new(w, cx));
    frame(cx, w);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Insights));
    w.update(cx, |t, _, _| assert!(t.model.detail_id.is_none())).unwrap();
    delete_all(cx);
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::History));
    frame(cx, w);
    w.update(cx, |t, _, _| assert!(t.model.entries.is_empty())).unwrap();
    assert_saw(&["No transcriptions yet"]);
}

// parity: HIST-015
#[flow_ui::gpui::test]
async fn blur_with_empty_text_closes_search(cx: &mut TestAppContext) {
    let w = open(cx);
    click(cx, w, "history.searchToggle".into());
    assert!(w.update(cx, |t, _, _| t.searching).unwrap());
    w.update(cx, |_, win, _| win.activate_window()).unwrap();
    frame(cx, w);
    w.update(cx, |t, win, cx| t.focus.focus(win, cx)).unwrap();
    frame(cx, w);
    frame(cx, w);
    w.update(cx, |t, _, _| assert!(!t.searching)).unwrap();
}

// parity: HIST-023
#[flow_ui::gpui::test]
async fn only_the_latest_search_counts(cx: &mut TestAppContext) {
    let w = open(cx);
    click(cx, w, "history.searchToggle".into());
    cx.update_window(w.into(), |_, win, cx| win.input("zzz", cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(100));
    cx.update_window(w.into(), |_, win, cx| win.press("backspace", cx)).unwrap();
    cx.update_window(w.into(), |_, win, cx| win.press("backspace", cx)).unwrap();
    cx.update_window(w.into(), |_, win, cx| win.press("backspace", cx)).unwrap();
    cx.update_window(w.into(), |_, win, cx| win.input("kickoff", cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(300));
    frame(cx, w);
    w.update(cx, |t, _, _| {
        assert_eq!(t.model.search_text, "kickoff");
        assert!(!t.model.entries.is_empty() && t.model.entries.iter().all(|e| e.text.to_lowercase().contains("kickoff")));
    })
    .unwrap();
}

// parity: HIST-002 HIST-025 HIST-026
#[flow_ui::gpui::test]
async fn sentinels_pin_and_first_load(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| {
        t.model.has_older = true;
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    let height = cx.update_window(w.into(), |_, win, _| win.find("history.sentinel.older").bounds().size.height).unwrap();
    assert_eq!(height, px(44.));
    // A pinned row that moved 100 down shifts the scroll by the same amount.
    let id = w.update(cx, |t, _, _| t.model.entries[0].id.clone()).unwrap();
    let was = w.update(cx, |t, _, _| t.tops.borrow()[&id]).unwrap();
    w.update(cx, |t, _, cx| {
        *t.pin.borrow_mut() = Some((id.clone(), was - px(100.)));
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    w.update(cx, |t, _, _| {
        assert_eq!(t.scroll.offset().y, px(-100.));
        assert!(t.pin.borrow().is_none());
    })
    .unwrap();
    // First load: no spinner line, no empty text.
    w.update(cx, |t, _, cx| {
        t.model.entries.clear();
        t.model.has_older = false;
        t.model.is_loading = true;
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert!(!saw("No transcriptions yet"));
}

// parity: HIST-032
#[flow_ui::gpui::test]
async fn failed_delete_reports_and_keeps_the_row(cx: &mut TestAppContext) {
    let w = open(cx);
    let e = w.update(cx, |t, _, _| t.model.entries.iter().find(|e| !e.is_attempting()).unwrap().clone()).unwrap();
    w.update(cx, |t, _, cx| t.ask_delete(&e, cx)).unwrap();
    frame(cx, w);
    cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute_batch("PRAGMA query_only=ON").unwrap());
    click(cx, w, "history.deleteDialog.confirm".into());
    assert_saw(&[ACTION_ERROR]);
    cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute_batch("PRAGMA query_only=OFF").unwrap());
    assert!(exists(cx, e.id));
}

// parity: HIST-038
#[flow_ui::gpui::test]
async fn only_rows_arriving_later_fade(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = w.update(cx, |t, _, _| t.model.entries[0].id.clone()).unwrap();
    w.update(cx, |t, _, _| {
        assert!(t.fades("arrived-now"));
        // Rows of the first list never fade, however soon the next frame comes.
        assert!(!t.fades(&id));
    })
    .unwrap();
    frame(cx, w);
}

// parity: HIST-047 HIST-097
#[flow_ui::gpui::test]
async fn row_text_selects_by_drag_and_copies(cx: &mut TestAppContext) {
    let w = open(cx);
    cx.write_to_clipboard(ClipboardItem::new_string("before".into()));
    let (id, text) = w.update(cx, |t, _, _| (t.model.entries[0].id.clone(), t.model.entries[0].text.clone())).unwrap();
    let b = cx.update_window(w.into(), |_, win, _| win.find(SharedString::from(format!("history.text.{id}"))).bounds()).unwrap();
    let y = b.top() + px(8.);
    cx.update_window(w.into(), |_, win, cx| win.drag(point(b.left(), y), point(b.left() + px(60.), y), cx)).unwrap();
    frame(cx, w);
    cx.update_window(w.into(), |_, win, cx| win.press("cmd-c", cx)).unwrap();
    let copied = cx.read_from_clipboard().and_then(|c| c.text()).unwrap();
    assert!(copied != "before" && !copied.is_empty() && text.starts_with(&copied), "{copied}");
}

// parity: HIST-048
#[flow_ui::gpui::test]
async fn tab_reaches_the_row_actions_and_keeps_them_visible(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = w.update(cx, |t, _, _| t.model.entries[0].id.clone()).unwrap();
    w.update(cx, |t, win, cx| t.focus.focus(win, cx)).unwrap();
    let copy = SharedString::from(format!("history.copy.{id}"));
    for _ in 0..4 {
        cx.update_window(w.into(), |_, win, cx| win.press("tab", cx)).unwrap();
        if cx.update_window(w.into(), |_, win, _| win.find(copy.clone()).focused()).unwrap() == Some(true) {
            break;
        }
    }
    assert_eq!(cx.update_window(w.into(), |_, win, _| win.find(copy.clone()).focused()).unwrap(), Some(true));
    // `in_focus` shows the actions on exactly this condition.
    let within = w.update(cx, |t, win, cx| t.action_focus.borrow()[&id].contains_focused(win, cx)).unwrap();
    assert!(within);
    // Shift-Tab goes back.
    cx.update_window(w.into(), |_, win, cx| win.press("shift-tab", cx)).unwrap();
    assert_ne!(cx.update_window(w.into(), |_, win, _| win.find(copy).focused()).unwrap(), Some(true));
}

// parity: HIST-049 HIST-052 HIST-053
#[flow_ui::gpui::test]
async fn row_icon_buttons_are_28_and_insert_follows_delivery(cx: &mut TestAppContext) {
    let w = open(cx);
    let entries = w.update(cx, |t, _, _| t.model.entries.clone()).unwrap();
    let id = &entries[0].id;
    let copy = cx.update_window(w.into(), |_, win, _| win.find(SharedString::from(format!("history.copy.{id}")))).unwrap();
    assert_eq!(copy.bounds().size, size(px(28.), px(28.)));
    let confirmed = entries.iter().find(|e| e.is_confirmed()).unwrap();
    let insert = cx.update_window(w.into(), |_, win, _| win.find(SharedString::from(format!("history.insert.{}", confirmed.id)))).unwrap();
    assert_eq!(insert.label().map(|l| l.to_string()).as_deref(), Some("Insert again"));
    // Attempting rows and a busy coordinator disable it.
    w.update(cx, |t, _, cx| {
        t.model.entries[0].delivery_state = "attempting".into();
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    let off = cx.update_window(w.into(), |_, win, _| win.find(SharedString::from(format!("history.insert.{id}"))).disabled()).unwrap();
    assert_eq!(off, Some(true));
}

// parity: HIST-056 HIST-057
#[flow_ui::gpui::test]
async fn the_row_menu_runs_the_row_actions(cx: &mut TestAppContext) {
    let w = open(cx);
    let e = w.update(cx, |t, _, _| t.model.entries[0].clone()).unwrap();
    let target = SharedString::from(format!("history.text.{}", e.id));
    let menu = |cx: &mut TestAppContext, item: u64| {
        cx.update_window(w.into(), |_, win, cx| win.right_click(target.clone(), cx)).unwrap();
        frame(cx, w);
        cx.update_window(w.into(), |_, win, cx| win.click(ElementId::Integer(item), cx)).unwrap();
        frame(cx, w);
    };
    menu(cx, 0);
    assert_eq!(cx.read_from_clipboard().and_then(|c| c.text()), Some(e.text.clone()));
    // Copy from the menu shows no check; Swift's check is only on the row button.
    w.update(cx, |t, _, _| assert!(t.copied.is_empty())).unwrap();
    menu(cx, 2);
    w.update(cx, |t, _, _| assert_eq!(t.model.detail_id.as_deref(), Some(e.id.as_str()))).unwrap();
}

// parity: HIST-055 HIST-059
#[flow_ui::gpui::test]
async fn more_button_and_menu_state_follow_the_row(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = w.update(cx, |t, _, _| t.model.entries[0].id.clone()).unwrap();
    let more = SharedString::from(format!("history.more.{id}"));
    let b = cx.update_window(w.into(), |_, win, _| win.find(more).bounds().size).unwrap();
    assert_eq!(b, size(px(28.), px(28.)));
    let mut e = w.update(cx, |t, _, _| t.model.entries.iter().find(|e| e.is_confirmed()).unwrap().clone()).unwrap();
    assert_eq!(row_menu_state(&e, false, false), ("Insert again…", false, false));
    assert_eq!(row_menu_state(&e, true, true), ("Insert again…", true, true));
    e.delivery_state = "attempting".into();
    assert_eq!(row_menu_state(&e, false, false), ("Insert…", false, true));
}

// parity: HIST-092 HIST-093 HIST-094 HIST-095
#[flow_ui::gpui::test]
async fn detail_loading_error_retry_and_missing(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = seed_id(1);
    w.update(cx, |t, _, cx| {
        t.model.detail_id = Some(id.clone());
        t.model.detail_error = Some(DETAIL_ERROR.into());
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_saw(&[DETAIL_ERROR, "Retry"]);
    click(cx, w, "history.detail.retry".into());
    w.update(cx, |t, _, _| assert!(t.model.detail_error.is_none() && t.model.envelope.is_some())).unwrap();
    // Removed underneath: the sheet closes and the row goes.
    cx.update(|cx| {
        let db = cx.global::<Core>().db.as_ref().unwrap();
        db.conn.execute("DELETE FROM transcriptions WHERE id=?", [&id]).unwrap();
    });
    click_retry(cx, w);
    w.update(cx, |t, _, _| {
        assert!(t.model.detail_id.is_none());
        assert!(t.model.entries.iter().all(|e| e.id != id));
    })
    .unwrap();
    // Loading: the sheet is up with no body text.
    w.update(cx, |t, _, cx| {
        t.model.detail_id = Some(seed_id(2));
        t.model.detail_loading = true;
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_saw(&["Details"]);
    assert!(!saw("Completeness: "));
}

fn click_retry(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>) {
    w.update(cx, |t, _, cx| {
        let db = cx.global::<Core>().db.as_ref().unwrap();
        t.model.retry_detail(db);
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
}

// parity: HIST-105 HIST-106 HIST-108 HIST-110 HIST-119
#[flow_ui::gpui::test]
async fn stages_and_processing_lines(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    frame(cx, w);
    click(cx, w, "history.detail.stage.assembled".into());
    let assembled = w.update(cx, |t, _, _| t.model.envelope.as_ref().unwrap().detail.as_ref().unwrap()["assembledText"].as_str().unwrap().to_string()).unwrap();
    assert_saw(&[&assembled]);
    // An empty stage and no windows.
    w.update(cx, |t, _, cx| {
        let d = t.model.envelope.as_mut().unwrap().detail.as_mut().unwrap();
        d["assembledText"] = "".into();
        d["rawWindows"] = Vec::<String>::new().into();
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_saw(&["(Empty stage)"]);
    click(cx, w, "history.detail.stage.raw".into());
    assert_saw(&["No raw windows were retained."]);
    click(cx, w, "history.detail.processing".into());
    assert_saw(&["Engine", "seed-engine", "Uncommitted build changes"]);
}

// parity: HIST-133 HIST-136 HIST-137 HIST-156 HIST-159 HIST-160
#[flow_ui::gpui::test]
async fn rewrite_notices_and_attempt_texts(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    cx.simulate_window_resize(w.into(), size(px(1180.), px(3000.)));
    frame(cx, w);
    let n = rewrite_notice("missing_credential");
    assert_eq!(n, "Rewriting skipped: no credential for this server.");
    w.update(cx, |t, _, cx| {
        t.model.rewrite_notice = Some(n.into());
        t.model.attempts[0].failure_category = Some("context_copied".into());
        t.open.insert("history.detail.rewrite.attempt.1".into());
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_saw(&[n, "Rewrite used on-screen text you did not say.", "Input snapshot"]);
    assert_eq!(rewrite_notice("attempt_limit"), "This dictation already has ten rewrite attempts.");
    w.update(cx, |t, _, cx| {
        t.model.attempts.clear();
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_saw(&["No rewrite attempts.", "Rewrite"]);
}

// parity: HIST-139 HIST-140 HIST-142 HIST-144 HIST-145 HIST-146 HIST-154 HIST-161
#[flow_ui::gpui::test]
async fn rewrite_columns_buttons_and_mode(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    frame(cx, w);
    assert_saw(&["Saved text", "The faithful transcript.", "Current rewrite (Polished)", "AI-generated rewrite, not the transcript.", "Retry", "Mode"]);
    let text = w.update(cx, |t, _, _| t.model.envelope.as_ref().unwrap().entry.text.clone()).unwrap();
    let h = cx.update_window(w.into(), |_, win, _| win.find("history.detail.copy.saved").bounds().size.height).unwrap();
    assert_eq!(h, px(24.));
    cx.update_window(w.into(), |_, win, cx| win.scroll("history.detail.scroll", ScrollDelta::Pixels(point(px(0.), px(-500.))), cx)).unwrap();
    frame(cx, w);
    click(cx, w, "history.detail.copy.saved".into());
    assert_eq!(cx.read_from_clipboard().and_then(|c| c.text()), Some(text));
    w.update(cx, |t, _, cx| {
        assert_eq!(t.model.rewrite_mode, RewriteMode::Clean);
        t.model.rewrite_mode = RewriteMode::Concise;
        t.open.insert("history.detail.rewrite.attempt.2".into());
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    cx.update_window(w.into(), |_, win, cx| win.scroll("history.detail.scroll", ScrollDelta::Pixels(point(px(0.), px(-2000.))), cx)).unwrap();
    frame(cx, w);
    let out = w.update(cx, |t, _, _| t.model.attempts.iter().find(|a| a.ordinal == 2).unwrap().output_text.clone().unwrap()).unwrap();
    click(cx, w, "history.detail.attempt.copy.2".into());
    assert_eq!(cx.read_from_clipboard().and_then(|c| c.text()), Some(out));
    // The mode survives another detail, and the popup is its native 99 by 24 in a 180 frame.
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(2), cx)).unwrap();
    w.update(cx, |t, _, _| assert_eq!(t.model.rewrite_mode, RewriteMode::Concise)).unwrap();
    frame(cx, w);
    assert_saw(&["Concise", "Rewrite"]);
    let popup = cx.update_window(w.into(), |_, win, _| win.find("history.detail.rewrite.mode").bounds().size).unwrap();
    assert_eq!(popup, size(px(99.), px(24.)));
}

// parity: HIST-097 HIST-103 HIST-104
#[flow_ui::gpui::test]
async fn segments_are_121_by_24(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    frame(cx, w);
    for id in ["history.detail.stage.normalized", "history.detail.stage.assembled", "history.detail.stage.raw"] {
        let s = cx.update_window(w.into(), |_, win, _| win.find(id).bounds().size).unwrap();
        assert_eq!(s, size(px(121.), px(24.)), "{id}");
    }
}

// parity: HIST-163 HIST-165
#[flow_ui::gpui::test]
async fn insert_opens_the_review_through_the_session(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    session(cx);
    let w = cx.add_window(|w, cx| HistoryPage::new(w, cx));
    frame(cx, w);
    let e = w.update(cx, |t, _, _| t.model.entries.iter().find(|e| !e.is_attempting()).unwrap().clone()).unwrap();
    click(cx, w, format!("history.insert.{}", e.id));
    let id = cx.update(|cx| cx.global::<Session>().insertion.entry.as_ref().map(|r| r.id.clone()));
    assert_eq!(id, Some(e.id));
}
