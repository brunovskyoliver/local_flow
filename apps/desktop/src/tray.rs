//! The menu bar extra. The glyph and items are plain data, so they're tested without an OS tray;
//! `install` builds them with the `tray-icon` crate, which has no headless mode.
use crate::core::Core;
use crate::pages::Page;
use crate::shell::{self, MeetingState, Session};
use flow_platform::SessionCommand;
use flow_ui::prelude::*;

/// `MenuBarGlyph.resolve`.
pub fn glyph(needs_attention: bool, meeting: Option<MeetingState>) -> (&'static str, &'static str) {
    match meeting {
        Some(MeetingState::Recording) => ("record.circle.fill", "LocalFlow: meeting recording"),
        Some(MeetingState::Paused) => ("pause.circle.fill", "LocalFlow: meeting paused"),
        _ if needs_attention => ("exclamationmark.circle", "LocalFlow needs attention"),
        _ => ("waveform", "LocalFlow"),
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Command {
    Open,
    Settings,
    Cancel,
    Pause,
    Resume,
    Stop,
    Start,
    Quit,
}

#[derive(Clone, PartialEq, Debug)]
pub enum Entry {
    /// Non-interactive line, optionally with a symbol.
    Text(String, Option<&'static str>),
    Separator,
    Item { title: &'static str, command: Command, enabled: bool, shortcut: Option<&'static str> },
}

fn item(title: &'static str, command: Command) -> Entry {
    Entry::Item { title, command, enabled: true, shortcut: None }
}

/// `LocalFlowMenu`.
pub fn entries(s: &Session, readiness: String) -> Vec<Entry> {
    let mut v = vec![Entry::Text(readiness, None)];
    if s.needs_attention() {
        v.push(Entry::Text("Review needed".into(), Some("exclamationmark.circle")));
    }
    v.push(Entry::Separator);
    v.push(item("Open LocalFlow", Command::Open));
    v.push(Entry::Item { title: "Settings…", command: Command::Settings, enabled: true, shortcut: Some("cmd-,") });
    if s.dictation.as_ref().is_some_and(|d| d.busy) {
        v.push(item("Cancel", Command::Cancel));
    }
    if s.meetings_available {
        v.push(Entry::Separator);
        match s.meeting.as_ref().map(|m| m.state) {
            Some(MeetingState::Recording) => {
                v.push(item("Pause Meeting", Command::Pause));
                v.push(item("Stop Meeting", Command::Stop));
            }
            Some(MeetingState::Paused) => {
                v.push(item("Resume Meeting", Command::Resume));
                v.push(item("Stop Meeting", Command::Stop));
            }
            Some(state @ (MeetingState::Preparing | MeetingState::Created | MeetingState::Finalizing)) => {
                v.push(Entry::Text(format!("Meeting {}…", state.badge_text().to_lowercase()), None));
            }
            _ => v.push(Entry::Item { title: "Start Meeting", command: Command::Start, enabled: s.can_start_meeting, shortcut: None }),
        }
    }
    v.push(Entry::Separator);
    v.push(Entry::Item { title: "Quit LocalFlow", command: Command::Quit, enabled: true, shortcut: Some("cmd-q") });
    v
}

/// Runs a menu item. Meeting commands go through `Services`, unavailable until capture exists.
pub fn run(command: Command, cx: &mut App) {
    let session = |command, cx: &mut App| {
        let _ = cx.global::<Core>().services.session_command(command);
    };
    match command {
        Command::Open => shell::open(None, cx),
        Command::Settings => shell::open(Some(Page::Settings), cx),
        Command::Cancel => shell::cancel_dictation(cx),
        Command::Pause => session(SessionCommand::PauseMeeting, cx),
        Command::Resume => session(SessionCommand::ResumeMeeting, cx),
        Command::Stop => session(SessionCommand::StopMeeting, cx),
        Command::Start => {
            shell::open(Some(Page::Meetings), cx);
            if cx.global::<Session>().can_start_meeting {
                session(SessionCommand::StartMeeting, cx);
            }
        }
        Command::Quit => crate::menu::quit(cx),
    }
}

/// Current entries with the readiness copy the `Core` preferences imply.
pub fn current(cx: &App) -> (Vec<Entry>, (&'static str, &'static str)) {
    let s = cx.global::<Session>();
    (entries(s, shell::readiness(cx)), glyph(s.needs_attention(), s.meeting.as_ref().map(|m| m.state)))
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
mod native {
    use super::*;
    use std::time::Duration;
    use tray_icon::menu::{Icon as MenuIcon, IconMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, accelerator::Accelerator};
    use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

    struct Tray {
        icon: TrayIcon,
        shown: (Vec<Entry>, (&'static str, &'static str)),
        ids: Vec<(tray_icon::menu::MenuId, Command)>,
    }
    impl Global for Tray {}

    /// Lucide glyph rasterized through GPUI's SVG renderer; black alpha for macOS's template mode.
    fn rgba(symbol: &str, points: f32, cx: &App) -> Option<(Vec<u8>, u32, u32)> {
        let path = format!("flow-icons/{}.svg", flow_ui::icons::lucide(symbol));
        let bytes = cx.asset_source().load(&path).ok().flatten()?;
        let image = cx.svg_renderer().render_single_frame(&bytes, points / 24. * 2.).ok()?;
        let s = image.size(0);
        let mut raw = image.as_bytes(0)?.to_vec();
        // RenderImage frames are BGRA.
        raw.chunks_exact_mut(4).for_each(|p| p.swap(0, 2));
        Some((raw, u32::from(s.width.0 as u32), u32::from(s.height.0 as u32)))
    }

    fn menu(entries: &[Entry], cx: &App) -> (Menu, Vec<(tray_icon::menu::MenuId, Command)>) {
        let m = Menu::new();
        let mut ids = vec![];
        for e in entries {
            let _ = match e {
                Entry::Separator => m.append(&PredefinedMenuItem::separator()),
                Entry::Text(text, None) => m.append(&MenuItem::new(text, false, None)),
                Entry::Text(text, Some(symbol)) => {
                    let icon = rgba(symbol, 14., cx).and_then(|(b, w, h)| MenuIcon::from_rgba(b, w, h).ok());
                    m.append(&IconMenuItem::new(text, false, icon, None))
                }
                Entry::Item { title, command, enabled, shortcut } => {
                    let accel: Option<Accelerator> = shortcut.and_then(|k| k.replace("cmd-", "cmdorctrl+").parse().ok());
                    let item = MenuItem::new(*title, *enabled, accel);
                    ids.push((item.id().clone(), *command));
                    m.append(&item)
                }
            };
        }
        (m, ids)
    }

    fn icon(symbol: &str, cx: &App) -> Option<Icon> {
        let (b, w, h) = rgba(symbol, 18., cx)?;
        Icon::from_rgba(b, w, h).ok()
    }

    /// Adds the status item and keeps it matching `Session`.
    pub fn install(cx: &mut App) {
        let shown = current(cx);
        let (m, ids) = menu(&shown.0, cx);
        let Some(i) = icon(shown.1.0, cx) else { return };
        let Ok(tray) = TrayIconBuilder::new().with_menu(Box::new(m)).with_icon(i).with_icon_as_template(true).with_tooltip(shown.1.1).build() else { return };
        cx.set_global(Tray { icon: tray, shown, ids });
        cx.observe_global::<Session>(sync).detach();
        // ponytail: 100 ms poll; `MenuEvent::set_event_handler` plus a channel if a wakeup ever shows in the idle measurements.
        cx.spawn(async move |cx| {
            loop {
                cx.background_executor().timer(Duration::from_millis(100)).await;
                while let Ok(event) = MenuEvent::receiver().try_recv() {
                    let _ = cx.update(|cx| {
                        let found = cx.global::<Tray>().ids.iter().find(|(id, _)| *id == event.id).map(|(_, c)| *c);
                        if let Some(command) = found {
                            run(command, cx);
                        }
                    });
                }
            }
        })
        .detach();
    }

    fn sync(cx: &mut App) {
        let next = current(cx);
        if cx.global::<Tray>().shown == next {
            return;
        }
        let (m, ids) = menu(&next.0, cx);
        let i = icon(next.1.0, cx);
        let tray = cx.global_mut::<Tray>();
        tray.icon.set_menu(Some(Box::new(m)));
        let _ = tray.icon.set_icon_with_as_template(i, true);
        let _ = tray.icon.set_tooltip(Some(next.1.1));
        tray.ids = ids;
        tray.shown = next;
    }
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
pub use native::install;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::{Dictation, MeetingStatus, ensure_session, update_session};
    use crate::testing::boot;
    use flow_platform::Fake;
    use flow_ui::test::TestAppContext;

    fn titles(e: &[Entry]) -> Vec<String> {
        e.iter()
            .map(|e| match e {
                Entry::Text(t, _) => t.clone(),
                Entry::Separator => "-".into(),
                Entry::Item { title, .. } => title.to_string(),
            })
            .collect()
    }

    // parity: MENU-002 MENU-003 MENU-004 MENU-005
    #[test]
    fn glyph_prefers_meeting_over_attention() {
        assert_eq!(glyph(true, Some(MeetingState::Recording)), ("record.circle.fill", "LocalFlow: meeting recording"));
        assert_eq!(glyph(true, Some(MeetingState::Paused)), ("pause.circle.fill", "LocalFlow: meeting paused"));
        assert_eq!(glyph(true, Some(MeetingState::Finalizing)), ("exclamationmark.circle", "LocalFlow needs attention"));
        assert_eq!(glyph(false, Some(MeetingState::Preparing)), ("waveform", "LocalFlow"));
        assert_eq!(glyph(false, None), ("waveform", "LocalFlow"));
        // Every glyph has a shipped icon.
        for s in ["record.circle.fill", "pause.circle.fill", "exclamationmark.circle", "waveform"] {
            flow_ui::icons::lucide(s);
        }
    }

    fn meeting(state: MeetingState) -> Option<MeetingStatus> {
        Some(MeetingStatus { id: "m".into(), title: None, state, elapsed_ms: 0 })
    }

    // parity: ONB-019 MENU-006 MENU-008 MENU-009 MENU-011 MENU-015 MENU-025 MENU-026 MENU-028 MENU-029
    #[flow_ui::gpui::test]
    async fn idle_menu_lists_swifts_items(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            ensure_session(cx);
            let session = |cx: &mut App| entries(cx.global::<Session>(), "Ready".into());
            let e = session(cx);
            assert_eq!(e[0], Entry::Text("Ready".into(), None), "readiness line is not interactive");
            assert_eq!(e[1], Entry::Separator);
            assert_eq!(e[2], Entry::Item { title: "Open LocalFlow", command: Command::Open, enabled: true, shortcut: None });
            assert_eq!(e[3], Entry::Item { title: "Settings…", command: Command::Settings, enabled: true, shortcut: Some("cmd-,") });
            assert_eq!(e[4], Entry::Separator, "meeting group divider");
            assert_eq!(e[5], Entry::Item { title: "Start Meeting", command: Command::Start, enabled: false, shortcut: None });
            assert_eq!(e[6], Entry::Separator);
            assert_eq!(e[7], Entry::Item { title: "Quit LocalFlow", command: Command::Quit, enabled: true, shortcut: Some("cmd-q") });
            update_session(cx, |s| s.can_start_meeting = true);
            assert_eq!(session(cx)[5], Entry::Item { title: "Start Meeting", command: Command::Start, enabled: true, shortcut: None });
            update_session(cx, |s| s.meetings_available = false);
            assert_eq!(titles(&session(cx)), ["Ready", "-", "Open LocalFlow", "Settings…", "-", "Quit LocalFlow"]);
        });
    }

    // parity: MENU-007 MENU-013
    #[flow_ui::gpui::test]
    async fn attention_and_busy_add_their_items(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            ensure_session(cx);
            update_session(cx, |s| s.dictation = Some(Dictation { busy: true, storage_blocked: true, ..Default::default() }));
            let e = entries(cx.global::<Session>(), "Ready".into());
            assert_eq!(e[1], Entry::Text("Review needed".into(), Some("exclamationmark.circle")));
            assert!(e.contains(&Entry::Item { title: "Cancel", command: Command::Cancel, enabled: true, shortcut: None }));
        });
    }

    // parity: MENU-016 MENU-019 MENU-022 MENU-023 MENU-024
    #[flow_ui::gpui::test]
    async fn meeting_items_follow_its_state(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            ensure_session(cx);
            let at = |state, cx: &mut App| {
                update_session(cx, |s| s.meeting = meeting(state));
                entries(cx.global::<Session>(), "Ready".into())[5..].to_vec()
            };
            let (pause, resume, stop) = (item("Pause Meeting", Command::Pause), item("Resume Meeting", Command::Resume), item("Stop Meeting", Command::Stop));
            assert_eq!(at(MeetingState::Recording, cx)[..2], [pause, stop.clone()]);
            assert_eq!(at(MeetingState::Paused, cx)[..2], [resume, stop]);
            assert_eq!(at(MeetingState::Preparing, cx)[0], Entry::Text("Meeting preparing…".into(), None));
            assert_eq!(at(MeetingState::Created, cx)[0], Entry::Text("Meeting created…".into(), None));
            assert_eq!(at(MeetingState::Finalizing, cx)[0], Entry::Text("Meeting finalizing…".into(), None));
            for ended in [MeetingState::Completed, MeetingState::Interrupted, MeetingState::Failed] {
                assert!(matches!(at(ended, cx)[0], Entry::Item { title: "Start Meeting", .. }));
            }
        });
    }

    fn routed(cx: &mut TestAppContext) -> std::rc::Rc<std::cell::RefCell<Vec<SessionCommand>>> {
        boot(cx, Mode::Light);
        let commands = std::rc::Rc::default();
        let window = cx.add_window(|_, _| flow_ui::gpui::Empty);
        cx.update(|cx| {
            ensure_session(cx);
            let fake = Fake { commands: std::rc::Rc::clone(&commands), ..Default::default() };
            fake.session_ok.set(true);
            cx.global_mut::<Core>().services = Box::new(fake);
            update_session(cx, |s| s.window = Some(window.into()));
        });
        commands
    }

    // parity: MENU-010 MENU-012
    #[flow_ui::gpui::test]
    async fn open_keeps_the_selection_and_settings_selects(cx: &mut TestAppContext) {
        let _ = routed(cx);
        cx.update(|cx| {
            run(Command::Open, cx);
            assert_eq!(cx.global::<Session>().selection, Page::History);
            run(Command::Settings, cx);
            assert_eq!(cx.global::<Session>().selection, Page::Settings);
        });
    }

    // parity: MENU-014 MENU-017 MENU-018 MENU-020 MENU-021
    #[flow_ui::gpui::test]
    async fn meeting_and_cancel_items_send_their_commands(cx: &mut TestAppContext) {
        let commands = routed(cx);
        let sent = |command, cx: &mut TestAppContext| {
            cx.update(|cx| run(command, cx));
            commands.borrow_mut().pop()
        };
        assert_eq!(sent(Command::Pause, cx), Some(SessionCommand::PauseMeeting));
        assert_eq!(sent(Command::Resume, cx), Some(SessionCommand::ResumeMeeting));
        assert_eq!(sent(Command::Stop, cx), Some(SessionCommand::StopMeeting));
        cx.update(|cx| update_session(cx, |s| s.meeting = meeting(MeetingState::Paused)));
        assert_eq!(sent(Command::Stop, cx), Some(SessionCommand::StopMeeting));
        cx.update(|cx| update_session(cx, |s| s.dictation.as_mut().unwrap().busy = true));
        assert_eq!(sent(Command::Cancel, cx), Some(SessionCommand::CancelDictation));
    }

    // parity: MENU-030
    #[flow_ui::gpui::test]
    async fn quit_item_runs_the_quit_sequence(cx: &mut TestAppContext) {
        let _ = routed(cx);
        cx.update(|cx| run(Command::Quit, cx));
        cx.update(|cx| assert!(cx.global::<Session>().quitting));
        cx.run_until_parked();
        cx.update(|cx| assert!(cx.global::<Session>().ready_to_terminate));
    }

    // parity: MENU-027
    #[flow_ui::gpui::test]
    async fn start_opens_notetaker_and_starts_only_when_allowed(cx: &mut TestAppContext) {
        let commands = routed(cx);
        cx.update(|cx| run(Command::Start, cx));
        cx.update(|cx| assert_eq!(cx.global::<Session>().selection, Page::Meetings));
        assert!(commands.borrow().is_empty());
        cx.update(|cx| update_session(cx, |s| s.can_start_meeting = true));
        cx.update(|cx| run(Command::Start, cx));
        assert_eq!(*commands.borrow(), vec![SessionCommand::StartMeeting]);
    }
}
