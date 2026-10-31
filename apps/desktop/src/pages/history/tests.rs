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
    cx.update_window(w.into(), |_, w, cx| w.render_frame(cx))
        .unwrap();
}

fn click(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>, id: String) {
    let id = SharedString::from(id);
    cx.update_window(w.into(), |_, win, cx| win.click(id, cx))
        .unwrap();
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
    fn open_permission_settings(
        &self,
        _: flow_platform::Permission,
    ) -> Result<(), flow_platform::Unavailable> {
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
    cx.update(|cx| {
        cx.global::<Core>()
            .db
            .as_ref()
            .map(|db| get(db, &id).unwrap().is_some())
            .unwrap()
    })
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
    cx.update_window(w.into(), |_, win, cx| win.input("zzzqqq", cx))
        .unwrap();
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
    let (id, text) = w
        .update(cx, |t, _, _| {
            (
                t.model.entries[0].id.clone(),
                t.model.entries[0].text.clone(),
            )
        })
        .unwrap();
    click(cx, w, format!("history.copy.{id}"));
    assert_eq!(cx.read_from_clipboard().and_then(|c| c.text()), Some(text));
    w.update(cx, |t, _, _| assert!(t.copied.contains(&id)))
        .unwrap();
    cx.executor().advance_clock(Duration::from_millis(1300));
    frame(cx, w);
    w.update(cx, |t, _, _| assert!(!t.copied.contains(&id)))
        .unwrap();
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
        let e = t
            .model
            .entries
            .iter()
            .find(|e| !e.is_attempting())
            .unwrap()
            .clone();
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
            let e = t
                .model
                .entries
                .iter()
                .find(|e| !e.is_attempting())
                .unwrap()
                .clone();
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
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx))
        .unwrap();
    frame(cx, w);
    assert_saw(&[
        "Details",
        "Completeness: ",
        "Recognized: ",
        "Delivery: ",
        "Stopped: ",
        "Normalized",
        "Raw recognition",
        "Processing details",
        "App context",
        "Rewrite",
        "Attempt 1",
    ]);
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
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(5), cx))
        .unwrap();
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
    assert_saw(&[
        "WAITING FOR SERVER",
        "Recognize Locally",
        "Save Audio…",
        "Discard",
    ]);
    let id = seed_id(9201);
    click(cx, w, format!("history.pending.save.{id}"));
    assert_saw(&[PENDING_ERROR]);
    click(cx, w, format!("history.pending.discard.{id}"));
    assert_saw(&[
        "Discard this recording?",
        "Its audio is deleted and it will not be recognized.",
    ]);
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
    assert_saw(&[
        "History could not be read. Your saved text has not been deleted. Try again.",
        "Retry",
    ]);
    click(cx, _w, "history.retry".into());
    assert!(!saw("History could not be read."));
    assert_saw(&["TODAY"]);
}

// parity: HIST-014 HIST-011
#[flow_ui::gpui::test]
async fn cmd_f_opens_search_and_escape_closes_it(cx: &mut TestAppContext) {
    let w = open(cx);
    cx.update_window(w.into(), |_, win, cx| win.press("cmd-f", cx))
        .unwrap();
    frame(cx, w);
    w.update(cx, |t, _, _| assert!(t.searching)).unwrap();
    cx.update_window(w.into(), |_, win, cx| win.press("escape", cx))
        .unwrap();
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
    cx.update(|cx| {
        cx.global::<Core>()
            .db
            .as_ref()
            .unwrap()
            .conn
            .execute_batch("DELETE FROM transcriptions")
            .unwrap()
    });
}

// parity: HIST-004 HIST-005 HIST-006
#[flow_ui::gpui::test]
async fn leaving_clears_detail_and_coming_back_reloads(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    session(cx);
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::History));
    let w = cx.add_window(|w, cx| HistoryPage::new(w, cx));
    frame(cx, w);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx))
        .unwrap();
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::Insights));
    w.update(cx, |t, _, _| assert!(t.model.detail_id.is_none()))
        .unwrap();
    delete_all(cx);
    cx.update(|cx| crate::shell::update_session(cx, |s| s.selection = Page::History));
    frame(cx, w);
    w.update(cx, |t, _, _| assert!(t.model.entries.is_empty()))
        .unwrap();
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
    cx.update_window(w.into(), |_, win, cx| win.input("zzz", cx))
        .unwrap();
    cx.executor().advance_clock(Duration::from_millis(100));
    cx.update_window(w.into(), |_, win, cx| win.press("backspace", cx))
        .unwrap();
    cx.update_window(w.into(), |_, win, cx| win.press("backspace", cx))
        .unwrap();
    cx.update_window(w.into(), |_, win, cx| win.press("backspace", cx))
        .unwrap();
    cx.update_window(w.into(), |_, win, cx| win.input("kickoff", cx))
        .unwrap();
    cx.executor().advance_clock(Duration::from_millis(300));
    frame(cx, w);
    w.update(cx, |t, _, _| {
        assert_eq!(t.model.search_text, "kickoff");
        assert!(
            !t.model.entries.is_empty()
                && t.model
                    .entries
                    .iter()
                    .all(|e| e.text.to_lowercase().contains("kickoff"))
        );
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
    let height = cx
        .update_window(w.into(), |_, win, _| {
            win.find("history.sentinel.older").bounds().size.height
        })
        .unwrap();
    assert_eq!(height, px(44.));
    // A pinned row that moved 100 down shifts the scroll by the same amount.
    let id = w
        .update(cx, |t, _, _| t.model.entries[0].id.clone())
        .unwrap();
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
    let e = w
        .update(cx, |t, _, _| {
            t.model
                .entries
                .iter()
                .find(|e| !e.is_attempting())
                .unwrap()
                .clone()
        })
        .unwrap();
    w.update(cx, |t, _, cx| t.ask_delete(&e, cx)).unwrap();
    frame(cx, w);
    cx.update(|cx| {
        cx.global::<Core>()
            .db
            .as_ref()
            .unwrap()
            .conn
            .execute_batch("PRAGMA query_only=ON")
            .unwrap()
    });
    click(cx, w, "history.deleteDialog.confirm".into());
    assert_saw(&[ACTION_ERROR]);
    cx.update(|cx| {
        cx.global::<Core>()
            .db
            .as_ref()
            .unwrap()
            .conn
            .execute_batch("PRAGMA query_only=OFF")
            .unwrap()
    });
    assert!(exists(cx, e.id));
}

// parity: HIST-038
#[flow_ui::gpui::test]
async fn only_rows_arriving_later_fade(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = w
        .update(cx, |t, _, _| t.model.entries[0].id.clone())
        .unwrap();
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
    let (id, text) = w
        .update(cx, |t, _, _| {
            (
                t.model.entries[0].id.clone(),
                t.model.entries[0].text.clone(),
            )
        })
        .unwrap();
    let b = cx
        .update_window(w.into(), |_, win, _| {
            win.find(SharedString::from(format!("history.text.{id}")))
                .bounds()
        })
        .unwrap();
    let y = b.top() + px(8.);
    cx.update_window(w.into(), |_, win, cx| {
        win.drag(point(b.left(), y), point(b.left() + px(60.), y), cx)
    })
    .unwrap();
    frame(cx, w);
    cx.update_window(w.into(), |_, win, cx| win.press("cmd-c", cx))
        .unwrap();
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
    let id = w
        .update(cx, |t, _, _| t.model.entries[0].id.clone())
        .unwrap();
    w.update(cx, |t, win, cx| t.focus.focus(win, cx)).unwrap();
    let copy = SharedString::from(format!("history.copy.{id}"));
    for _ in 0..4 {
        cx.update_window(w.into(), |_, win, cx| win.press("tab", cx))
            .unwrap();
        if cx
            .update_window(w.into(), |_, win, _| win.find(copy.clone()).focused())
            .unwrap()
            == Some(true)
        {
            break;
        }
    }
    assert_eq!(
        cx.update_window(w.into(), |_, win, _| win.find(copy.clone()).focused())
            .unwrap(),
        Some(true)
    );
    // `in_focus` shows the actions on exactly this condition.
    let within = w
        .update(cx, |t, win, cx| {
            t.action_focus.borrow()[&id].contains_focused(win, cx)
        })
        .unwrap();
    assert!(within);
    // Shift-Tab goes back.
    cx.update_window(w.into(), |_, win, cx| win.press("shift-tab", cx))
        .unwrap();
    assert_ne!(
        cx.update_window(w.into(), |_, win, _| win.find(copy).focused())
            .unwrap(),
        Some(true)
    );
}

// parity: HIST-049 HIST-052 HIST-053
#[flow_ui::gpui::test]
async fn row_icon_buttons_are_28_and_insert_follows_delivery(cx: &mut TestAppContext) {
    let w = open(cx);
    let entries = w.update(cx, |t, _, _| t.model.entries.clone()).unwrap();
    let id = &entries[0].id;
    let copy = cx
        .update_window(w.into(), |_, win, _| {
            win.find(SharedString::from(format!("history.copy.{id}")))
        })
        .unwrap();
    assert_eq!(copy.bounds().size, size(px(28.), px(28.)));
    assert_eq!(copy.label().map(|l| l.to_string()).as_deref(), Some("Copy"));
    let confirmed = entries.iter().find(|e| e.is_confirmed()).unwrap();
    let insert = cx
        .update_window(w.into(), |_, win, _| {
            win.find(SharedString::from(format!(
                "history.insert.{}",
                confirmed.id
            )))
        })
        .unwrap();
    assert_eq!(
        insert.label().map(|l| l.to_string()).as_deref(),
        Some("Insert again")
    );
    // Attempting rows and a busy coordinator disable it.
    w.update(cx, |t, _, cx| {
        t.model.entries[0].delivery_state = "attempting".into();
        cx.notify();
    })
    .unwrap();
    frame(cx, w);
    let off = cx
        .update_window(w.into(), |_, win, _| {
            win.find(SharedString::from(format!("history.insert.{id}")))
                .disabled()
        })
        .unwrap();
    assert_eq!(off, Some(true));
}

// parity: HIST-056 HIST-057
#[flow_ui::gpui::test]
async fn the_row_menu_runs_the_row_actions(cx: &mut TestAppContext) {
    let w = open(cx);
    let e = w.update(cx, |t, _, _| t.model.entries[0].clone()).unwrap();
    let target = SharedString::from(format!("history.text.{}", e.id));
    let menu = |cx: &mut TestAppContext, item: u64| {
        cx.update_window(w.into(), |_, win, cx| win.right_click(target.clone(), cx))
            .unwrap();
        frame(cx, w);
        cx.update_window(w.into(), |_, win, cx| {
            win.click(ElementId::Integer(item), cx)
        })
        .unwrap();
        frame(cx, w);
    };
    menu(cx, 0);
    assert_eq!(
        cx.read_from_clipboard().and_then(|c| c.text()),
        Some(e.text.clone())
    );
    // Copy from the menu shows no check; Swift's check is only on the row button.
    w.update(cx, |t, _, _| assert!(t.copied.is_empty()))
        .unwrap();
    menu(cx, 2);
    w.update(cx, |t, _, _| {
        assert_eq!(t.model.detail_id.as_deref(), Some(e.id.as_str()))
    })
    .unwrap();
}

// parity: HIST-055 HIST-059
#[flow_ui::gpui::test]
async fn more_button_and_menu_state_follow_the_row(cx: &mut TestAppContext) {
    let w = open(cx);
    let id = w
        .update(cx, |t, _, _| t.model.entries[0].id.clone())
        .unwrap();
    let more = SharedString::from(format!("history.more.{id}"));
    let b = cx
        .update_window(w.into(), |_, win, _| win.find(more).bounds().size)
        .unwrap();
    assert_eq!(b, size(px(28.), px(28.)));
    let mut e = w
        .update(cx, |t, _, _| {
            t.model
                .entries
                .iter()
                .find(|e| e.is_confirmed())
                .unwrap()
                .clone()
        })
        .unwrap();
    assert_eq!(
        row_menu_state(&e, false, false),
        ("Insert again…", false, false)
    );
    assert_eq!(
        row_menu_state(&e, true, true),
        ("Insert again…", true, true)
    );
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
    w.update(cx, |t, _, _| {
        assert!(t.model.detail_error.is_none() && t.model.envelope.is_some())
    })
    .unwrap();
    // Removed underneath: the sheet closes and the row goes.
    cx.update(|cx| {
        let db = cx.global::<Core>().db.as_ref().unwrap();
        db.conn
            .execute("DELETE FROM transcriptions WHERE id=?", [&id])
            .unwrap();
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
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx))
        .unwrap();
    frame(cx, w);
    click(cx, w, "history.detail.stage.assembled".into());
    let assembled = w
        .update(cx, |t, _, _| {
            t.model.envelope.as_ref().unwrap().detail.as_ref().unwrap()["assembledText"]
                .as_str()
                .unwrap()
                .to_string()
        })
        .unwrap();
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
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx))
        .unwrap();
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
    assert_saw(&[
        n,
        "Rewrite used on-screen text you did not say.",
        "Input snapshot",
    ]);
    assert_eq!(
        rewrite_notice("attempt_limit"),
        "This dictation already has ten rewrite attempts."
    );
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
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx))
        .unwrap();
    frame(cx, w);
    assert_saw(&[
        "Saved text",
        "The faithful transcript.",
        "Current rewrite (Polished)",
        "AI-generated rewrite, not the transcript.",
        "Retry",
        "Mode",
    ]);
    let text = w
        .update(cx, |t, _, _| {
            t.model.envelope.as_ref().unwrap().entry.text.clone()
        })
        .unwrap();
    let h = cx
        .update_window(w.into(), |_, win, _| {
            win.find("history.detail.copy.saved").bounds().size.height
        })
        .unwrap();
    assert_eq!(h, px(24.));
    cx.update_window(w.into(), |_, win, cx| {
        win.scroll(
            "history.detail.scroll",
            ScrollDelta::Pixels(point(px(0.), px(-500.))),
            cx,
        )
    })
    .unwrap();
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
    cx.update_window(w.into(), |_, win, cx| {
        win.scroll(
            "history.detail.scroll",
            ScrollDelta::Pixels(point(px(0.), px(-2000.))),
            cx,
        )
    })
    .unwrap();
    frame(cx, w);
    let out = w
        .update(cx, |t, _, _| {
            t.model
                .attempts
                .iter()
                .find(|a| a.ordinal == 2)
                .unwrap()
                .output_text
                .clone()
                .unwrap()
        })
        .unwrap();
    click(cx, w, "history.detail.attempt.copy.2".into());
    assert_eq!(cx.read_from_clipboard().and_then(|c| c.text()), Some(out));
    // The mode survives another detail, and the popup is its native 99 by 24 in a 180 frame.
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(2), cx))
        .unwrap();
    w.update(cx, |t, _, _| {
        assert_eq!(t.model.rewrite_mode, RewriteMode::Concise)
    })
    .unwrap();
    frame(cx, w);
    assert_saw(&["Concise", "Rewrite"]);
    let popup = cx
        .update_window(w.into(), |_, win, _| {
            win.find("history.detail.rewrite.mode").bounds().size
        })
        .unwrap();
    assert_eq!(popup, size(px(99.), px(24.)));
}

// parity: HIST-103 HIST-104
#[flow_ui::gpui::test]
async fn segments_are_121_by_24(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx))
        .unwrap();
    frame(cx, w);
    for id in [
        "history.detail.stage.normalized",
        "history.detail.stage.assembled",
        "history.detail.stage.raw",
    ] {
        let s = cx
            .update_window(w.into(), |_, win, _| win.find(id).bounds().size)
            .unwrap();
        assert_eq!(s, size(px(121.), px(24.)), "{id}");
    }
}

// parity: HIST-165
#[flow_ui::gpui::test]
async fn insert_opens_the_review_through_the_session(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    session(cx);
    let w = cx.add_window(|w, cx| HistoryPage::new(w, cx));
    frame(cx, w);
    let e = w
        .update(cx, |t, _, _| {
            t.model
                .entries
                .iter()
                .find(|e| !e.is_attempting())
                .unwrap()
                .clone()
        })
        .unwrap();
    click(cx, w, format!("history.insert.{}", e.id));
    let id = cx.update(|cx| {
        cx.global::<Session>()
            .insertion
            .entry
            .as_ref()
            .map(|r| r.id.clone())
    });
    assert_eq!(id, Some(e.id));
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
    cx.update_window(window.into(), |_, w, cx| w.render_frame(cx))
        .unwrap();
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
}

// parity: INS-002
#[flow_ui::gpui::test]
async fn insights_are_unavailable_until_the_stores_exist(cx: &mut TestAppContext) {
    unavailable(cx, crate::pages::Page::Insights);
    assert_saw(&["Insights unavailable", crate::shell::SETUP_STARTING]);
}

// parity: DICT-005
#[flow_ui::gpui::test]
async fn the_dictionary_is_unavailable_until_the_stores_exist(cx: &mut TestAppContext) {
    unavailable(cx, crate::pages::Page::Dictionary);
    assert_saw(&["Dictionary unavailable", crate::shell::SETUP_STARTING]);
}

// parity: HIST-163 HIST-164 HIST-166 HIST-173
#[flow_ui::gpui::test]
async fn review_warns_and_cancel_or_timeout_keep_the_text(cx: &mut TestAppContext) {
    use crate::insertion::{ReviewEntry, arm_selection, begin_review};
    use crate::shell::{Session, ensure_session, update_session};
    boot(cx, Mode::Light);
    let entry = |quality| ReviewEntry {
        id: seed_id(20),
        text: "Saved words".into(),
        quality,
        delivery: Delivery::None,
    };
    cx.update(|cx| {
        ensure_session(cx);
        cx.global_mut::<Core>().services = Box::new(flow_platform::Fake::default());
        assert!(begin_review(entry(Quality::Incomplete), cx));
    });
    let window = shell(cx);
    shell_frame(cx, window);
    assert_saw(&[
        "Review before inserting",
        "Saved words",
        "This transcription is incomplete. Review the text before inserting.",
    ]);
    cx.update(|cx| {
        update_session(cx, |s| {
            s.insertion.entry.as_mut().unwrap().quality = Quality::DurationLimited
        })
    });
    shell_frame(cx, window);
    assert_saw(&["Recording stopped at 180 seconds. The ending may be missing."]);

    cx.update_window(window.into(), |_, w, cx| w.click("insertion.cancel", cx))
        .unwrap();
    cx.run_until_parked();
    let status = |cx: &mut TestAppContext| {
        cx.update(|cx| {
            cx.global::<Session>()
                .dictation
                .as_ref()
                .unwrap()
                .status
                .clone()
        })
    };
    assert_eq!(status(cx), "Insertion cancelled. The text remains saved.");

    cx.update(|cx| {
        assert!(begin_review(entry(Quality::Complete), cx));
        arm_selection(cx);
    });
    cx.executor()
        .advance_clock(std::time::Duration::from_secs(61));
    cx.run_until_parked();
    assert_eq!(status(cx), "Selection expired. Your text remains saved.");
}

fn first_id(cx: &mut TestAppContext, w: WindowHandle<HistoryPage>, n: usize) -> String {
    w.update(cx, |t, _, _| t.model.entries[n].id.clone())
        .unwrap()
}

// parity: HIST-040
#[flow_ui::gpui::test]
async fn hovering_a_row_fills_it_and_leaving_clears_it(cx: &mut TestAppContext) {
    let w = open(cx);
    let (a, b) = (first_id(cx, w, 0), first_id(cx, w, 1));
    let canvas = cx.update(|cx| pal(cx).canvas);
    let fill = |cx: &mut TestAppContext, id: &str| {
        let id = id.to_string();
        w.update(cx, move |t, _, cx| t.row_fill(&id, &pal(cx)))
            .unwrap()
    };
    assert_eq!(fill(cx, &a), gpui::transparent_black());
    cx.update_window(w.into(), |_, win, cx| {
        win.hover(SharedString::from(format!("history.text.{a}")), cx)
    })
    .unwrap();
    frame(cx, w);
    assert_eq!(fill(cx, &a), canvas);
    assert_eq!(fill(cx, &b), gpui::transparent_black());
    cx.update_window(w.into(), |_, win, cx| {
        win.hover(SharedString::from(format!("history.text.{b}")), cx)
    })
    .unwrap();
    frame(cx, w);
    assert_eq!(fill(cx, &a), gpui::transparent_black());
    assert_eq!(fill(cx, &b), canvas);
}

// parity: HIST-064
#[flow_ui::gpui::test]
async fn deleting_while_full_reports_whether_there_is_room(cx: &mut TestAppContext) {
    let w = open(cx);
    session(cx);
    let status = |cx: &mut TestAppContext| {
        cx.update(|cx| {
            cx.global::<Session>()
                .dictation
                .as_ref()
                .map(|d| (d.capacity_blocked, d.status.clone()))
                .unwrap()
        })
    };
    let remove_one = |cx: &mut TestAppContext, full: bool| {
        cx.update(|cx| {
            crate::shell::update_session(cx, |s| {
                s.dictation.as_mut().unwrap().capacity_blocked = true
            });
            let rows = if full { MAX_ROWS + 5 } else { 1 };
            cx.global::<Core>()
                .db
                .as_ref()
                .unwrap()
                .conn
                .execute("UPDATE history_usage SET row_count=?", [rows])
                .unwrap();
        });
        w.update(cx, |t, _, cx| {
            let e = t
                .model
                .entries
                .iter()
                .find(|e| !e.is_attempting())
                .unwrap()
                .clone();
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
    w.update(cx, |t, _, cx| t.note_clock(was + DAY, false, cx))
        .unwrap();
    assert_eq!(
        w.update(cx, |t, _, _| t.now).unwrap(),
        was,
        "missed while away"
    );
    w.update(cx, |t, _, cx| t.note_clock(was + DAY, true, cx))
        .unwrap();
    assert_eq!(
        w.update(cx, |t, _, _| t.now).unwrap(),
        was,
        "the same day, even once shown"
    );
    w.update(cx, |t, _, cx| t.note_clock(was + 2 * DAY, true, cx))
        .unwrap();
    assert_eq!(w.update(cx, |t, _, _| t.now).unwrap(), was + 2 * DAY);
}

// parity: HIST-183
#[flow_ui::gpui::test]
async fn a_refresh_starts_an_open_detail_over(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx))
        .unwrap();
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
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    cx.update(|cx| {
        let core = cx.global_mut::<Core>();
        core.prefs.set("rewriteEnabled", true);
        core.prefs
            .set("rewriteEndpoint", format!("http://127.0.0.1:{port}"));
        let db = core.db.as_ref().unwrap();
        db.conn
            .execute(
                "DELETE FROM rewrite_attempts WHERE transcription_id=?",
                [&id],
            )
            .unwrap();
        db.conn
            .execute(
                "UPDATE transcriptions SET quality='complete' WHERE id=?",
                [&id],
            )
            .unwrap();
    });
    w.update(cx, |t, _, cx| t.show_detail(&id, cx)).unwrap();
    frame(cx, w);
    click(cx, w, "history.detail.rewrite.retry".into());
    cx.run_until_parked();
    w.update(cx, |t, _, _| {
        assert_eq!(
            t.model.rewrite_notice.as_deref(),
            Some("Rewrite server unreachable.")
        );
        assert_eq!(
            t.model
                .attempts
                .iter()
                .map(|a| a.state.as_str())
                .collect::<Vec<_>>(),
            ["failed"]
        );
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
        db.conn
            .execute(
                "DELETE FROM rewrite_attempts WHERE transcription_id=?",
                [&id],
            )
            .unwrap();
        db.conn
            .execute(
                "UPDATE transcriptions SET quality='complete' WHERE id=?",
                [&id],
            )
            .unwrap();
    });
    w.update(cx, |t, _, cx| t.show_detail(&id, cx)).unwrap();
    frame(cx, w);
    let retry = cx
        .update_window(w.into(), |_, win, _| {
            win.find("history.detail.rewrite.retry").disabled()
        })
        .unwrap();
    assert_ne!(retry, Some(true));
    // A real notice first: enabled, with no endpoint, the click is refused.
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("rewriteEnabled", true));
    click(cx, w, "history.detail.rewrite.retry".into());
    w.update(cx, |t, _, _| {
        assert_eq!(
            t.model.rewrite_notice.as_deref(),
            Some("Rewriting skipped: the endpoint is invalid.")
        )
    })
    .unwrap();
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
    cx.update_window(w.into(), |_, win, _| win.find(id).bounds())
        .unwrap()
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
    let (row, retry) = (
        bounds(cx, w, "history.errorRow"),
        bounds(cx, w, "history.retry"),
    );
    assert_eq!(retry.origin.y - row.origin.y, px(20.));
}

// parity: HIST-098
#[flow_ui::gpui::test]
async fn the_status_block_is_five_lines_at_its_pitch(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx))
        .unwrap();
    frame(cx, w);
    // Headless Figtree 13 is a 14 line; on screen `Txt` gives 16 and the pitch matches Swift's.
    assert_eq!(
        bounds(cx, w, "history.detail.status").size.height,
        px(5. * 14. + 4. * 3.)
    );
}

// parity: HIST-110 HIST-123
#[flow_ui::gpui::test]
async fn processing_lines_and_hashes_keep_their_spacing(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx))
        .unwrap();
    frame(cx, w);
    click(cx, w, "history.detail.processing".into());
    let (list, hashes) = (
        bounds(cx, w, "history.detail.processing.lines"),
        bounds(cx, w, "history.detail.hashes"),
    );
    assert_eq!(hashes.origin.y - list.bottom(), px(8.));
    let d = w
        .update(cx, |t, _, _| {
            t.model.envelope.as_ref().unwrap().detail.clone().unwrap()
        })
        .unwrap();
    let items = processing_lines(&d);
    let (a, b) = items
        .windows(2)
        .find_map(|w| match (&w[0], &w[1]) {
            (Line::Meta(a, _), Line::Meta(b, _)) => Some((a.clone(), b.clone())),
            _ => None,
        })
        .unwrap();
    let (first, second) = (
        bounds(cx, w, &format!("history.meta.{a}")),
        bounds(cx, w, &format!("history.meta.{b}")),
    );
    assert_eq!(second.origin.y - first.bottom(), px(8.));
    // Two headless Figtree 13 lines, spacing 2.
    assert_eq!(first.size.height, px(14. + 2. + 14.));
}

// parity: HIST-129
#[flow_ui::gpui::test]
async fn context_disclosures_are_8_apart(cx: &mut TestAppContext) {
    let w = open(cx);
    w.update(cx, |t, _, cx| t.show_detail(&seed_id(1), cx))
        .unwrap();
    frame(cx, w);
    let (before, snapshot) = (
        bounds(cx, w, "history.detail.context.before"),
        bounds(cx, w, "history.detail.context.snapshot"),
    );
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
