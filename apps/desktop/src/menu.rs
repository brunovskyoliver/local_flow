//! The application menu, its shortcuts and the quit sequence.
use crate::core::Core;
use crate::pages::Page;
use crate::shell::{self, Alert, update_session};
use flow_ui::prelude::*;

actions!(localflow, [OpenSettings, Quit, CheckForUpdates, CancelSession, Hide, HideOthers, ShowAll]);

/// Registers actions, shortcuts and the menu bar. Call once at launch.
pub fn init(cx: &mut App) {
    shell::ensure_session(cx);
    cx.bind_keys([
        KeyBinding::new("cmd-,", OpenSettings, None),
        KeyBinding::new("cmd-q", Quit, None),
        KeyBinding::new("cmd-h", Hide, None),
        KeyBinding::new("alt-cmd-h", HideOthers, None),
        KeyBinding::new("escape", CancelSession, Some("Shell")),
    ]);
    cx.on_action(|_: &OpenSettings, cx| shell::open(Some(Page::Settings), cx));
    cx.on_action(|_: &Quit, cx| quit(cx));
    cx.on_action(|_: &CheckForUpdates, cx| {
        let _ = cx.global::<Core>().services.check_for_updates();
    });
    cx.on_action(|_: &Hide, cx| cx.hide());
    cx.on_action(|_: &HideOthers, cx| cx.hide_other_apps());
    cx.on_action(|_: &ShowAll, cx| cx.unhide_other_apps());
    let can_check = cx.global::<Core>().services.can_check_for_updates();
    cx.set_menus(app_menus(can_check));
}

/// Swift customizes three app-menu groups; the others are SwiftUI's defaults.
pub fn app_menus(can_check: bool) -> Vec<Menu> {
    let updates = MenuItem::action("Check for Updates…", CheckForUpdates).disabled(!can_check);
    vec![
        Menu {
            name: "LocalFlow".into(),
            items: vec![
                updates,
                MenuItem::separator(),
                MenuItem::action("Settings…", OpenSettings),
                MenuItem::separator(),
                MenuItem::os_submenu("Services", SystemMenuType::Services),
                MenuItem::separator(),
                MenuItem::action("Hide LocalFlow", Hide),
                MenuItem::action("Hide Others", HideOthers),
                MenuItem::action("Show All", ShowAll),
                MenuItem::separator(),
                MenuItem::action("Quit LocalFlow", Quit),
            ],
            disabled: false,
        },
    ]
}

/// `AppServices.quit()` up to the teardown.
pub fn quit(cx: &mut App) {
    let s = cx.global::<shell::Session>();
    if s.quitting {
        return;
    }
    let (model_command, installing) = (s.model_command, s.installing);
    let busy = s.dictation.as_ref().is_some_and(|d| d.busy);
    let unsaved = s.dictation.as_ref().is_some_and(|d| d.unsaved.is_some());
    if model_command {
        update_session(cx, |s| s.setup_status = "Wait for the model operation to finish, then quit again.".into());
    } else if installing {
        update_session(cx, |s| {
            s.installing = false;
            s.setup_status = "Cancelling installation. Quit again after cleanup finishes.".into();
        });
    } else if busy {
        shell::cancel_dictation(cx);
        update_session(cx, |s| s.setup_status = "Cancelling. Quit again after work stops.".into());
    } else if unsaved {
        shell::open(None, cx);
        if cx.global::<shell::Session>().alert.is_none() {
            shell::show_alert(Alert::QuitUnsaved, cx);
        }
    } else {
        finish_quit(cx);
    }
}

/// The teardown, in Swift's order. Capture and shortcuts don't exist yet; the services answer for models and the recorder.
pub fn finish_quit(cx: &mut App) {
    update_session(cx, |s| s.quitting = true);
    // Deferred: a Cmd-Q runs inside the window's own dispatch, and the flush needs that window.
    cx.defer(|cx| {
        shell::flush_notes(cx);
        if cx.global::<shell::Session>().meeting.as_ref().is_some_and(|m| m.state.is_active()) {
            let _ = cx.global::<Core>().services.session_command(flow_platform::SessionCommand::StopMeeting);
        }
        if !cx.global::<Core>().services.shutdown_models_if_idle() {
            update_session(cx, |s| {
                s.quitting = false;
                s.setup_status = "Model shutdown is still busy. Wait for it to finish before quitting.".into();
            });
            return;
        }
        if !cx.global::<Core>().services.close_recorder() {
            update_session(cx, |s| s.setup_status = "Measurement export is incomplete. Its completion record contains the loss status.".into());
        }
        update_session(cx, |s| s.ready_to_terminate = true);
        cx.quit();
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::{Dictation, Session, Shell};
    use crate::testing::boot;
    use flow_ui::test::{TestAppContext, TestWindowExt};

    fn open_shell(cx: &mut TestAppContext) -> WindowHandle<Shell> {
        cx.update(|cx| {
            init(cx);
            cx.global_mut::<Core>().prefs.set("setupVersion", 1);
        });
        let window = cx.add_window(|w, cx| Shell::new(w, cx));
        cx.run_until_parked();
        cx.update(|cx| update_session(cx, |s| s.window = Some(window.into())));
        window
    }

    fn actions(menus: &[Menu]) -> Vec<(String, bool)> {
        menus[0].items.iter().filter_map(|i| match i {
            MenuItem::Action { name, disabled, .. } => Some((name.to_string(), *disabled)),
            _ => None,
        }).collect()
    }

    // parity: SHELL-016 SHELL-018 SHELL-019 SHELL-021 SHELL-024
    #[test]
    fn app_menu_has_swifts_groups() {
        let (off, on) = (actions(&app_menus(false)), actions(&app_menus(true)));
        assert_eq!(off[0], ("Check for Updates…".to_string(), true));
        assert_eq!(on[0], ("Check for Updates…".to_string(), false));
        assert_eq!(off[1], ("Settings…".to_string(), false));
        assert_eq!(off.last().unwrap(), &("Quit LocalFlow".to_string(), false));
        // Only the app menu is customized; the rest stays the system's.
        assert_eq!(app_menus(false).len(), 1);
    }

    // parity: SHELL-020
    #[flow_ui::gpui::test]
    async fn command_comma_opens_settings(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let window = open_shell(cx);
        cx.update_window(window.into(), |_, w, cx| w.press("cmd-,", cx)).unwrap();
        cx.run_until_parked();
        cx.update(|cx| assert_eq!(cx.global::<Session>().selection, Page::Settings));
    }

    // parity: SHELL-128
    #[flow_ui::gpui::test]
    async fn quit_stops_an_active_meeting_then_terminates(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let commands = std::rc::Rc::default();
        cx.update(|cx| {
            let fake = flow_platform::Fake { commands: std::rc::Rc::clone(&commands), ..Default::default() };
            fake.session_ok.set(true);
            cx.global_mut::<Core>().services = Box::new(fake);
        });
        let _window = open_shell(cx);
        cx.update(|cx| update_session(cx, |s| s.meeting = Some(shell::MeetingStatus { id: "m".into(), title: None, state: shell::MeetingState::Recording, elapsed_ms: 0 })));
        cx.update(quit);
        cx.update(|cx| assert!(cx.global::<Session>().quitting));
        cx.run_until_parked();
        assert_eq!(*commands.borrow(), vec![flow_platform::SessionCommand::StopMeeting]);
        cx.update(|cx| assert!(cx.global::<Session>().ready_to_terminate));
    }

    // parity: SHELL-129
    #[flow_ui::gpui::test]
    async fn busy_model_shutdown_refuses_the_quit(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            let fake = flow_platform::Fake::default();
            fake.models_busy.set(true);
            cx.global_mut::<Core>().services = Box::new(fake);
        });
        let _window = open_shell(cx);
        cx.update(quit);
        cx.run_until_parked();
        cx.update(|cx| {
            let s = cx.global::<Session>();
            assert_eq!((s.quitting, s.ready_to_terminate), (false, false));
            assert_eq!(s.setup_status, "Model shutdown is still busy. Wait for it to finish before quitting.");
        });
    }

    // parity: SHELL-130
    #[flow_ui::gpui::test]
    async fn incomplete_export_reports_and_quits_anyway(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            let fake = flow_platform::Fake::default();
            fake.export_incomplete.set(true);
            cx.global_mut::<Core>().services = Box::new(fake);
        });
        let _window = open_shell(cx);
        cx.update(quit);
        cx.run_until_parked();
        cx.update(|cx| {
            let s = cx.global::<Session>();
            assert_eq!(s.setup_status, "Measurement export is incomplete. Its completion record contains the loss status.");
            assert!(s.ready_to_terminate);
        });
    }

    // parity: SHELL-121 SHELL-122 SHELL-123 SHELL-124 SHELL-022 MENU-030 SHELL-125 SHELL-126 SHELL-127
    #[flow_ui::gpui::test]
    async fn quit_refuses_in_swifts_order(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        let _window = open_shell(cx);
        let status = |cx: &mut TestAppContext| cx.update(|cx| cx.global::<Session>().setup_status.clone());
        cx.update(|cx| update_session(cx, |s| {
            s.model_command = true;
            s.installing = true;
            s.dictation = Some(Dictation { busy: true, unsaved: Some("x".into()), ..Default::default() });
        }));
        cx.update(quit);
        assert_eq!(status(cx), "Wait for the model operation to finish, then quit again.");
        cx.update(|cx| update_session(cx, |s| s.model_command = false));
        cx.update(quit);
        assert_eq!(status(cx), "Cancelling installation. Quit again after cleanup finishes.");
        cx.update(quit);
        assert_eq!(status(cx), "Cancelling. Quit again after work stops.");
        cx.update(|cx| update_session(cx, |s| s.dictation.as_mut().unwrap().busy = false));
        cx.update(quit);
        cx.run_until_parked();
        cx.update(|cx| assert_eq!(cx.global::<Session>().alert, Some(Alert::QuitUnsaved)));
        let prompt = cx.pending_prompt().expect("Swift's quit alert is native");
        assert_eq!(prompt, ("Quit with unsaved text?".to_string(), "This text will be lost. Copy it or retry saving before quitting.".to_string()));
        cx.simulate_prompt_answer("Keep Open");
        cx.run_until_parked();
        cx.update(|cx| assert!(!cx.global::<Session>().ready_to_terminate));
        cx.update(|cx| assert_eq!(cx.global::<Session>().alert, None));
        cx.update(quit);
        cx.run_until_parked();
        cx.simulate_prompt_answer("Quit and Lose Text");
        cx.run_until_parked();
        cx.update(|cx| assert!(cx.global::<Session>().ready_to_terminate));
        // A second request after teardown started is a no-op.
        cx.update(quit);
        cx.update(|cx| assert!(cx.global::<Session>().quitting));
    }
}
