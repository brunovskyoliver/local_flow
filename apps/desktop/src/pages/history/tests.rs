use super::*;
use crate::testing::{assert_saw, boot, saw};
use flow_ui::test::{TestAppContext, TestQueryExt, TestWindowExt};

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

/// What the Mac build has today: the save panel keeps `Services`' default, `Unavailable`.
struct NoSavePanel;
impl flow_platform::Services for NoSavePanel {
    fn name(&self) -> &'static str {
        "test"
    }
    fn device_word(&self) -> &'static str {
        "Desktop"
    }
    fn app_data_dir(&self) -> std::path::PathBuf {
        std::env::temp_dir()
    }
    fn permission(&self, _: flow_platform::Permission) -> flow_platform::PermissionState {
        flow_platform::PermissionState::Granted
    }
    fn open_permission_settings(&self, _: flow_platform::Permission) -> Result<(), flow_platform::Unavailable> {
        Ok(())
    }
    fn high_contrast(&self) -> bool {
        false
    }
    fn reduce_motion(&self) -> bool {
        false
    }
    fn launch_at_login(&self) -> Result<bool, flow_platform::Unavailable> {
        Ok(false)
    }
    fn set_launch_at_login(&self, _: bool) -> Result<(), flow_platform::Unavailable> {
        Ok(())
    }
    fn free_disk_bytes(&self) -> Option<u64> {
        None
    }
    fn secret(&self, _: &str) -> Result<Option<String>, flow_platform::Unavailable> {
        Ok(None)
    }
    fn set_secret(&self, _: &str, _: &str) -> Result<(), flow_platform::Unavailable> {
        Ok(())
    }
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
    // Typed with no click, so the field opened focused.
    w.update(cx, |t, _, cx| {
        assert_eq!(t.search.read(cx).value().as_ref(), "zzzqqq")
    })
    .unwrap();
    w.update(cx, |t, _, cx| {
        t.searching = false;
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    let toggle = cx
        .update_window(w.into(), |_, win, _| {
            win.try_find("history.searchToggle").is_some()
        })
        .unwrap();
    assert!(!toggle, "text in the model keeps the field up");
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
    cx.update(|cx| {
        let core = cx.global_mut::<Core>();
        core.paths = flow_core::paths::Paths::new(dir.clone());
        core.services = Box::new(NoSavePanel);
    });
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

// parity: HIST-027 HIST-030 HIST-031
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
/// Typing again before the wait ends: the first timer fires and is discarded by the generation
/// check, so the list only changes when the latest wait ends.
#[flow_ui::gpui::test]
async fn only_the_latest_search_counts(cx: &mut TestAppContext) {
    let w = open(cx);
    let all = w.update(cx, |t, _, _| t.model.entries.len()).unwrap();
    click(cx, w, "history.searchToggle".into());
    cx.update_window(w.into(), |_, win, cx| win.input("zzz", cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(100));
    cx.update_window(w.into(), |_, win, cx| win.press("backspace", cx)).unwrap();
    cx.update_window(w.into(), |_, win, cx| win.press("backspace", cx)).unwrap();
    cx.update_window(w.into(), |_, win, cx| win.press("backspace", cx)).unwrap();
    cx.update_window(w.into(), |_, win, cx| win.input("kickoff", cx)).unwrap();
    // 300 in all: the first wait has ended, the latest hasn't.
    cx.executor().advance_clock(Duration::from_millis(200));
    frame(cx, w);
    w.update(cx, |t, _, _| {
        assert_eq!(t.model.search_text, "kickoff");
        assert_eq!(t.model.entries.len(), all, "the older request did not run");
    })
    .unwrap();
    cx.executor().advance_clock(Duration::from_millis(100));
    frame(cx, w);
    w.update(cx, |t, _, _| {
        assert!(t.model.entries.len() < all);
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

// parity: HIST-047
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
    assert!(
        copied != "before" && !copied.is_empty() && text.starts_with(&copied),
        "{copied}"
    );
    assert_saw(&[&text]);
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
    assert_eq!(copy.label().map(|l| l.to_string()).as_deref(), Some("Copy"));
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

// parity: HIST-103 HIST-104
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

// parity: HIST-165
/// Each thing the guard names, through the page's own Insert, then busy until the review ends.
#[flow_ui::gpui::test]
async fn insert_opens_the_review_only_when_nothing_blocks_it(cx: &mut TestAppContext) {
    use crate::shell::update_session;
    boot(cx, Mode::Light);
    session(cx);
    let w = cx.add_window(|w, cx| HistoryPage::new(w, cx));
    frame(cx, w);
    let e = w.update(cx, |t, _, _| t.model.entries.iter().find(|e| !e.is_attempting()).unwrap().clone()).unwrap();
    let opened = |cx: &mut TestAppContext| cx.update(|cx| cx.global::<Session>().insertion.entry.as_ref().map(|r| r.id.clone()));
    for block in [
        (|s: &mut Session| s.dictation.as_mut().unwrap().busy = true) as fn(&mut Session),
        |s| s.dictation.as_mut().unwrap().unsaved = Some("x".into()),
        |s| s.dictation.as_mut().unwrap().storage_blocked = true,
        |s| s.dictation.as_mut().unwrap().cleanup_blocked = true,
        |s| s.installing = true,
    ] {
        cx.update(|cx| update_session(cx, block));
        w.update(cx, |t, _, cx| t.insert(&e, e.text.clone(), cx)).unwrap();
        assert_eq!(opened(cx), None);
        cx.update(|cx| {
            update_session(cx, |s| {
                s.installing = false;
                s.dictation = Some(Default::default());
            })
        });
    }
    frame(cx, w);
    click(cx, w, format!("history.insert.{}", e.id));
    assert_eq!(opened(cx), Some(e.id.clone()));
    let busy = |cx: &mut TestAppContext| cx.update(|cx| cx.global::<Session>().dictation.as_ref().unwrap().busy);
    assert!(busy(cx), "busy from the start of the review");
    // Not idle any more: a second review is refused, the open one stays.
    let other = w.update(cx, |t, _, _| t.model.entries.iter().find(|x| x.id != e.id).unwrap().clone()).unwrap();
    w.update(cx, |t, _, cx| t.insert(&other, other.text.clone(), cx)).unwrap();
    assert_eq!(opened(cx), Some(e.id));
    cx.update(crate::insertion::cancel);
    cx.run_until_parked();
    assert!(!busy(cx), "and until it finishes");
}

fn shell(cx: &mut TestAppContext) -> WindowHandle<crate::shell::Shell> {
    cx.update(|cx| {
        crate::menu::init(cx);
        cx.global_mut::<Core>().prefs.set("setupVersion", 1);
    });
    let window = cx.add_window(|w, cx| crate::shell::Shell::new(w, cx));
    cx.run_until_parked();
    window
}

fn shell_frame(cx: &mut TestAppContext, window: WindowHandle<crate::shell::Shell>) {
    cx.run_until_parked();
    flow_ui::probe::clear();
    cx.update_window(window.into(), |_, w, cx| w.render_frame(cx)).unwrap();
}

fn unavailable(cx: &mut TestAppContext, page: crate::pages::Page) {
    boot(cx, Mode::Light);
    let window = shell(cx);
    cx.update(|cx| {
        crate::shell::update_session(cx, |s| {
            s.stores_ready = false;
            s.dictation = None;
            s.selection = page;
        })
    });
    shell_frame(cx, window);
}

// parity: HIST-003
#[flow_ui::gpui::test]
async fn transcriptions_are_unavailable_until_the_stores_exist(cx: &mut TestAppContext) {
    unavailable(cx, crate::pages::Page::History);
    assert_saw(&["Transcriptions unavailable", crate::shell::SETUP_STARTING]);
    assert!(flow_ui::probe::symbols().iter().any(|s| s == "externaldrive.badge.exclamationmark"));
}

// parity: INS-002
#[flow_ui::gpui::test]
async fn insights_are_unavailable_until_the_stores_exist(cx: &mut TestAppContext) {
    unavailable(cx, crate::pages::Page::Insights);
    assert_saw(&["Insights unavailable", crate::shell::SETUP_STARTING]);
    assert!(flow_ui::probe::symbols().iter().any(|s| s == "externaldrive.badge.exclamationmark"));
}

// parity: DICT-005
#[flow_ui::gpui::test]
async fn the_dictionary_is_unavailable_until_the_stores_exist(cx: &mut TestAppContext) {
    unavailable(cx, crate::pages::Page::Dictionary);
    assert_saw(&["Dictionary unavailable", crate::shell::SETUP_STARTING]);
    assert!(flow_ui::probe::symbols().iter().any(|s| s == "externaldrive.badge.exclamationmark"));
}

// parity: HIST-163 HIST-164 HIST-166 HIST-173
#[flow_ui::gpui::test]
async fn review_warns_and_cancel_or_timeout_keep_the_text(cx: &mut TestAppContext) {
    use crate::insertion::{ReviewEntry, arm_selection, begin_review};
    use crate::shell::{Session, ensure_session, update_session};
    boot(cx, Mode::Light);
    let entry = |quality| ReviewEntry { id: seed_id(20), text: "Saved words".into(), quality, delivery: Delivery::None };
    cx.update(|cx| {
        ensure_session(cx);
        cx.global_mut::<Core>().services = Box::new(flow_platform::Fake::default());
        assert!(begin_review(entry(Quality::Incomplete), cx));
    });
    let window = shell(cx);
    shell_frame(cx, window);
    assert_saw(&["Review before inserting", "Saved words", "This transcription is incomplete. Review the text before inserting."]);
    cx.update(|cx| update_session(cx, |s| s.insertion.entry.as_mut().unwrap().quality = Quality::DurationLimited));
    shell_frame(cx, window);
    assert_saw(&["Recording stopped at 180 seconds. The ending may be missing."]);

    cx.update_window(window.into(), |_, w, cx| w.click("insertion.cancel", cx)).unwrap();
    cx.run_until_parked();
    let status = |cx: &mut TestAppContext| cx.update(|cx| cx.global::<Session>().dictation.as_ref().unwrap().status.clone());
    assert_eq!(status(cx), "Insertion cancelled. The text remains saved.");

    cx.update(|cx| {
        assert!(begin_review(entry(Quality::Complete), cx));
        arm_selection(cx);
    });
    cx.executor().advance_clock(std::time::Duration::from_secs(61));
    cx.run_until_parked();
    assert_eq!(status(cx), "Selection expired. Your text remains saved.");
}

fn first_id(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>, n: usize) -> String {
    w.update(cx, |t, _, _| t.model.entries[n].id.clone()).unwrap()
}

// parity: HIST-040
#[flow_ui::gpui::test]
async fn hovering_a_row_fills_it_and_leaving_clears_it(cx: &mut TestAppContext) {
    let w = open(cx);
    let (a, b) = (first_id(cx, w, 0), first_id(cx, w, 1));
    let canvas = cx.update(|cx| pal(cx).canvas);
    let fill = |cx: &mut TestAppContext, id: &str| {
        let id = id.to_string();
        w.update(cx, move |t, _, cx| t.row_fill(&id, &pal(cx))).unwrap()
    };
    assert_eq!(fill(cx, &a), gpui::transparent_black());
    cx.update_window(w.into(), |_, win, cx| win.hover(SharedString::from(format!("history.text.{a}")), cx)).unwrap();
    frame(cx, w);
    assert_eq!(fill(cx, &a), canvas);
    assert_eq!(fill(cx, &b), gpui::transparent_black());
    cx.update_window(w.into(), |_, win, cx| win.hover(SharedString::from(format!("history.text.{b}")), cx)).unwrap();
    frame(cx, w);
    assert_eq!(fill(cx, &a), gpui::transparent_black());
    assert_eq!(fill(cx, &b), canvas);
}

// parity: HIST-064
#[flow_ui::gpui::test]
async fn deleting_while_full_reports_whether_there_is_room(cx: &mut TestAppContext) {
    let w = open(cx);
    session(cx);
    let status = |cx: &mut TestAppContext| cx.update(|cx| cx.global::<Session>().dictation.as_ref().map(|d| (d.capacity_blocked, d.status.clone())).unwrap());
    let remove_one = |cx: &mut TestAppContext, full: bool| {
        cx.update(|cx| {
            crate::shell::update_session(cx, |s| s.dictation.as_mut().unwrap().capacity_blocked = true);
            let rows = if full { MAX_ROWS + 5 } else { 1 };
            cx.global::<Core>().db.as_ref().unwrap().conn.execute("UPDATE history_usage SET row_count=?", [rows]).unwrap();
        });
        w.update(cx, |t, _, cx| {
            let e = t.model.entries.iter().find(|e| !e.is_attempting()).unwrap().clone();
            t.ask_delete(&e, cx);
        })
        .unwrap();
        frame(cx, w);
        click(cx, w, "history.deleteDialog.confirm".into());
    };
    remove_one(cx, true);
    assert_eq!(status(cx), (true, CAPACITY_STILL_FULL.to_string()));
    remove_one(cx, false);
    assert_eq!(status(cx), (false, CAPACITY_FREED.to_string()));
}

// parity: HIST-178
#[flow_ui::gpui::test]
async fn a_day_that_turns_while_away_keeps_the_old_headings(cx: &mut TestAppContext) {
    let w = open(cx);
    const DAY: i64 = 86_400_000;
    let was = w.update(cx, |t, _, _| t.now).unwrap();
    w.update(cx, |t, _, cx| t.note_clock(was + DAY, false, cx)).unwrap();
    assert_eq!(w.update(cx, |t, _, _| t.now).unwrap(), was, "missed while away");
    w.update(cx, |t, _, cx| t.note_clock(was + DAY, true, cx)).unwrap();
    assert_eq!(w.update(cx, |t, _, _| t.now).unwrap(), was, "the same day, even once shown");
    w.update(cx, |t, _, cx| t.note_clock(was + 2 * DAY, true, cx)).unwrap();
    assert_eq!(w.update(cx, |t, _, _| t.now).unwrap(), was + 2 * DAY);
}

// parity: HIST-183
#[flow_ui::gpui::test]
async fn a_refresh_starts_an_open_detail_over(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    frame(cx, w);
    click(cx, w, "history.detail.stage.raw".into());
    click(cx, w, "history.detail.processing".into());
    w.update(cx, |t, _, cx| {
        assert_eq!(t.stage, detail::Stage::Raw);
        assert!(!t.open.is_empty());
        t.reload(cx);
        assert_eq!(t.stage, detail::Stage::Normalized);
        assert!(t.open.is_empty());
    })
    .unwrap();
}

// parity: HIST-148
#[flow_ui::gpui::test]
async fn the_rewrite_button_sends_the_request_and_shows_the_failure(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = seed_id(40);
    // Nothing listens on this port once the listener is gone, so the real client fails to connect.
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    cx.update(|cx| {
        let core = cx.global_mut::<Core>();
        core.prefs.set("rewriteEnabled", true);
        core.prefs.set("rewriteEndpoint", format!("http://127.0.0.1:{port}"));
        let db = core.db.as_ref().unwrap();
        db.conn.execute("DELETE FROM rewrite_attempts WHERE transcription_id=?", [&id]).unwrap();
        db.conn.execute("UPDATE transcriptions SET quality='complete' WHERE id=?", [&id]).unwrap();
    });
    w.update(cx, |t, _, cx| t.show_detail(&id, cx)).unwrap();
    frame(cx, w);
    click(cx, w, "history.detail.rewrite.retry".into());
    cx.run_until_parked();
    w.update(cx, |t, _, _| {
        assert_eq!(t.model.rewrite_notice.as_deref(), Some("Rewrite server unreachable."));
        assert_eq!(t.model.attempts.iter().map(|a| a.state.as_str()).collect::<Vec<_>>(), ["failed"]);
    })
    .unwrap();
}

// parity: HIST-179
#[flow_ui::gpui::test]
async fn the_rewrite_button_stays_on_and_does_nothing_with_rewriting_off(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = seed_id(40);
    cx.update(|cx| {
        cx.global_mut::<Core>().prefs.set("rewriteEnabled", false);
        let db = cx.global::<Core>().db.as_ref().unwrap();
        db.conn.execute("DELETE FROM rewrite_attempts WHERE transcription_id=?", [&id]).unwrap();
        db.conn.execute("UPDATE transcriptions SET quality='complete' WHERE id=?", [&id]).unwrap();
    });
    w.update(cx, |t, _, cx| t.show_detail(&id, cx)).unwrap();
    frame(cx, w);
    let retry = cx.update_window(w.into(), |_, win, _| win.find("history.detail.rewrite.retry").disabled()).unwrap();
    assert_ne!(retry, Some(true));
    // A real notice first: enabled, with no endpoint, the click is refused.
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("rewriteEnabled", true));
    click(cx, w, "history.detail.rewrite.retry".into());
    w.update(cx, |t, _, _| assert_eq!(t.model.rewrite_notice.as_deref(), Some("Rewriting skipped: the endpoint is invalid."))).unwrap();
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("rewriteEnabled", false));
    // The notice pushed the button below the sheet's fold.
    w.update(cx, |t, _, cx| {
        t.detail_scroll.scroll_to_bottom();
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    click(cx, w, "history.detail.rewrite.retry".into());
    w.update(cx, |t, _, _| {
        assert!(t.model.rewrite_notice.is_none());
        assert!(t.model.attempts.is_empty());
    })
    .unwrap();
}

fn bounds(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>, id: &str) -> Bounds<Pixels> {
    let id = SharedString::from(id.to_string());
    cx.update_window(w.into(), |_, win, _| win.find(id).bounds()).unwrap()
}

// parity: HIST-001
#[flow_ui::gpui::test]
async fn the_page_shell_has_its_padding_at_both_widths(cx: &mut TestAppContext) {
    let w = open(cx);
    let padding = |cx: &mut TestAppContext| {
        let (page, list, title) = (bounds(cx, w, "history.content"), bounds(cx, w, "history.list"), bounds(cx, w, "history.title"));
        (list.left() - page.left(), title.top() - page.top(), page.bottom() - list.bottom())
    };
    assert_eq!(bounds(cx, w, "history.content").size.width, px(960.));
    assert_eq!(padding(cx), (px(48.), px(48.), px(64.)));
    cx.update(|cx| cx.global_mut::<Flow>().compact = true);
    w.update(cx, |_, _, cx| cx.notify()).unwrap();
    frame(cx, w);
    assert_eq!(padding(cx), (px(24.), px(32.), px(64.)));
}

// parity: HIST-029
#[flow_ui::gpui::test]
async fn the_error_row_has_its_top_padding(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| {
        t.model.error = Some(READ_ERROR.into());
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    let (row, retry) = (bounds(cx, w, "history.errorRow"), bounds(cx, w, "history.retry"));
    assert_eq!(retry.origin.y - row.origin.y, px(20.));
}

// parity: HIST-098
#[flow_ui::gpui::test]
async fn the_status_block_is_five_lines_at_its_pitch(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    frame(cx, w);
    // Headless Figtree 13 is a 14 line; on screen `Txt` gives 16 and the pitch matches Swift's.
    assert_eq!(bounds(cx, w, "history.detail.status").size.height, px(5. * 14. + 4. * 3.));
}

// parity: HIST-110 HIST-123
#[flow_ui::gpui::test]
async fn processing_lines_and_hashes_keep_their_spacing(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    frame(cx, w);
    click(cx, w, "history.detail.processing".into());
    let (list, hashes) = (bounds(cx, w, "history.detail.processing.lines"), bounds(cx, w, "history.detail.hashes"));
    assert_eq!(hashes.origin.y - list.bottom(), px(8.));
    let d = w.update(cx, |t, _, _| t.model.envelope.as_ref().unwrap().detail.clone().unwrap()).unwrap();
    let items = processing_lines(&d);
    let (a, b) = items.windows(2).find_map(|w| match (&w[0], &w[1]) {
        (Line::Meta(a, _), Line::Meta(b, _)) => Some((a.clone(), b.clone())),
        _ => None,
    }).unwrap();
    let (first, second) = (bounds(cx, w, &format!("history.meta.{a}")), bounds(cx, w, &format!("history.meta.{b}")));
    assert_eq!(second.origin.y - first.bottom(), px(7.));
    // Two headless Figtree 13 lines, spacing 1: `Txt` rounds a line up, Swift spacing is 2 and 8 over 15.
    assert_eq!(first.size.height, px(14. + 1. + 14.));
}

// parity: HIST-129
#[flow_ui::gpui::test]
async fn context_disclosures_are_8_apart(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    frame(cx, w);
    let (before, snapshot) = (bounds(cx, w, "history.detail.context.before"), bounds(cx, w, "history.detail.context.snapshot"));
    assert_eq!(snapshot.origin.y - before.bottom(), px(8.));
}

// parity: HIST-097
#[flow_ui::gpui::test]
async fn detail_is_spaced_14_and_its_text_selects(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx))
        .unwrap();
    frame(cx, w);
    let (status, stage) = (
        bounds(cx, w, "history.detail.status"),
        bounds(cx, w, "history.detail.stage.normalized"),
    );
    assert_eq!(stage.origin.y - status.bottom(), px(14.));
    let y = status.top() + px(6.);
    cx.update_window(w.into(), |_, win, cx| {
        win.drag(
            point(status.left(), y),
            point(status.left() + px(50.), y),
            cx,
        )
    })
    .unwrap();
    frame(cx, w);
    cx.update_window(w.into(), |_, win, cx| win.press("cmd-c", cx))
        .unwrap();
    let copied = cx.read_from_clipboard().and_then(|c| c.text()).unwrap();
    assert!(
        "Completeness: Complete".starts_with(&copied) && !copied.is_empty(),
        "{copied}"
    );
}

// parity: HIST-163
#[flow_ui::gpui::test]
async fn the_review_sheet_is_520_wide_with_a_300_text_limit(cx: &mut TestAppContext) {
    use crate::insertion::{ReviewEntry, begin_review};
    boot(cx, Mode::Light);
    cx.update(|cx| {
        crate::shell::ensure_session(cx);
        cx.global_mut::<Core>().services = Box::new(flow_platform::Fake::default());
        assert!(begin_review(
            ReviewEntry {
                id: seed_id(20),
                text: "A long saved line of words. ".repeat(200),
                quality: Quality::Incomplete,
                delivery: Delivery::None
            },
            cx
        ));
    });
    let window = shell(cx);
    shell_frame(cx, window);
    let text = cx
        .update_window(window.into(), |_, win, _| {
            win.find("insertion.text").bounds()
        })
        .unwrap();
    assert_eq!(text.size.width, px(520. - 52.));
    assert_eq!(text.size.height, px(300.));
    assert_saw(&["Review before inserting"]);
}

// parity: HIST-191
/// Swift's sentinels share the first and last rows' IDs; the row says not to copy that. Here each has its own.
#[flow_ui::gpui::test]
async fn sentinels_have_their_own_identity_apart_from_the_rows(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| {
        t.model.has_older = true;
        t.model.has_newer = true;
        t.model.is_loading = true;
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    let (first, last) = w.update(cx, |t, _, _| (t.model.entries[0].id.clone(), t.model.entries.last().unwrap().id.clone())).unwrap();
    let row = |id: &str| format!("history.text.{id}");
    let (newer, older) = (bounds(cx, w, "history.sentinel.newer"), bounds(cx, w, "history.sentinel.older"));
    let (top, bottom) = (bounds(cx, w, &row(&first)), bounds(cx, w, &row(&last)));
    assert!(newer.bottom() <= top.top(), "newer is its own element above the first row");
    assert!(older.top() >= bottom.bottom(), "older is its own element below the last row");
}

// parity: HIST-155
/// The real page path: Cancel marks the row at once and the flag stops the request before it connects.
#[flow_ui::gpui::test]
async fn cancel_rewrite_marks_the_row_and_stops_the_request(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = seed_id(40);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let port = listener.local_addr().unwrap().port();
    cx.update(|cx| {
        let core = cx.global_mut::<Core>();
        core.prefs.set("rewriteEnabled", true);
        core.prefs.set("rewriteEndpoint", format!("http://127.0.0.1:{port}"));
        let db = core.db.as_ref().unwrap();
        db.conn.execute("DELETE FROM rewrite_attempts WHERE transcription_id=?", [&id]).unwrap();
        db.conn.execute("UPDATE transcriptions SET quality='complete' WHERE id=?", [&id]).unwrap();
    });
    w.update(cx, |t, _, cx| t.show_detail(&id, cx)).unwrap();
    frame(cx, w);
    cx.update_window(w.into(), |_, win, cx| win.click("history.detail.rewrite.retry", cx)).unwrap();
    // Admitted, its request not yet running.
    w.update(cx, |t, _, cx| {
        assert_eq!(t.model.pending_rewrite().map(|a| a.state.clone()).as_deref(), Some("pending"));
        assert!(!t.model.can_request_rewrite(), "busy while it runs");
        t.cancel_rewrite(cx);
        assert_eq!(t.model.rewrite_notice.as_deref(), Some("Rewrite cancelled."));
    })
    .unwrap();
    cx.run_until_parked();
    w.update(cx, |t, _, _| {
        assert_eq!(t.model.attempts.iter().map(|a| a.state.as_str()).collect::<Vec<_>>(), ["cancelled"]);
        assert_eq!(t.model.rewrite_notice.as_deref(), Some("Rewrite cancelled."), "the stopped request adds no failure");
        assert!(t.model.can_request_rewrite(), "busy ends");
    })
    .unwrap();
    assert!(listener.accept().is_err(), "nothing reached the server");
}

// parity: HIST-056
#[flow_ui::gpui::test]
async fn the_row_menu_lists_its_items_with_their_symbols(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = w.update(cx, |t, _, _| t.model.entries[0].id.clone()).unwrap();
    let target = SharedString::from(format!("history.text.{id}"));
    cx.update_window(w.into(), |_, win, cx| win.right_click(target, cx)).unwrap();
    frame(cx, w);
    assert_saw(&["Copy", "Insert", "Details", "Delete"]);
    let symbols = flow_ui::probe::symbols();
    for s in ["doc.on.doc", "text.insert", "info.circle", "trash"] {
        assert!(symbols.iter().any(|x| x == s), "{s} in {symbols:?}");
    }
    assert!(cx.update_window(w.into(), |_, win, _| win.find("history.row.details").bounds().size.height).unwrap() > px(0.));
    let red = cx.update(|cx| pal(cx).destructive());
    assert_eq!(flow_ui::probe::style_of("Delete").map(|s| s.color), Some(red));
    // Item 3 is the divider, so Delete is 4.
    cx.update_window(w.into(), |_, win, cx| win.click(ElementId::Integer(4), cx)).unwrap();
    frame(cx, w);
    w.update(cx, |t, _, _| assert!(t.confirming_delete)).unwrap();
}

// parity: HIST-014
#[flow_ui::gpui::test]
async fn escape_in_search_clears_the_text_and_closes_the_field(cx: &mut TestAppContext) {
    let w = open(cx);
    let all = w.update(cx, |t, _, _| t.model.entries.len()).unwrap();
    click(cx, w, "history.searchToggle".into());
    cx.update_window(w.into(), |_, win, cx| win.input("kickoff", cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(300));
    frame(cx, w);
    assert!(w.update(cx, |t, _, _| t.model.entries.len()).unwrap() < all);
    cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
    frame(cx, w);
    w.update(cx, |t, _, _| {
        assert!(!t.searching);
        assert_eq!(t.model.search_text, "");
        assert_eq!(t.model.entries.len(), all);
    })
    .unwrap();
}

// parity: HIST-065
#[flow_ui::gpui::test]
async fn escape_dismisses_the_delete_dialog_like_cancel(cx: &mut TestAppContext) {
    let w = open(cx);
    let ask = |cx: &mut TestAppContext| {
        w.update(cx, |t, _, cx| {
            let e = t.model.entries.iter().find(|e| !e.is_attempting()).unwrap().clone();
            t.ask_delete(&e, cx);
        })
        .unwrap();
        frame(cx, w);
    };
    ask(cx);
    assert!(w.update(cx, |t, _, _| t.confirming_delete).unwrap());
    click(cx, w, "history.deleteDialog.cancel".into());
    assert!(w.update(cx, |t, _, _| !t.confirming_delete).unwrap());
    ask(cx);
    cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
    frame(cx, w);
    assert!(w.update(cx, |t, _, _| !t.confirming_delete).unwrap());
    assert!(!saw("Delete this transcription?"));
}

// parity: HIST-091 HIST-090
#[flow_ui::gpui::test]
async fn done_and_escape_clear_the_detail(cx: &mut TestAppContext) {
    let w = open(cx);
    for close in [true, false] {
        w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
        frame(cx, w);
        assert!(w.update(cx, |t, _, _| t.model.envelope.is_some()).unwrap());
        if close {
            click(cx, w, "history.detail.close".into());
        } else {
            cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
            frame(cx, w);
        }
        w.update(cx, |t, _, _| assert!(t.model.detail_id.is_none() && t.model.envelope.is_none() && t.model.detail_error.is_none())).unwrap();
    }
}

// parity: HIST-045
#[flow_ui::gpui::test]
async fn a_local_row_says_local_only_while_remote_dictation_is_on(cx: &mut TestAppContext) {
    let w = open(cx);
    frame(cx, w);
    assert!(!flow_ui::probe::seen().iter().any(|t| t == "Local"));
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("remoteEnabled", true));
    w.update(cx, |_, _, cx| cx.notify()).unwrap();
    frame(cx, w);
    assert!(flow_ui::probe::seen().iter().any(|t| t == "Local"));
}

// parity: HIST-154
#[flow_ui::gpui::test]
async fn cancel_rewrite_is_there_only_while_one_is_pending(cx: &mut TestAppContext) {
    let w = open(cx);
    cx.update(|cx| {
        let db = cx.global::<Core>().db.as_ref().unwrap();
        db.conn.execute("DELETE FROM rewrite_attempts WHERE transcription_id=?", [seed_id(1)]).unwrap();
    });
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    frame(cx, w);
    assert!(!saw("Cancel rewrite"));
    cx.update(|cx| {
        let db = cx.global::<Core>().db.as_ref().unwrap();
        let e = flow_core::history::get(db, &seed_id(1)).unwrap().unwrap();
        flow_core::history::begin_rewrite(db, &e.id, "clean", &e.text, "http://127.0.0.1:9", false, None).unwrap();
    });
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    frame(cx, w);
    assert_saw(&["Cancel rewrite"]);
    assert_eq!(cx.update_window(w.into(), |_, win, _| win.find("history.detail.rewrite.cancel").label().map(str::to_string)).unwrap().as_deref(), Some("Cancel rewrite"));
}

// parity: HIST-006
#[flow_ui::gpui::test]
async fn a_history_change_reloads_the_list(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    session(cx);
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::History));
    let w = cx.add_window(|w, cx| HistoryPage::new(w, cx));
    frame(cx, w);
    delete_all(cx);
    w.update(cx, |t, _, _| assert!(!t.model.entries.is_empty())).unwrap();
    cx.update(crate::shell::history_changed);
    frame(cx, w);
    w.update(cx, |t, _, _| assert!(t.model.entries.is_empty())).unwrap();
}

fn style(text: &str) -> (f32, f32, Hsla) {
    let s = flow_ui::probe::style_of(text).unwrap_or_else(|| panic!("{text} was not drawn"));
    (s.size, s.weight, s.color)
}

fn palette(cx: &mut TestAppContext) -> Palette {
    cx.update(|cx| pal(cx))
}

fn label_of(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>, id: String) -> Option<String> {
    cx.update_window(w.into(), |_, win, _| win.find(SharedString::from(id)).label().map(str::to_string)).unwrap()
}

fn disabled(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>, id: String) -> bool {
    cx.update_window(w.into(), |_, win, _| win.find(SharedString::from(id)).disabled()).unwrap() == Some(true)
}

fn sql(cx: &mut TestAppContext, q: &str) {
    cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute_batch(q).unwrap());
}

fn opened_with_session(cx: &mut TestAppContext) -> WindowHandle<HistoryPage> {
    boot(cx, Mode::Light);
    session(cx);
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::History));
    let w = cx.add_window(|w, cx| HistoryPage::new(w, cx));
    frame(cx, w);
    w
}

fn review_text(cx: &mut TestAppContext) -> Option<String> {
    cx.update(|cx| cx.global::<Session>().insertion.entry.as_ref().map(|r| r.text.clone()))
}

fn end_review(cx: &mut TestAppContext) {
    cx.update(crate::insertion::cancel);
    cx.run_until_parked();
}

/// Brings an element of the sheet into its scroll view, for a real click.
fn reveal(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>, id: &str) {
    let (b, view) = (bounds(cx, w, id), bounds(cx, w, "history.detail.scroll"));
    w.update(cx, |t, _, cx| {
        let o = t.detail_scroll.offset();
        t.detail_scroll.set_offset(point(o.x, o.y - (b.center().y - view.center().y)));
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
}

fn click_in_sheet(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>, id: &str) {
    reveal(cx, w, id);
    click(cx, w, id.into());
}

fn sheet_bottom(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>) {
    w.update(cx, |t, _, cx| {
        t.detail_scroll.scroll_to_bottom();
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
}

// parity: HIST-002 HIST-024 HIST-025
/// The real path: scrolled to the end, the sentinel loads the next page, the window trims past 200
/// and the row at the top of the view stays where it was through every page.
#[flow_ui::gpui::test]
async fn pages_join_and_leave_without_moving_the_row_in_view(cx: &mut TestAppContext) {
    let w = open(cx);
    cx.update(|cx| {
        let db = cx.global::<Core>().db.as_ref().unwrap();
        for n in 0..260 {
            db.conn.execute_batch(&format!("INSERT INTO transcriptions (id,text,created_at,delivery_state,recovery_state,quality,stop_reason) VALUES ('{}','Filler row',{},'not_attempted','needs_review','complete','key_release')", seed_id(20_000 + n), 1_000_000 - n)).unwrap();
        }
    });
    w.update(cx, |t, _, cx| t.reload(cx)).unwrap();
    frame(cx, w);
    let mut trimmed = false;
    for _ in 0..16 {
        w.update(cx, |t, _, cx| {
            t.scroll.scroll_to_bottom();
            cx.notify();
        })
        .unwrap();
        frame(cx, w);
        frame(cx, w);
        let before = w.update(cx, |t, _, _| t.model.entries.len()).unwrap();
        // The sentinel at the end has asked for a page by now; settle it and read where a row went.
        let (id, top) = w.update(cx, |t, _, _| {
            let tops = t.tops.borrow();
            let view = t.scroll.bounds().top();
            t.model.entries.iter().find_map(|e| tops.get(&e.id).filter(|y| **y >= view).map(|y| (e.id.clone(), *y))).unwrap()
        }).unwrap();
        w.update(cx, |t, _, cx| t.load_page(true, cx)).unwrap();
        frame(cx, w);
        frame(cx, w);
        let (after, now, newer) = w.update(cx, |t, _, _| (t.model.entries.len(), t.tops.borrow().get(&id).copied(), t.model.has_newer)).unwrap();
        if after != before || newer {
            assert_eq!(now, Some(top), "the row in view stayed put with {after} rows");
        }
        trimmed |= newer;
        assert!(after <= RESIDENT_LIMIT);
    }
    assert!(trimmed, "the window trimmed its top");
    let newer = bounds(cx, w, "history.sentinel.newer").size.height;
    assert_eq!(newer, px(44.));
}

// parity: HIST-004 HIST-006
#[flow_ui::gpui::test]
async fn appearing_replaces_the_list_and_reloads_pending_and_an_insertion_end_refreshes(cx: &mut TestAppContext) {
    let w = opened_with_session(cx);
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Insights));
    let dir = std::env::temp_dir().join(format!("lf-hist-appear-{}", std::process::id()));
    cx.update(|cx| seed_pending(cx.global::<Core>().db.as_ref().unwrap(), &dir));
    sql(cx, "UPDATE transcriptions SET text='Changed while away' WHERE id=(SELECT id FROM transcriptions ORDER BY created_at DESC,id DESC LIMIT 1)");
    w.update(cx, |t, _, _| assert!(t.model.pending_items.is_empty())).unwrap();
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::History));
    frame(cx, w);
    w.update(cx, |t, _, _| {
        assert_eq!(t.model.pending_items.len(), 2);
        assert_eq!(t.model.entries[0].text, "Changed while away");
    })
    .unwrap();
    let _ = std::fs::remove_dir_all(dir);
    // A review doesn't refresh while it runs; its end does.
    let id = w.update(cx, |t, _, _| t.model.entries.iter().find(|e| !e.is_attempting()).unwrap().id.clone()).unwrap();
    click(cx, w, format!("history.insert.{id}"));
    sql(cx, &format!("UPDATE transcriptions SET text='Changed during review' WHERE id='{id}'"));
    let text = |cx: &mut TestAppContext| w.update(cx, |t, _, _| t.model.entries.iter().find(|e| e.id == id).unwrap().text.clone()).unwrap();
    assert_ne!(text(cx), "Changed during review");
    end_review(cx);
    assert_eq!(text(cx), "Changed during review");
}

// parity: HIST-007
/// Half of the row: the day change, checked when drawn rather than by a notification. The time zone half is recorded.
#[flow_ui::gpui::test]
async fn a_new_day_while_shown_renames_the_headings(cx: &mut TestAppContext) {
    let w = open(cx);
    const DAY: i64 = 86_400_000;
    let title = |cx: &mut TestAppContext, w: WindowHandle<HistoryPage>| {
        w.update(cx, |t, _, cx| t.model.date_groups(cx.global::<Core>().db.as_ref().unwrap(), t.now)[0].title.clone()).unwrap()
    };
    assert_eq!(title(cx, w), "Today");
    let was = w.update(cx, |t, _, _| t.now).unwrap();
    w.update(cx, |t, _, cx| t.note_clock(was + DAY, true, cx)).unwrap();
    assert_eq!(title(cx, w), "Yesterday");
}

// parity: HIST-008 HIST-034
#[flow_ui::gpui::test]
async fn the_title_and_day_headings_have_their_type(cx: &mut TestAppContext) {
    let w = open(cx);
    let p = palette(cx);
    assert_eq!(style(cx_title()), (26., 500., p.ink));
    assert_eq!(style("TODAY"), (12., 500., p.muted));
    let _ = w;
}

fn cx_title() -> &'static str {
    "Transcriptions"
}

fn input_author_id(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>) -> Option<String> {
    use flow_ui::gpui::{Element as _, IntoElement as _, Render as _, Role, accesskit::Node};
    let state = w.update(cx, |t, _, _| t.search.clone()).unwrap();
    w.update(cx, |_, win, cx| {
        state.update(cx, |s, cx| {
            let input = s.render(win, cx).into_element();
            let mut node = Node::new(Role::Unknown);
            input.write_a11y_info(&mut node);
            node.author_id().map(ToOwned::to_owned)
        })
    })
    .unwrap()
}

// parity: HIST-009 HIST-010 HIST-012 HIST-013
#[flow_ui::gpui::test]
async fn the_search_toggle_and_field_read_as_swift(cx: &mut TestAppContext) {
    let w = opened_with_session(cx);
    assert_eq!(bounds(cx, w, "history.searchToggle").size, size(px(32.), px(32.)));
    assert_eq!(label_of(cx, w, "history.searchToggle".into()).as_deref(), Some("Search transcriptions"));
    assert!(flow_ui::probe::symbols().iter().any(|s| s == "magnifyingglass"));
    click(cx, w, "history.searchToggle".into());
    let field = bounds(cx, w, "history.searchField");
    let input = bounds(cx, w, "history.searchInput");
    assert_eq!(field.size.height, px(32.));
    assert_eq!(input.size.width, px(160.));
    assert_eq!(field.right() - input.right(), px(10.));
    assert!(flow_ui::probe::symbols().iter().any(|s| s == "magnifyingglass"));
    let toggle = cx.update_window(w.into(), |_, win, _| win.try_find("history.searchToggle").is_some()).unwrap();
    assert!(!toggle);
    assert_eq!(input_author_id(cx, w).as_deref(), Some("history.search"));
    assert_eq!(cx.update_window(w.into(), |_, win, _| win.find_by_label("Search transcriptions").placeholder().map(str::to_string)).unwrap().as_deref(), Some("Search"));
    w.update(cx, |t, win, cx| assert!(t.search.read(cx).focus_handle(cx).is_focused(win), "the field opens focused")).unwrap();
    // Text lives in the model, so a return to the page shows the field with it.
    cx.update_window(w.into(), |_, win, cx| win.input("kick", cx)).unwrap();
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Insights));
    w.update(cx, |t, _, _| t.searching = false).unwrap();
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::History));
    frame(cx, w);
    assert_eq!(bounds(cx, w, "history.searchField").size.height, px(32.));
    w.update(cx, |t, _, cx| assert_eq!(t.search.read(cx).value().as_ref(), "kick")).unwrap();
    // The compact width.
    cx.update(|cx| cx.global_mut::<Flow>().compact = true);
    w.update(cx, |_, _, cx| cx.notify()).unwrap();
    frame(cx, w);
    assert_eq!(bounds(cx, w, "history.searchInput").size.width, px(90.));
}

// parity: HIST-016 HIST-017
#[flow_ui::gpui::test]
async fn typing_waits_250_ms_and_an_over_long_query_reverts(cx: &mut TestAppContext) {
    let w = open(cx);
    let all = w.update(cx, |t, _, _| t.model.entries.len()).unwrap();
    click(cx, w, "history.searchToggle".into());
    cx.update_window(w.into(), |_, win, cx| win.input("kickoff", cx)).unwrap();
    cx.executor().advance_clock(Duration::from_millis(249));
    frame(cx, w);
    assert_eq!(w.update(cx, |t, _, _| t.model.entries.len()).unwrap(), all, "not yet");
    cx.executor().advance_clock(Duration::from_millis(2));
    frame(cx, w);
    assert!(w.update(cx, |t, _, _| t.model.entries.len()).unwrap() < all, "now");
    cx.update_window(w.into(), |_, win, cx| win.input(&"x".repeat(257), cx)).unwrap();
    frame(cx, w);
    w.update(cx, |t, _, cx| assert_eq!(t.search.read(cx).value().as_ref(), "kickoff")).unwrap();
    assert_saw(&[SEARCH_LIMIT_MESSAGE]);
}

// parity: HIST-026 HIST-027 HIST-028 HIST-029 HIST-030
#[flow_ui::gpui::test]
async fn empty_texts_and_the_error_row_have_their_style_and_retry_refreshes(cx: &mut TestAppContext) {
    let w = open(cx);
    let p = palette(cx);
    // A first load shows neither text nor a sentinel.
    w.update(cx, |t, _, cx| {
        t.model.entries.clear();
        t.model.has_older = false;
        t.model.is_loading = true;
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    let any = |cx: &mut TestAppContext, id: &'static str| cx.update_window(w.into(), |_, win, _| win.try_find(id).is_some()).unwrap();
    assert!(!any(cx, "history.sentinel.older") && !any(cx, "history.empty"));
    w.update(cx, |t, _, cx| {
        t.model.is_loading = false;
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_eq!(style("No transcriptions yet"), (14., 400., p.muted));
    let empty = bounds(cx, w, "history.empty").size.height;
    assert_eq!(empty, px(160. + 15.), "80 above and below a headless Figtree 14 line");
    w.update(cx, |t, _, cx| {
        t.model.set_search("nothing");
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_eq!(style("No matches"), (14., 400., p.muted));
    assert_eq!(bounds(cx, w, "history.empty").size.height, empty);
    // The error row: warning text and a Retry that really reads the store again.
    sql(cx, "DELETE FROM transcriptions WHERE id NOT IN (SELECT id FROM transcriptions LIMIT 1)");
    w.update(cx, |t, _, cx| {
        t.model.set_search("");
        t.model.error = Some(READ_ERROR.into());
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_eq!(style(READ_ERROR).2, p.warning);
    assert_eq!(label_of(cx, w, "history.retry".into()).as_deref(), Some("Retry"));
    click(cx, w, "history.retry".into());
    w.update(cx, |t, _, _| assert_eq!((t.model.entries.len(), t.model.error.is_none()), (1, true))).unwrap();
}

// parity: HIST-038 HIST-043 HIST-047
#[flow_ui::gpui::test]
async fn row_text_and_labels_have_their_type(cx: &mut TestAppContext) {
    let w = open(cx);
    let p = palette(cx);
    assert!(bounds(cx, w, "history.list").size.height > px(0.));
    assert_eq!(style("Incomplete"), (11., 500., p.warning));
    assert_eq!(style("Cut short at 180 seconds"), (11., 500., p.warning));
    let text = w.update(cx, |t, _, _| t.model.entries[0].text.clone()).unwrap();
    assert_eq!(style(&text), (15., 400., p.ink));
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("remoteEnabled", true));
    w.update(cx, |_, _, cx| cx.notify()).unwrap();
    frame(cx, w);
    assert_eq!(style("Local"), (11., 400., p.muted));
}

// parity: HIST-048
/// The page root holds focus at rest: no row counts as focused until Tab reaches its actions, then only that row.
#[flow_ui::gpui::test]
async fn only_the_row_tab_reached_keeps_its_actions(cx: &mut TestAppContext) {
    let w = open(cx);
    let ids: Vec<String> = w.update(cx, |t, _, _| t.model.entries.iter().map(|e| e.id.clone()).collect()).unwrap();
    frame(cx, w);
    let shown = |cx: &mut TestAppContext| w.update(cx, |t, win, cx| ids.iter().filter(|id| t.action_focus.borrow()[*id].contains_focused(win, cx)).count()).unwrap();
    w.update(cx, |t, win, cx| t.focus.focus(win, cx)).unwrap();
    assert_eq!(shown(cx), 0, "the root's focus shows nobody's actions");
    for _ in 0..4 {
        cx.update_window(w.into(), |_, win, cx| win.press("tab", cx)).unwrap();
        if shown(cx) > 0 {
            break;
        }
    }
    assert_eq!(shown(cx), 1);
    // Clicking through the invisible actions is possible only by hover in Swift; here too the bounds stay.
    assert_eq!(bounds(cx, w, &format!("history.more.{}", ids[1])).size, size(px(28.), px(28.)));
}

// parity: HIST-049 HIST-050 HIST-051 HIST-052 HIST-053 HIST-055
#[flow_ui::gpui::test]
async fn row_buttons_read_their_symbols_labels_and_states(cx: &mut TestAppContext) {
    let w = opened_with_session(cx);
    let entries = w.update(cx, |t, _, _| t.model.entries.clone()).unwrap();
    let plain = entries.iter().find(|e| !e.is_confirmed() && !e.is_attempting()).unwrap().id.clone();
    let symbols = flow_ui::probe::symbols;
    for s in ["doc.on.doc", "text.insert", "ellipsis"] {
        assert!(symbols().iter().any(|x| x == s), "{s}");
    }
    assert!(!symbols().iter().any(|x| x == "checkmark"));
    assert_eq!(bounds(cx, w, &format!("history.insert.{plain}")).size, size(px(28.), px(28.)));
    assert_eq!(label_of(cx, w, format!("history.insert.{plain}")).as_deref(), Some("Insert"));
    assert_eq!(label_of(cx, w, format!("history.more.{plain}")).as_deref(), Some("More"));
    // Copy turns to a check for 1.2 s, for that row only.
    click(cx, w, format!("history.copy.{plain}"));
    assert_eq!(symbols().iter().filter(|x| *x == "checkmark").count(), 1);
    cx.executor().advance_clock(Duration::from_millis(1199));
    frame(cx, w);
    assert_eq!(symbols().iter().filter(|x| *x == "checkmark").count(), 1, "at 1,199 ms");
    cx.executor().advance_clock(Duration::from_millis(2));
    frame(cx, w);
    assert!(!symbols().iter().any(|x| x == "checkmark"), "past 1,200 ms");
    // A busy coordinator turns Insert off and leaves Copy on.
    cx.update(|cx| crate::shell::update_session(cx, |s| s.dictation.as_mut().unwrap().busy = true));
    frame(cx, w);
    assert!(disabled(cx, w, format!("history.insert.{plain}")));
    assert!(!disabled(cx, w, format!("history.copy.{plain}")));
    cx.write_to_clipboard(ClipboardItem::new_string("before".into()));
    click(cx, w, format!("history.copy.{plain}"));
    let text = entries.iter().find(|e| e.id == plain).unwrap().text.clone();
    assert_eq!(cx.read_from_clipboard().and_then(|c| c.text()), Some(text));
}

// parity: HIST-054 HIST-058
#[flow_ui::gpui::test]
async fn row_and_menu_insert_review_the_row_and_are_ignored_while_blocked(cx: &mut TestAppContext) {
    let w = opened_with_session(cx);
    let e = w.update(cx, |t, _, _| t.model.entries.iter().find(|e| !e.is_attempting()).unwrap().clone()).unwrap();
    click(cx, w, format!("history.insert.{}", e.id));
    assert_eq!(review_text(cx), Some(e.text.clone()));
    end_review(cx);
    let target = SharedString::from(format!("history.text.{}", e.id));
    cx.update_window(w.into(), |_, win, cx| win.right_click(target.clone(), cx)).unwrap();
    frame(cx, w);
    cx.update_window(w.into(), |_, win, cx| win.click(ElementId::Integer(1), cx)).unwrap();
    frame(cx, w);
    assert_eq!(review_text(cx), Some(e.text.clone()), "the menu item");
    end_review(cx);
    cx.update(|cx| crate::shell::update_session(cx, |s| s.insertion.entry = None));
    for block in [(|s: &mut Session| s.installing = true) as fn(&mut Session), |s| s.model_command = true] {
        cx.update(|cx| crate::shell::update_session(cx, block));
        frame(cx, w);
        click(cx, w, format!("history.insert.{}", e.id));
        assert_eq!(review_text(cx), None);
        cx.update(|cx| {
            crate::shell::update_session(cx, |s| {
                s.installing = false;
                s.model_command = false;
            })
        });
    }
}

// parity: HIST-056 HIST-060
#[flow_ui::gpui::test]
async fn both_menus_read_the_same_items_and_delete_can_be_off(cx: &mut TestAppContext) {
    let w = opened_with_session(cx);
    let entries = w.update(cx, |t, _, _| t.model.entries.clone()).unwrap();
    let confirmed = entries.iter().find(|e| e.is_confirmed()).unwrap().id.clone();
    let other = entries.iter().find(|e| !e.is_confirmed() && !e.is_attempting()).unwrap().id.clone();
    let open_menu = |cx: &mut TestAppContext, id: &str, right: bool| {
        let (text, more) = (SharedString::from(format!("history.text.{id}")), SharedString::from(format!("history.more.{id}")));
        cx.update_window(w.into(), |_, win, cx| if right { win.right_click(text, cx) } else { win.click(more, cx) }).unwrap();
        frame(cx, w);
    };
    for right in [true, false] {
        open_menu(cx, &confirmed, right);
        assert_saw(&["Copy", "Insert again…", "Details", "Delete"]);
        let s = flow_ui::probe::symbols();
        for symbol in ["doc.on.doc", "text.insert", "info.circle", "trash"] {
            assert!(s.iter().any(|x| x == symbol), "{symbol}, {right}");
        }
        cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
        frame(cx, w);
        open_menu(cx, &other, right);
        assert_saw(&["Insert…"]);
        assert!(!flow_ui::probe::seen().iter().any(|x| x == "Insert again…"), "{right}");
        cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
        frame(cx, w);
    }
    // The fifth item is Delete: the click asks about that row. The same click is dead below.
    let click_delete = |cx: &mut TestAppContext| {
        cx.update_window(w.into(), |_, win, cx| win.click(ElementId::Integer(4), cx)).unwrap();
        frame(cx, w);
        w.update(cx, |t, _, _| t.confirming_delete).unwrap()
    };
    open_menu(cx, &other, true);
    assert!(click_delete(cx), "opens the dialog");
    w.update(cx, |t, _, _| assert_eq!(t.model.selected.as_ref().map(|e| e.id.clone()), Some(other.clone()))).unwrap();
    cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
    frame(cx, w);
    // Attempting: off.
    sql(cx, &format!("UPDATE transcriptions SET delivery_state='attempting' WHERE id='{other}'"));
    w.update(cx, |t, _, cx| t.model.refresh(cx.global::<Core>().db.as_ref().unwrap())).unwrap();
    frame(cx, w);
    open_menu(cx, &other, true);
    assert!(!click_delete(cx), "attempting");
    cx.update_window(w.into(), |_, win, cx| win.press("escape", cx)).unwrap();
    frame(cx, w);
    sql(cx, &format!("UPDATE transcriptions SET delivery_state='not_inserted' WHERE id='{other}'"));
    w.update(cx, |t, _, cx| t.model.refresh(cx.global::<Core>().db.as_ref().unwrap())).unwrap();
    frame(cx, w);
    // Busy: off.
    cx.update(|cx| crate::shell::update_session(cx, |s| s.dictation.as_mut().unwrap().busy = true));
    frame(cx, w);
    open_menu(cx, &other, true);
    assert!(!click_delete(cx), "busy");
}

// parity: HIST-185
#[flow_ui::gpui::test]
async fn delete_stays_on_for_a_pending_rewrite_and_the_store_refuses(cx: &mut TestAppContext) {
    let w = open(cx);
    let mut e = w.update(cx, |t, _, _| t.model.entries.iter().find(|e| !e.is_attempting()).unwrap().clone()).unwrap();
    e.rewrite_state = "pending".into();
    assert!(!row_menu_state(&e, false, false).2, "only delivery and busy turn it off");
    sql(cx, &format!("UPDATE transcriptions SET rewrite_state='pending' WHERE id='{}'", e.id));
    let refused = cx.update(|cx| {
        let db = cx.global::<Core>().db.as_ref().unwrap();
        let revision = flow_core::history::get(db, &e.id).unwrap().unwrap().revision;
        flow_core::history::delete_confirmed(db, &e.id, revision)
    });
    assert!(matches!(refused, Err(flow_core::history::StoreError::Busy)));
}

// parity: HIST-059
#[flow_ui::gpui::test]
async fn details_from_the_menu_stay_on_while_busy_and_clear_what_was_open(cx: &mut TestAppContext) {
    let w = opened_with_session(cx);
    let e = w.update(cx, |t, _, _| t.model.entries[0].clone()).unwrap();
    w.update(cx, |t, _, cx| {
        t.show_detail(&seed_id(1), cx);
        t.model.rewrite_notice = Some("Old notice".into());
        t.model.detail_error = Some("Old error".into());
        t.stage = detail::Stage::Raw;
        t.open.insert("history.detail.processing".into());
        t.model.detail_id = None;
    })
    .unwrap();
    cx.update(|cx| crate::shell::update_session(cx, |s| s.dictation.as_mut().unwrap().busy = true));
    frame(cx, w);
    cx.update_window(w.into(), |_, win, cx| win.right_click(SharedString::from(format!("history.text.{}", e.id)), cx)).unwrap();
    frame(cx, w);
    cx.update_window(w.into(), |_, win, cx| win.click("history.row.details", cx)).unwrap();
    frame(cx, w);
    w.update(cx, |t, _, _| {
        assert_eq!(t.model.detail_id.as_deref(), Some(e.id.as_str()));
        assert_eq!((t.model.rewrite_notice.clone(), t.model.detail_error.clone(), t.stage, t.open.is_empty()), (None, None, detail::Stage::Normalized, true));
    })
    .unwrap();
}

// parity: HIST-061 HIST-062 HIST-063
#[flow_ui::gpui::test]
async fn the_delete_dialog_reads_its_buttons_and_refuses_when_it_must(cx: &mut TestAppContext) {
    let w = opened_with_session(cx);
    let e = w.update(cx, |t, _, _| t.model.entries.iter().find(|e| !e.is_attempting()).unwrap().clone()).unwrap();
    let ask = |cx: &mut TestAppContext, e: &Entry| {
        w.update(cx, |t, _, cx| t.ask_delete(e, cx)).unwrap();
        frame(cx, w);
    };
    ask(cx, &e);
    assert_eq!(label_of(cx, w, "history.deleteDialog.confirm".into()).as_deref(), Some("Delete"));
    assert_eq!(label_of(cx, w, "history.deleteDialog.cancel".into()).as_deref(), Some("Cancel"));
    let red = cx.update(|cx| pal(cx).destructive());
    assert_eq!(style("Delete").2, red);
    // Busy and storage-blocked coordinators refuse with the action error.
    for block in [(|d: &mut crate::shell::Dictation| d.busy = true) as fn(&mut crate::shell::Dictation), |d| d.storage_blocked = true] {
        cx.update(|cx| crate::shell::update_session(cx, |s| block(s.dictation.as_mut().unwrap())));
        click(cx, w, "history.deleteDialog.confirm".into());
        assert!(exists(cx, e.id.clone()));
        assert_saw(&[ACTION_ERROR]);
        cx.update(|cx| crate::shell::update_session(cx, |s| s.dictation = Some(Default::default())));
        w.update(cx, |t, _, _| t.model.error = None).unwrap();
        ask(cx, &e);
    }
    // A stale revision, then a pending rewrite: the store refuses, the page shows the copy.
    let stale = Entry { revision: e.revision + 9, ..e.clone() };
    w.update(cx, |t, _, _| t.model.selected = Some(stale)).unwrap();
    click(cx, w, "history.deleteDialog.confirm".into());
    assert_saw(&[ACTION_ERROR]);
    assert!(exists(cx, e.id.clone()));
    w.update(cx, |t, _, _| t.model.error = None).unwrap();
    cx.update(|cx| { flow_core::history::begin_rewrite(cx.global::<Core>().db.as_ref().unwrap(), &e.id, "clean", &e.text, "http://127.0.0.1:9", false, None).unwrap(); });
    let fresh = cx.update(|cx| get(cx.global::<Core>().db.as_ref().unwrap(), &e.id).unwrap().unwrap());
    ask(cx, &fresh);
    click(cx, w, "history.deleteDialog.confirm".into());
    assert_saw(&[ACTION_ERROR]);
    assert!(exists(cx, e.id.clone()));
    // Refused: nothing stays selected and no dialog remains.
    w.update(cx, |t, _, _| assert!(t.model.selected.is_none() && !t.confirming_delete)).unwrap();
}

fn pending_page(cx: &mut TestAppContext) -> (WindowHandle<HistoryPage>, std::path::PathBuf) {
    let w = open(cx);
    let dir = std::env::temp_dir().join(format!("lf-hist-pending-{}-{:?}", std::process::id(), std::thread::current().id()));
    w.update(cx, |t, _, cx| {
        let db = cx.global::<Core>().db.as_ref().unwrap();
        seed_pending(db, &dir.join("PendingAudio"));
        t.model.refresh_pending(db);
        cx.notify();
    })
    .unwrap();
    cx.update(|cx| {
        let core = cx.global_mut::<Core>();
        core.paths = flow_core::paths::Paths::new(dir.clone());
        core.services = Box::new(NoSavePanel);
    });
    frame(cx, w);
    (w, dir)
}

// parity: HIST-068 HIST-069 HIST-071 HIST-073 HIST-074 HIST-076 HIST-077 HIST-079 HIST-081 HIST-082 HIST-083 HIST-084
/// The waiting section, read and driven through its own buttons.
#[flow_ui::gpui::test]
async fn the_waiting_section_reads_its_rows_and_discards_through_the_dialog(cx: &mut TestAppContext) {
    let (w, dir) = pending_page(cx);
    let p = palette(cx);
    let (old, new) = (seed_id(9201), seed_id(9202));
    assert_eq!(style("WAITING FOR SERVER"), (12., 500., p.muted));
    assert_eq!(style("Retries stopped after 24 hours"), (14., 400., p.ink));
    assert_eq!(style("Waiting for server"), (14., 400., p.ink));
    assert_eq!(style("3 s of audio"), (12., 400., p.muted));
    assert_saw(&["10 s of audio", "TODAY"]);
    // Oldest first, above the list, with the list still below.
    let (a, b, list) = (bounds(cx, w, &format!("history.pendingRemote.{old}")), bounds(cx, w, &format!("history.pendingRemote.{new}")), bounds(cx, w, "history.list"));
    assert!(a.bottom() <= b.top() && b.bottom() <= list.top());
    // Buttons by row, and Recognize follows the local model.
    assert_eq!(label_of(cx, w, format!("history.pending.recognize.{new}")).as_deref(), Some("Recognize Locally"));
    assert_eq!(label_of(cx, w, format!("history.pending.save.{new}")).as_deref(), Some("Save Audio…"));
    assert_eq!(label_of(cx, w, format!("history.pending.discard.{new}")).as_deref(), Some("Discard"));
    assert!(disabled(cx, w, format!("history.pending.recognize.{new}")));
    w.update(cx, |t, _, cx| {
        t.model.local_speech = true;
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert!(!disabled(cx, w, format!("history.pending.recognize.{new}")));
    // A failure shows the warning, 12, then the next action clears it.
    click(cx, w, format!("history.pending.save.{new}"));
    assert_eq!(style(PENDING_ERROR), (12., 400., p.warning));
    click(cx, w, format!("history.pending.discard.{new}"));
    assert_eq!(label_of(cx, w, "history.discardDialog.confirm".into()).as_deref(), Some("Discard"));
    assert_eq!(label_of(cx, w, "history.discardDialog.cancel".into()).as_deref(), Some("Cancel"));
    assert_saw(&["Discard this recording?", "Its audio is deleted and it will not be recognized."]);
    let audio = dir.join("PendingAudio").join(format!("{new}.f32"));
    assert!(audio.exists());
    click(cx, w, "history.discardDialog.confirm".into());
    assert!(!audio.exists(), "the audio went");
    assert!(!saw(PENDING_ERROR), "cleared by this action");
    w.update(cx, |t, _, _| assert_eq!(t.model.pending_items.iter().map(|i| i.id.clone()).collect::<Vec<_>>(), [old.clone()])).unwrap();
    cx.update(|cx| {
        let n: i64 = cx.global::<Core>().db.as_ref().unwrap().conn.query_row("SELECT count(*) FROM pending_remote_dictations", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 1, "the row went");
    });
    // With no waiting rows the section is gone.
    click(cx, w, format!("history.pending.discard.{old}"));
    click(cx, w, "history.discardDialog.confirm".into());
    assert!(!saw("WAITING FOR SERVER"));
    assert_saw(&["TODAY"]);
    let _ = std::fs::remove_dir_all(dir);
}

// parity: HIST-089 HIST-090 HIST-092 HIST-093 HIST-094 HIST-095
#[flow_ui::gpui::test]
async fn the_sheet_has_its_size_loading_error_and_retry(cx: &mut TestAppContext) {
    let w = open(cx);
    let p = palette(cx);
    let id = seed_id(3);
    w.update(cx, |t, _, cx| t.show_detail(&id, cx)).unwrap();
    frame(cx, w);
    assert_eq!(bounds(cx, w, "history.detail.scroll").size.width, px(600. - 48.));
    assert_eq!(style("Details"), (20., 500., p.ink));
    assert_eq!(label_of(cx, w, "history.detail.close".into()).as_deref(), Some("Done"));
    // Loading: a spinner with 40 around it, and no body.
    w.update(cx, |t, _, cx| {
        t.model.detail_loading = true;
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    let loading = bounds(cx, w, "history.detail.loading");
    assert!(loading.size.height >= px(80.) && loading.size.width == px(552.));
    assert!(!saw("Completeness: "));
    // Error: warning text; Retry reads the same entry again.
    w.update(cx, |t, _, cx| {
        t.model.detail_loading = false;
        t.model.envelope = None;
        t.model.detail_error = Some(DETAIL_ERROR.into());
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_eq!(style(DETAIL_ERROR).2, p.warning);
    assert_eq!(label_of(cx, w, "history.detail.retry".into()).as_deref(), Some("Retry"));
    click(cx, w, "history.detail.retry".into());
    w.update(cx, |t, _, _| assert_eq!(t.model.envelope.as_ref().map(|e| e.entry.id.clone()), Some(id.clone()))).unwrap();
    // The row gone from under the same button: the sheet closes and the row goes.
    w.update(cx, |t, _, cx| {
        t.model.envelope = None;
        t.model.detail_error = Some(DETAIL_ERROR.into());
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    sql(cx, &format!("DELETE FROM transcriptions WHERE id='{id}'"));
    click(cx, w, "history.detail.retry".into());
    w.update(cx, |t, _, _| assert!(t.model.detail_id.is_none() && t.model.entries.iter().all(|e| e.id != id))).unwrap();
    assert!(!saw("Details"));
}

// parity: HIST-097 HIST-098 HIST-100 HIST-101
#[flow_ui::gpui::test]
async fn the_status_block_reads_each_value_in_words(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = seed_id(3);
    let p = palette(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    frame(cx, w);
    assert_eq!(style("Completeness: Complete"), (13., 400., p.ink));
    assert_saw(&["Recognized: Local", "Microphone: Studio Microphone"]);
    assert!(bounds(cx, w, "history.detail").size.width > px(0.));
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(2), cx)).unwrap();
    frame(cx, w);
    assert_saw(&["Completeness: Incomplete"]);
    for (raw, shown) in [("not_attempted", "not attempted"), ("attempting", "attempting"), ("confirmed", "confirmed"), ("not_inserted", "not inserted"), ("uncertain", "uncertain")] {
        sql(cx, &format!("UPDATE transcriptions SET delivery_state='{raw}' WHERE id='{id}'"));
        w.update(cx, |t, _, cx| t.show_detail(&id, cx)).unwrap();
        frame(cx, w);
        assert_saw(&[&format!("Delivery: {shown}")]);
    }
    for (raw, shown) in [("key_release", "key release"), ("duration_limit", "duration limit"), ("cancel", "cancel"), ("overflow", "overflow"), ("device_loss", "device loss"), ("permission_revoked", "permission revoked"), ("sleep", "sleep"), ("failure", "failure")] {
        sql(cx, &format!("UPDATE transcriptions SET stop_reason='{raw}' WHERE id='{id}'"));
        w.update(cx, |t, _, cx| t.show_detail(&id, cx)).unwrap();
        frame(cx, w);
        assert_saw(&[&format!("Stopped: {shown}")]);
    }
}

// parity: HIST-102
#[flow_ui::gpui::test]
async fn the_legacy_lines_have_their_type(cx: &mut TestAppContext) {
    let w = open(cx);
    let p = palette(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(5), cx)).unwrap();
    frame(cx, w);
    assert_eq!(style(LEGACY_DETAIL), (13., 400., p.muted));
    assert_saw(&["Saved text"]);
    let text = w.update(cx, |t, _, _| t.model.envelope.as_ref().unwrap().entry.text.clone()).unwrap();
    assert_saw(&[&text]);
    assert!(!saw("Transcript stage"), "no stages without a quality row");
}

// parity: HIST-103 HIST-104 HIST-107 HIST-109 HIST-124 HIST-127 HIST-128 HIST-130
#[flow_ui::gpui::test]
async fn stages_and_sections_read_their_text_and_type(cx: &mut TestAppContext) {
    let w = open(cx);
    let p = palette(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    cx.simulate_window_resize(w.into(), size(px(1180.), px(3000.)));
    frame(cx, w);
    let text = w.update(cx, |t, _, _| t.model.envelope.as_ref().unwrap().entry.text.clone()).unwrap();
    assert_saw(&["Transcript stage", "Normalized", "Assembled", "Raw recognition"]);
    assert_eq!(style(&text).0, 14., "the normalized stage is the default and shows the saved text");
    assert!(!saw("Engine"), "Processing details starts collapsed");
    assert_eq!(style("App context"), (14., 600., p.ink));
    assert_eq!(style("Context: used"), (13., 400., p.ink));
    assert_eq!(style("Rewrite"), (14., 600., p.ink));
    assert_eq!(style("“north wind” → “Northwind” · on screen (window title)"), (13., 400., p.ink));
    // "Text before context spelling" opens to its text; "Context as captured" to its rows.
    assert!(!saw("Move the kickoff to Thursday and ask north wind to send the updated floor plan before noon."));
    click(cx, w, "history.detail.context.before".into());
    assert_eq!(style("Move the kickoff to Thursday and ask north wind to send the updated floor plan before noon.").0, 13.);
    click(cx, w, "history.detail.context.snapshot".into());
    assert_saw(&["App", "Mail", "Field", "multi line", "Terms", "Northwind", "Shortened", "before_cursor"]);
    // Raw: the note, then "Window n · samples a–b".
    click(cx, w, "history.detail.stage.raw".into());
    assert_eq!(style("Exact received windows in order. Overlapping windows can repeat words."), (12., 400., p.muted));
    assert_eq!(style("Window 1 · samples 0–239360"), (12., 400., p.muted));
    assert_saw(&["Window 2 · samples 207360–240000"]);
    // Processing opens 10 under its title.
    click(cx, w, "history.detail.processing".into());
    let (title, lines) = (bounds(cx, w, "history.detail.processing"), bounds(cx, w, "history.detail.processing.lines"));
    assert_eq!(lines.top() - title.bottom(), px(10.));
    assert_saw(&["Engine"]);
    assert_eq!(style("Processing reasons"), (14., 600., p.ink));
}

// parity: HIST-131 HIST-132 HIST-138 HIST-139 HIST-140 HIST-142 HIST-143 HIST-146 HIST-156 HIST-157 HIST-158 HIST-160 HIST-161 HIST-162
/// The rewrite section against a dictation with three kinds of attempt, through its own buttons.
#[flow_ui::gpui::test]
async fn the_rewrite_section_reads_and_drives_its_columns_and_attempts(cx: &mut TestAppContext) {
    let w = opened_with_session(cx);
    let p = palette(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx)).unwrap();
    cx.simulate_window_resize(w.into(), size(px(1180.), px(3000.)));
    frame(cx, w);
    assert_eq!(style("Rewrite: succeeded"), (13., 400., p.muted));
    assert_eq!(style("Delivered: rewrite attempt 2 (Polished)"), (13., 400., p.ink));
    assert_eq!(style("Saved text").0, 12.);
    assert_eq!(style("The faithful transcript."), (12., 400., p.muted));
    assert_eq!(style("Current rewrite (Polished)").0, 12.);
    assert_eq!(style("AI-generated rewrite, not the transcript."), (12., 400., p.muted));
    // Side by side, 16 apart; buttons 8 apart.
    let (saved, current, insert) = (bounds(cx, w, "history.detail.copy.saved"), bounds(cx, w, "history.detail.copy.current"), bounds(cx, w, "history.detail.insert.saved"));
    assert_eq!(current.left() - saved.left(), px((552. - 16.) / 2. + 16.));
    assert_eq!(insert.left() - saved.right(), px(8.));
    assert_eq!(label_of(cx, w, "history.detail.copy.saved".into()).as_deref(), Some("Copy Saved text"));
    assert_eq!(label_of(cx, w, "history.detail.copy.current".into()).as_deref(), Some("Copy Current rewrite (Polished)"));
    assert_eq!(label_of(cx, w, "history.detail.insert.saved".into()).as_deref(), Some("Insert Saved text"));
    assert_eq!(label_of(cx, w, "history.detail.insert.current".into()).as_deref(), Some("Insert Current rewrite (Polished)"));
    assert_eq!(label_of(cx, w, "history.detail.rewrite.retry".into()).as_deref(), Some("Retry"));
    let (saved_text, out) = w.update(cx, |t, _, _| (t.model.envelope.as_ref().unwrap().entry.text.clone(), t.model.current_rewrite().unwrap().output_text.clone().unwrap())).unwrap();
    click_in_sheet(cx, w, "history.detail.copy.current");
    assert_eq!(cx.read_from_clipboard().and_then(|c| c.text()), Some(out.clone()));
    // Each Insert reviews its own text. Both stay enabled while busy, and a refused one is silent.
    click_in_sheet(cx, w, "history.detail.insert.saved");
    assert_eq!(review_text(cx), Some(saved_text));
    assert!(!disabled(cx, w, "history.detail.insert.current".into()), "no disabled state, even while the coordinator is busy");
    end_review(cx);
    click_in_sheet(cx, w, "history.detail.insert.current");
    assert_eq!(review_text(cx), Some(out.clone()));
    end_review(cx);
    // Attempts start collapsed, each titled; the summary and texts show when open.
    assert_eq!(style("Attempt 2 · Polished · succeeded").0, 13.);
    assert!(!saw("Input snapshot"));
    click_in_sheet(cx, w, "history.detail.rewrite.attempt.2");
    assert_eq!(style("Input snapshot").0, 12.);
    assert_saw(&["420 ms total · 85 ms to first byte · context sent · delivered · seed-model-1+p3+s2"]);
    assert_eq!(label_of(cx, w, "history.detail.attempt.copy.2".into()).as_deref(), Some("Copy rewrite attempt 2"));
    assert_eq!(label_of(cx, w, "history.detail.attempt.insert.2".into()).as_deref(), Some("Insert rewrite attempt 2"));
    // Stale still inserts, and an output that isn't a success can't be inserted.
    sql(cx, &format!("UPDATE rewrite_attempts SET stale=1 WHERE id='{}'", seed_id(9102)));
    w.update(cx, |t, _, cx| {
        t.model.reload_attempts(cx.global::<Core>().db.as_ref().unwrap());
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_saw(&["stale"]);
    assert!(!disabled(cx, w, "history.detail.attempt.insert.2".into()));
    click_in_sheet(cx, w, "history.detail.attempt.insert.2");
    assert_eq!(review_text(cx), Some(out));
    end_review(cx);
    // A CHECK ties output to success, so only a damaged row can show this; the model is set by hand.
    // The end of the review refreshed the open detail, which closes its disclosures (HIST-183).
    w.update(cx, |t, _, cx| {
        t.open.insert("history.detail.rewrite.attempt.2".into());
        t.model.attempts[1].state = "failed".into();
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert!(disabled(cx, w, "history.detail.attempt.insert.2".into()));
    // Ten attempts: the explanation in its style. None: the other button name and the empty line.
    cx.update(|cx| {
        let db = cx.global::<Core>().db.as_ref().unwrap();
        for n in 3..=10 {
            db.conn.execute_batch(&format!("INSERT INTO rewrite_attempts (id,transcription_id,ordinal,mode,state,input_text,input_hash,started_at,protocol_version,endpoint_origin) SELECT 'extra-{n}',transcription_id,{n},mode,'cancelled',input_text,input_hash,started_at,1,endpoint_origin FROM rewrite_attempts WHERE id='{}'", seed_id(9102))).unwrap();
        }
    });
    w.update(cx, |t, _, cx| {
        t.model.reload_attempts(cx.global::<Core>().db.as_ref().unwrap());
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_eq!(style("This dictation already has ten rewrite attempts."), (13., 400., p.muted));
    w.update(cx, |t, _, cx| {
        t.model.attempts.clear();
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    assert_eq!(label_of(cx, w, "history.detail.rewrite.retry".into()).as_deref(), Some("Rewrite"));
    assert_eq!(style("No rewrite attempts."), (13., 400., p.muted));
}

// parity: HIST-144 HIST-145
#[flow_ui::gpui::test]
async fn the_mode_menu_lists_three_modes_and_a_click_keeps_for_the_next_detail(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(5), cx)).unwrap();
    cx.simulate_window_resize(w.into(), size(px(1180.), px(3000.)));
    frame(cx, w);
    assert_eq!(bounds(cx, w, "history.detail.rewrite.modeFrame").size.width, px(180.));
    assert_eq!(w.update(cx, |t, _, _| t.model.rewrite_mode).unwrap(), RewriteMode::Clean);
    assert_eq!(label_of(cx, w, "history.detail.rewrite.mode".into()).as_deref(), Some("Mode"));
    sheet_bottom(cx, w);
    click(cx, w, "history.detail.rewrite.mode".into());
    for mode in ["Clean", "Polished", "Concise"] {
        cx.update_window(w.into(), |_, win, _| win.find_by_label(mode).bounds()).unwrap();
    }
    assert_eq!(cx.update_window(w.into(), |_, win, _| win.try_find(ElementId::Integer(3)).is_some()).unwrap(), false, "three items: exact isn't one");
    cx.update_window(w.into(), |_, win, cx| win.click(ElementId::Integer(2), cx)).unwrap();
    frame(cx, w);
    w.update(cx, |t, _, _| assert_eq!(t.model.rewrite_mode, RewriteMode::Concise)).unwrap();
    click(cx, w, "history.detail.close".into());
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(3), cx)).unwrap();
    frame(cx, w);
    assert_saw(&["Concise"]);
    // A new page is a new launch: back to the default, nothing persisted.
    let fresh = cx.add_window(|w, cx| HistoryPage::new(w, cx));
    fresh.update(cx, |t, _, _| assert_eq!(t.model.rewrite_mode, RewriteMode::Clean)).unwrap();
}

// parity: HIST-133
#[flow_ui::gpui::test]
async fn the_notice_is_none_until_a_refusal_or_cancel_and_has_its_type(cx: &mut TestAppContext) {
    let w = open(cx);
    let p = palette(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(3), cx)).unwrap();
    frame(cx, w);
    w.update(cx, |t, _, _| assert_eq!(t.model.rewrite_notice, None)).unwrap();
    cx.update(|cx| { flow_core::history::begin_rewrite(cx.global::<Core>().db.as_ref().unwrap(), &seed_id(3), "clean", "words", "http://127.0.0.1:9", false, None).unwrap(); });
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(3), cx)).unwrap();
    frame(cx, w);
    sheet_bottom(cx, w);
    click(cx, w, "history.detail.rewrite.cancel".into());
    assert_eq!(style("Rewrite cancelled."), (13., 400., p.muted));
}

// parity: HIST-164 HIST-165
#[flow_ui::gpui::test]
async fn the_review_warns_about_delivery_from_the_row(cx: &mut TestAppContext) {
    let w = opened_with_session(cx);
    let id = seed_id(3);
    let warnings = |cx: &mut TestAppContext| cx.update(|cx| cx.global::<Session>().insertion.warnings());
    let e = |cx: &mut TestAppContext| cx.update(|cx| get(cx.global::<Core>().db.as_ref().unwrap(), &id).unwrap().unwrap());
    for (state, warning) in [("uncertain", "This text may already be in the destination. Inserting again could duplicate it."), ("confirmed", "This text was already inserted. Inserting again creates another copy.")] {
        sql(cx, &format!("UPDATE transcriptions SET delivery_state='{state}' WHERE id='{id}'"));
        let row = e(cx);
        w.update(cx, |t, _, cx| t.insert(&row, row.text.clone(), cx)).unwrap();
        assert_eq!(warnings(cx), vec![warning]);
        end_review(cx);
    }
    sql(cx, &format!("UPDATE transcriptions SET delivery_state='not_inserted' WHERE id='{id}'"));
    let row = e(cx);
    w.update(cx, |t, _, cx| t.insert(&row, row.text.clone(), cx)).unwrap();
    assert!(warnings(cx).is_empty());
    end_review(cx);
    // `model_command` joins the guards of `insert_opens_the_review_only_when_nothing_blocks_it`.
    cx.update(|cx| crate::shell::update_session(cx, |s| s.model_command = true));
    w.update(cx, |t, _, cx| t.insert(&row, row.text.clone(), cx)).unwrap();
    cx.update(|cx| assert!(!cx.global::<Session>().insertion.is_reviewing()));
}
