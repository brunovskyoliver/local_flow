use super::*;
use crate::testing::{assert_saw, boot, saw};
use flow_platform::{Fake, PermissionState, Unavailable};
use flow_ui::test::{TestAppContext, TestQueryExt, TestWindowExt};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::PathBuf;

/// `DisclosureGroup` at Figtree 12, as measured on the reference.
const DISCLOSURE: Pixels = px(22.);

type Win = WindowHandle<SettingsPage>;
type Log = Rc<RefCell<Vec<String>>>;

/// Fake OS services that keep secrets in memory and record calls. `ok` false makes them `Unavailable`.
struct Stub {
    fake: Fake,
    ok: Rc<Cell<bool>>,
    log: Log,
    secrets: Rc<RefCell<HashMap<String, String>>>,
    permissions: Rc<Cell<PermissionState>>,
    catalog: Rc<RefCell<Option<flow_platform::InputCatalog>>>,
    install: Rc<Cell<Option<(u64, u64, bool)>>>,
    google: Rc<Cell<bool>>,
}
impl Stub {
    fn call(&self, name: String) -> Result<(), Unavailable> {
        self.log.borrow_mut().push(name);
        if self.ok.get() { Ok(()) } else { Err(Unavailable("test")) }
    }
}
impl flow_platform::Services for Stub {
    fn name(&self) -> &'static str {
        "stub"
    }
    fn device_word(&self) -> &'static str {
        self.fake.device_word()
    }
    fn app_data_dir(&self) -> PathBuf {
        self.fake.app_data_dir()
    }
    fn permission(&self, _: Permission) -> PermissionState {
        self.permissions.get()
    }
    fn open_permission_settings(&self, p: Permission) -> Result<(), Unavailable> {
        self.call(format!("settings {p:?}"))
    }
    fn request_permission(&self, p: Permission) -> Result<PermissionState, Unavailable> {
        self.call(format!("request {p:?}"))?;
        Ok(PermissionState::Denied)
    }
    fn input_catalog(&self) -> Option<flow_platform::InputCatalog> {
        self.catalog.borrow().clone()
    }
    fn high_contrast(&self) -> bool {
        false
    }
    fn app_name(&self, id: &str) -> Option<String> {
        (id == "com.apple.Passwords").then(|| "Alpha Keys".to_string())
    }
    fn speech_install(&self) -> Option<(u64, u64, bool)> {
        self.install.get()
    }
    fn reduce_motion(&self) -> bool {
        false
    }
    fn launch_at_login(&self) -> Result<bool, Unavailable> {
        Ok(false)
    }
    fn set_launch_at_login(&self, _: bool) -> Result<(), Unavailable> {
        Ok(())
    }
    fn free_disk_bytes(&self) -> Option<u64> {
        None
    }
    fn secret(&self, name: &str) -> Result<Option<String>, Unavailable> {
        if self.ok.get() { Ok(self.secrets.borrow().get(name).cloned()) } else { Err(Unavailable("test")) }
    }
    fn set_secret(&self, name: &str, value: &str) -> Result<(), Unavailable> {
        self.call(format!("set {name}"))?;
        self.secrets.borrow_mut().insert(name.into(), value.into());
        Ok(())
    }
    fn remove_secret(&self, name: &str) -> Result<(), Unavailable> {
        self.call(format!("remove {name}"))?;
        self.secrets.borrow_mut().remove(name);
        Ok(())
    }
    fn settings_action(&self, action: &str) -> Result<(), Unavailable> {
        self.call(format!("action {action}"))
    }
    fn open_url(&self, url: &str) -> Result<(), Unavailable> {
        self.call(format!("open {url}"))
    }
    fn reveal_app(&self) -> Result<(), Unavailable> {
        self.call("reveal".into())
    }
    fn record_shortcut(&self) -> Result<(), Unavailable> {
        self.call("record".into())
    }
    fn install_shortcut(&self, _: &str) -> Result<(), Unavailable> {
        self.call("install".into())
    }
    fn enroll_device(&self, provider: &str) -> Result<String, Unavailable> {
        self.call(format!("enroll {provider}"))?;
        if provider == "unreachable" {
            return Err(Unavailable(core::SERVER_UNREACHABLE));
        }
        Ok("pending".into())
    }
    fn running_apps(&self) -> Vec<(String, String)> {
        vec![("Zed".into(), "dev.zed.Zed".into()), ("Arc".into(), "company.thebrowser.Browser".into())]
    }
    fn google_sign_in_available(&self) -> bool {
        self.google.get()
    }
}

struct Rig {
    win: Win,
    ok: Rc<Cell<bool>>,
    log: Log,
    secrets: Rc<RefCell<HashMap<String, String>>>,
    catalog: Rc<RefCell<Option<flow_platform::InputCatalog>>>,
    permissions: Rc<Cell<PermissionState>>,
    install: Rc<Cell<Option<(u64, u64, bool)>>>,
    google: Rc<Cell<bool>>,
}

fn rig(cx: &mut TestAppContext, scenario: &str, prep: impl FnOnce(&mut flow_core::prefs::Prefs)) -> Rig {
    boot(cx, Mode::Light);
    let (ok, log, secrets, permissions) = (Rc::new(Cell::new(true)), Log::default(), Rc::new(RefCell::new(HashMap::new())), Rc::new(Cell::new(PermissionState::NotAsked)));
    let catalog = Rc::new(RefCell::new(None));
    let permissions_handle = permissions.clone();
    let install = Rc::new(Cell::new(None));
    let google = Rc::new(Cell::new(false));
    let stub = Stub { google: google.clone(), fake: Fake::default(), ok: ok.clone(), log: log.clone(), secrets: secrets.clone(), permissions, catalog: catalog.clone(), install: install.clone() };
    cx.update(|cx| {
        let core = cx.global_mut::<Core>();
        core.services = Box::new(stub);
        core.scenario = (!scenario.is_empty()).then(|| format!("settings.{scenario}"));
        prep(&mut core.prefs);
    });
    // Tall, so every control is on screen and clickable.
    let bounds = Bounds::new(point(px(0.), px(0.)), size(px(1180.), px(6000.)));
    let win = cx.update(|cx| cx.open_window(WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..Default::default() }, |w, cx| cx.new(|cx| SettingsPage::new(w, cx)))).unwrap();
    frame(cx, win);
    Rig { win, ok, log, secrets, catalog, permissions: permissions_handle, install, google }
}
fn frame(cx: &mut TestAppContext, win: Win) {
    cx.run_until_parked();
    flow_ui::probe::clear();
    cx.update_window(win.into(), |_, w, cx| w.render_frame(cx)).unwrap();
}
fn click(cx: &mut TestAppContext, win: Win, id: &'static str) {
    cx.update_window(win.into(), |_, w, cx| w.click(id, cx)).unwrap();
    frame(cx, win);
}
fn set(cx: &mut TestAppContext, win: Win, f: impl FnOnce(&mut SettingsPage, &mut Window, &mut Context<SettingsPage>)) {
    win.update(cx, |p, w, cx| {
        f(p, w, cx);
        cx.notify();
    })
    .unwrap();
    frame(cx, win);
}
fn read<T>(cx: &mut TestAppContext, win: Win, f: impl FnOnce(&SettingsPage, &App) -> T) -> T {
    win.update(cx, |p, _, cx| f(p, cx)).unwrap()
}
fn pref_s(cx: &mut TestAppContext, key: &str) -> Option<String> {
    cx.update(|cx| cx.global::<Core>().prefs.string(key))
}
fn pref_b(cx: &mut TestAppContext, key: &str) -> Option<bool> {
    cx.update(|cx| cx.global::<Core>().prefs.contains(key).then(|| cx.global::<Core>().prefs.bool_or(key, false)))
}
fn pref_i(cx: &mut TestAppContext, key: &str, default: i64) -> i64 {
    cx.update(|cx| cx.global::<Core>().prefs.int_or(key, default))
}
fn pick(cx: &mut TestAppContext, win: Win, id: &'static str, value: &'static str) {
    win.update(cx, |p, w, cx| p.apply_pick(id, value, w, cx)).unwrap();
    frame(cx, win);
}
fn type_into(cx: &mut TestAppContext, win: Win, of: impl FnOnce(&SettingsPage) -> Entity<InputState>, text: &str) {
    let state = read(cx, win, |p, _| of(p));
    // Real keystrokes: `set_value` alone sends no change event.
    cx.update_window(win.into(), |_, w, cx| {
        state.update(cx, |s, cx| s.set_value("", w, cx));
        state.read(cx).focus_handle(cx).focus(w, cx);
    })
    .unwrap();
    frame(cx, win);
    cx.update_window(win.into(), |_, w, cx| {
        if text.is_empty() {
            w.input("x", cx);
            w.press("backspace", cx);
        } else {
            w.input(text, cx);
        }
    })
    .unwrap();
    frame(cx, win);
}
fn has(cx: &mut TestAppContext, win: Win, id: &'static str) -> bool {
    win.update(cx, |_, w, _| w.try_find(id).is_some()).unwrap()
}
fn disabled(cx: &mut TestAppContext, win: Win, id: &'static str) -> bool {
    win.update(cx, |_, w, _| w.find(id).disabled().unwrap_or(false)).unwrap()
}
fn identity(key: &str, fp: &str) -> Identity {
    Identity { server_key: key.into(), fingerprint: fp.into(), protocol_versions: vec![1], schema_version: 1, server: Default::default(), suite: "x25519-hkdfsha256-chacha20poly1305".into() }
}
fn logged(r: &Rig, s: &str) -> bool {
    r.log.borrow().iter().any(|l| l == s)
}

// parity: SET-034 SET-036 SET-037 SET-134 SET-135 SET-136 SET-146 SET-151 SET-152 SET-166 SET-168 SET-170 SET-172 SET-174 SET-199 SET-200 SET-202 SET-206 SET-209 SET-210 SET-211 SET-239 SET-247 SET-248 SET-252 SET-256 SET-270 SET-272 SET-274 SET-276 SET-278 SET-280 SET-293 SET-296 SET-301 SET-303 SET-335 SET-336 SET-021
#[flow_ui::gpui::test]
async fn default_page_shows_every_section_in_order(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert_saw(&["Settings", "Server", "Remote dictation", "Run dictation, rewriting, summaries and meetings on a LocalFlow server you run.", "Updates", "Software updates", "This build uses manual updates", "General", "Shortcut", "fn / Globe", "Appearance", "Learn corrections", "Show meeting progress", "Meeting language", "App context", "Use app context", "Send context to rewrite server", "Turn on Use app context first.", "Match style to the app", "Experimental", "Excluded apps", "10 apps", "App kinds", "Built in", "Models", "Parakeet", "Dictation · Not installed", "Whisper Turbo", "Meeting transcripts · Not installed · 1.63 GB", "Speaker labels", "Who said what · Not installed", "Term booster", "Dictionary terms in dictation · Not installed · 103 MB", "Keep Parakeet loaded", "Rewriting", "Enable rewriting", "Enter a valid http:// or https:// endpoint first.", "Default mode", "Server URL", "Server secret", "Connection", "Advanced", "Summaries", "Permissions needed", "Microphone", "Input Monitoring", "Accessibility"]);
    assert!(!saw("Microphones"), "the catalog isn't wired, so the section is absent");
    for id in ["settings.remoteEnabled", "settings.updateDownloads", "settings.shortcut", "settings.appearance", "settings.learnCorrections", "settings.showsBackgroundProgress", "settings.meetingLanguage", "settings.contextEnabled", "settings.contextRewriteEnabled", "settings.contextStyleEnabled", "settings.contextExclusions", "settings.contextKinds", "settings.speechDownload", "settings.speechImport", "settings.rewriteEnabled", "settings.rewriteDefaultMode", "settings.rewriteTestConnection", "settings.summaryServer", "settings.keepModelReady"] {
        assert!(has(cx, r.win, id), "{id}");
    }
    assert!(disabled(cx, r.win, "settings.contextRewriteEnabled"));
    assert!(disabled(cx, r.win, "settings.contextStyleEnabled"));
}

// parity: SET-204
#[flow_ui::gpui::test]
async fn context_rewrite_says_turn_on_rewriting_when_only_that_is_off(cx: &mut TestAppContext) {
    let r = rig(cx, "", |p| p.set("contextEnabled", true));
    assert_saw(&["Turn on rewriting first."]);
    assert!(disabled(cx, r.win, "settings.contextRewriteEnabled"));
    assert_eq!(cx.update_window(r.win.into(), |_, w, _| w.find("settings.contextRewriteEnabled").checked()).unwrap(), Some(false));
}

// parity: SET-351 SET-352
#[flow_ui::gpui::test]
async fn permissions_list_only_what_is_missing_in_order(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    let top = |cx: &mut TestAppContext, id: &'static str| bounds(cx, r.win, id).top();
    let (mic, input, access) = (top(cx, "settings.allow.Microphone"), top(cx, "settings.allow.Input Monitoring"), top(cx, "settings.allow.Accessibility"));
    assert!(mic < input && input < access);
    assert_eq!(cx.update_window(r.win.into(), |_, w, _| w.find("settings.allow.Microphone").label().map(|l| l.to_string())).unwrap().as_deref(), Some("Allow Microphone"));
    assert_eq!(bounds(cx, r.win, "settings.allow.Accessibility").size.width.max(px(99.)), bounds(cx, r.win, "settings.allow.Accessibility").size.width, "min width 99");
    r.permissions.set(PermissionState::Granted);
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    assert!(!has(cx, r.win, "settings.allow.Microphone"), "granted rows leave");
}

// parity: SET-003
#[flow_ui::gpui::test]
async fn sections_stack_in_swifts_order(cx: &mut TestAppContext) {
    let r = rig(cx, "microphones", |_| {});
    let mut last = px(-1.);
    for title in ["Server", "Updates", "General", "Microphones", "App context", "Models", "Rewriting", "Summaries", "Permissions needed"] {
        let id: &'static str = format!("settings.section.{title}").leak();
        let top = bounds(cx, r.win, id).top();
        assert!(top > last, "{title} sits below the section before it");
        last = top;
    }
}

// parity: SET-016 SET-350
#[flow_ui::gpui::test]
async fn refresh_reads_permissions_and_all_granted_hides_the_section(cx: &mut TestAppContext) {
    rig(cx, "", |_| {});
    assert_saw(&["Permissions needed", "Allow…"]);
    let r = rig(cx, "permissions-granted", |_| {});
    assert!(!saw("Permissions needed"), "all granted hides the section");
    assert_eq!(read(cx, r.win, |p, _| p.snapshot.microphone), Perm::Granted);
}

// parity: SET-017
#[flow_ui::gpui::test]
async fn poll_sees_a_permission_change_within_half_a_second(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    let before = read(cx, r.win, |p, _| p.snapshot.microphone);
    assert_ne!(before, Perm::Granted);
    r.permissions.set(PermissionState::Granted);
    cx.executor().advance_clock(Duration::from_millis(100));
    frame(cx, r.win);
    assert_eq!(read(cx, r.win, |p, _| p.snapshot.microphone), before, "not before the next poll");
    cx.executor().advance_clock(Duration::from_millis(500));
    frame(cx, r.win);
    assert_eq!(read(cx, r.win, |p, _| p.snapshot.microphone), Perm::Granted);
    assert!(!saw("Permissions needed"));
}

// parity: SET-019 SET-015
#[flow_ui::gpui::test]
async fn leaving_clears_the_test_and_secret_draft(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    type_into(cx, r.win, |p| p.credential.clone(), "typed");
    set(cx, r.win, |p, w, cx| {
        p.connection = Some((Connection::Connected, None, "health_response"));
        p.recording = true;
        p.left_page(w, cx);
    });
    assert!(read(cx, r.win, |p, cx| p.connection.is_none() && !p.recording && p.credential_draft(cx).is_empty()));
    assert!(read(cx, r.win, |p, _| p.visible), "tests have no shell, so the page counts as visible");
    // Clicking empty space moves focus back to the page.
    set(cx, r.win, |p, w, cx| {
        p.credential.update(cx, |s, cx| s.focus_handle(cx).focus(w, cx));
        p.key("escape", w, cx);
    });
    assert!(r.win.update(cx, |p, w, _| p.focus.is_focused(w)).unwrap());
}

// parity: SET-023 SET-024 SET-025 SET-154 SET-029
#[flow_ui::gpui::test]
async fn failures_read_at_the_page_bottom(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    r.ok.set(false);
    click(cx, r.win, "settings.shortcut");
    assert_saw(&["The keyboard shortcut could not start. Check permissions and try again."]);
    assert!(read(cx, r.win, |p, _| !p.recording));
    set(cx, r.win, |p, _, cx| p.run("load", cx));
    assert_saw(&["Error type flow_platform.Unavailable, code 0."]);
    r.ok.set(true);
    set(cx, r.win, |p, _, cx| p.run("load", cx));
    assert!(!saw("Error type"), "a new action clears the old error");
    set(cx, r.win, |p, _, cx| {
        p.performing = true;
        p.run("ignored", cx);
    });
    assert!(!logged(&r, "action ignored"), "ignored while performing");
}

// parity: SET-040 SET-041 SET-077 SET-078 SET-079 SET-080 SET-084 SET-086 SET-087 SET-088 SET-089 SET-085
#[flow_ui::gpui::test]
async fn consent_sheet_stores_nothing_until_turn_on(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    click(cx, r.win, "settings.remoteEnabled");
    assert_saw(&["https://server.example.com"]);
    assert_eq!(cx.update_window(r.win.into(), |_, w, _| w.find_by_label("Server address").label().map(|l| l.to_string())).unwrap().as_deref(), Some("Server address"));
    assert_saw(&["Use your LocalFlow server?", "Dictation audio, transcripts, Dictionary terms"]);
    assert_eq!(pref_b(cx, "remote.enabled"), None, "nothing persists on opening");
    assert!(disabled(cx, r.win, "settings.remoteConsentConfirm"));
    type_into(cx, r.win, |p| p.server_draft.clone(), "http://nope.example.com");
    assert!(disabled(cx, r.win, "settings.remoteConsentConfirm"));
    type_into(cx, r.win, |p| p.server_draft.clone(), "https://flow.example.com");
    assert_saw(&["Server: flow.example.com"]);
    click(cx, r.win, "settings.remoteConsentCancel");
    assert!(read(cx, r.win, |p, cx| p.modal.is_none() && val(&p.server_draft, cx).is_empty()));
    assert_eq!(pref_s(cx, "remote.serverURL"), None);
    click(cx, r.win, "settings.remoteEnabled");
    set(cx, r.win, |p, w, cx| p.key("escape", w, cx));
    assert!(read(cx, r.win, |p, _| p.modal.is_none()), "Esc cancels");
    click(cx, r.win, "settings.remoteEnabled");
    type_into(cx, r.win, |p| p.server_draft.clone(), "https://127.0.0.1:9");
    click(cx, r.win, "settings.remoteConsentConfirm");
    assert_eq!(pref_s(cx, "remote.serverURL").as_deref(), Some("https://127.0.0.1:9"));
    assert_eq!(pref_b(cx, "remote.enabled"), Some(true));
    assert_eq!(pref_i(cx, "remote.consentVersion", 0), 2);
    assert!(read(cx, r.win, |p, _| p.modal.is_none()));
}

// parity: ONB-110
/// Meetings only: purpose becomes both, Right Control goes in, `server.only` stays.
#[flow_ui::gpui::test]
async fn set_up_dictation_keeps_the_server_choice(cx: &mut TestAppContext) {
    let r = rig(cx, "meeting-only", |_| {});
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("server.only", true));
    assert!(!cx.update(|cx| flow_core::onboarding::Shortcut::is_saved(&cx.global::<Core>().prefs)));
    click(cx, r.win, "settings.setUpDictation");
    assert_eq!(pref_s(cx, "setup.purpose").as_deref(), Some("both"));
    assert_eq!(pref_b(cx, "server.only"), Some(true));
    assert!(cx.update(|cx| flow_core::onboarding::Shortcut::load(&cx.global::<Core>().prefs)) == flow_core::onboarding::Shortcut::right_control());
    assert!(logged(&r, "install"));
}

// parity: SET-038 SET-147 SET-148 SET-149 SET-150 SET-349 SET-082 SET-076
#[flow_ui::gpui::test]
async fn meeting_only_variant(cx: &mut TestAppContext) {
    let r = rig(cx, "meeting-only", |_| {});
    assert_saw(&["Your server", "Run meeting transcripts and notes on a LocalFlow server you run.", "Set up dictation", "Hold a key in any app to talk. Meetings stay as they are.", "Permissions needed", "Microphone"]);
    assert!(!saw("Input Monitoring"));
    assert!(!has(cx, r.win, "settings.shortcut"));
    click(cx, r.win, "settings.setUpDictation");
    assert_eq!(pref_s(cx, "setup.purpose").as_deref(), Some("both"));
    assert!(pref_s(cx, "shortcut").is_some() || cx.update(|cx| cx.global::<Core>().prefs.contains("shortcut")));
    assert!(logged(&r, "install"));
    assert_saw(&["Shortcut"]);
}

// parity: SET-039 SET-042 SET-049 SET-053 SET-092 SET-093 SET-094 SET-095 SET-096 SET-100 SET-101 SET-102 SET-103 SET-104 SET-110 SET-111 SET-117 SET-116 SET-114
#[flow_ui::gpui::test]
async fn approved_server_shows_routing_and_turns_off(cx: &mut TestAppContext) {
    let r = rig(cx, "approved", |_| {});
    assert_saw(&["flow.example.com · Approved", "Use this server for everything", "Server only", "Never load models on this Mac", "Services", "On your server: Dictation, Rewriting", "Check connection", "Advanced"]);
    assert!(!has(cx, r.win, "settings.remoteFingerprint"));
        click(cx, r.win, "settings.serverUseForEverything");
    assert_eq!(pref_b(cx, "server.useForEverything"), Some(false));
    click(cx, r.win, "settings.serverUseForEverything");
    click(cx, r.win, "settings.serverOnly");
    assert_eq!(pref_b(cx, "server.only"), Some(true));
    assert!(disabled(cx, r.win, "settings.serverUseForEverything"));
    click(cx, r.win, "settings.remoteEnabled");
    assert_saw(&["Turn off remote dictation?", "This Mac's sign-in, device key and server pin are deleted. Your history stays. You will need approval again to turn it back on.", "Turn Off"]);
    assert_eq!(pref_b(cx, "remote.enabled"), Some(true), "stays on until confirmed");
    assert!(bounds(cx, r.win, "settings.alert.cancel").right() < bounds(cx, r.win, "settings.alert.confirm").left(), "Cancel on the left");
    assert_eq!(bounds(cx, r.win, "settings.alert").size.width, px(260.));
    click(cx, r.win, "settings.alert.cancel");
    assert_eq!(pref_b(cx, "remote.enabled"), Some(true));
    assert!(!has(cx, r.win, "settings.alert"));
    click(cx, r.win, "settings.remoteEnabled");
    click(cx, r.win, "settings.alert.confirm");
    assert_eq!(pref_b(cx, "remote.enabled"), Some(false));
    assert_eq!(pref_s(cx, "remote.serverURL"), None);
    assert!(logged(&r, &format!("remove {}", core::remote_keychain("device-key"))));
    for item in ["access-token", "refresh-token", "server-key"] {
        assert!(logged(&r, &format!("remove {}", core::remote_keychain(item))), "{item}");
    }
    assert_saw(&["Server only"]);
    assert!(!saw("Use this server for everything"));
}

// parity: SET-060 SET-061 SET-062 SET-066 SET-069 SET-073
#[flow_ui::gpui::test]
async fn remote_status_lines_and_their_controls(cx: &mut TestAppContext) {
    for (scenario, status, enroll, sign_in) in [("pinned", "Sign in to finish", false, true), ("sign-in-again", "Sign in again", false, true), ("pending", "Waiting for approval", false, false), ("rejected", "Rejected", true, false), ("revoked", "Removed from the server", true, false), ("pin-mismatch", "Server identity changed", true, false), ("update-required", "Update LocalFlow or the server", false, false)] {
        let r = rig(cx, scenario, |_| {});
        assert_saw(&[status]);
        assert_eq!(has(cx, r.win, "settings.remoteEnrollAgain"), enroll, "{scenario}");
        assert_eq!(has(cx, r.win, "settings.remoteSignInApple"), sign_in, "{scenario}");
        assert!(!has(cx, r.win, "settings.remoteSignInGoogle"), "no client ID hides Google");
        if sign_in {
            r.ok.set(false);
            click(cx, r.win, "settings.remoteSignInApple");
            assert_saw(&["Sign-in did not finish."]);
            r.ok.set(true);
            click(cx, r.win, "settings.remoteSignInApple");
            assert_eq!(pref_s(cx, "remote.state").as_deref(), Some("pending"));
        }
    }
    let r = rig(cx, "checking", |_| {});
    assert_saw(&["Checking the server…"]);
    drop(r);
}

// parity: SET-054 SET-055 SET-056 SET-057 SET-058 SET-059 SET-133 SET-045
#[flow_ui::gpui::test]
async fn trust_pins_the_key_and_shows_the_pin(cx: &mut TestAppContext) {
    let r = rig(cx, "checking", |_| {});
    let key = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA";
    let raw = core::base64url_decode(key).unwrap();
    let fp = core::fingerprint_of(&raw);
    set(cx, r.win, |p, _, _| p.identity = Some(identity(key, &fp)));
    assert_saw(&["Compare the fingerprint", "Server fingerprint", &fp, "Compare it with ", "flowd admin identity", "Trust This Server"]);
    click(cx, r.win, "settings.remoteTrust");
    assert_eq!(r.secrets.borrow().get(&core::remote_keychain("server-key")).map(String::as_str), Some(key));
    assert_eq!(pref_s(cx, "remote.state").as_deref(), Some("pinned"));
    assert!(logged(&r, &format!("remove {}", core::remote_keychain("refresh-token"))));
    assert_saw(&[&format!("Pinned fingerprint  {fp}"), "Sign in to finish"]);
    // A failed Keychain write leaves the state alone and says so.
    r.ok.set(false);
    set(cx, r.win, |p, _, _| p.identity = Some(identity(key, "")));
    click(cx, r.win, "settings.remoteTrust");
    assert_saw(&["The server identity could not be saved."]);
    // Advanced shows it too once pinned.
    r.ok.set(true);
    let r = rig(cx, "advanced", |_| {});
    r.secrets.borrow_mut().insert(core::remote_keychain("server-key"), key.into());
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    assert_saw(&["Server fingerprint", &fp]);
}

// parity: SET-105 SET-106 SET-107 SET-108 SET-109
#[flow_ui::gpui::test]
async fn consent_update_sheet(cx: &mut TestAppContext) {
    let r = rig(cx, "consent-update", |_| {});
    assert_saw(&["Summaries and meetings", "Confirm the updated consent to send them to your server."]);
    click(cx, r.win, "settings.serverConsentUpdate");
    assert_saw(&["Send summaries and meetings to your server?"]);
    click(cx, r.win, "settings.serverConsentCancel");
    assert!(read(cx, r.win, |p, _| p.modal.is_none()), "Cancel closes");
    assert_eq!(pref_i(cx, "remote.consentVersion", 0), 1);
    click(cx, r.win, "settings.serverConsentUpdate");
    set(cx, r.win, |p, w, cx| p.key("escape", w, cx));
    assert!(read(cx, r.win, |p, _| p.modal.is_none()), "Esc closes");
    assert_eq!(pref_i(cx, "remote.consentVersion", 0), 1, "Esc leaves the version");
    click(cx, r.win, "settings.serverConsentUpdate");
    click(cx, r.win, "settings.serverConsentConfirm");
    assert_eq!(pref_i(cx, "remote.consentVersion", 0), 2);
    let r = rig(cx, "consent-update", |_| {});
    click(cx, r.win, "settings.serverConsentUpdate");
    set(cx, r.win, |p, w, cx| p.key("enter", w, cx));
    assert_eq!(pref_i(cx, "remote.consentVersion", 0), 2, "Return confirms");
    assert!(!saw("Confirm the updated consent"));
}

// parity: SET-130
#[flow_ui::gpui::test]
async fn fallback_threshold_stops_at_both_limits(cx: &mut TestAppContext) {
    let r = rig(cx, "approved", |p| p.set("remote.fallbackThresholdMs", 500));
    click(cx, r.win, "settings.serverAdvanced");
    assert_saw(&["Fallback threshold", "Dictation uses this Mac after this wait"]);
    assert_eq!(cx.update_window(r.win.into(), |_, w, _| w.find("settings.serverFallbackThreshold.up").label().map(|l| l.to_string())).unwrap().as_deref(), Some("Remote dictation fallback threshold in milliseconds, increase"));
    for want in [250, 250] {
        click(cx, r.win, "settings.serverFallbackThreshold.down");
        assert_eq!(pref_i(cx, "remote.fallbackThresholdMs", 0), want);
    }
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("remote.fallbackThresholdMs", 9750));
    for want in [10_000, 10_000] {
        click(cx, r.win, "settings.serverFallbackThreshold.up");
        assert_eq!(pref_i(cx, "remote.fallbackThresholdMs", 0), want);
    }
    assert_saw(&[&format!("{} ms", flow_core::insights::grouped(10_000))]);
}

// parity: SET-374
#[flow_ui::gpui::test]
async fn usage_enrollment_runs_when_approved_with_a_device_key(cx: &mut TestAppContext) {
    let r = rig(cx, "approved", |_| {});
    let count = |cx: &mut TestAppContext, sql: &str| cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap());
    cx.update(|cx| {
        let conn = &cx.global::<Core>().db.as_ref().unwrap().conn;
        conn.execute("INSERT OR REPLACE INTO usage_reporting_state(id,binding,enabled) VALUES(1,'{\"origin\":\"https://old\",\"credentialFingerprint\":\"f\"}',1)", []).unwrap();
        conn.execute("INSERT INTO usage_reporting_completions(id,day) VALUES('00000000-0000-0000-0000-000000000000','2026-10-31')", []).unwrap();
    });
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    assert_eq!(count(cx, "SELECT count(*) FROM usage_reporting_completions"), 1, "no device key, no identity");
    r.secrets.borrow_mut().insert(core::remote_keychain("device-key"), "key".into());
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    assert_eq!(count(cx, "SELECT count(*) FROM usage_reporting_completions"), 0, "a changed binding wipes");
    assert_eq!(count(cx, "SELECT count(*) FROM usage_reporting_state WHERE binding IS NULL"), 1);
    assert_eq!(core::usage_fingerprint(b"key").len(), 64, "the whole digest, as Swift keeps it");
}

// parity: SET-120 SET-121 SET-122 SET-123 SET-124 SET-125 SET-126 SET-127 SET-128 SET-129 SET-131 SET-132 SET-306 SET-334
#[flow_ui::gpui::test]
async fn server_advanced_writes_each_override(cx: &mut TestAppContext) {
    let r = rig(cx, "approved", |_| {});
    assert!(!saw("Fallback threshold"), "collapsed by default");
    assert!(!has(cx, r.win, "settings.rewriteTestConnection"), "served: fields move to Advanced");
    assert!(!has(cx, r.win, "settings.summaryServer"), "Summaries hides while the switch applies");
    click(cx, r.win, "settings.serverAdvanced");
    assert_saw(&["Dictation", "Speech recognition; rewriting follows its own row", "Rewriting", "Summaries", "Meetings", "Transcripts, speaker labels and voice matching", "Fallback threshold", "Dictation uses this Mac after this wait", &format!("{} ms", flow_core::insights::grouped(1500))]);
    set(cx, r.win, |p, _, _| p.check_result = Some("Answered in 3 ms".into()));
    pick(cx, r.win, "settings.serverOverride.dictation", "thisMac");
    assert_eq!(pref_s(cx, "server.override.dictation").as_deref(), Some("thisMac"));
    assert!(read(cx, r.win, |p, _| p.check_result.is_none()), "routing controls clear the check");
    pick(cx, r.win, "settings.serverOverride.meetings", "thisMac");
    assert_eq!(pref_s(cx, "server.override.meetings").as_deref(), Some("thisMac"));
    pick(cx, r.win, "settings.serverOverride.rewriting", "custom");
    assert_eq!(pref_s(cx, "server.override.rewrite").as_deref(), Some("custom"));
    assert!(has(cx, r.win, "settings.rewriteTestConnection"), "custom shows the fields");
    pick(cx, r.win, "settings.serverOverride.summaries", "custom");
    assert_eq!(pref_s(cx, "summaryServer").as_deref(), Some("remote"));
    assert_saw(&["Your server is used if this server fails"]);
    assert_saw(&["Model", "API key"]);
    click(cx, r.win, "settings.serverFallbackThreshold.up");
    assert_eq!(pref_i(cx, "remote.fallbackThresholdMs", 0), 1750);
    click(cx, r.win, "settings.serverFallbackThreshold.down");
    click(cx, r.win, "settings.serverFallbackThreshold.down");
    assert_eq!(pref_i(cx, "remote.fallbackThresholdMs", 0), 1250);
    click(cx, r.win, "settings.serverOnly");
    assert!(disabled(cx, r.win, "settings.serverOverride.dictation"));
    assert_saw(&["Your server"]);
}

// parity: SET-115 SET-118
#[flow_ui::gpui::test]
async fn check_connection_when_the_server_is_down(cx: &mut TestAppContext) {
    cx.executor().allow_parking();
    let r = rig(cx, "approved", |_| {});
    // A closed localhost port answers with a refused connection.
    set(cx, r.win, |p, _, _| p.remote_base = Some("http://127.0.0.1:9".into()));
    click(cx, r.win, "settings.serverCheckConnection");
    for _ in 0..50 {
        if read(cx, r.win, |p, _| !p.checking) {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
        frame(cx, r.win);
    }
    frame(cx, r.win);
    assert_saw(&["Server unreachable"]);
    set(cx, r.win, |p, _, cx| {
        prefs_mut(cx).set("server.override.dictation", "thisMac");
        for key in ["rewrite", "summaries", "meetings"] {
            prefs_mut(cx).set(&format!("server.override.{key}"), "thisMac");
        }
        p.check_connection(cx);
    });
    assert_saw(&["Nothing runs on your server"]);
}

// parity: SET-137 SET-138 SET-139 SET-140 SET-142
#[flow_ui::gpui::test]
async fn updates_variants(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    click(cx, r.win, "settings.updateDownloads");
    assert!(logged(&r, &format!("open {}", core::RELEASES_URL)));
    let r = rig(cx, "updates-failed", |_| {});
    assert_saw(&["The updater could not start. Reopen LocalFlow to retry."]);
    let r2 = rig(cx, "updates-sparkle", |_| {});
    assert_saw(&["Latest version", "You choose when to install.", "Check for Updates…", "Check automatically", "Installation waits until active work finishes."]);
    drop(r);
    click(cx, r2.win, "settings.checkForUpdates");
    assert_saw(&["Error type flow_platform.Unavailable, code 0."]);
    click(cx, r2.win, "settings.automaticUpdates");
    assert!(logged(&r2, "action toggleAutomaticUpdates"));
}

// parity: SET-153 SET-154 SET-163 SET-167 SET-169 SET-171 SET-173
#[flow_ui::gpui::test]
async fn general_controls_persist(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    click(cx, r.win, "settings.shortcut");
    assert!(logged(&r, "record"));
    assert_saw(&["Listening…", "Press a shortcut, then release. Esc to cancel."]);
    click(cx, r.win, "settings.shortcut");
    assert!(!saw("Listening…"), "a second press stops the recorder");
    // Installs first and saves only if that worked.
    r.ok.set(false);
    set(cx, r.win, |p, _, cx| p.recorded(Some(Shortcut::right_control()), cx));
    assert_saw(&["The keyboard shortcut could not start."]);
    assert!(cx.update(|cx| !cx.global::<Core>().prefs.contains("shortcut")));
    r.ok.set(true);
    set(cx, r.win, |p, _, cx| p.recorded(Some(Shortcut::right_control()), cx));
    assert!(cx.update(|cx| cx.global::<Core>().prefs.contains("shortcut")));
    assert_saw(&["Right Control"]);
    // Clicking a picker opens its menu.
    click(cx, r.win, "settings.appearance");
    cx.update_window(r.win.into(), |_, w, cx| w.press("escape", cx)).ok();
    frame(cx, r.win);
    pick(cx, r.win, "settings.appearance", "dark");
    assert_eq!(pref_s(cx, "appearance").as_deref(), Some("dark"));
    assert!(cx.update(|cx| pal(cx).mode.is_dark()));
    click(cx, r.win, "settings.learnCorrections");
    assert_eq!(pref_b(cx, "learnCorrections"), Some(true));
    click(cx, r.win, "settings.showsBackgroundProgress");
    assert_eq!(pref_b(cx, "showsBackgroundProgress"), Some(false));
    pick(cx, r.win, "settings.meetingLanguage", "slovak");
    assert_eq!(pref_s(cx, "settings.meetingLanguage").as_deref(), Some("slovak"));
}

// parity: SET-175 SET-176 SET-178 SET-179 SET-180 SET-181 SET-182 SET-186 SET-187 SET-188 SET-191 SET-193
#[flow_ui::gpui::test]
async fn microphones_list_edits(cx: &mut TestAppContext) {
    let r = rig(cx, "microphones", |_| {});
    assert_saw(&["Microphones", "LocalFlow records from the first microphone", "Blue Yeti", "USB", "Studio Mic", "USB · Not connected", "System default", "Currently: MacBook Pro Microphone", "Add microphone"]);
    assert!(has(cx, r.win, "settings.microphones.add"));
    let ids = |cx: &mut TestAppContext| read(cx, r.win, |p, _| p.mics.as_ref().unwrap().entries.iter().map(|e| e.id.clone()).collect::<Vec<_>>());
    let start = ids(cx);
    assert_eq!(start.len(), 3);
    cx.update_window(r.win.into(), |_, w, cx| w.drag_to(SharedString::from(format!("settings.microphones.row.{}", start[1])), SharedString::from(format!("settings.microphones.row.{}", start[0])), cx)).unwrap();
    frame(cx, r.win);
    assert_eq!(ids(cx)[0], start[1], "dragged takes the target's place");
    assert!(cx.update(|cx| cx.global::<Core>().prefs.contains(core::INPUTS_KEY)), "drag saves");
    set(cx, r.win, |p, _, cx| p.move_mic(&start[1], 1, cx));
    assert_eq!(ids(cx)[1], start[1]);
    let n = ids(cx).len();
    set(cx, r.win, |p, _, cx| p.add_mic("bt-XXXX-3F2A", cx));
    assert_eq!(ids(cx).len(), n + 1);
    let after = ids(cx);
    assert_eq!(after.last().unwrap(), core::InputEntry::system_default().id.as_str(), "System default stays last");
    let stored = cx.update(|cx| core::load_inputs(&cx.global::<Core>().prefs));
    assert_eq!(stored[stored.len() - 2].uid.as_deref(), Some("bt-XXXX-3F2A"), "inserted just above System default, and saved");
    assert_eq!(stored.iter().map(|e| e.id.clone()).collect::<Vec<_>>(), after, "rebuilt from what was saved");
    assert_saw(&["AirPods Pro", "Bluetooth · Uses call-quality audio and lowers playback quality while recording."]);
    let row = SharedString::from(format!("settings.microphones.row.{}", start[0]));
    cx.update_window(r.win.into(), |_, w, cx| w.within(row).click("settings.microphones.remove", cx)).unwrap();
    frame(cx, r.win);
    assert_eq!(ids(cx).len(), n);
}

// parity: SET-186
#[flow_ui::gpui::test]
async fn remove_is_always_shown_except_on_system_default(cx: &mut TestAppContext) {
    let r = rig(cx, "microphones", |_| {});
    let entries = read(cx, r.win, |p, _| p.mics.as_ref().unwrap().entries.iter().map(|e| e.id.clone()).collect::<Vec<_>>());
    let default_id = core::InputEntry::system_default().id;
    assert!(entries.contains(&default_id));
    for id in entries {
        let row = SharedString::from(format!("settings.microphones.row.{id}"));
        let found = cx.update_window(r.win.into(), |_, w, _| w.within(row).find_all("settings.microphones.remove").iter().map(|b| b.visible()).collect::<Vec<_>>()).unwrap();
        // With no hover anywhere.
        assert_eq!(found, if id == default_id { vec![] } else { vec![true] }, "{id}");
    }
}

// parity: SET-190
#[flow_ui::gpui::test]
async fn voice_over_gets_move_buttons_within_the_rank_limits(cx: &mut TestAppContext) {
    let r = rig(cx, "voice-over", |_| {});
    let ids = |cx: &mut TestAppContext| read(cx, r.win, |p, _| p.mics.as_ref().unwrap().entries.iter().map(|e| e.id.clone()).collect::<Vec<_>>());
    let start = ids(cx);
    assert!(!has(cx, r.win, format!("settings.microphones.moveUp.{}", start[0]).leak()), "rank 1 has no Move up");
    assert!(!has(cx, r.win, format!("settings.microphones.moveDown.{}", start[2]).leak()), "the last has no Move down");
    let down: &'static str = format!("settings.microphones.moveDown.{}", start[0]).leak();
    let label = cx.update_window(r.win.into(), |_, w, _| w.find(down).label().map(|l| l.to_string())).unwrap().unwrap();
    assert!(label.starts_with("Move down: Blue Yeti"), "{label}");
    click(cx, r.win, down);
    assert_eq!(ids(cx)[1], start[0]);
    click(cx, r.win, format!("settings.microphones.moveUp.{}", start[0]).leak());
    assert_eq!(ids(cx)[0], start[0]);
    let r = rig(cx, "microphones", |_| {});
    let first = read(cx, r.win, |p, _| p.mics.as_ref().unwrap().entries[0].id.clone());
    assert!(!has(cx, r.win, format!("settings.microphones.moveDown.{first}").leak()), "only under VoiceOver");
}

// parity: SET-189
#[flow_ui::gpui::test]
async fn dragging_over_a_row_shows_the_two_point_bar(cx: &mut TestAppContext) {
    use flow_ui::gpui::{Modifiers, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, PlatformInput};
    let r = rig(cx, "microphones", |_| {});
    let ids = read(cx, r.win, |p, _| p.mics.as_ref().unwrap().entries.iter().map(|e| format!("settings.microphones.row.{}", e.id)).collect::<Vec<_>>());
    let target: &'static str = ids[0].clone().leak();
    let source: &'static str = ids[1].clone().leak();
    let (top, from) = (bounds(cx, r.win, target), bounds(cx, r.win, source).center());
    let to = top.center();
    let send = |cx: &mut TestAppContext, e: PlatformInput| {
        cx.update_window(r.win.into(), |_, w, cx| w.dispatch_event(e, cx)).unwrap();
    };
    send(cx, PlatformInput::MouseDown(MouseDownEvent { button: MouseButton::Left, position: from, modifiers: Modifiers::default(), click_count: 1, first_mouse: false }));
    send(cx, PlatformInput::MouseMove(MouseMoveEvent { position: to, pressed_button: Some(MouseButton::Left), modifiers: Modifiers::default() }));
    send(cx, PlatformInput::MouseMove(MouseMoveEvent { position: to, pressed_button: Some(MouseButton::Left), modifiers: Modifiers::default() }));
    frame(cx, r.win);
    let bar = bounds(cx, r.win, "settings.microphones.dropBar");
    assert_eq!((bar.size.height, bar.top(), bar.size.width), (px(2.), bounds(cx, r.win, target).top(), top.size.width), "2 pt at the top of the targeted row");
    assert_eq!(bounds(cx, r.win, target).size.height, top.size.height, "the bar doesn't move the row");
    send(cx, PlatformInput::MouseUp(MouseUpEvent { button: MouseButton::Left, position: to, modifiers: Modifiers::default(), click_count: 1 }));
    frame(cx, r.win);
    assert!(!has(cx, r.win, "settings.microphones.dropBar"), "gone after the drop");
}

// parity: SET-201 SET-203 SET-205 SET-207
#[flow_ui::gpui::test]
async fn app_context_switches(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    click(cx, r.win, "settings.contextEnabled");
    assert_eq!(pref_b(cx, "contextEnabled"), Some(true));
    assert_saw(&["Turn on rewriting first."]);
    assert!(!disabled(cx, r.win, "settings.contextStyleEnabled"));
    click(cx, r.win, "settings.contextStyleEnabled");
    assert_eq!(pref_b(cx, "contextStyleEnabled"), Some(true));
    set(cx, r.win, |_, _, cx| prefs_mut(cx).set("rewriteEnabled", true));
    click(cx, r.win, "settings.contextRewriteEnabled");
    assert_eq!(pref_b(cx, "contextRewriteEnabled"), Some(true));
}

// parity: SET-220 SET-222
#[flow_ui::gpui::test]
async fn context_rows_use_the_app_name_and_show_remove_on_focus(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    click(cx, r.win, "settings.contextExclusions");
    assert_saw(&["Alpha Keys"]);
    let top = |cx: &mut TestAppContext, id: &str| bounds(cx, r.win, format!("context.row.{id}").leak()).top();
    assert!(top(cx, "com.apple.Passwords") < top(cx, "com.1password.1password"), "sorted by name, not bundle ID");
    let remove = SharedString::from("context.remove.com.apple.Passwords");
    assert_eq!(cx.update_window(r.win.into(), |_, w, _| w.find(remove.clone()).label().map(|l| l.to_string())).unwrap().as_deref(), Some("Stop excluding Alpha Keys"));
    let focus = read(cx, r.win, |p, _| p.remove_focus.borrow()["com.apple.Passwords"].clone());
    set(cx, r.win, |p, w, cx| p.focus.focus(w, cx));
    assert!(!cx.update_window(r.win.into(), |_, w, cx| focus.contains_focused(w, cx)).unwrap(), "page focus doesn't reveal it");
    set(cx, r.win, |_, w, cx| focus.focus(w, cx));
    assert!(cx.update_window(r.win.into(), |_, w, cx| focus.contains_focused(w, cx)).unwrap(), "`focus_revealed` shows the button on exactly this condition");
    click(cx, r.win, "settings.contextDone");
    click(cx, r.win, "settings.contextKinds");
    pick(cx, r.win, "context.running", "dev.zed.Zed");
    pick(cx, r.win, "context.addKind", "email");
    click(cx, r.win, "settings.contextAdd");
    assert_eq!(cx.update_window(r.win.into(), |_, w, _| w.find("context.remove.dev.zed.Zed").label().map(|l| l.to_string())).unwrap().as_deref(), Some("Use the built-in kind for dev.zed.Zed"));
}

// parity: SET-213 SET-219 SET-221 SET-226 SET-228 SET-231 SET-232 SET-234 SET-236 SET-237
#[flow_ui::gpui::test]
async fn exclusions_sheet(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    click(cx, r.win, "settings.contextExclusions");
    assert_saw(&["Excluded apps", "App context is never read in these apps.", "com.apple.Passwords", "Always", "Running app"]);
    assert!(disabled(cx, r.win, "settings.contextAdd"));
    let count = |cx: &mut TestAppContext| cx.update(|cx| core::exclusions(&cx.global::<Core>().prefs).len());
    let before = count(cx);
    type_into(cx, r.win, |p| p.bundle_draft.clone(), "has space");
    click(cx, r.win, "settings.contextAdd");
    assert_saw(&["Enter a bundle ID such as com.example.App. At most 200 apps can be excluded."]);
    assert_eq!(count(cx), before);
    type_into(cx, r.win, |p| p.bundle_draft.clone(), "aaa.example.New");
    click(cx, r.win, "settings.contextAdd");
    assert_eq!(count(cx), before + 1);
    assert!(read(cx, r.win, |p, cx| val(&p.bundle_draft, cx).is_empty()), "draft clears");
    assert!(read(cx, r.win, |p, _| p.exclusion_error.is_none()));
    assert_saw(&["aaa.example.New"]);
    cx.update_window(r.win.into(), |_, w, cx| w.hover("context.row.aaa.example.New", cx)).unwrap();
    frame(cx, r.win);
    click(cx, r.win, "context.remove.aaa.example.New");
    assert_eq!(count(cx), before);
    pick(cx, r.win, "context.running", "dev.zed.Zed");
    assert_eq!(count(cx), before + 1, "a running app is added at once");
    click(cx, r.win, "settings.contextDone");
    assert!(read(cx, r.win, |p, _| p.modal.is_none()));
    assert_saw(&["11 apps"]);
}

// parity: SET-214 SET-223 SET-224 SET-225 SET-228 SET-230 SET-235
#[flow_ui::gpui::test]
async fn kinds_sheet(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    click(cx, r.win, "settings.contextKinds");
    assert_saw(&["App kinds", "Sets the kind of app used for writing style.", "No apps yet", "Work chat"]);
    pick(cx, r.win, "context.running", "dev.zed.Zed");
    assert_eq!(read(cx, r.win, |p, cx| val(&p.bundle_draft, cx)), "dev.zed.Zed", "only fills the draft");
    pick(cx, r.win, "context.addKind", "email");
    click(cx, r.win, "settings.contextAdd");
    let kind = |cx: &mut TestAppContext| cx.update(|cx| core::overrides(&cx.global::<Core>().prefs).get("dev.zed.Zed").cloned());
    assert_eq!(kind(cx).as_deref(), Some("email"));
    assert_saw(&["dev.zed.Zed", "Email"]);
    set(cx, r.win, |p, w, cx| p.apply_pick("context.kind.dev.zed.Zed", "code", w, cx));
    assert_eq!(kind(cx).as_deref(), Some("code"));
    cx.update_window(r.win.into(), |_, w, cx| w.hover("context.row.dev.zed.Zed", cx)).unwrap();
    frame(cx, r.win);
    click(cx, r.win, "context.remove.dev.zed.Zed");
    assert_eq!(kind(cx), None);
    type_into(cx, r.win, |p| p.bundle_draft.clone(), "bad id");
    click(cx, r.win, "settings.contextAdd");
    assert_saw(&["At most 200 apps can have a kind."]);
    click(cx, r.win, "settings.contextDone");
}

// parity: SET-243 SET-241 SET-242 SET-244 SET-245 SET-246 SET-249 SET-250 SET-251 SET-264 SET-265
#[flow_ui::gpui::test]
async fn installed_model_controls(cx: &mut TestAppContext) {
    let r = rig(cx, "installed", |_| {});
    assert_saw(&["Dictation · Unloaded", "Load"]);
    assert!(!has(cx, r.win, "settings.speechDownload"));
    click(cx, r.win, "settings.speechLoad");
    assert!(logged(&r, "action load"));
    click(cx, r.win, "settings.test.speech");
    assert!(logged(&r, "action test.speech"), "the Test action reaches the service");
    assert_saw(&["Working · "]);
    r.ok.set(false);
    click(cx, r.win, "settings.test.speech");
    assert_saw(&["Dictation · Error type flow_platform.Unavailable, code 0."]);
    r.ok.set(true);
    set(cx, r.win, |p, _, _| p.testing = Some("speech"));
    assert_saw(&["Testing…"]);
    assert!(rig_saw_loaded(cx));
    let r = rig(cx, "alt-installed", |_| {});
    click(cx, r.win, "settings.alternateUse");
    assert!(r.log.borrow().iter().any(|l| l.starts_with("action useSpeechModel.")));
    let r = rig(cx, "approved", |_| {});
    assert_saw(&["Dictation · On this Mac (used if the server is unreachable)"]);
    drop(r);
}
fn rig_saw_loaded(cx: &mut TestAppContext) -> bool {
    let r = rig(cx, "loaded", |_| {});
    let unload = saw("Unload") && saw("Ready");
    let _ = has(cx, r.win, "settings.speechLoad");
    unload
}

// parity: SET-260
#[flow_ui::gpui::test]
async fn alternate_row_detail_and_when_it_shows(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    let r = rig(cx, "alternate", |_| {});
    assert!(has(cx, r.win, "settings.alternateSpeechModel"));
    let a = read(cx, r.win, |p, _| p.snapshot.alternate.clone().unwrap());
    let place = cx.update(|cx| core::routing(&cx.global::<Core>().prefs).model_place(flow_core::settings::Service::Dictation).map_or(a.role().to_string(), |x| format!("{} · {x}", a.role())));
    assert_saw(&[&format!("{place} · CC BY 4.0 · {}", a.readiness())]);
    set(cx, r.win, |p, _, _| p.snapshot.alternate = None);
    assert!(!has(cx, r.win, "settings.alternateSpeechModel"), "no other manifest, no row");
}

// parity: SET-253 SET-254 SET-255 SET-257 SET-258 SET-259 SET-261 SET-262 SET-263 SET-266 SET-267 SET-268 SET-269
#[flow_ui::gpui::test]
async fn downloads_and_progress(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    click(cx, r.win, "settings.speechDownload");
    let size = core::byte_count(core::speech_download_bytes(read(cx, r.win, |p, _| p.snapshot.speech_model)));
    assert_saw(&["Download Parakeet", &format!("{size}\n"), "License: CC BY 4.0"]);
    click(cx, r.win, "settings.alert.cancel");
    assert!(!logged(&r, "action download"));
    click(cx, r.win, "settings.speechDownload");
    click(cx, r.win, "settings.alert.confirm");
    assert!(logged(&r, "action download"));
    assert!(!has(cx, r.win, "settings.installProgress"), "the action returned; nothing is installing yet");
    r.install.set(Some((10, 100, false)));
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    assert!(has(cx, r.win, "settings.installProgress"), "installing takes over from performing");
    assert!(!has(cx, r.win, "settings.speechDownload"));
    r.install.set(None);
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    click(cx, r.win, "settings.speechImport");
    assert!(logged(&r, "action importModel"));
    let r = rig(cx, "installing", |_| {});
    assert_saw(&["Downloading…"]);
    assert!(has(cx, r.win, "settings.installProgress"));
    click(cx, r.win, "settings.installCancel");
    assert!(logged(&r, "action cancelInstall"));
    rig(cx, "verifying", |_| {});
    assert_saw(&["Verifying…"]);
    let r = rig(cx, "alternate", |_| {});
    assert_saw(&["CC BY 4.0", "Not installed · "]);
    click(cx, r.win, "settings.alternateDownload");
    assert_saw(&["from Hugging Face, verified against pinned hashes.", "Dictation keeps using"]);
    click(cx, r.win, "settings.alert.confirm");
    assert!(logged(&r, "action downloadAlternateSpeechModel"));
    let r = rig(cx, "alt-downloading", |_| {});
    assert_saw(&["Downloading…"]);
    assert!(has(cx, r.win, "settings.alternateProgress"));
    click(cx, r.win, "settings.alternateCancel");
    assert!(logged(&r, "action cancelAlternateSpeechModel"));
}

// parity: SET-271 SET-273 SET-275 SET-277 SET-279 SET-281 SET-285 SET-286
#[flow_ui::gpui::test]
async fn other_models(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    for (id, action) in [("settings.meetingDownload", "downloadMeetingModel"), ("settings.meetingImport", "importMeetingModel"), ("settings.speakerDownload", "downloadSpeakerModel"), ("settings.speakerImport", "importSpeakerModel"), ("settings.boostDownload", "downloadBoostModel")] {
        click(cx, r.win, id);
        assert!(logged(&r, &format!("action {action}")), "{action}");
    }
    click(cx, r.win, "settings.keepModelReady");
    assert_eq!(pref_b(cx, "keepModelReady"), Some(true));
    assert!(!logged(&r, "action load"), "not installed: nothing to load");
    let r = rig(cx, "others-installing", |_| {});
    assert_saw(&["Meeting transcripts · Installing…", "Who said what · Installing…", "Dictionary terms in dictation · Installing…"]);
    assert!(!has(cx, r.win, "settings.meetingDownload"));
    let r = rig(cx, "all-installed", |_| {});
    assert_saw(&["Meeting transcripts · Ready", "Who said what · Ready", "Dictionary terms in dictation · Ready"]);
    assert!(has(cx, r.win, "settings.test.meeting") && has(cx, r.win, "settings.test.speaker"));
    assert!(!has(cx, r.win, "settings.boostDownload"));
    click(cx, r.win, "settings.keepModelReady");
    assert!(logged(&r, "action load"), "installed: loads now");
}

// parity: SET-287 SET-288 SET-289 SET-290 SET-291
#[flow_ui::gpui::test]
async fn rewrite_model_rows_need_the_loopback_endpoint(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert!(!has(cx, r.win, "settings.localModelIdleUnload"));
    let r = rig(cx, "", |p| p.set("rewriteEndpoint", core::loopback_endpoint()));
    assert_saw(&["Unload rewrite model", "Unload during games", "Never"]);
    pick(cx, r.win, "settings.localModelIdleUnload", "900");
    assert_eq!(pref_i(cx, "localModelIdleUnload", 0), 900);
    click(cx, r.win, "settings.unloadLocalModelDuringGames");
    assert_eq!(pref_b(cx, "unloadLocalModelDuringGames"), Some(false));
}

// parity: SET-294 SET-296 SET-297 SET-299 SET-300 SET-304 SET-308 SET-309 SET-323 SET-324 SET-019
#[flow_ui::gpui::test]
async fn rewriting_blocks_until_address_and_secret_are_right(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert!(disabled(cx, r.win, "settings.rewriteEnabled"));
    type_into(cx, r.win, |p| p.endpoint.clone(), "http://10.0.0.5:8080");
    assert_eq!(pref_s(cx, "rewriteEndpoint").as_deref(), Some("http://10.0.0.5:8080"), "each keystroke writes raw text");
    assert_saw(&["Allow the unencrypted connection to this server first, or use https://.", "Allow unencrypted connection"]);
    click(cx, r.win, "settings.rewriteInsecureOverride");
    assert!(cx.update(|cx| core::insecure_override(&cx.global::<Core>().prefs, "http://10.0.0.5:8080")));
    assert_saw(&["Transcripts and the credential travel unencrypted to 10.0.0.5.", "Set a credential for this server first."]);
    type_into(cx, r.win, |p| p.credential.clone(), "s3cret-value");
    click(cx, r.win, "settings.rewriteCredentialSave");
    assert_eq!(r.secrets.borrow().get(&core::rewrite_keychain("http://10.0.0.5:8080")).map(String::as_str), Some("s3cret-value"), "the typed text, not its mask");
    assert!(!disabled(cx, r.win, "settings.rewriteEnabled"));
    click(cx, r.win, "settings.rewriteEnabled");
    assert_eq!(pref_b(cx, "rewriteEnabled"), Some(true));
    pick(cx, r.win, "settings.rewriteDefaultMode", "polished");
    assert_eq!(pref_s(cx, "rewriteDefaultMode").as_deref(), Some("polished"));
    // A different origin loses the override, and rewriting turns off.
    type_into(cx, r.win, |p| p.endpoint.clone(), "");
    assert_eq!(pref_b(cx, "rewriteEnabled"), Some(false));
    assert_saw(&["Enter a valid http:// or https:// endpoint first."]);
    assert!(cx.update(|cx| !core::insecure_override(&cx.global::<Core>().prefs, "http://10.0.0.5:8080")));
}

// parity: SET-311 SET-312 SET-313 SET-314 SET-315 SET-316 SET-317 SET-318 SET-319 SET-320 SET-321
#[flow_ui::gpui::test]
async fn saved_secret_can_be_revealed_edited_and_removed(cx: &mut TestAppContext) {
    let r = rig(cx, "", |p| p.set("rewriteEndpoint", "https://rw.example.com"));
    let account = core::rewrite_keychain("https://rw.example.com");
    assert!(disabled(cx, r.win, "settings.rewriteCredentialSave"), "empty draft");
    type_into(cx, r.win, |p| p.credential.clone(), " padded ");
    click(cx, r.win, "settings.rewriteCredentialSave");
    assert_saw(&["Remove surrounding whitespace and line breaks."]);
    type_into(cx, r.win, |p| p.credential.clone(), "abc");
    r.ok.set(false);
    click(cx, r.win, "settings.rewriteCredentialSave");
    assert!(read(cx, r.win, |p, _| p.credential_error.is_some()));
    r.ok.set(true);
    click(cx, r.win, "settings.rewriteCredentialSave");
    assert_saw(&["Saved in Keychain", "••••••••••••"]);
    assert!(read(cx, r.win, |p, cx| p.credential_draft(cx).is_empty()));
    click(cx, r.win, "settings.rewriteCredentialEdit");
    assert_saw(&["Reveal saved secret"]);
    click(cx, r.win, "settings.rewriteCredentialReveal");
    assert_eq!(read(cx, r.win, |p, cx| p.credential_draft(cx)), "abc");
    assert_saw(&["Hide saved secret"]);
    click(cx, r.win, "settings.rewriteCredentialReveal");
    assert!(read(cx, r.win, |p, cx| p.credential_draft(cx).is_empty()));
    click(cx, r.win, "settings.rewriteCredentialCancel");
    assert!(read(cx, r.win, |p, _| !p.editing_credential));
    click(cx, r.win, "settings.rewriteCredentialEdit");
    click(cx, r.win, "settings.rewriteCredentialRemove");
    assert!(!r.secrets.borrow().contains_key(&account));
    assert_saw(&["Set a credential for this server first."]);
}

// parity: SET-329
#[flow_ui::gpui::test]
async fn rewrite_advanced_starts_collapsed_with_padding_14(cx: &mut TestAppContext) {
    let r = rig(cx, "", |p| p.set("rewriteEndpoint", "https://rw.example.com"));
    assert!(!saw("Timeout"), "collapsed");
    assert_saw(&["Advanced"]);
    let (row, button) = (bounds(cx, r.win, "settings.rewriteAdvancedRow"), bounds(cx, r.win, "settings.rewriteAdvanced"));
    assert_eq!((button.top() - row.top(), row.bottom() - button.bottom()), (px(14.), px(14.)));
}

// parity: SET-325 SET-330 SET-331 SET-333 SET-298 SET-305
#[flow_ui::gpui::test]
async fn test_connection_preflight_and_advanced(cx: &mut TestAppContext) {
    let r = rig(cx, "", |p| p.set("rewriteEndpoint", "https://rw.example.com"));
    click(cx, r.win, "settings.rewriteTestConnection");
    assert_saw(&["Set a credential"]);
    assert_eq!(read(cx, r.win, |p, _| p.connection.as_ref().map(|c| c.2)), Some("preflight"), "preflight sends nothing");
    click(cx, r.win, "settings.rewriteAdvanced");
    assert_saw(&["Timeout", "20 seconds", "Developer diagnostics"]);
    click(cx, r.win, "settings.rewriteTimeout.up");
    assert_eq!(pref_i(cx, "rewriteTimeoutSeconds", 0), 21);
    click(cx, r.win, "settings.rewriteTimeout.down");
    assert_eq!(pref_i(cx, "rewriteTimeoutSeconds", 0), 20);
    click(cx, r.win, "settings.rewriteDiagnostics");
    assert_saw(&["connection_test=", "code=preflight"]);
}

// parity: SET-337 SET-338 SET-339 SET-340 SET-341 SET-342 SET-343 SET-344 SET-345 SET-346
#[flow_ui::gpui::test]
async fn summaries_fields_and_key(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert!(!has(cx, r.win, "settings.summaryServerKeySave"));
    pick(cx, r.win, "settings.summaryServer", "remote");
    assert_eq!(pref_s(cx, "summaryServer").as_deref(), Some("remote"));
    assert_saw(&["Server URL", "Model", "API key", "http://host:8000/v1"]);
    assert_eq!(cx.update_window(r.win.into(), |_, w, _| w.find_by_label("Model").placeholder().map(|l| l.to_string())).unwrap().as_deref(), Some("Model"));
    type_into(cx, r.win, |p| p.summary_url.clone(), "http://host:8000/v1");
    assert_eq!(pref_s(cx, "summaryServerURL").as_deref(), Some("http://host:8000/v1"));
    type_into(cx, r.win, |p| p.summary_model.clone(), "qwen");
    assert_eq!(pref_s(cx, "summaryServerModel").as_deref(), Some("qwen"));
    assert!(disabled(cx, r.win, "settings.summaryServerKeySave"));
    type_into(cx, r.win, |p| p.summary_key.clone(), " x ");
    click(cx, r.win, "settings.summaryServerKeySave");
    assert_saw(&["Remove surrounding whitespace and line breaks."]);
    type_into(cx, r.win, |p| p.summary_key.clone(), "key-1");
    click(cx, r.win, "settings.summaryServerKeySave");
    assert_eq!(r.secrets.borrow().get(&core::rewrite_keychain(core::SUMMARY_ACCOUNT)).map(String::as_str), Some("key-1"));
    assert_saw(&["••••••••••••"]);
    click(cx, r.win, "settings.summaryServerKeyEdit");
    assert!(has(cx, r.win, "settings.summaryServerKeyCancel"));
    click(cx, r.win, "settings.summaryServerKeyCancel");
    assert!(read(cx, r.win, |p, _| !p.editing_summary_key));
}

// parity: SET-022 SET-353 SET-354 SET-355 SET-356
#[flow_ui::gpui::test]
async fn permission_buttons(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    click(cx, r.win, "settings.allow.Microphone");
    assert!(logged(&r, "request Microphone"));
    assert!(logged(&r, "settings Microphone"), "refused opens System Settings");
    let r = rig(cx, "permissions-refused", |_| {});
    click(cx, r.win, "settings.allow.Accessibility");
    assert!(!logged(&r, "request Accessibility"), "denied goes straight to System Settings");
    assert!(logged(&r, "settings Accessibility"));
    assert!(logged(&r, "reveal"), "not trusted: the app is shown in Finder");
    assert_eq!(read(cx, r.win, |p, _| p.snapshot.status.clone()), "Enable LocalFlow in Accessibility settings. The app is shown in Finder if you need to add it.");
    assert!(!logged(&r, "settings Microphone"), "only the pane asked for");
    r.ok.set(false);
    click(cx, r.win, "settings.allow.Accessibility");
    assert_saw(&["Error type flow_platform.Unavailable, code 0."]);
}

#[cfg(unix)]
#[path = "../../../../../crates/flow-core/src/settings/test_flowd.rs"]
mod test_flowd;

// parity: SET-045 SET-055 SET-070 SET-072 SET-119 SET-326 SET-327 SET-328 SET-332
// Starts its own throwaway flowd; see `test_flowd`. Never the owner's server.
#[cfg(unix)]
#[flow_ui::gpui::test]
async fn real_flowd_through_the_page(cx: &mut TestAppContext) {
    let flowd = test_flowd::Flowd::start();
    let (identity_url, rewrite_url, token, expected_fp) = (flowd.remote.clone(), flowd.rewrite.clone(), flowd.token.clone(), flowd.fingerprint.clone());
    cx.executor().allow_parking();
    let wait = |cx: &mut TestAppContext, win: Win, done: &dyn Fn(&SettingsPage) -> bool| {
        for _ in 0..100 {
            if read(cx, win, |p, _| done(p)) {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
            frame(cx, win);
        }
        panic!("timed out");
    };
    // Consent, identity, Trust.
    let r = rig(cx, "checking", |_| {});
    set(cx, r.win, |p, _, _| p.remote_base = Some(identity_url.clone()));
    set(cx, r.win, |p, _, cx| p.fetch_identity(cx));
    wait(cx, r.win, &|p| !p.busy);
    frame(cx, r.win);
    assert_saw(&["Compare the fingerprint", &expected_fp]);
    click(cx, r.win, "settings.remoteTrust");
    assert_eq!(pref_s(cx, "remote.state").as_deref(), Some("pinned"));
    // Check connection runs the sealed channel: nothing pinned is unreachable, as Swift's nil
    // `sessionInputs`; with the pin and an approved device's token it times `ready`.
    let r = rig(cx, "approved", |_| {});
    set(cx, r.win, |p, _, _| p.remote_base = Some(identity_url.clone()));
    click(cx, r.win, "settings.serverCheckConnection");
    wait(cx, r.win, &|p| !p.checking);
    frame(cx, r.win);
    assert_saw(&["Server unreachable"]);
    let identity = core::fetch_identity(&identity_url).unwrap();
    r.secrets.borrow_mut().insert(core::remote_keychain("server-key"), identity.server_key);
    r.secrets.borrow_mut().insert(core::remote_keychain("access-token"), flowd.access_token.clone());
    flow_ui::probe::clear();
    click(cx, r.win, "settings.serverCheckConnection");
    wait(cx, r.win, &|p| !p.checking);
    frame(cx, r.win);
    assert_saw(&["Answered in "]);
    // A wrong identity base is reported, not trusted.
    let r = rig(cx, "checking", |_| {});
    set(cx, r.win, |p, _, _| p.remote_base = Some("http://127.0.0.1:9".into()));
    set(cx, r.win, |p, _, cx| p.fetch_identity(cx));
    wait(cx, r.win, &|p| !p.busy);
    frame(cx, r.win);
    assert_saw(&["The server did not answer with a LocalFlow identity. Check the address."]);
    // Rewrite health and its identity block, right and wrong secret.
    let r = rig(cx, "", |p| {
        p.set("rewriteEndpoint", rewrite_url.as_str());
    });
    let account = core::rewrite_keychain(&core::normalized_origin(&rewrite_url).unwrap());
    r.secrets.borrow_mut().insert(account.clone(), "wrong-secret".into());
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    click(cx, r.win, "settings.rewriteTestConnection");
    wait(cx, r.win, &|p| !p.connection_testing);
    frame(cx, r.win);
    assert_saw(&["The server rejected the credential."]);
    r.secrets.borrow_mut().insert(account, token);
    click(cx, r.win, "settings.rewriteTestConnection");
    wait(cx, r.win, &|p| !p.connection_testing);
    frame(cx, r.win);
    assert_saw(&["Connected.", &format!("Meeting analysis: available (model {}).", test_flowd::MODEL)]);
    click(cx, r.win, "settings.rewriteAdvanced");
    assert_saw(&["Server: flowd "]);
}


fn bounds(cx: &mut TestAppContext, win: Win, id: &'static str) -> Bounds<Pixels> {
    cx.update_window(win.into(), |_, w, _| w.find(id).bounds()).unwrap()
}

fn gap(a: Bounds<Pixels>, b: Bounds<Pixels>) -> f32 {
    f32::from(b.left() - a.right())
}

// parity: SET-129 SET-149 SET-151 SET-166 SET-172 SET-288 SET-303 SET-336 SET-352 SET-352
#[flow_ui::gpui::test]
async fn controls_have_swifts_measured_sizes(cx: &mut TestAppContext) {
    let r = rig(cx, "advanced", |_| {});
    let switch = bounds(cx, r.win, "settings.remoteEnabled").size;
    assert_eq!((f32::from(switch.width), f32::from(switch.height)), (54., 24.));
    let cell = bounds(cx, r.win, "settings.serverFallbackThreshold.cell");
    assert_eq!((f32::from(cell.size.width), f32::from(cell.size.height)), STEPPER);
    let (up, down) = (bounds(cx, r.win, "settings.serverFallbackThreshold.up"), bounds(cx, r.win, "settings.serverFallbackThreshold.down"));
    assert_eq!((up.top(), up.bottom(), down.bottom()), (cell.top(), down.top(), cell.bottom()), "one cell split in two");
    assert_eq!(bounds(cx, r.win, "settings.serverOverride.dictation.frame").size.width, px(150.));
    let r = rig(cx, "", |_| {});
    assert!(bounds(cx, r.win, "settings.shortcut").size.width >= px(99.));
    assert_eq!(bounds(cx, r.win, "settings.appearance.frame").size.width, px(110.));
    assert_eq!(bounds(cx, r.win, "settings.meetingLanguage.frame").size.width, px(210.));
    assert_eq!(bounds(cx, r.win, "settings.rewriteDefaultMode.frame").size.width, px(120.));
    assert_eq!(bounds(cx, r.win, "settings.summaryServer.frame").size.width, px(110.));
    assert!(bounds(cx, r.win, "settings.allow.Microphone").size.width >= px(99.));
    let r = rig(cx, "meeting-only", |_| {});
    assert!(bounds(cx, r.win, "settings.setUpDictation").size.width >= px(99.));
    let r = rig(cx, "", |p| p.set("rewriteEndpoint", core::loopback_endpoint()));
    assert_eq!(bounds(cx, r.win, "settings.localModelIdleUnload.frame").size.width, px(130.));
}

// parity: SET-001 SET-004 SET-005 SET-007 SET-240
#[flow_ui::gpui::test]
async fn page_rows_and_sections_are_spaced_like_swift(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    let content = bounds(cx, r.win, "settings.content");
    let (section, text) = (bounds(cx, r.win, "settings.section.General"), bounds(cx, r.win, "settings.section.General.text"));
    assert_eq!((content.size.width, bounds(cx, r.win, "settings.pageTitle").top() - content.top()), (px(960.), px(47.)), "max width and top padding");
    assert_eq!((text.top() - section.top(), section.bottom() - text.bottom()), (px(29.), px(13.)));
    let row = bounds(cx, r.win, "settings.row.Learn corrections");
    assert_eq!(row.left() - content.left(), px(47. + 19.), "page padding, then the group's horizontal padding");
    let (left, switch) = (bounds(cx, r.win, "settings.row.Learn corrections.text"), bounds(cx, r.win, "settings.learnCorrections"));
    assert_eq!((gap(left, switch), row.size.height), (44., switch.size.height + px(38.)), "spacing 22 on each side of the Spacer, vertical padding 19");
    let r = rig(cx, "installed", |_| {});
    assert_eq!(gap(bounds(cx, r.win, "settings.speechLoad"), bounds(cx, r.win, "settings.test.speech")), 8., "model controls");
}

// parity: SET-077 SET-080 SET-107 SET-212 SET-213 SET-215 SET-217 SET-226 SET-229 SET-011
#[flow_ui::gpui::test]
async fn sheets_have_swifts_geometry(cx: &mut TestAppContext) {
    let r = rig(cx, "consent", |_| {});
    let sheet = bounds(cx, r.win, "settings.sheet");
    assert_eq!((sheet.size.width, bounds(cx, r.win, "settings.consentBody").left() - sheet.left()), (px(460.), px(24.)));
    let body = bounds(cx, r.win, "settings.consentBody");
    assert!(body.size.height > px(3. * 16.) && body.size.width == px(412.), "wraps inside the padding: {body:?}");
    let r = rig(cx, "consent-update-sheet", |_| {});
    let (sheet, cancel) = (bounds(cx, r.win, "settings.sheet"), bounds(cx, r.win, "settings.serverConsentCancel"));
    assert_eq!((sheet.size.width, sheet.bottom() - cancel.bottom()), (px(460.), px(24.)));
    let r = rig(cx, "exclusions", |_| {});
    let sheet = bounds(cx, r.win, "settings.sheet");
    let (header, list) = (bounds(cx, r.win, "settings.contextHeader"), bounds(cx, r.win, "settings.contextList"));
    assert_eq!((sheet.size.width, header.left() - sheet.left(), list.top() - header.bottom()), (px(480.), px(22.), px(18.)));
    assert!(header.size.height > px(30.), "title and description stacked: {header:?}");
    assert_eq!(list.size.height, px(308.), "min(10 x 57, 308)");
    assert_eq!(bounds(cx, r.win, "context.row.com.1password.1password").size.height, px(56.));
    let (menu, field, done) = (bounds(cx, r.win, "context.running"), bounds(cx, r.win, "settings.contextField"), bounds(cx, r.win, "settings.contextDone").size);
    assert_eq!(gap(menu, field), 8.);
    assert_eq!(field.size.height, px(30.), "13pt with padding 7, measured 30 in the reference");
    assert!(done.height >= px(36.) && done.height <= px(40.), "prominent pill: {done:?}");
}

// parity: SET-110 SET-120 SET-176 SET-258 SET-311 SET-316 SET-338
#[flow_ui::gpui::test]
async fn lower_sections_are_spaced_like_swift(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert!(!has(cx, r.win, "settings.serverServices"), "only when approved");
    let r = rig(cx, "approved", |_| {});
    set(cx, r.win, |p, _, _| p.check_result = Some("Answered in 3 ms".into()));
    assert_eq!(gap(bounds(cx, r.win, "settings.serverCheckResult"), bounds(cx, r.win, "settings.serverCheckConnection")), 10.);
    assert_eq!(bounds(cx, r.win, "settings.serverAdvanced").size.height, DISCLOSURE, "the audit's measured disclosure");
    let r = rig(cx, "", |p| p.set("rewriteEndpoint", "https://rw.example.com"));
    assert_eq!(bounds(cx, r.win, "settings.rewriteAdvanced").size.height, DISCLOSURE);
    let r = rig(cx, "microphones", |_| {});
    let (d, list) = (bounds(cx, r.win, "settings.microphones.description"), bounds(cx, r.win, "settings.microphones.list"));
    assert_eq!(list.top(), d.bottom(), "the 12 below the text is inside");
    let r = rig(cx, "installing", |_| {});
    let (bar, cancel) = (bounds(cx, r.win, "settings.installProgress"), bounds(cx, r.win, "settings.installCancel"));
    assert_eq!(cancel.top() - bar.bottom(), px(10.), "VStack spacing 10");
    let r = rig(cx, "", |p| p.set("rewriteEndpoint", "https://rw.example.com"));
    type_into(cx, r.win, |p| p.credential.clone(), "abc");
    click(cx, r.win, "settings.rewriteCredentialSave");
    click(cx, r.win, "settings.rewriteCredentialEdit");
    assert_eq!(gap(bounds(cx, r.win, "settings.rewriteCredentialRemove"), bounds(cx, r.win, "settings.rewriteCredentialCancel")), 12.);
    let header = bounds(cx, r.win, "settings.secretHeader");
    assert_eq!(bounds(cx, r.win, "settings.credentialRow").top() - header.bottom(), px(8.), "section spacing 8");
    let r = rig(cx, "summary-remote", |_| {});
    let (url, label) = (bounds(cx, r.win, "settings.summaryURLField"), bounds(cx, r.win, "settings.summaryModelLabel"));
    assert_eq!(label.top() - url.bottom(), px(14.), "spacing 14");
}

// parity: SET-020
#[flow_ui::gpui::test]
async fn microphones_anchor_scrolls_there_once(cx: &mut TestAppContext) {
    let r = rig(cx, "microphones", |_| {});
    cx.update(|cx| {
        let mut session = crate::shell::Session::new(cx.global::<Core>());
        session.microphones_anchor = true;
        cx.set_global(session);
    });
    set(cx, r.win, |p, _, cx| p.take_anchor(cx));
    assert_eq!(cx.update(|cx| cx.global::<crate::shell::Session>().microphones_anchor), false, "the anchor clears");
    let (y, top) = read(cx, r.win, |p, _| (p.scroll.offset().y, p.mic_top.get()));
    assert!(y < px(0.) && top > px(0.), "scrolled down to the section: {y:?} {top:?}");
}

// parity: SET-067
#[flow_ui::gpui::test]
async fn sign_in_reports_an_unreachable_server(cx: &mut TestAppContext) {
    let r = rig(cx, "pinned", |_| {});
    set(cx, r.win, |p, _, cx| p.sign_in("unreachable", cx));
    frame(cx, r.win);
    assert_saw(&["The server could not be reached. Try again."]);
    assert!(!saw("Sign-in did not finish."));
}

fn input(id: u32, uid: &str, name: &str, kind: &'static str) -> flow_platform::InputDevice {
    flow_platform::InputDevice { device_id: id, uid: uid.into(), model_uid: None, name: name.into(), kind, alive: true }
}

// parity: SET-174 SET-177 SET-179 SET-180 SET-181 SET-184 SET-192 SET-196
#[flow_ui::gpui::test]
async fn microphones_follow_the_catalog(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert!(!saw("Microphones"), "hidden with no catalog");
    *r.catalog.borrow_mut() = Some(flow_platform::InputCatalog { devices: vec![input(1, "BuiltIn", "MacBook Pro Microphone", "builtIn")], default_input: Some(1), clamshell: false });
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    frame(cx, r.win);
    assert_saw(&["Microphones", "System default", "Currently: MacBook Pro Microphone"]);
    // A new device becomes an Add item and, once added, is stored and survives unplugging.
    r.catalog.borrow_mut().as_mut().unwrap().devices.push(input(2, "usb-1", "Blue Yeti", "usb"));
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    set(cx, r.win, |p, _, cx| p.add_mic("usb-1", cx));
    frame(cx, r.win);
    assert_saw(&["Blue Yeti", "USB"]);
    assert_eq!(cx.update(|cx| core::load_inputs(&cx.global::<Core>().prefs).len()), 2, "stored");
    r.catalog.borrow_mut().as_mut().unwrap().devices.pop();
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    frame(cx, r.win);
    assert_saw(&["USB · Not connected"]);
    // No default device reads as none; a closed lid takes the built-in out.
    r.catalog.borrow_mut().as_mut().unwrap().default_input = None;
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    set(cx, r.win, |p, _, cx| p.add_mic("BuiltIn", cx));
    frame(cx, r.win);
    assert_saw(&["Currently: none", "All connected microphones are listed", "Built-in"]);
    r.catalog.borrow_mut().as_mut().unwrap().clamshell = true;
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    frame(cx, r.win);
    assert_saw(&["Built-in · Not connected"]);
}

// parity: SET-024
#[flow_ui::gpui::test]
async fn selectable_text_copies(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    set(cx, r.win, |p, _, cx| {
        p.error = Some("Something failed".into());
        cx.notify();
    });
    frame(cx, r.win);
    let b = bounds(cx, r.win, "settings.error");
    let selected = cx.update_window(r.win.into(), |_, w, cx| {
        w.drag(point(b.left() + px(1.), b.center().y), point(b.left() + px(400.), b.center().y), cx);
        base::TextSelection::selected_text(w, cx)
    })
    .unwrap();
    assert_eq!(selected, "Something failed");
}

mod rows;
