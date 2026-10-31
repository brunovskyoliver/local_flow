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
    /// What a permission prompt answers.
    answer: Rc<Cell<PermissionState>>,
    /// The sign-in's outcome: a state, or the service's failure.
    enroll: Rc<RefCell<Result<String, &'static str>>>,
    recorded: Rc<RefCell<Option<Option<String>>>>,
    background: Rc<Cell<bool>>,
    verified: Rc<Cell<bool>>,
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
        self.call(format!("request {p:?}"), self.answer.get())
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
    fn enroll_device(&self, p: &str) -> Result<String, Unavailable> {
        self.log.borrow_mut().push(format!("enroll {p}"));
        self.enroll.borrow().clone().map_err(Unavailable)
    }
    fn remove_secret(&self, name: &str) -> Result<(), Unavailable> {
        self.call(format!("remove {name}"), ())
    }
    fn reveal_app(&self) -> Result<(), Unavailable> {
        self.call("reveal".into(), ())
    }
    fn install_term_booster(&self) -> Result<(), Unavailable> {
        self.call("booster".into(), ())
    }
    fn set_app_appearance(&self, dark: Option<bool>) -> Result<(), Unavailable> {
        self.log.borrow_mut().push(format!("appearance {dark:?}"));
        Ok(())
    }
    fn mark_alert_button_destructive(&self, title: &str) -> bool {
        self.log.borrow_mut().push(format!("destructive {title}"));
        true
    }
    fn take_recorded_shortcut(&self) -> Option<Option<String>> {
        self.recorded.borrow_mut().take()
    }
    fn background_services_enabled(&self) -> bool {
        self.background.get()
    }
    fn speech_model_verified(&self) -> bool {
        self.verified.get()
    }
    fn session_command(&self, c: SessionCommand) -> Result<(), Unavailable> {
        self.call(format!("{c:?}"), ())
    }
}

struct Rig {
    win: Win,
    ok: Rc<Cell<bool>>,
    log: Log,
    answer: Rc<Cell<PermissionState>>,
    enroll: Rc<RefCell<Result<String, &'static str>>>,
    recorded: Rc<RefCell<Option<Option<String>>>>,
    background: Rc<Cell<bool>>,
    verified: Rc<Cell<bool>>,
}

/// A real HTTP server on loopback answering each path with a status and body. An unknown path is a 404.
fn http(routes: Vec<(&'static str, u16, String)>) -> String {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let mut request = vec![];
            let mut byte = [0u8; 1];
            while !request.ends_with(b"\r\n\r\n") && stream.read_exact(&mut byte).is_ok() {
                request.push(byte[0]);
            }
            let line = String::from_utf8_lossy(&request).lines().next().unwrap_or_default().to_string();
            let path = line.split(' ').nth(1).unwrap_or_default().to_string();
            let (status, body) = routes.iter().find(|r| r.0 == path).map_or((404, String::new()), |r| (r.1, r.2.clone()));
            let _ = write!(stream, "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        }
    });
    base
}

/// A port nothing listens on.
fn closed_server() -> String {
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    format!("http://127.0.0.1:{port}")
}

/// A valid `GET /v1/remote/identity` body and its fingerprint.
fn identity() -> (String, String) {
    let key = [7u8; 32];
    let fingerprint = flow_core::settings::fingerprint_of(&key);
    let body = format!(r#"{{"schema_version":1,"server":{{}},"protocol_versions":[1],"suite":"x25519-hkdfsha256-chacha20poly1305","server_key":"{}","fingerprint":"{fingerprint}"}}"#, flow_core::settings::base64url_encode(&key));
    (body, fingerprint)
}

const HEALTHY: &str = r#"{"service":"localflow-rewrite","protocol_versions":[1],"server":{"name":"studio"},"backend":{"state":"ready","model":"qwen"}}"#;

fn rig(cx: &mut TestAppContext, ok: bool, perms: &[(Permission, PermissionState)]) -> Rig {
    boot(cx, Mode::Light);
    let (ok, log): (Rc<Cell<bool>>, Log) = (Rc::new(Cell::new(ok)), Default::default());
    let answer = Rc::new(Cell::new(PermissionState::Denied));
    let enroll: Rc<RefCell<Result<String, &'static str>>> = Rc::new(RefCell::new(Ok("pending".to_string())));
    let (recorded, background): (Rc<RefCell<Option<Option<String>>>>, _) = (Default::default(), Rc::new(Cell::new(false)));
    let verified = Rc::new(Cell::new(false));
    let fake = Fake::default();
    *fake.permissions.borrow_mut() = perms.to_vec();
    let services = Stub { fake, ok: ok.clone(), log: log.clone(), answer: answer.clone(), enroll: enroll.clone(), recorded: recorded.clone(), background: background.clone(), verified: verified.clone() };
    cx.update(|cx| cx.global_mut::<Core>().services = Box::new(services));
    let win = cx.add_window(|w, cx| OnboardingPage::new(w, cx));
    frame(cx, win);
    log.borrow_mut().clear();
    Rig { win, ok, log, answer, enroll, recorded, background, verified }
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

// parity: ONB-036 ONB-042 ONB-056 ONB-076 ONB-119 ONB-120 ONB-122 ONB-123 ONB-124 ONB-125
#[flow_ui::gpui::test]
async fn introduction_copy(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    assert_saw(&[
        "Your voice, written on this Mac.",
        "Hold a key in any app, talk, and let go, or record a meeting and get notes. LocalFlow turns speech into clean text right here on your Mac.",
        "Speech recognition runs on this Mac. Audio leaves it only if you connect a LocalFlow server you run.",
        "Hold Right Control, speak, release. The text lands where your cursor is.",
        "Records your calls, then writes a transcript with speaker labels and notes.",
        "Optional AI fixes punctuation, drops the ums and ahs, and writes meeting notes.",
        "Get started",
    ]);
    r.win.update(cx, |_, w, _| {
        assert_eq!(w.find("onboarding.progress").label().as_deref(), Some("Step 1 of 8"));
        assert!(w.try_find("onboarding.back").is_none());
    })
    .unwrap();
    assert!(!disabled(cx, r.win, "onboarding.primary"));
}

// parity: ONB-012
/// `.task { refresh }`: the first frame already shows what the OS says.
#[flow_ui::gpui::test]
async fn first_frame_reads_the_permissions(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[(Permission::Microphone, PermissionState::Granted)]);
    assert_eq!(read(cx, r.win, |p, _| p.snap.microphone), Perm::Granted);
}

// parity: ONB-041 ONB-062 ONB-126 ONB-127 ONB-129 ONB-130 ONB-131 ONB-134
#[flow_ui::gpui::test]
async fn purpose_copy_and_ids(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    click(cx, w, "onboarding.primary");
    assert_saw(&[
        "What is LocalFlow for?",
        "Setup only asks for what your choice needs. You can add dictation later in Settings.",
        "Recommended",
        "Dictation in every app, and notes from your meetings.",
        "Hold a key in any app and talk. Meeting notes stay optional.",
        "Record calls and get transcripts and notes. No shortcut or keyboard permissions.",
        "Continue",
        "Back",
    ]);
    w.update(cx, |_, w, _| {
        for id in ["onboarding.purpose.both", "onboarding.purpose.dictation", "onboarding.purpose.meetings"] {
            assert!(w.try_find(id).is_some(), "{id}");
        }
    })
    .unwrap();
}

// parity: ONB-128 ONB-417
/// Cards stack 10 apart, Both first. A card's height is its text plus 16 of padding on each side.
#[flow_ui::gpui::test]
async fn purpose_cards_stack_in_order(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    click(cx, w, "onboarding.primary");
    let (both, dictation, meetings) = w.update(cx, |_, w, _| (w.find("onboarding.purpose.both").bounds(), w.find("onboarding.purpose.dictation").bounds(), w.find("onboarding.purpose.meetings").bounds())).unwrap();
    assert_eq!(f32::from(dictation.origin.y - (both.origin.y + both.size.height)), 10.);
    assert_eq!(f32::from(meetings.origin.y - (dictation.origin.y + dictation.size.height)), 10.);
    assert_eq!(both.size.width, dictation.size.width);
    assert!(f32::from(dictation.size.height) >= 32. + 15., "padding 16 around a 15 point title");
}

// parity: ONB-051 ONB-138 ONB-139 ONB-140 ONB-142 ONB-144 ONB-145 ONB-147 ONB-148 ONB-149 ONB-151 ONB-152
#[flow_ui::gpui::test]
async fn location_copy_for_dictation_and_both(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    click(cx, w, "onboarding.primary");
    click(cx, w, "onboarding.primary");
    assert_eq!(read(cx, w, |p, _| p.setup.ai_mode), AiMode::Local, "the default");
    assert_saw(&[
        "OPTIONAL",
        "Add AI rewriting.",
        "A language model can polish each dictation and turn meetings into notes. Choose where it runs.",
        "Private and offline. LocalFlow installs MTPLX, an open-source engine for Apple Silicon, and a model you pick.",
        "Use a LocalFlow server on another computer you run, for bigger models. Its administrator approves this Mac once.",
        "MTPLX engine",
        "About 550 MB, kept in LocalFlow's folder. No Homebrew or Python setup.",
        "They start at login and only accept connections from this Mac.",
        "Your text never leaves this Mac. Every download is pinned to an exact version and checksum.",
        "Skip for now",
    ]);
    assert!(!saw("Once the server approves"), "the server note replaces the local panel");
    click(cx, w, "onboarding.ai.remote");
    assert_eq!(read(cx, w, |p, _| p.setup.ai_mode), AiMode::Remote);
    assert_saw(&["Once the server approves this Mac, dictation audio, meeting recordings and their text go to it. Until then, and whenever it can't be reached, dictation is transcribed on this Mac."]);
    assert!(!saw("MTPLX engine"));
    assert!(!cx.update(|cx| cx.global::<Core>().prefs.contains("remote.enabled")), "choosing a card stores nothing");
}

// parity: ONB-135 ONB-136 ONB-137 ONB-141 ONB-143 ONB-146 ONB-153
#[flow_ui::gpui::test]
async fn location_copy_for_meetings(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    click(cx, w, "onboarding.primary");
    click(cx, w, "onboarding.purpose.meetings");
    click(cx, w, "onboarding.primary");
    assert_eq!(pref(cx, "setup.purpose").as_deref(), Some("meetings"));
    assert_saw(&[
        "MEETING NOTES",
        "Where should meetings run?",
        "Recordings are always saved on this Mac first. Choose what turns them into notes.",
        "Nothing leaves this Mac. LocalFlow downloads speech, Whisper and speaker models, about 2.3 GB, then offers a language model for summaries.",
        "Meeting audio, transcripts and summary text go to a LocalFlow server you run. Nothing downloads to this Mac. Its administrator approves this Mac once.",
        "Skip for now to keep meetings on this Mac without a language model. You still get transcripts with speaker labels, but summaries won't be available.",
    ]);
    click(cx, w, "onboarding.ai.remote");
    assert_saw(&["Once the server approves this Mac, meeting recordings and their text go to it. Until then, and whenever it can't be reached, recordings wait on this Mac."]);
}

// parity: ONB-155 ONB-156 ONB-157 ONB-158 ONB-164 ONB-165 ONB-166 ONB-167 ONB-171 ONB-172 ONB-058 ONB-059 ONB-077 ONB-078 ONB-270 ONB-269
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

// parity: ONB-249 ONB-250 ONB-251 ONB-254 ONB-257 ONB-258 ONB-259 ONB-260 ONB-263 ONB-272 ONB-273 ONB-046 ONB-047 ONB-038 ONB-039 ONB-277 ONB-280
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

// parity: ONB-391
/// `prepareTest` loads the model unless the server serves dictation.
#[flow_ui::gpui::test]
async fn preparing_the_test_skips_the_load_on_a_server(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| {
        ready(&mut p.snap);
        p.setup.step = Step::Test;
    });
    r.log.borrow_mut().clear();
    w.update(cx, |p, _, cx| p.arm_test(cx)).unwrap();
    assert!(r.log.borrow().iter().any(|c| c.contains("load")), "{:?}", r.log.borrow());
    r.log.borrow_mut().clear();
    cx.update(|cx| {
        let prefs = &mut cx.global_mut::<Core>().prefs;
        prefs.set("remote.enabled", true);
        prefs.set("remote.serverURL", "https://box.example.com");
        prefs.set("remote.state", "approved");
        prefs.set("remote.consentVersion", 2);
    });
    set(cx, w, |p| {
        p.setup.back();
        p.setup.step = Step::Test;
    });
    w.update(cx, |p, _, cx| p.arm_test(cx)).unwrap();
    assert!(r.log.borrow().iter().all(|c| !c.contains("load")), "{:?}", r.log.borrow());
}

// parity: ONB-253 ONB-255 ONB-256 ONB-276 ONB-278
#[flow_ui::gpui::test]
async fn download_rows_read_like_swift(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    set(cx, w, |p| {
        p.setup.step = Step::Downloads;
        p.setup.ai_mode = AiMode::Local;
    });
    let (speech, model) = read(cx, w, |p, _| (p.snap.speech_model.to_string(), p.selected_model()));
    assert_saw(&["Speech recognition", &format!("{speech} · {}", bytes(SPEECH_FALLBACK_BYTES))]);
    assert_saw(&["On-device AI", &format!("{} · {}", model.name, bytes(model.download_bytes))]);
    assert_saw(&["Queued"]);
    set(cx, w, |p| {
        let i = p.selection;
        p.downloaded[i] = true;
    });
    assert_saw(&[&format!("{} · already on this Mac", model.name)]);
    set(cx, w, |p| {
        p.snap.installing = true;
        p.snap.progress = (10 << 20, 100 << 20);
    });
    assert_saw(&[&format!("{} of {}", bytes(10 << 20), bytes(100 << 20))]);
    set(cx, w, |p| {
        p.snap.installing = false;
        p.snap.model_installed = true;
    });
    assert_saw(&["Ready"]);
}

// parity: ONB-261 ONB-262
#[flow_ui::gpui::test]
async fn server_row_follows_approval_and_skip_has_no_row(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    cx.update(|cx| {
        let prefs = &mut cx.global_mut::<Core>().prefs;
        prefs.set("remote.enabled", true);
        prefs.set("remote.serverURL", "https://box.example.com");
        prefs.set("remote.state", "approved");
    });
    set(cx, w, |p| {
        p.setup.step = Step::Downloads;
        p.setup.ai_mode = AiMode::Remote;
    });
    assert_saw(&["Your server", "box.example.com", "Ready"]);
    set(cx, w, |p| p.setup.ai_mode = AiMode::Off);
    assert!(!saw("Your server") && !saw("On-device AI"));
}

// parity: ONB-010
/// A model already on disk reads as done on return, through the service.
#[flow_ui::gpui::test]
async fn resume_counts_a_verified_model_as_installed(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    assert!(!read(cx, r.win, |p, _| p.snap.model_installed));
    r.verified.set(true);
    r.win.update(cx, |p, _, cx| p.refresh(cx)).unwrap();
    assert!(read(cx, r.win, |p, _| p.snap.model_installed));
}

// parity: ONB-315 ONB-317 ONB-327 ONB-331 ONB-332 ONB-333 ONB-049 ONB-334 ONB-336
#[flow_ui::gpui::test]
async fn permission_group_shows_only_what_is_missing(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    set(cx, w, |p| {
        p.setup.step = Step::Permissions;
        p.snap.model_installed = true;
        p.snap.storage_available = true;
        p.snap.shortcut_ready = true;
        p.snap.controls_available = true;
        p.snap.microphone = Perm::Unknown;
    });
    assert_saw(&["Allow access.", "Microphone and Input Monitoring let LocalFlow hear you while you hold the shortcut. Accessibility lets it type the text for you and record a custom shortcut; without it, you paste the text yourself.", "Permissions needed", "Input Monitoring", "Accessibility", "System audio"]);
    let has = |cx: &mut TestAppContext, id: &'static str| w.update(cx, |_, w, _| w.try_find(id).is_some()).unwrap();
    assert!(has(cx, "onboarding.allow.Microphone"), "not asked shows Allow");
    assert_saw(&["Allow Microphone access to record."]);
    set(cx, w, |p| p.snap.microphone = Perm::Denied);
    assert!(has(cx, "onboarding.allow.Microphone"), "refused shows Allow too");
    set(cx, w, |p| {
        p.snap.microphone = Perm::Granted;
        p.snap.input_monitoring = Perm::Granted;
    });
    assert!(!has(cx, "onboarding.allow.Microphone") && !has(cx, "onboarding.allow.Input Monitoring"), "granted rows collapse");
    assert!(has(cx, "onboarding.allow.Accessibility"));
    assert_saw(&["Permissions needed"]);
    set(cx, w, |p| p.setup.purpose = Purpose::Dictation);
    assert!(!saw("System audio"), "only Both has the system audio card");
    set(cx, w, |p| p.snap.accessibility = Perm::Granted);
    assert!(!saw("Permissions needed"), "nothing missing, no group");
}

// parity: ONB-316 ONB-318 ONB-319 ONB-320 ONB-322 ONB-323 ONB-346 ONB-335
#[flow_ui::gpui::test]
async fn meeting_path_has_its_own_card(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| {
        p.setup.step = Step::Permissions;
        p.setup.purpose = Purpose::Meetings;
    });
    assert_saw(&["LocalFlow records your microphone and the other people on a call.", "Needed to record a meeting.", "Records the other people on a call. macOS calls this Screen Recording and may ask you to reopen LocalFlow. Without it, meetings record your microphone only."]);
    assert!(!saw("Input Monitoring") && !saw("Accessibility"), "no keyboard permissions");
    w.update(cx, |_, w, _| assert_eq!(w.find("onboarding.allow.Microphone").label().as_deref(), Some("Allow Microphone"))).unwrap();
    win_allow(cx, w, Permission::InputMonitoring);
    assert!(r.log.borrow().is_empty(), "ignored for meetings");
    set(cx, w, |p| p.performing = true);
    assert!(disabled(cx, w, "onboarding.allow.Microphone"));
    set(cx, w, |p| {
        p.performing = false;
        p.snap.microphone = Perm::Granted;
    });
    assert_saw(&["Allowed"]);
    assert!(w.update(cx, |_, w, _| w.try_find("onboarding.allow.Microphone").is_none()).unwrap());
}

// parity: ONB-325 ONB-326
#[flow_ui::gpui::test]
async fn everything_allowed_follows_the_path(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    set(cx, w, |p| {
        p.setup.step = Step::Permissions;
        p.setup.purpose = Purpose::Meetings;
        p.snap.microphone = Perm::Granted;
    });
    assert!(!saw("Everything is allowed."), "system audio still missing");
    set(cx, w, |p| p.snap.system_audio = Perm::Granted);
    assert_saw(&["Everything is allowed."]);
    set(cx, w, |p| {
        p.setup.purpose = Purpose::Dictation;
        p.snap.system_audio = Perm::Denied;
        p.snap.input_monitoring = Perm::Granted;
    });
    assert!(!saw("Everything is allowed."), "Accessibility still missing");
    set(cx, w, |p| p.snap.accessibility = Perm::Granted);
    assert_saw(&["Everything is allowed."]);
}

// parity: ONB-340 ONB-341
#[flow_ui::gpui::test]
async fn allow_microphone_says_the_outcome(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| p.setup.step = Step::Permissions);
    click(cx, w, "onboarding.allow.Microphone");
    assert_eq!(r.log.borrow().as_slice(), ["request Microphone"], "a first refusal doesn't open Settings");
    assert_eq!(read(cx, w, |p, _| p.status.clone()).as_deref(), Some("Microphone permission is needed for dictation."));
    r.answer.set(PermissionState::Granted);
    click(cx, w, "onboarding.allow.Microphone");
    assert_eq!(read(cx, w, |p, _| p.status.clone()).as_deref(), Some("Microphone allowed."));
    r.log.borrow_mut().clear();
    set(cx, w, |p| p.snap.microphone = Perm::Denied);
    click(cx, w, "onboarding.allow.Microphone");
    assert_eq!(r.log.borrow().as_slice(), ["settings Microphone"], "a refusal opens Settings without asking");
}

// parity: ONB-342 ONB-343 ONB-344
#[flow_ui::gpui::test]
async fn allow_the_other_permissions(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| p.setup.step = Step::Permissions);
    click(cx, w, "onboarding.allow.System audio");
    assert_eq!(r.log.borrow().as_slice(), ["request SystemAudio", "settings SystemAudio"]);
    r.log.borrow_mut().clear();
    click(cx, w, "onboarding.allow.Input Monitoring");
    assert_eq!(r.log.borrow().as_slice(), ["request InputMonitoring", "shortcut", "settings InputMonitoring"]);
    r.log.borrow_mut().clear();
    click(cx, w, "onboarding.allow.Accessibility");
    assert_eq!(r.log.borrow().as_slice(), ["request Accessibility", "reveal", "settings Accessibility"]);
    assert_eq!(read(cx, w, |p, _| p.status.clone()).as_deref(), Some("Enable LocalFlow in Accessibility settings. The app is shown in Finder if you need to add it."));
    r.log.borrow_mut().clear();
    r.answer.set(PermissionState::Granted);
    click(cx, w, "onboarding.allow.Accessibility");
    assert_eq!(r.log.borrow().as_slice(), ["request Accessibility"]);
    assert_eq!(read(cx, w, |p, _| p.status.clone()).as_deref(), Some("Accessibility allowed. Insertion is available in supported fields."));
}

// parity: ONB-345
#[flow_ui::gpui::test]
async fn action_wrapper_blocks_and_reports(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| {
        p.setup.step = Step::Permissions;
        p.performing = true;
    });
    win_allow(cx, w, Permission::Microphone);
    assert!(r.log.borrow().is_empty(), "performing blocks a second action");
    set(cx, w, |p| {
        p.performing = false;
        p.error = Some("old".into());
    });
    r.ok.set(false);
    win_allow(cx, w, Permission::Microphone);
    assert_eq!(read(cx, w, |p, _| p.error.clone()).as_deref(), Some("This build can't use this service yet."), "the old error is cleared and the failure shown");
}

fn win_allow(cx: &mut TestAppContext, w: Win, p: Permission) {
    w.update(cx, |page, _, cx| page.allow(p, cx)).unwrap();
    frame(cx, w);
}

// parity: ONB-352 ONB-356 ONB-364 ONB-367 ONB-350 ONB-379
#[flow_ui::gpui::test]
async fn personalize_copy_and_first_shortcut(cx: &mut TestAppContext) {
    let r = rig(cx, false, &[]);
    let w = r.win;
    set(cx, w, |p| {
        ready(&mut p.snap);
        p.setup.step = Step::Permissions;
    });
    click(cx, w, "onboarding.primary");
    assert_eq!(read(cx, w, |p, _| p.setup.step), Step::Personalize);
    assert!(r.log.borrow().iter().any(|c| c == "shortcut"), "first run configures Right Control");
    assert!(!cx.update(|cx| Shortcut::is_saved(&cx.global::<Core>().prefs)), "a failed install isn't saved");
    assert_saw(&["Make it yours.", "Pick a look and the key you hold to dictate. Both can change later in Settings.", "Match system", "Light", "Dark", "Dictation shortcut", "Record shortcut"]);
    // A saved shortcut stays: re-entering asks for nothing.
    r.ok.set(true);
    click(cx, w, "onboarding.preset.1");
    r.log.borrow_mut().clear();
    click(cx, w, "onboarding.back");
    click(cx, w, "onboarding.primary");
    assert!(r.log.borrow().iter().all(|c| c != "shortcut"), "{:?}", r.log.borrow());
}

// parity: ONB-375 ONB-378
/// `configureShortcut`: skip for meetings, refuse while busy, install, then save, then say so.
#[flow_ui::gpui::test]
async fn preset_installs_before_saving(cx: &mut TestAppContext) {
    let r = rig(cx, false, &[]);
    let w = r.win;
    set(cx, w, |p| {
        ready(&mut p.snap);
        p.setup.step = Step::Personalize;
    });
    click(cx, w, "onboarding.preset.1");
    assert!(pref(cx, "shortcut").is_none(), "install failed, nothing saved");
    assert_saw(&["This build can't use this service yet."]);
    r.ok.set(true);
    r.log.borrow_mut().clear();
    set(cx, w, |p| p.snap.busy = true);
    click(cx, w, "onboarding.preset.2");
    assert!(r.log.borrow().is_empty(), "busy refuses before the tap");
    assert_saw(&["Another dictation or model operation is still running. Wait for it to finish."]);
    set(cx, w, |p| p.snap.busy = false);
    click(cx, w, "onboarding.preset.1");
    assert_eq!(r.log.borrow().as_slice(), ["shortcut"]);
    assert_eq!(cx.update(|cx| Shortcut::load(&cx.global::<Core>().prefs)), Shortcut::right_option(), "saved as JSON");
    assert_eq!(read(cx, w, |p, _| p.status.clone()).as_deref(), Some("Shortcut updated."));
    r.log.borrow_mut().clear();
    set(cx, w, |p| p.setup.purpose = Purpose::Meetings);
    w.update(cx, |p, _, cx| p.configure_shortcut(Shortcut::right_control(), cx)).unwrap();
    assert!(r.log.borrow().is_empty(), "skipped for meetings");
    assert_eq!(cx.update(|cx| Shortcut::load(&cx.global::<Core>().prefs)), Shortcut::right_option());
}

// parity: ONB-368 ONB-373 ONB-372
#[flow_ui::gpui::test]
async fn recording_gates_and_results(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[(Permission::Accessibility, PermissionState::Granted)]);
    let w = r.win;
    let step = |p: &mut OnboardingPage| {
        ready(&mut p.snap);
        p.setup.step = Step::Personalize;
    };
    w.update(cx, |p, _, _| step(p)).unwrap();
    // Refused Accessibility says so and never reaches the service.
    w.update(cx, |p, _, cx| {
        p.snap.accessibility = Perm::Denied;
        p.toggle_recording(cx);
    })
    .unwrap();
    assert_eq!(read(cx, w, |p, _| p.recording_error.clone()).as_deref(), Some("Allow Accessibility to record and prioritize shortcuts."));
    assert!(!r.log.borrow().contains(&"record".to_string()));
    w.update(cx, |p, _, cx| {
        p.snap.accessibility = Perm::Granted;
        p.toggle_recording(cx);
    })
    .unwrap();
    frame(cx, w);
    assert_saw(&["Press your keys…"]);
    assert!(disabled(cx, w, "onboarding.primary"), "no advancing while recording");
    // The value arrives from the service through the poll, and is configured and saved.
    *r.recorded.borrow_mut() = Some(Some(Shortcut::right_option().json()));
    w.update(cx, |p, _, cx| p.refresh(cx)).unwrap();
    assert!(!read(cx, w, |p, _| p.recording));
    assert_eq!(cx.update(|cx| Shortcut::load(&cx.global::<Core>().prefs)), Shortcut::right_option());
    // Nil just ends.
    w.update(cx, |p, _, cx| p.toggle_recording(cx)).unwrap();
    r.log.borrow_mut().clear();
    *r.recorded.borrow_mut() = Some(None);
    w.update(cx, |p, _, cx| p.refresh(cx)).unwrap();
    assert!(!read(cx, w, |p, _| p.recording));
    assert!(!r.log.borrow().contains(&"shortcut".to_string()));
}

// parity: ONB-015 ONB-357 ONB-358 ONB-359
/// `NSApp.appearance` follows the choice: nil for system, aqua, darkAqua.
#[flow_ui::gpui::test]
async fn theme_cards_write_and_apply(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| p.setup.step = Step::Personalize);
    r.log.borrow_mut().clear();
    click(cx, w, "onboarding.theme.dark");
    assert_eq!(pref(cx, "appearance").as_deref(), Some("dark"));
    assert!(r.log.borrow().contains(&"appearance Some(true)".to_string()), "{:?}", r.log.borrow());
    assert!(cx.update(|cx| pal(cx).mode.is_dark()));
    click(cx, w, "onboarding.theme.light");
    assert!(r.log.borrow().contains(&"appearance Some(false)".to_string()));
    assert!(!cx.update(|cx| pal(cx).mode.is_dark()));
    click(cx, w, "onboarding.theme.system");
    assert!(r.log.borrow().contains(&"appearance None".to_string()));
    w.update(cx, |_, w, _| {
        assert_eq!(w.find("onboarding.theme.system").label().as_deref(), Some("Match system appearance"));
        assert_eq!(w.find("onboarding.theme.system").checked(), Some(true));
    })
    .unwrap();
}

// parity: ONB-061 ONB-351 ONB-086
/// Meetings: no shortcut, its own button, and the same gate as permissions: microphone and storage.
#[flow_ui::gpui::test]
async fn meeting_personalize_gate(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| {
        p.setup.purpose = Purpose::Meetings;
        p.setup.step = Step::Personalize;
        p.snap.storage_available = true;
        p.snap.microphone = Perm::Denied;
        p.snap.input_monitoring = Perm::Denied;
    });
    assert_saw(&["Pick a look. You can change it later in Settings.", "Finish setup"]);
    assert!(!saw("Dictation shortcut"));
    assert!(disabled(cx, w, "onboarding.primary"), "no microphone");
    set(cx, w, |p| p.snap.microphone = Perm::Granted);
    assert!(!disabled(cx, w, "onboarding.primary"), "Input Monitoring isn't needed");
    set(cx, w, |p| p.snap.storage_available = false);
    assert!(disabled(cx, w, "onboarding.primary"), "no storage");
    assert!(r.log.borrow().iter().all(|c| c != "shortcut"));
}

// parity: ONB-369 ONB-370
#[flow_ui::gpui::test]
async fn record_button_toggles_without_saving(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| {
        ready(&mut p.snap);
        p.setup.step = Step::Personalize;
    });
    click(cx, w, "onboarding.recordShortcut");
    assert!(read(cx, w, |p, _| p.recording) && r.log.borrow().contains(&"record".to_string()));
    click(cx, w, "onboarding.recordShortcut");
    assert!(!read(cx, w, |p, _| p.recording));
    assert!(pref(cx, "shortcut").is_none(), "stopping saves nothing");
}

// parity: ONB-381 ONB-382 ONB-383 ONB-384 ONB-385 ONB-386 ONB-387 ONB-388 ONB-389 ONB-396 ONB-060 ONB-053 ONB-087 ONB-088 ONB-404 ONB-405 ONB-406 ONB-407 ONB-033
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

// parity: ONB-057 ONB-174 ONB-175 ONB-176 ONB-177 ONB-178 ONB-179 ONB-180 ONB-192 ONB-193 ONB-194 ONB-195 ONB-196 ONB-197 ONB-198 ONB-199 ONB-202 ONB-203 ONB-204 ONB-205 ONB-206 ONB-207 ONB-208 ONB-209 ONB-210 ONB-212 ONB-213 ONB-214 ONB-215 ONB-217 ONB-218 ONB-219 ONB-222 ONB-045 ONB-107
#[flow_ui::gpui::test]
async fn server_step_consent_trust_sign_in_and_turn_off(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    let (body, fingerprint) = identity();
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.setup.ai_mode = AiMode::Remote;
        p.remote.base = Some(http(vec![("/v1/remote/identity", 200, body.clone())]));
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
    assert_saw(&["Server fingerprint", &fingerprint, "flowd admin identity", "Trust This Server", "Compare the fingerprint"]);
    // Trust pins, then both sign-ins appear when configured.
    click(cx, w, "settings.remoteTrust");
    assert_eq!(pref(cx, "remote.state").as_deref(), Some("pinned"));
    assert!(r.log.borrow().contains(&format!("secret {}", flow_core::settings::remote_keychain("server-key"))), "{:?}", r.log.borrow());
    assert!(r.log.borrow().contains(&format!("remove {}", flow_core::settings::remote_keychain("device-key"))), "pinning clears old credentials");
    assert_saw(&[&format!("Pinned fingerprint  {fingerprint}"), "Sign in with Apple"]);
    assert!(!saw("Sign in with Google"));
    set(cx, w, |p| p.remote.google = true);
    assert_saw(&["Sign in with Google"]);
    // A failed sign-in stays pinned and says so.
    *r.enroll.borrow_mut() = Err("sign-in cancelled");
    click(cx, w, "settings.remoteSignInApple");
    assert_saw(&["Sign-in did not finish."]);
    assert_eq!(pref(cx, "remote.state").as_deref(), Some("pinned"));
    *r.enroll.borrow_mut() = Err(server::SERVER_UNREACHABLE);
    click(cx, w, "settings.remoteSignInApple");
    assert_saw(&["The server could not be reached. Try again."]);
    *r.enroll.borrow_mut() = Ok("pending".to_string());
    click(cx, w, "settings.remoteSignInApple");
    assert_eq!(pref(cx, "remote.state").as_deref(), Some("pending"));
    assert!(!disabled(cx, w, "onboarding.primary"), "enrolled unlocks the step");
    // Pin mismatch offers Enroll Again, whose failure is the identity error.
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("remote.state", "pin_mismatch"));
    frame(cx, w);
    assert_saw(&["Server identity changed"]);
    set(cx, w, |p| p.remote.base = Some(closed_server()));
    click(cx, w, "settings.remoteEnrollAgain");
    assert_saw(&["The server did not answer with a LocalFlow identity. Check the address."]);
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
    let base = http(vec![("/v1/rewrite/health", 200, HEALTHY.to_string()), ("/v1/analysis/health", 404, String::new())]);
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("rewriteEndpoint", base.as_str()));
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
    let origin = rewrite_origin(&base).unwrap();
    assert!(r.log.borrow().contains(&format!("secret {}", flow_core::settings::rewrite_keychain(&origin))), "{:?}", r.log.borrow());
    assert_saw(&["Connected · studio · qwen", "This server does not offer meeting analysis."]);
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
    click(cx, w, "onboarding.allowInsecure");
    assert!(cx.update(|cx| insecure_override(&cx.global::<Core>().prefs, "http://studio.local:8080")));
    // A real connection refused reads as unreachable.
    let closed = closed_server();
    w.update(cx, |p, _, cx| p.edit_endpoint(closed, cx)).unwrap();
    frame(cx, w);
    click(cx, w, "onboarding.connect");
    assert_saw(&["Could not reach the server."]);
    // Editing invalidates the result.
    w.update(cx, |p, _, cx| p.edit_endpoint("http://other.local:8080".into(), cx)).unwrap();
    assert!(read(cx, w, |p, _| p.connection.is_none()));
}

// parity: ONB-011 ONB-304
/// The 500 ms loop sees a new grant, and resumes an AI install once the login item is approved.
#[flow_ui::gpui::test]
async fn polling_picks_up_a_new_permission(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    cx.update_window(w.into(), |_, w, _| w.activate_window()).unwrap();
    w.update(cx, |p, _, _| p.ai_phase = AiPhase::Failed(AI_ERROR_APPROVAL.into())).unwrap();
    cx.executor().advance_clock(Duration::from_millis(600));
    cx.run_until_parked();
    assert!(r.log.borrow().iter().all(|c| !c.starts_with("ai ")), "not approved yet");
    r.background.set(true);
    cx.update(|cx| {
        let fake = Fake::default();
        *fake.permissions.borrow_mut() = vec![(Permission::Microphone, PermissionState::Granted)];
        let stub = Stub { fake, ok: r.ok.clone(), log: r.log.clone(), answer: r.answer.clone(), enroll: r.enroll.clone(), recorded: r.recorded.clone(), background: r.background.clone(), verified: r.verified.clone() };
        cx.global_mut::<Core>().services = Box::new(stub);
    });
    cx.executor().advance_clock(Duration::from_millis(600));
    cx.run_until_parked();
    assert_eq!(read(cx, w, |p, _| p.snap.microphone), Perm::Granted);
    assert!(r.log.borrow().iter().any(|c| c.starts_with("ai ")), "{:?}", r.log.borrow());
}

// parity: ONB-004
/// An unfinished meetings setup starts over as Both, before any step shows.
#[flow_ui::gpui::test]
async fn launch_resets_an_unfinished_meetings_purpose(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("setup.purpose", "meetings"));
    let w = cx.add_window(|w, cx| OnboardingPage::new(w, cx));
    frame(cx, w);
    assert_eq!(read(cx, w, |p, _| p.setup.purpose), Purpose::Both);
    assert_eq!(pref(cx, "setup.purpose").as_deref(), Some("both"));
}

// parity: ONB-271
/// Silent, once, only after speech is on disk and never for a server-only setup. A failure shows nothing.
#[flow_ui::gpui::test]
async fn booster_follows_the_speech_model(cx: &mut TestAppContext) {
    let r = rig(cx, false, &[]);
    let w = r.win;
    let refresh = |cx: &mut TestAppContext| {
        w.update(cx, |p, _, cx| {
            p.frozen = false;
            p.refresh(cx);
        })
        .unwrap()
    };
    let boosts = |r: &Rig| r.log.borrow().iter().filter(|c| *c == "booster").count();
    w.update(cx, |p, _, cx| {
        p.setup.purpose = Purpose::Both;
        p.setup.ai_mode = AiMode::Off;
        p.setup.step = Step::Ai;
        p.primary(cx);
    })
    .unwrap();
    refresh(cx);
    assert_eq!(boosts(&r), 0, "speech isn't installed yet");
    w.update(cx, |p, _, _| p.snap.model_installed = true).unwrap();
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("server.only", true));
    refresh(cx);
    assert_eq!(boosts(&r), 0, "a server-only setup needs no booster");
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("server.only", false));
    let before = read(cx, w, |p, _| p.error.clone());
    refresh(cx);
    refresh(cx);
    assert_eq!(boosts(&r), 1, "once");
    assert_eq!(read(cx, w, |p, _| p.error.clone()), before, "its failure is only logged");
}

// parity: ONB-220 ONB-229
/// `busy` covers the identity fetch and sign-in and disables Enroll Again and sign-in only.
#[flow_ui::gpui::test]
async fn busy_disables_sign_in_and_offline_stays_enrolled(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    cx.update(|cx| {
        let prefs = &mut cx.global_mut::<Core>().prefs;
        prefs.set("remote.enabled", true);
        prefs.set("remote.serverURL", "https://box.example.com");
        prefs.set("remote.state", "pin_mismatch");
    });
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.setup.ai_mode = AiMode::Remote;
        p.remote.base = Some(closed_server());
    });
    assert!(!disabled(cx, w, "settings.remoteEnrollAgain"));
    // Busy is true from the press until the answer comes back.
    w.update(cx, |p, _, cx| p.fetch_identity(cx)).unwrap();
    assert!(read(cx, w, |p, _| p.remote.busy));
    cx.update_window(w.into(), |_, w, cx| w.render_frame(cx)).unwrap();
    assert!(disabled(cx, w, "settings.remoteEnrollAgain"));
    assert!(!disabled(cx, w, "settings.remoteEnabled"), "the switch stays live");
    frame(cx, w);
    assert!(!read(cx, w, |p, _| p.remote.busy));
    assert_saw(&["The server did not answer with a LocalFlow identity. Check the address."]);
    // Sign-in the same way.
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("remote.state", "pinned"));
    frame(cx, w);
    w.update(cx, |p, _, cx| p.sign_in("apple", cx)).unwrap();
    assert!(read(cx, w, |p, _| p.remote.busy));
    cx.update_window(w.into(), |_, w, cx| w.render_frame(cx)).unwrap();
    assert!(disabled(cx, w, "settings.remoteSignInApple"));
    frame(cx, w);
    assert!(!read(cx, w, |p, _| p.remote.busy));
    // Enrolled, the same closed server blocks nothing: the state is a stored cache.
    assert_eq!(pref(cx, "remote.state").as_deref(), Some("pending"));
    assert!(!disabled(cx, w, "onboarding.primary"));
    click(cx, w, "onboarding.primary");
    assert_eq!(read(cx, w, |p, _| p.setup.step), Step::Downloads);
}

// parity: ONB-201
#[flow_ui::gpui::test]
async fn sign_in_pin_mismatch_is_a_state_not_an_error(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    cx.update(|cx| {
        let prefs = &mut cx.global_mut::<Core>().prefs;
        prefs.set("remote.enabled", true);
        prefs.set("remote.serverURL", "https://box.example.com");
        prefs.set("remote.state", "pinned");
    });
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.setup.ai_mode = AiMode::Remote;
    });
    *r.enroll.borrow_mut() = Ok("pin_mismatch".to_string());
    click(cx, w, "settings.remoteSignInApple");
    assert_eq!(pref(cx, "remote.state").as_deref(), Some("pin_mismatch"));
    assert!(read(cx, w, |p, _| p.remote.error.is_none()));
    assert_saw(&["Server identity changed", "Enroll Again"]);
}

// parity: ONB-230 ONB-192
/// `DisclosureGroup`: content 12 under the title, children 16 apart, not the page's 24.
#[flow_ui::gpui::test]
async fn advanced_disclosure_spacing(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.setup.ai_mode = AiMode::Remote;
        p.legacy_open = true;
    });
    let (title, content) = w.update(cx, |_, w, _| (w.find("onboarding.legacyRewriteServer").bounds(), w.find("onboarding.legacyContent").bounds())).unwrap();
    assert_eq!(f32::from(content.origin.y - (title.origin.y + title.size.height)), 12.);
}

// parity: ONB-196
/// The sign-in buttons are SwiftUI's default button: 24 high, 8 apart.
#[flow_ui::gpui::test]
async fn sign_in_buttons_are_native_sized(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    cx.update(|cx| {
        let prefs = &mut cx.global_mut::<Core>().prefs;
        prefs.set("remote.enabled", true);
        prefs.set("remote.serverURL", "https://box.example.com");
        prefs.set("remote.state", "pinned");
    });
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.setup.ai_mode = AiMode::Remote;
        p.remote.google = true;
    });
    let (apple, google) = w.update(cx, |_, w, _| (w.find("settings.remoteSignInApple").bounds(), w.find("settings.remoteSignInGoogle").bounds())).unwrap();
    assert_eq!(f32::from(apple.size.height).round(), 24.);
    assert_eq!(f32::from(google.origin.x - (apple.origin.x + apple.size.width)), 8.);
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

// parity: SHELL-035 ONB-411
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

// parity: ONB-281 ONB-282 ONB-283
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

// parity: ONB-252
/// The first card follows the AI choice; the real Skip leaves speech alone in it.
#[flow_ui::gpui::test]
async fn first_download_card_follows_the_ai_choice(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    set(cx, w, |p| {
        p.setup.step = Step::Downloads;
        p.setup.ai_mode = AiMode::Local;
    });
    assert_saw(&["Speech recognition", "On-device AI"]);
    assert!(!saw("Your server"));
    set(cx, w, |p| p.setup.ai_mode = AiMode::Remote);
    assert_saw(&["Speech recognition", "Your server"]);
    assert!(!saw("On-device AI"));
    set(cx, w, |p| {
        p.setup.step = Step::Ai;
        p.setup.ai_mode = AiMode::Local;
    });
    click(cx, w, "onboarding.skipAI");
    assert_eq!(read(cx, w, |p, _| (p.setup.step, p.setup.ai_mode)), (Step::Downloads, AiMode::Off));
    assert_saw(&["Speech recognition"]);
    assert!(!saw("On-device AI") && !saw("Your server"), "nothing extra with Skip");
}

// parity: ONB-330
/// Microphone in the permissions group: Allow is at least 99 wide, named for screen readers,
/// off while an action runs, and asks for the microphone.
#[flow_ui::gpui::test]
async fn microphone_group_row(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    set(cx, w, |p| {
        p.setup.step = Step::Permissions;
        p.snap.microphone = Perm::Unknown;
    });
    let (width, label) = w.update(cx, |_, w, _| (w.find("onboarding.allow.Microphone").bounds().size.width, w.find("onboarding.allow.Microphone").label().map(|l| l.to_string()))).unwrap();
    assert_eq!(f32::from(width), 99.);
    assert_eq!(label.as_deref(), Some("Allow Microphone"));
    assert!(!disabled(cx, w, "onboarding.allow.Microphone"));
    click(cx, w, "onboarding.allow.Microphone");
    assert!(r.log.borrow().iter().any(|c| c == "request Microphone"), "{:?}", r.log.borrow());
    set(cx, w, |p| p.performing = true);
    assert!(disabled(cx, w, "onboarding.allow.Microphone"));
}

// parity: ONB-218
/// The native alert's Turn Off carries `role: .destructive`; Cancel doesn't.
#[flow_ui::gpui::test]
async fn turn_off_alert_is_destructive(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    cx.update(|cx| {
        let prefs = &mut cx.global_mut::<Core>().prefs;
        prefs.set("remote.enabled", true);
        prefs.set("remote.serverURL", "https://box.example.com");
        prefs.set("remote.state", "approved");
    });
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.setup.ai_mode = AiMode::Remote;
    });
    click(cx, w, "settings.remoteEnabled");
    let (message, detail) = cx.pending_prompt().expect("Swift's alert is native");
    assert_eq!(message, "Turn off remote dictation?");
    assert_eq!(detail, "This Mac's sign-in, device key and server pin are deleted. Your history stays. You will need approval again to turn it back on.");
    cx.run_until_parked();
    assert_eq!(r.log.borrow().iter().filter(|c| c.starts_with("destructive")).cloned().collect::<Vec<_>>(), ["destructive Turn Off"]);
    cx.simulate_prompt_answer("Turn Off");
    cx.run_until_parked();
    assert!(!flag(cx, "remote.enabled"));
}

// parity: ONB-232 ONB-234
/// Both placeholders show until there's a value, and the address's is a link colour.
#[flow_ui::gpui::test]
async fn placeholders_are_drawn_until_typed(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.setup.ai_mode = AiMode::Remote;
        p.legacy_open = true;
    });
    assert_saw(&["https://studio.local:8080", "The server's LOCALFLOW_REWRITE_TOKEN"]);
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("rewriteEndpoint", "https://a.example.com"));
    w.update(cx, |p, w, cx| p.credential_input.update(cx, |s, cx| s.set_value("k", w, cx))).unwrap();
    frame(cx, w);
    assert!(!saw("https://studio.local:8080") && !saw("The server's LOCALFLOW_REWRITE_TOKEN"));
}

#[track_caller]
fn style(text: &str, size: f32, weight: Option<f32>, color: Hsla) {
    let s = flow_ui::probe::style_of(text).unwrap_or_else(|| panic!("not drawn: {text}"));
    assert_eq!(s.size, size, "size of {text}");
    if let Some(weight) = weight {
        assert_eq!(s.weight, weight, "weight of {text}");
    }
    assert_eq!(s.color, color, "colour of {text}");
}

#[track_caller]
fn drew(symbols: &[&str]) {
    let all = flow_ui::probe::symbols();
    for s in symbols {
        assert!(all.iter().any(|d| d == s), "{s} not in {all:?}");
    }
}

fn colours(cx: &mut TestAppContext) -> (Hsla, Hsla, Hsla) {
    cx.update(|cx| {
        let p = pal(cx);
        (p.accent, p.muted, p.warning)
    })
}

// parity: ONB-118 ONB-122 ONB-123 ONB-124 ONB-125 ONB-129 ONB-130 ONB-131
#[flow_ui::gpui::test]
async fn intro_and_purpose_draw_swifts_symbols(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    let (accent, ..) = colours(cx);
    drew(&["waveform", "lock.shield", "keyboard", "person.2.wave.2", "sparkles"]);
    assert_eq!(flow_ui::probe::symbol_color("waveform"), Some(accent));
    click(cx, w, "onboarding.primary");
    drew(&["square.stack", "keyboard", "person.2.wave.2"]);
    assert!(!flow_ui::probe::symbols().iter().any(|s| s == "lock.shield"));
}

// parity: ONB-141 ONB-142 ONB-143 ONB-144 ONB-146 ONB-147 ONB-149 ONB-150 ONB-151 ONB-152 ONB-153 ONB-051
#[flow_ui::gpui::test]
async fn ai_step_symbols_notes_and_skip(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    let (_, muted, _) = colours(cx);
    assert_saw(&["Get started"]);
    assert!(!saw("Skip for now"), "only on the AI step");
    set(cx, w, |p| p.setup.step = Step::Ai);
    assert_saw(&["Skip for now"]);
    drew(&["laptopcomputer", "server.rack", "cpu", "square.stack.3d.up", "bolt.horizontal", "checkmark.shield"]);
    style("Your text never leaves this Mac. Every download is pinned to an exact version and checksum.", 13., None, muted);
    set(cx, w, |p| p.setup.ai_mode = AiMode::Remote);
    drew(&["laptopcomputer", "server.rack", "info.circle"]);
    assert!(!flow_ui::probe::symbols().iter().any(|s| s == "cpu"), "the local panel leaves");
    set(cx, w, |p| {
        p.setup.purpose = Purpose::Meetings;
        p.setup.ai_mode = AiMode::Local;
    });
    assert_saw(&["Skip for now"]);
    drew(&["laptopcomputer", "server.rack", "text.badge.xmark"]);
    w.update(cx, |_, w, _| assert!(w.try_find("onboarding.meetingSkip").is_some())).unwrap();
    set(cx, w, |p| p.setup.step = Step::Permissions);
    assert!(!saw("Skip for now"));
}

// parity: ONB-164 ONB-165 ONB-166 ONB-167 ONB-171 ONB-078
#[flow_ui::gpui::test]
async fn model_rows_type_colour_and_memory_gate(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    let (accent, muted, warning) = colours(cx);
    let ink = cx.update(|cx| pal(cx).ink);
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.downloaded[1] = true;
    });
    let first = read(cx, w, |p, _| p.selected_model());
    style(&bytes(first.download_bytes), 13., Some(500.), ink);
    style("Downloaded", 13., Some(500.), accent);
    style(&format!("Uses about {} GB", first.peak()), 12., None, muted);
    style("Needs 48 GB memory", 12., None, warning);
    // Meetings on this computer: the choice must fit the memory.
    set(cx, w, |p| {
        p.setup.purpose = Purpose::Meetings;
        p.setup.ai_mode = AiMode::Local;
        p.selection = 4;
    });
    assert!(disabled(cx, w, "onboarding.primary"), "a model that doesn't fit");
    set(cx, w, |p| p.selection = 1);
    assert!(!disabled(cx, w, "onboarding.primary"));
    // In memory only: a new page starts from the first model again.
    let again = cx.add_window(|w, cx| OnboardingPage::new(w, cx));
    assert_eq!(read(cx, again, |p, _| p.selection), 0);
}

// parity: ONB-253 ONB-255 ONB-257 ONB-258 ONB-259 ONB-264 ONB-276 ONB-277 ONB-278 ONB-279 ONB-280 ONB-284
#[flow_ui::gpui::test]
async fn download_row_states_read_like_swift(cx: &mut TestAppContext) {
    let w = rig(cx, false, &[]).win;
    let (accent, muted, warning) = colours(cx);
    set(cx, w, |p| {
        p.setup.step = Step::Downloads;
        p.setup.ai_mode = AiMode::Local;
    });
    drew(&["waveform", "sparkles"]);
    style("Queued", 12., None, muted);
    assert_eq!(w.update(cx, |_, w, _| w.find_all("onboarding.bar").len()).unwrap(), 0, "waiting has no bar");
    set(cx, w, |p| {
        p.snap.installing = true;
        p.snap.progress = (10 << 20, 100 << 20);
    });
    style(&format!("{} of {}", bytes(10 << 20), bytes(100 << 20)), 12., None, muted);
    w.update(cx, |_, w, _| {
        let bars = w.find_all("onboarding.bar");
        assert_eq!(bars.len(), 1);
        assert_eq!(bars[0].label().as_deref(), Some("Progress"));
        assert_eq!(bars[0].value(), Some("10 percent"));
    })
    .unwrap();
    set(cx, w, |p| {
        p.snap.installing = false;
        p.snap.model_installed = true;
        p.ai_phase = AiPhase::PreparingRuntime;
    });
    style("Ready", 12., Some(500.), accent);
    assert_eq!(flow_ui::probe::symbol_color("checkmark.circle.fill"), Some(accent));
    w.update(cx, |_, w, _| {
        let bars = w.find_all("onboarding.bar");
        assert_eq!(bars.len(), 1, "only the working row has a bar");
        assert_eq!(bars[0].value(), Some("In progress"));
    })
    .unwrap();
    click(cx, w, "onboarding.meetingDownload");
    drew(&["person.2.wave.2"]);
    style("Stopped", 12., None, warning);
    style("This build can't use this service yet.", 12., None, warning);
    assert_eq!(flow_ui::probe::symbol_color("exclamationmark.circle"), Some(warning));
    // The server row names the enrolled host, the rewrite host, or "Remote".
    set(cx, w, |p| p.setup.ai_mode = AiMode::Remote);
    drew(&["server.rack"]);
    assert_saw(&["Your server"]);
    style("Remote", 13., None, muted);
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("rewriteEndpoint", "https://rewrite.example.com"));
    frame(cx, w);
    style("rewrite.example.com", 13., None, muted);
    cx.update(|cx| {
        let prefs = &mut cx.global_mut::<Core>().prefs;
        prefs.set("remote.enabled", true);
        prefs.set("remote.serverURL", "https://box.example.com");
        prefs.set("remote.state", "approved");
    });
    frame(cx, w);
    style("box.example.com", 13., None, muted);
}

// parity: ONB-038 ONB-039
#[flow_ui::gpui::test]
async fn live_ai_card_follows_mode_phase_and_step(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    for step in [Step::Permissions, Step::Personalize, Step::Test] {
        set(cx, w, |p| {
            p.setup.step = step;
            p.setup.ai_mode = AiMode::Local;
            p.ai_phase = AiPhase::PreparingRuntime;
        });
        assert_saw(&["On-device AI"]);
        drew(&["sparkles"]);
        set(cx, w, |p| p.ai_phase = AiPhase::Ready);
        assert!(!saw("On-device AI"), "ready hides it on {step:?}");
        set(cx, w, |p| {
            p.ai_phase = AiPhase::PreparingRuntime;
            p.setup.ai_mode = AiMode::Remote;
        });
        assert!(!saw("On-device AI"), "a server hides it on {step:?}");
    }
    set(cx, w, |p| {
        p.setup.step = Step::Purpose;
        p.setup.ai_mode = AiMode::Local;
    });
    assert!(!saw("On-device AI"), "other steps don't show it");
}

// parity: ONB-319 ONB-320 ONB-322 ONB-324
#[flow_ui::gpui::test]
async fn access_rows_symbols_and_allowed_type(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    let (accent, ..) = colours(cx);
    set(cx, w, |p| {
        p.setup.step = Step::Permissions;
        p.setup.purpose = Purpose::Meetings;
        p.snap.microphone = Perm::Granted;
        p.snap.system_audio = Perm::Denied;
    });
    drew(&["mic", "speaker.wave.2"]);
    style("Allowed", 12., Some(500.), accent);
    assert_eq!(flow_ui::probe::symbol_color("checkmark.circle.fill"), Some(accent));
    set(cx, w, |p| p.snap.system_audio = Perm::Granted);
    style("Everything is allowed.", 14., Some(500.), accent);
}

// parity: ONB-357 ONB-359 ONB-367 ONB-373 ONB-378
#[flow_ui::gpui::test]
async fn personalize_labels_record_gate_and_errors(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[(Permission::Accessibility, PermissionState::Granted)]);
    let w = r.win;
    let (accent, _, warning) = colours(cx);
    set(cx, w, |p| {
        p.setup.step = Step::Personalize;
        ready(&mut p.snap);
    });
    click(cx, w, "onboarding.theme.dark");
    let accent_dark = cx.update(|cx| pal(cx).accent);
    assert_ne!(accent_dark, accent, "the theme applies, so read the live accent");
    assert_eq!(flow_ui::probe::symbol_color("checkmark.circle.fill"), Some(accent_dark));
    w.update(cx, |_, w, _| {
        assert_eq!(w.find("onboarding.theme.light").label().as_deref(), Some("Light"));
        assert_eq!(w.find("onboarding.theme.dark").label().as_deref(), Some("Dark"));
        assert_eq!(w.find("onboarding.theme.dark").checked(), Some(true));
    })
    .unwrap();
    click(cx, w, "onboarding.theme.light");
    assert!(!disabled(cx, w, "onboarding.recordShortcut"));
    set(cx, w, |p| p.performing = true);
    assert!(disabled(cx, w, "onboarding.recordShortcut"));
    // The busy refusal is the third of Swift's recording errors.
    set(cx, w, |p| {
        p.performing = false;
        p.snap.busy = true;
    });
    click(cx, w, "onboarding.preset.1");
    let busy = "Another dictation or model operation is still running. Wait for it to finish.";
    assert_eq!(read(cx, w, |p, _| p.recording_error.clone().or(p.error.clone())).as_deref(), Some(busy));
    style(busy, 12., None, warning);
}

// parity: ONB-053 ONB-384 ONB-385 ONB-389 ONB-396
#[flow_ui::gpui::test]
async fn test_step_type_hint_and_final_disable(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    let (_, muted, warning) = colours(cx);
    set(cx, w, |p| {
        p.setup.step = Step::Test;
        ready(&mut p.snap);
    });
    style("This test is optional. You can start dictating after setup.", 13., None, muted);
    w.update(cx, |_, w, _| assert_eq!(w.find("onboarding.skipTest").label().as_deref(), Some("Skip test. Finish setup without recording a dictation."))).unwrap();
    set(cx, w, |p| p.setup.test_error = Some("The speech model is unavailable. Verify the local model in Settings.".into()));
    style("The speech model is unavailable. Verify the local model in Settings.", 13., None, warning);
    set(cx, w, |p| {
        p.setup.test_error = None;
        p.snap.microphone = Perm::Denied;
    });
    style("Allow Microphone access to record.", 14., None, warning);
    set(cx, w, |p| {
        p.snap.microphone = Perm::Granted;
        p.setup.test_succeeded = true;
    });
    assert!(disabled(cx, w, "onboarding.startTest"), "succeeded");
}

// parity: ONB-193 ONB-194 ONB-195 ONB-199 ONB-210 ONB-212 ONB-213 ONB-214 ONB-215 ONB-217
#[flow_ui::gpui::test]
async fn server_type_keys_prefill_and_trust_failure(cx: &mut TestAppContext) {
    let r = rig(cx, true, &[]);
    let w = r.win;
    let (_, muted, warning) = colours(cx);
    let (body, fingerprint) = identity();
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("remote.serverURL", "https://old.example.com"));
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.setup.ai_mode = AiMode::Remote;
        p.remote.base = Some(http(vec![("/v1/remote/identity", 200, body.clone())]));
    });
    // Turning on opens the sheet with the stored address, focused.
    click(cx, w, "settings.remoteEnabled");
    assert_eq!(read(cx, w, |p, cx| p.server_draft.read(cx).value().to_string()), "https://old.example.com");
    assert!(w.update(cx, |p, w, cx| p.server_draft.read(cx).focus_handle(cx).is_focused(w)).unwrap());
    style("Server: old.example.com", 13., Some(500.), cx.update(|cx| pal(cx).ink));
    // Escape closes it, clears the draft and stores nothing.
    cx.update_window(w.into(), |_, w, cx| w.press("escape", cx)).unwrap();
    frame(cx, w);
    assert!(!read(cx, w, |p, _| p.remote.consent_open) && !flag(cx, "remote.enabled"));
    // Typed text doesn't survive: the next open starts from the stored address.
    click(cx, w, "settings.remoteEnabled");
    w.update(cx, |p, w, cx| p.server_draft.update(cx, |s, cx| s.set_value("https://typed.example.com", w, cx))).unwrap();
    click(cx, w, "settings.remoteConsentCancel");
    click(cx, w, "settings.remoteEnabled");
    assert_eq!(read(cx, w, |p, cx| p.server_draft.read(cx).value().to_string()), "https://old.example.com");
    click(cx, w, "settings.remoteConsentCancel");
    // Return follows a disabled Turn On: a bad address is refused in the error line.
    click(cx, w, "settings.remoteEnabled");
    w.update(cx, |p, w, cx| p.server_draft.update(cx, |s, cx| s.set_value("http://x.example.com/path", w, cx))).unwrap();
    frame(cx, w);
    assert!(disabled(cx, w, "settings.remoteConsentConfirm"));
    w.update(cx, |p, _, cx| p.confirm_consent(cx)).unwrap();
    frame(cx, w);
    style("Enter the server's https:// address without a path.", 12., None, warning);
    w.update(cx, |p, w, cx| p.server_draft.update(cx, |s, cx| s.set_value("https://box.example.com", w, cx))).unwrap();
    frame(cx, w);
    cx.update_window(w.into(), |_, w, cx| w.press("enter", cx)).unwrap();
    frame(cx, w);
    assert!(flag(cx, "remote.enabled"), "Return confirms a valid address");
    style("Server fingerprint", 12., Some(500.), muted);
    assert_eq!(flow_ui::probe::style_of(&fingerprint).map(|s| s.size), Some(13.));
    w.update(cx, |_, w, _| assert!(w.try_find("settings.remoteFingerprint").is_some())).unwrap();
    style("Compare it with `flowd admin identity` on the server before trusting it.", 12., None, muted);
    // The Keychain refusing the key is Swift's error, and nothing is pinned.
    r.ok.set(false);
    click(cx, w, "settings.remoteTrust");
    assert_saw(&["The server identity could not be saved."]);
    assert_ne!(pref(cx, "remote.state").as_deref(), Some("pinned"));
    r.ok.set(true);
    click(cx, w, "settings.remoteTrust");
    style(&format!("Pinned fingerprint  {fingerprint}"), 12., None, muted);
    *r.enroll.borrow_mut() = Err("sign-in cancelled");
    click(cx, w, "settings.remoteSignInApple");
    style("Sign-in did not finish.", 12., None, warning);
}

// parity: ONB-222 ONB-235 ONB-238 ONB-240 ONB-241 ONB-242
#[flow_ui::gpui::test]
async fn rewrite_form_type_masking_and_analysis_lines(cx: &mut TestAppContext) {
    let w = rig(cx, true, &[]).win;
    let (accent, muted, warning) = colours(cx);
    let analysis = |body: &str| server::analysis_status_text(&http(vec![("/v1/analysis/health", 200, body.to_string())]), None);
    assert_eq!(analysis(r#"{"service":"localflow-analysis","protocol_versions":[1],"backend":{"state":"ready","model":"m"}}"#), "Meeting analysis: available (model m).");
    assert_eq!(analysis(r#"{"service":"localflow-analysis","protocol_versions":[1]}"#), "Meeting analysis: available.");
    assert_eq!(analysis("not json"), "Meeting analysis could not be checked.");
    assert_eq!(server::analysis_status_text(&http(vec![]), None), "This server does not offer meeting analysis.");
    cx.update(|cx| cx.global_mut::<Core>().prefs.set("rewriteEndpoint", "https://rewrite.example.com"));
    set(cx, w, |p| {
        p.setup.step = Step::AiDetails;
        p.setup.ai_mode = AiMode::Remote;
    });
    w.update(cx, |_, w, _| assert!(w.try_find("onboarding.remoteStatus").is_some())).unwrap();
    click(cx, w, "onboarding.legacyRewriteServer");
    assert!(!disabled(cx, w, "onboarding.connect"));
    set(cx, w, |p| {
        p.connection_testing = true;
        p.credential_error = Some("Enter a credential first.".into());
    });
    assert_saw(&["Connecting…"]);
    assert!(disabled(cx, w, "onboarding.connect"));
    style("Enter a credential first.", 12., None, warning);
    set(cx, w, |p| {
        p.connection_testing = false;
        p.credential_error = None;
        p.connection = Some(Ok(vec!["studio".into(), "qwen".into()]));
        p.analysis = Some("Meeting analysis: available.".into());
    });
    style("Connected · studio · qwen", 13., Some(500.), accent);
    assert_eq!(flow_ui::probe::symbol_color("checkmark.circle.fill"), Some(accent));
    style("Meeting analysis: available.", 12., None, muted);
    set(cx, w, |p| p.connection = Some(Err("Could not reach the server.".into())));
    style("Could not reach the server.", 13., None, warning);
    w.update(cx, |p, _, cx| p.edit_endpoint("not a url".into(), cx)).unwrap();
    frame(cx, w);
    assert!(disabled(cx, w, "onboarding.connect"), "an invalid endpoint");
}

// parity: ONB-021
#[test]
fn step_change_animates_a_quarter_second_unless_reduce_motion() {
    assert_eq!(step_transition(false), Some(Duration::from_millis(250)));
    assert_eq!(step_transition(true), None);
}

// parity: ONB-003
#[flow_ui::gpui::test]
async fn launch_page_follows_the_purpose(cx: &mut TestAppContext) {
    boot(cx, Mode::Light);
    cx.update(|cx| {
        assert_eq!(crate::shell::landing_page(cx.global::<Core>()), crate::pages::Page::History);
        cx.global_mut::<Core>().prefs.set("setup.purpose", "meetings");
        assert_eq!(crate::shell::landing_page(cx.global::<Core>()), crate::pages::Page::Meetings);
    });
}
