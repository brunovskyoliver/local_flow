use super::*;
use crate::testing::{assert_saw, boot, saw};
use flow_platform::Fake;
use flow_ui::test::{TestAppContext, TestWindowExt};
use std::cell::{Cell, RefCell};
use std::path::PathBuf as Path;
use std::rc::Rc;

type Log = Rc<RefCell<Vec<String>>>;
type Win = WindowHandle<OnboardingPage>;

/// Fake OS services that record calls and either accept them all or are all `Unavailable`.
struct Stub {
    fake: Fake,
    ok: Rc<Cell<bool>>,
    log: Log,
}

impl Stub {
    fn call<T>(&self, name: String, value: T) -> Result<T, Unavailable> {
        self.log.borrow_mut().push(name);
        if self.ok.get() { Ok(value) } else { Err(Unavailable("this service")) }
    }
}

impl flow_platform::Services for Stub {
    fn name(&self) -> &'static str {
        "stub"
    }
    fn device_word(&self) -> &'static str {
        self.fake.device_word()
    }
    fn app_data_dir(&self) -> Path {
        self.fake.app_data_dir()
    }
    fn permission(&self, p: Permission) -> PermissionState {
        self.fake.permission(p)
    }
    fn open_permission_settings(&self, p: Permission) -> Result<(), Unavailable> {
        self.call(format!("settings {p:?}"), ())
    }
    fn high_contrast(&self) -> bool {
        false
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
    fn secret(&self, _: &str) -> Result<Option<String>, Unavailable> {
        Ok(None)
    }
    fn set_secret(&self, name: &str, _: &str) -> Result<(), Unavailable> {
        self.call(format!("secret {name}"), ())
    }
    fn physical_memory(&self) -> u64 {
        16 << 30
    }
    fn request_permission(&self, p: Permission) -> Result<PermissionState, Unavailable> {
        self.call(format!("request {p:?}"), PermissionState::Denied)
    }
    fn install_speech_model(&self) -> Result<(), Unavailable> {
        self.call("speech".into(), ())
    }
    fn install_meeting_models(&self) -> Result<(), Unavailable> {
        self.call("meeting".into(), ())
    }
    fn install_local_ai(&self, id: &str) -> Result<(), Unavailable> {
        self.call(format!("ai {id}"), ())
    }
    fn install_shortcut(&self, _: &str) -> Result<(), Unavailable> {
        self.call("shortcut".into(), ())
    }
    fn record_shortcut(&self) -> Result<(), Unavailable> {
        self.call("record".into(), ())
    }
    fn load_speech_model(&self) -> Result<(), Unavailable> {
        self.call("load".into(), ())
    }
    fn fetch_server_identity(&self, _: &str) -> Result<String, Unavailable> {
        self.call("identity".into(), "SHA256:abc".to_string())
    }
    fn enroll_device(&self, p: &str) -> Result<String, Unavailable> {
        self.call(format!("enroll {p}"), "pending".to_string())
    }
    fn rewrite_health(&self, _: &str) -> Result<(Option<String>, Option<String>, String), Unavailable> {
        self.call("health".into(), (Some("studio".to_string()), Some("qwen".to_string()), "Analysis uses this server.".to_string()))
    }
    fn session_command(&self, c: SessionCommand) -> Result<(), Unavailable> {
        self.call(format!("{c:?}"), ())
    }
}

struct Rig {
    win: Win,
    ok: Rc<Cell<bool>>,
    log: Log,
}

fn rig(cx: &mut TestAppContext, ok: bool, perms: &[(Permission, PermissionState)]) -> Rig {
    boot(cx, Mode::Light);
    let (ok, log): (Rc<Cell<bool>>, Log) = (Rc::new(Cell::new(ok)), Default::default());
    let fake = Fake::default();
    *fake.permissions.borrow_mut() = perms.to_vec();
    let services = Stub { fake, ok: ok.clone(), log: log.clone() };
    cx.update(|cx| cx.global_mut::<Core>().services = Box::new(services));
    let win = cx.add_window(|w, cx| OnboardingPage::new(w, cx));
    frame(cx, win);
    Rig { win, ok, log }
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

fn set(cx: &mut TestAppContext, win: Win, f: impl FnOnce(&mut OnboardingPage)) {
    win.update(cx, |p, _, cx| {
        p.frozen = true;
        f(p);
        cx.notify();
    })
    .unwrap();
    frame(cx, win);
}

fn read<T>(cx: &mut TestAppContext, win: Win, f: impl FnOnce(&OnboardingPage, &App) -> T) -> T {
    win.read_with(cx, |p, cx| f(p, cx)).unwrap()
}

fn pref(cx: &mut TestAppContext, key: &str) -> Option<String> {
    cx.update(|cx| cx.global::<Core>().prefs.string(key))
}

fn flag(cx: &mut TestAppContext, key: &str) -> bool {
    cx.update(|cx| cx.global::<Core>().prefs.bool_or(key, false))
}

fn ready(s: &mut Snapshot) {
    s.model_installed = true;
    s.speaker_model_installed = true;
    s.meeting_model_installed = true;
    s.microphone = Perm::Granted;
    s.input_monitoring = Perm::Granted;
    s.accessibility = Perm::Granted;
    s.system_audio = Perm::Granted;
    s.shortcut_ready = true;
    s.storage_available = true;
    s.shortcut = Shortcut::right_control();
}

fn disabled(cx: &mut TestAppContext, win: Win, id: &'static str) -> bool {
    win.update(cx, |_, w, _| w.find(id).disabled().unwrap_or(false)).unwrap()
}

// parity: ONB-012 ONB-028 ONB-029 ONB-031 ONB-032 ONB-036 ONB-037 ONB-040 ONB-041 ONB-042 ONB-055 ONB-056 ONB-062 ONB-076 ONB-118 ONB-119 ONB-120 ONB-121 ONB-122 ONB-123 ONB-124 ONB-125 ONB-126 ONB-127 ONB-128 ONB-129 ONB-130 ONB-131 ONB-134 ONB-135 ONB-136 ONB-137 ONB-138 ONB-139 ONB-140 ONB-141 ONB-142 ONB-143 ONB-144 ONB-145 ONB-146 ONB-147 ONB-148 ONB-149 ONB-151 ONB-152 ONB-153 ONB-051
#[flow_ui::gpui::test]
async fn introduction_purpose_and_location_copy(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    assert_saw(&["LocalFlow", "Your voice, written ", "on this Mac", "Hold a key in any app", "Private by design", "Works in every app", "Meeting notes", "Tidies up as you go", "Get started"]);
    let w = r.win;
    w.update(cx, |_, w, _| {
        assert_eq!(w.find("onboarding.progress").label().as_deref(), Some("Step 1 of 8"));
        assert!(w.try_find("onboarding.back").is_none());
    })
    .unwrap();
    click(cx, w, "onboarding.primary");
    assert_saw(&["What is LocalFlow ", "Setup only asks", "Both", "Recommended", "Dictation in every app", "Hold a key in any app and talk", "Record calls"]);
    w.update(cx, |_, w, _| assert!(w.try_find("onboarding.back").is_some())).unwrap();
    click(cx, w, "onboarding.primary");
    assert_saw(&["OPTIONAL", "AI", "A language model can polish", "On this Mac", "On your server", "Use a LocalFlow server on another", "MTPLX engine", "A language model", "Two background services", "Your text never leaves", "Skip for now"]);
    click(cx, w, "onboarding.ai.remote");
    assert_eq!(read(cx, w, |p, _| p.setup.ai_mode), AiMode::Remote);
    assert_saw(&["dictation audio, meeting recordings"]);
    click(cx, w, "onboarding.back");
    click(cx, w, "onboarding.purpose.meetings");
    assert_eq!(read(cx, w, |p, _| p.setup.purpose), Purpose::Meetings);
    click(cx, w, "onboarding.primary");
    assert_saw(&["MEETING NOTES", "meetings", "Recordings are always saved", "This computer", "Your server", "Nothing leaves this Mac", "Meeting audio, transcripts and summary text", "Skip for now to keep meetings"]);
    click(cx, w, "onboarding.ai.remote");
    assert_saw(&["recordings wait on this Mac"]);
    assert_eq!(pref(cx, "setup.purpose").as_deref(), Some("meetings"));
}

// parity: ONB-155 ONB-156 ONB-157 ONB-158 ONB-164 ONB-165 ONB-166 ONB-167 ONB-171 ONB-172 ONB-057 ONB-058 ONB-059 ONB-077 ONB-078 ONB-270 ONB-269
#[flow_ui::gpui::test]
async fn model_picker_gates_and_starts_downloads(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.downloaded[1] = true;
    });
    assert_saw(&["Choose a ", "This Mac has 16 GB of memory", "Qwen 3.5 4B Speed", "Uses about 2.9 GB", "Downloaded", "Needs 48 GB memory", "Download Qwen 3.5 4B Speed"]);
    assert!(disabled(cx, w, "onboarding.model.4"));
    click(cx, w, "onboarding.model.4");
    assert_eq!(read(cx, w, |p, _| p.selection), 0, "a model that doesn't fit can't be chosen");
    click(cx, w, "onboarding.model.1");
    assert_eq!(read(cx, w, |p, _| p.selection), 1);
    assert_saw(&["Use Qwen 3.5 4B Quality"]);
    set(cx, w, |p| {
        p.selection = 4;
        p.memory = 8 << 30;
    });
    assert!(disabled(cx, w, "onboarding.primary"));
    set(cx, w, |p| {
        p.selection = 1;
        p.memory = 16 << 30;
    });
    click(cx, w, "onboarding.primary");
    assert_eq!(read(cx, w, |p, _| p.setup.step), Step::Downloads);
    assert!(r.log.borrow().iter().any(|c| c == "speech"), "{:?}", r.log.borrow());
    let id = CATALOG[1].id;
    assert!(r.log.borrow().contains(&format!("ai {id}")));
}

// parity: ONB-249 ONB-250 ONB-251 ONB-252 ONB-253 ONB-254 ONB-255 ONB-256 ONB-257 ONB-258 ONB-259 ONB-260 ONB-261 ONB-262 ONB-263 ONB-265 ONB-275 ONB-276 ONB-277 ONB-278 ONB-279 ONB-280 ONB-272 ONB-273 ONB-046 ONB-047 ONB-038 ONB-039
#[flow_ui::gpui::test]
async fn downloads_show_each_row_and_retry(cx: &mut TestAppContext) {
    let r = rig(cx, false, &[]);
    let w = r.win;
    set(cx, w, |p| {
        p.setup.step = Step::Downloads;
        p.snap.installing = true;
        p.snap.progress = (10 << 20, 100 << 20);
        p.ai_phase = AiPhase::PreparingRuntime;
    });
    assert_saw(&["Getting ", "Downloads keep going", "Speech recognition", "On-device AI", "Installing MTPLX…", "Meeting transcription", "or skip for now", "Waiting for speech recognition…"]);
    assert!(saw(" of "), "a progress row shows bytes");
    // The offered Download goes to the service, which refuses, and the row says so.
    click(cx, w, "onboarding.meetingDownload");
    assert!(read(cx, w, |p, _| p.setup.meetings_requested));
    assert_saw(&["Stopped", "This build can't use this service yet."]);
    assert!(r.log.borrow().iter().any(|c| c == "meeting"));
    r.log.borrow_mut().clear();
    click(cx, w, "onboarding.retry.Meeting transcription");
    assert!(r.log.borrow().iter().any(|c| c == "meeting"));
    r.log.borrow_mut().clear();
    r.ok.set(false);
    set(cx, w, |p| {
        p.snap.installing = false;
        p.error = Some("x".into());
        p.ai_phase = AiPhase::Failed("y".into());
    });
    click(cx, w, "onboarding.retry.Speech recognition");
    assert!(r.log.borrow().iter().any(|c| c == "speech"));
    click(cx, w, "onboarding.retry.On-device AI");
    assert!(r.log.borrow().iter().any(|c| c.starts_with("ai ")));
    // Meeting path: its own lede and a wait; the server row on a remote path.
    set(cx, w, |p| {
        p.setup.purpose = Purpose::Meetings;
        p.setup.ai_mode = AiMode::Remote;
        p.snap.model_installed = true;
    });
    assert_saw(&["Meeting notes on this Mac need these models", "Your server", "Waiting for meeting models…", "used when the server can't be reached"]);
    cx.update(|cx| {
        let prefs = &mut cx.global_mut::<Core>().prefs;
        prefs.set("remote.enabled", true);
        prefs.set("remote.serverURL", "https://box.example.com");
        prefs.set("remote.state", "pending");
    });
    frame(cx, w);
    assert_saw(&["box.example.com", "Waiting for approval"]);
    // Skip mode has no second row; the live AI card follows later steps only for local mode.
    set(cx, w, |p| {
        p.setup.ai_mode = AiMode::Local;
        p.setup.step = Step::Permissions;
        p.setup.purpose = Purpose::Both;
        p.ai_phase = AiPhase::Starting;
    });
    assert_saw(&["On-device AI", "Starting…"]);
    set(cx, w, |p| p.ai_phase = AiPhase::Ready);
    assert!(!saw("On-device AI"));
}

// parity: ONB-315 ONB-316 ONB-317 ONB-318 ONB-319 ONB-320 ONB-321 ONB-322 ONB-323 ONB-324 ONB-327 ONB-328 ONB-329 ONB-330 ONB-331 ONB-332 ONB-333 ONB-334 ONB-335 ONB-336 ONB-340 ONB-341 ONB-342 ONB-343 ONB-344 ONB-345 ONB-346 ONB-049
#[flow_ui::gpui::test]
async fn permission_rows_and_allow_actions(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| {
        p.setup.step = Step::Permissions;
        p.snap.model_installed = true;
        p.snap.storage_available = true;
        p.snap.shortcut_ready = true;
        p.snap.controls_available = true;
    });
    assert_saw(&["Allow ", "access", "Microphone and Input Monitoring let", "Permissions needed", "Microphone", "Input Monitoring", "Accessibility", "System audio"]);
    click(cx, w, "onboarding.allow.Microphone");
    assert_eq!(r.log.borrow().as_slice(), ["request Microphone", "settings Microphone"]);
    r.log.borrow_mut().clear();
    set(cx, w, |p| p.snap.microphone = Perm::Denied);
    click(cx, w, "onboarding.allow.Microphone");
    assert_eq!(r.log.borrow().as_slice(), ["settings Microphone"], "a refusal opens Settings without asking");
    r.log.borrow_mut().clear();
    for (id, name) in [("onboarding.allow.Input Monitoring", "InputMonitoring"), ("onboarding.allow.Accessibility", "Accessibility"), ("onboarding.allow.System audio", "SystemAudio")] {
        click(cx, w, id);
        assert_eq!(r.log.borrow()[0], format!("request {name}"));
        r.log.borrow_mut().clear();
    }
    // `performing` blocks a second action.
    set(cx, w, |p| p.performing = true);
    win_allow(cx, w, Permission::Microphone);
    assert!(r.log.borrow().is_empty());
    set(cx, w, |p| p.performing = false);
    // A failed request is shown, never treated as granted.
    r.ok.set(false);
    click(cx, w, "onboarding.allow.Accessibility");
    assert!(read(cx, w, |p, _| p.error.clone()).is_some());
    r.ok.set(true);
    // The meeting path has its own card and never asks for keyboard access.
    set(cx, w, |p| {
        p.setup.purpose = Purpose::Meetings;
        p.error = None;
    });
    assert_saw(&["LocalFlow records your microphone", "Needed to record a meeting."]);
    r.log.borrow_mut().clear();
    win_allow(cx, w, Permission::InputMonitoring);
    assert!(r.log.borrow().is_empty());
    set(cx, w, |p| {
        p.snap.microphone = Perm::Granted;
        p.snap.system_audio = Perm::Granted;
    });
    assert_saw(&["Everything is allowed.", "Allowed"]);
    set(cx, w, |p| {
        p.setup.purpose = Purpose::Dictation;
        ready(&mut p.snap);
    });
    assert_saw(&["Everything is allowed."]);
    assert!(!saw("System audio"), "dictation never shows the system audio row");
}

fn win_allow(cx: &mut TestAppContext, w: Win, p: Permission) {
    w.update(cx, |page, _, cx| page.allow(p, cx)).unwrap();
    frame(cx, w);
}

// parity: ONB-350 ONB-351 ONB-352 ONB-353 ONB-354 ONB-355 ONB-356 ONB-357 ONB-358 ONB-359 ONB-364 ONB-365 ONB-366 ONB-367 ONB-368 ONB-369 ONB-370 ONB-372 ONB-373 ONB-374 ONB-375 ONB-378 ONB-379 ONB-015 ONB-061
#[flow_ui::gpui::test]
async fn personalize_theme_and_shortcut(cx: &mut TestAppContext) {
    let r = rig(cx, false, &[]);
    let w = r.win;
    set(cx, w, |p| {
        ready(&mut p.snap);
        p.setup.step = Step::Permissions;
    });
    // Entering the step with no saved shortcut configures Right Control, and a failure isn't saved.
    click(cx, w, "onboarding.primary");
    assert_eq!(read(cx, w, |p, _| p.setup.step), Step::Personalize);
    assert!(r.log.borrow().iter().any(|c| c == "shortcut"));
    assert!(pref(cx, "shortcut").is_none() && !cx.update(|cx| Shortcut::is_saved(&cx.global::<Core>().prefs)));
    assert_saw(&["Make it ", "Pick a look and the key", "Appearance", "Match system", "Light", "Dark", "Dictation shortcut", "Hold to talk", "Record shortcut", "Right Option", "fn / Globe", "This build can't use"]);
    r.ok.set(true);
    click(cx, w, "onboarding.preset.1");
    assert!(cx.update(|cx| Shortcut::is_saved(&cx.global::<Core>().prefs)));
    assert_eq!(read(cx, w, |p, _| p.snap.shortcut.clone()), Shortcut::right_option());
    w.update(cx, |_, w, _| assert_eq!(w.find("onboarding.preset.1").label().as_deref(), Some("Right Option"))).unwrap();
    // Busy refuses instead of installing.
    set(cx, w, |p| p.snap.busy = true);
    click(cx, w, "onboarding.preset.2");
    assert_saw(&["Another dictation or model operation"]);
    set(cx, w, |p| {
        p.snap.busy = false;
        p.error = None;
    });
    // Recording: Accessibility first, then the service, then a toggle back.
    set(cx, w, |p| p.snap.accessibility = Perm::Denied);
    click(cx, w, "onboarding.recordShortcut");
    assert_saw(&["Allow Accessibility to record and prioritize shortcuts."]);
    set(cx, w, |p| p.snap.accessibility = Perm::Granted);
    click(cx, w, "onboarding.recordShortcut");
    assert_saw(&["Press your keys…"]);
    assert!(disabled(cx, w, "onboarding.primary"), "no advancing while recording");
    click(cx, w, "onboarding.recordShortcut");
    assert_saw(&["Record shortcut"]);
    // Theme cards write the preference and apply it live.
    click(cx, w, "onboarding.theme.dark");
    assert_eq!(pref(cx, "appearance").as_deref(), Some("dark"));
    assert!(cx.update(|cx| pal(cx).mode.is_dark()));
    w.update(cx, |_, w, _| assert_eq!(w.find("onboarding.theme.system").label().as_deref(), Some("Match system appearance"))).unwrap();
    click(cx, w, "onboarding.theme.light");
    assert!(!cx.update(|cx| pal(cx).mode.is_dark()));
    // Meeting path: no shortcut section, no configuring, and its own button.
    r.log.borrow_mut().clear();
    set(cx, w, |p| p.setup.purpose = Purpose::Meetings);
    assert_saw(&["Pick a look. You can change it", "Finish setup"]);
    assert!(!saw("Dictation shortcut"));
    assert!(r.log.borrow().is_empty());
}

// parity: ONB-381 ONB-382 ONB-383 ONB-384 ONB-385 ONB-386 ONB-387 ONB-388 ONB-389 ONB-391 ONB-396 ONB-060 ONB-053 ONB-087 ONB-088 ONB-404 ONB-405 ONB-406 ONB-407 ONB-033
#[flow_ui::gpui::test]
async fn test_step_arms_and_done_copy(cx: &mut TestAppContext) {
    let r = rig(cx, false, &[]);
    let w = r.win;
    set(cx, w, |p| {
        p.setup.step = Step::Test;
        ready(&mut p.snap);
    });
    assert_saw(&["Try ", "Press the button, then hold Right Control", "This test is optional", "Start test", "Skip test", "Finish setup"]);
    assert!(disabled(cx, w, "onboarding.primary"));
    // A failed model load shows the error and doesn't arm.
    click(cx, w, "onboarding.startTest");
    assert!(r.log.borrow().iter().any(|c| c == "load"));
    assert!(!read(cx, w, |p, _| p.setup.test_armed));
    assert!(read(cx, w, |p, _| p.setup.test_error.is_some()));
    r.ok.set(true);
    click(cx, w, "onboarding.startTest");
    assert!(read(cx, w, |p, _| p.setup.test_armed));
    assert_saw(&["Listening for your shortcut…"]);
    assert!(disabled(cx, w, "onboarding.startTest"));
    set(cx, w, |p| {
        p.setup.test_armed = false;
        p.setup.preparing_test = true;
    });
    assert_saw(&["Preparing speech model…"]);
    set(cx, w, |p| {
        p.setup.preparing_test = false;
        p.snap.microphone = Perm::Denied;
    });
    assert_saw(&["Allow Microphone access to record."]);
    assert!(disabled(cx, w, "onboarding.startTest"));
    set(cx, w, |p| {
        p.snap.microphone = Perm::Granted;
        p.setup.test_succeeded = true;
    });
    assert_saw(&["Your first transcript is saved in Transcriptions."]);
    assert!(!saw("This test is optional") && !saw("Skip test"));
    assert!(!disabled(cx, w, "onboarding.primary"));
    set(cx, w, |p| p.setup.step = Step::Complete);
    assert_saw(&["You're ", "all set", "Hold your shortcut in any app to dictate."]);
    w.update(cx, |_, w, _| {
        assert!(w.try_find("onboarding.primary").is_none() && w.try_find("onboarding.back").is_none() && w.try_find("onboarding.progress").is_none());
    })
    .unwrap();
    set(cx, w, |p| p.setup.purpose = Purpose::Meetings);
    assert_saw(&["Start a meeting in Notetaker."]);
}

// parity: ONB-174 ONB-175 ONB-176 ONB-177 ONB-178 ONB-179 ONB-180 ONB-192 ONB-193 ONB-194 ONB-195 ONB-196 ONB-197 ONB-198 ONB-199 ONB-202 ONB-203 ONB-204 ONB-205 ONB-206 ONB-207 ONB-208 ONB-209 ONB-210 ONB-212 ONB-213 ONB-214 ONB-215 ONB-217 ONB-218 ONB-219 ONB-222 ONB-045 ONB-107
#[flow_ui::gpui::test]
async fn server_step_consent_trust_sign_in_and_turn_off(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.setup.ai_mode = AiMode::Remote;
    });
    assert_saw(&["Connect ", "your server", "Turn on Remote dictation", "Remote dictation", "Run dictation, rewriting", "Nothing leaves this Mac until", "Sign in to continue", "Use this server"]);
    assert!(disabled(cx, w, "onboarding.primary"));
    // Toggle shows consent; Cancel leaves it off.
    click(cx, w, "settings.remoteEnabled");
    assert_saw(&["Use your LocalFlow server?", "Dictation audio, transcripts, Dictionary terms"]);
    assert!(disabled(cx, w, "settings.remoteConsentConfirm"));
    click(cx, w, "settings.remoteConsentCancel");
    assert!(!read(cx, w, |p, _| p.remote.consent_open) && !flag(cx, "remote.enabled"));
    // An unusable address is refused with its message; a good one fetches the identity.
    click(cx, w, "settings.remoteEnabled");
    w.update(cx, |p, w, cx| p.server_draft.update(cx, |s, cx| s.set_value("http://x.example.com/path", w, cx))).unwrap();
    w.update(cx, |p, _, cx| p.confirm_consent(cx)).unwrap();
    frame(cx, w);
    assert_saw(&["Enter the server's https:// address without a path."]);
    w.update(cx, |p, w, cx| p.server_draft.update(cx, |s, cx| s.set_value("https://box.example.com", w, cx))).unwrap();
    frame(cx, w);
    assert_saw(&["Server: box.example.com"]);
    click(cx, w, "settings.remoteConsentConfirm");
    assert!(flag(cx, "remote.enabled"));
    assert_eq!(pref(cx, "remote.serverURL").as_deref(), Some("https://box.example.com"));
    assert_saw(&["Server fingerprint", "SHA256:abc", "flowd admin identity", "Trust This Server", "Compare the fingerprint"]);
    // Trust pins, then both sign-ins appear when configured.
    click(cx, w, "settings.remoteTrust");
    assert_eq!(pref(cx, "remote.state").as_deref(), Some("pinned"));
    assert!(r.log.borrow().iter().any(|c| c == "secret remote.serverKey"));
    assert_saw(&["Pinned fingerprint  SHA256:abc", "Sign in with Apple"]);
    assert!(!saw("Sign in with Google"));
    set(cx, w, |p| p.remote.google = true);
    assert_saw(&["Sign in with Google"]);
    // A failed sign-in stays pinned and says so.
    r.ok.set(false);
    click(cx, w, "settings.remoteSignInApple");
    assert_saw(&["Sign-in did not finish."]);
    assert_eq!(pref(cx, "remote.state").as_deref(), Some("pinned"));
    r.ok.set(true);
    click(cx, w, "settings.remoteSignInApple");
    assert_eq!(pref(cx, "remote.state").as_deref(), Some("pending"));
    assert!(!disabled(cx, w, "onboarding.primary"), "enrolled unlocks the step");
    // Pin mismatch offers Enroll Again, whose failure is the identity error.
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("remote.state", "pin_mismatch"));
    frame(cx, w);
    assert_saw(&["Server identity changed"]);
    r.ok.set(false);
    click(cx, w, "settings.remoteEnrollAgain");
    assert_saw(&["The server did not answer with a LocalFlow identity. Check the address."]);
    r.ok.set(true);
    // Swift's switch: a 54 by 24 track, not the Kit's 44 by 24.
    let track = cx.update_window(w.into(), |_, w, cx| {
        w.render_frame(cx);
        w.find("settings.remoteEnabled").bounds().size
    })
    .unwrap();
    assert_eq!((f32::from(track.width), f32::from(track.height)), (54., 24.));
    // Turn off asks first; Cancel keeps it; Turn Off clears it.
    click(cx, w, "settings.remoteEnabled");
    let (message, detail) = cx.pending_prompt().expect("Swift's turn-off alert is native");
    assert_eq!(message, "Turn off remote dictation?");
    assert!(detail.contains("device key and server pin are deleted"));
    cx.simulate_prompt_answer("Cancel");
    cx.run_until_parked();
    assert!(flag(cx, "remote.enabled"));
    click(cx, w, "settings.remoteEnabled");
    cx.simulate_prompt_answer("Turn Off");
    cx.run_until_parked();
    assert!(!flag(cx, "remote.enabled"));
    assert!(read(cx, w, |p, _| p.remote.identity.is_none() && p.remote.pinned.is_none()));
    // Meeting wording, including the consent text with retention.
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("setup.purpose", "meetings"));
    set(cx, w, |p| p.setup.purpose = Purpose::Meetings);
    assert_saw(&["Turn on Your server", "Run meeting transcripts and notes"]);
    assert!(!saw("Advanced: rewrite-only server"));
    click(cx, w, "settings.remoteEnabled");
    assert_saw(&["Meetings handed off to the server stay there"]);
}

// parity: ONB-230 ONB-231 ONB-232 ONB-234 ONB-236 ONB-238 ONB-239 ONB-240 ONB-242 ONB-243 ONB-244
#[flow_ui::gpui::test]
async fn rewrite_only_form_connects_and_reports(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("rewriteEndpoint", "https://studio.local:8080"));
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.setup.ai_mode = AiMode::Remote;
    });
    assert!(!saw("Server address"));
    click(cx, w, "onboarding.legacyRewriteServer");
    assert_saw(&["Only rewriting uses this server", "Server address", "Access key", "Connect", "On the server, run flowd", "flowd serve --listen"]);
    // A credential with a line break isn't stored.
    w.update(cx, |p, w, cx| p.credential_input.update(cx, |s, cx| s.set_value(" bad-key", w, cx))).unwrap();
    click(cx, w, "onboarding.connect");
    assert!(read(cx, w, |p, _| p.credential_error.is_some()));
    assert!(!r.log.borrow().iter().any(|c| c.starts_with("secret")));
    w.update(cx, |p, w, cx| p.credential_input.update(cx, |s, cx| s.set_value("good-key", w, cx))).unwrap();
    click(cx, w, "onboarding.connect");
    assert!(r.log.borrow().iter().any(|c| c.starts_with("secret rewrite.")));
    assert!(r.log.borrow().iter().any(|c| c == "health"));
    assert_saw(&["Connected · studio · qwen", "Analysis uses this server."]);
    assert_eq!(read(cx, w, |p, cx| p.credential_input.read(cx).value().len()), 0);
    assert!(!disabled(cx, w, "onboarding.primary"), "a tested server unlocks the step");
    click(cx, w, "onboarding.primary");
    assert!(flag(cx, "rewriteEnabled"));
    // Plain HTTP needs the override; health failure reads as unreachable.
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.connection = None;
    });
    w.update(cx, |p, _, cx| p.edit_endpoint("http://studio.local:8080".into(), cx)).unwrap();
    frame(cx, w);
    assert_saw(&["Allow unencrypted HTTP to this server"]);
    click(cx, w, "onboarding.connect");
    assert!(read(cx, w, |p, _| matches!(p.connection, Some(Err(_)))));
    click(cx, w, "onboarding.allowInsecure");
    set(cx, w, |p| p.credential_present = true);
    r.ok.set(false);
    click(cx, w, "onboarding.connect");
    assert_saw(&["Could not reach the server."]);
    // Editing invalidates the result.
    w.update(cx, |p, _, cx| p.edit_endpoint("http://other.local:8080".into(), cx)).unwrap();
    assert!(read(cx, w, |p, _| p.connection.is_none()));
}

// parity: ONB-011 ONB-013 ONB-014 ONB-004 ONB-010
#[flow_ui::gpui::test]
async fn polling_picks_up_a_new_permission(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    let fake = Fake::default();
    cx.update(|cx| cx.global_mut::<Core>().services = Box::new(fake));
    let w = cx.add_window(|w, cx| OnboardingPage::new(w, cx));
    frame(cx, w);
    cx.update(|cx| {
        let fake = Fake::default();
        *fake.permissions.borrow_mut() = vec![(Permission::Microphone, PermissionState::Granted)];
        cx.global_mut::<Core>().services = Box::new(fake);
    });
    cx.update_window(w.into(), |_, w, _| w.activate_window()).unwrap();
    cx.executor().advance_clock(Duration::from_millis(600));
    cx.run_until_parked();
    assert_eq!(read(cx, w, |p, _| p.snap.microphone), Perm::Granted);
    assert_eq!(read(cx, w, |p, _| p.downloaded), CATALOG.map(|m| m.is_downloaded(&models_dir())));
}

// parity: ONB-016 ONB-063 ONB-064
#[flow_ui::gpui::test]
async fn return_advances_and_escape_cancels_dictation(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    cx.update_window(w.into(), |_, w, cx| w.press("enter", cx)).unwrap();
    frame(cx, w);
    assert_eq!(read(cx, w, |p, _| p.setup.step), Step::Purpose);
    cx.update_window(w.into(), |_, w, cx| w.press("escape", cx)).unwrap();
    frame(cx, w);
    assert_eq!(read(cx, w, |p, _| p.setup.step), Step::Purpose, "Escape is not Back");
    assert!(r.log.borrow().iter().any(|c| c.contains("Cancel")), "{:?}", r.log.borrow());
}

// parity: SHELL-035 ONB-001 ONB-002 ONB-003 ONB-398 ONB-399 ONB-403 ONB-054 ONB-401 ONB-402 ONB-411
#[flow_ui::gpui::test]
async fn finishing_writes_prefs_and_opens_the_library(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| {
        ready(&mut p.snap);
        p.setup.step = Step::Test;
    });
    assert_eq!(cx.update(|cx| cx.global::<Core>().prefs.int_or("setupVersion", 0)), 0);
    click(cx, w, "onboarding.skipTest");
    assert_eq!(cx.update(|cx| cx.global::<Core>().prefs.int_or("setupVersion", 0)), CURRENT_SETUP_VERSION);
    assert!(pref(cx, "speechModel").is_some());
    assert!(r.log.borrow().iter().all(|c| !c.starts_with("secret")), "finishing touches no keychain items");
    assert!(cx.update(|cx| is_complete(&cx.global::<Core>().prefs)));
}

// parity: ONB-281 ONB-282 ONB-283 ONB-284 ONB-021
#[flow_ui::gpui::test]
async fn bars_expose_percent_and_honor_reduce_motion(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| {
        p.setup.step = Step::Downloads;
        p.snap.installing = true;
        p.snap.progress = (25, 100);
        p.ai_phase = AiPhase::DownloadingModel(50, 100);
    });
    let values = w.update(cx, |_, w, _| w.find_all("onboarding.bar").iter().map(|b| b.value().map(str::to_string)).collect::<Vec<_>>()).unwrap();
    assert!(values.contains(&Some("25 percent".into())) && values.contains(&Some("50 percent".into())), "{values:?}");
    cx.update(|cx| cx.global_mut::<Flow>().reduce_motion = true);
    set(cx, w, |p| p.ai_phase = AiPhase::PreparingRuntime);
    assert_saw(&["Installing MTPLX…"]);
    let indeterminate = w.update(cx, |_, w, _| w.find_all("onboarding.bar").iter().any(|b| b.value() == Some("In progress"))).unwrap();
    assert!(indeterminate);
}

// Selects a state the audit captures.
#[flow_ui::gpui::test]
async fn scenario_selects_a_state(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    cx.update(|cx| cx.global_mut::<Core>().scenario = Some("onboarding.downloadsfailed".into()));
    let w = cx.add_window(|w, cx| OnboardingPage::new(w, cx));
    frame(cx, w);
    assert_saw(&["Stopped", "Installation failed.", "The download stopped."]);
    assert!(read(cx, w, |p, _| p.frozen));
}

// parity: ONB-001 ONB-002 ONB-401 ONB-403 ONB-408
#[flow_ui::gpui::test]
async fn shell_swaps_to_the_library_and_notetaker_on_a_meetings_finish(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    cx.update(|cx| {
        crate::menu::init(cx);
        cx.global_mut::<Core>().scenario = Some("onboarding.personalize-meetings".into());
    });
    let win = cx.add_window(|w, cx| crate::shell::Shell::new(w, cx));
    let render = |cx: &mut TestAppContext| {
        cx.run_until_parked();
        flow_ui::probe::clear();
        cx.update_window(win.into(), |_, w, cx| w.render_frame(cx)).unwrap();
    };
    render(cx);
    assert_saw(&["Make it ", "Finish setup"]);
    cx.update_window(win.into(), |_, w, _| assert!(w.try_find("navigation.settings").is_none())).unwrap();
    cx.update_window(win.into(), |_, w, cx| w.click("onboarding.primary", cx)).unwrap();
    render(cx);
    assert!(cx.update(|cx| is_complete(&cx.global::<Core>().prefs)));
    assert!(cx.update(|cx| cx.global::<crate::shell::Session>().selection == Page::Meetings));
    cx.update_window(win.into(), |_, w, _| assert!(w.try_find("navigation.settings").is_some())).unwrap();
    cx.update_window(win.into(), |_, w, _| assert!(w.try_find("onboarding.primary").is_none())).unwrap();
}

struct BarView(Option<f64>);

impl Render for BarView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div().w(px(200.)).child(parts::bar(self.0, cx))
    }
}

fn fill_width(cx: &mut TestAppContext, w: WindowHandle<BarView>) -> f32 {
    cx.update_window(w.into(), |_, w, cx| {
        w.render_frame(cx);
        f32::from(w.find("onboarding.bar.fill").bounds().size.width)
    })
    .unwrap()
}

// parity: ONB-281
/// `.animation(reduceMotion ? nil : .smooth, value: fraction)`: the fill tweens, or lands at once under Reduce Motion.
#[flow_ui::gpui::test]
async fn progress_fill_tweens_and_reduce_motion_lands_at_once(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    let w = cx.add_window(|_, _| BarView(Some(0.)));
    fill_width(cx, w);
    w.update(cx, |v, _, cx| {
        v.0 = Some(1.);
        cx.notify();
    })
    .unwrap();
    let first = fill_width(cx, w);
    assert!(first < 100., "starts from the old value, was {first}");
    cx.executor().advance_clock(Duration::from_millis(100));
    let mid = fill_width(cx, w);
    assert!(mid > first && mid < 200., "moves over time, was {mid}");
    cx.executor().advance_clock(Duration::from_secs(3));
    fill_width(cx, w);
    cx.executor().advance_clock(Duration::from_millis(16));
    assert_eq!(fill_width(cx, w), 200.);
    cx.update(|cx| cx.global_mut::<Flow>().reduce_motion = true);
    w.update(cx, |v, _, cx| {
        v.0 = Some(0.5);
        cx.notify();
    })
    .unwrap();
    assert_eq!(fill_width(cx, w), 100.);
}
