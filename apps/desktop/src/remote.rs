//! Remote client wiring: platform credentials behind flow-core's traits, off-thread operations, and
//! the pairing and address sheets Settings and onboarding share.
use crate::core::Core;
use flow_core::remote::channel::WebSockets;
use flow_core::remote::handoff::{self, Handoff, Plan, Queue};
use flow_core::remote::transfer::{self, Request};
use flow_core::remote::enrollment::{EnrollError, Enrollment, HttpIdentity, Parts, RemoteSettings, system_now};
use flow_core::remote::pairing::{PairingLink, PairingToken, failure_message};
use flow_core::remote::pool::Pool;
use flow_core::remote::{DeviceKeys, Secrets, Unavailable, address, raw_signature_to_der};
use flow_core::settings::{self, remote_keychain};
use flow_platform::Credentials;
use flow_ui::gpui::base::TestSupportExt;
use flow_ui::prelude::*;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// How often a paired device asks whether its server now offers the handoff.
const PROBE_EVERY: Duration = Duration::from_secs(60);

struct Platform(Arc<dyn Credentials>);

fn refused(e: flow_platform::Unavailable) -> Unavailable {
    Unavailable(e.0)
}

impl Secrets for Platform {
    fn read(&self, account: &str) -> Result<Option<Vec<u8>>, Unavailable> {
        self.0.secret_data(&remote_keychain(account)).map_err(refused)
    }
    fn write(&self, account: &str, value: &[u8]) -> Result<(), Unavailable> {
        self.0.set_secret_data(&remote_keychain(account), value).map_err(refused)
    }
    fn remove(&self, account: &str) -> Result<(), Unavailable> {
        self.0.remove_secret(&remote_keychain(account)).map_err(refused)
    }
}
impl DeviceKeys for Platform {
    fn create(&self) -> Result<(Vec<u8>, Vec<u8>), Unavailable> {
        self.0.device_key_create().map_err(refused)
    }
    fn public_key(&self, handle: &[u8]) -> Option<Vec<u8>> {
        self.0.device_key_public_key(handle)
    }
    fn sign(&self, message: &[u8], handle: &[u8]) -> Result<Vec<u8>, Unavailable> {
        let raw = self.0.device_key_sign(handle, message).map_err(refused)?;
        raw_signature_to_der(&raw).ok_or(Unavailable("device key"))
    }
    fn delete(&self, handle: &[u8]) -> Result<(), Unavailable> {
        self.0.device_key_delete(handle).map_err(refused)
    }
}
pub struct Remote {
    pub enrollment: Arc<Enrollment>,
    pub pool: Arc<Pool>,
    /// Made on first use: its paths come from `Core`.
    handoff: OnceLock<Arc<Handoff>>,
}

impl Remote {
    pub fn new(enrollment: Enrollment) -> Arc<Remote> {
        let enrollment = Arc::new(enrollment);
        let pool = Arc::new(Enrollment::pool(&enrollment));
        Arc::new(Remote { enrollment, pool, handoff: OnceLock::new() })
    }

    pub fn native(credentials: Arc<dyn Credentials>) -> Arc<Remote> {
        let platform = Arc::new(Platform(credentials.clone()));
        Remote::new(Enrollment::new(Parts { secrets: platform.clone(), keys: platform, identity: Arc::new(HttpIdentity), transports: Arc::new(WebSockets::default()), now: Box::new(system_now), device_name: credentials.device_name() }))
    }
}

/// Runs `op` on a background thread with the current `remote.*` settings, stores what it changed and
/// calls `done`. A turn off meanwhile keeps its reset.
// ponytail: the last operation to finish writes all of `remote.*`; pages keep one running through
// `busy` and the refresh loop skips while one runs, a per-field merge if that ever loses a state.
pub fn run<V: 'static, T: Send + 'static>(cx: &mut Context<V>, op: impl FnOnce(&Enrollment) -> T + Send + 'static, done: impl FnOnce(&mut V, T, &mut Context<V>) + 'static) {
    let remote = cx.global_mut::<Core>().remote();
    remote.enrollment.load(RemoteSettings::from_prefs(&cx.global::<Core>().prefs));
    let generation = remote.enrollment.generation();
    cx.spawn(async move |this, cx| {
        let enrollment = remote.enrollment.clone();
        let (answer, after) = cx
            .background_spawn(async move {
                let answer = op(&enrollment);
                (answer, enrollment.settings())
            })
            .await;
        let _ = this.update(cx, |this, cx| {
            if remote.enrollment.generation() == generation {
                after.store(&mut cx.global_mut::<Core>().prefs);
            }
            done(this, answer, cx);
            cx.notify();
        });
    })
    .detach();
}

/// Keeps an approved device's access token fresh: once at launch, then 12 minutes after each issue.
// ponytail: a 60 s poll instead of a timer per token; a pending device checks at launch only until
// dictation start (Feature 026) calls `refresh_now` as Swift's `refreshIfPending` does.
/// The handoff's automatic retries: one tick at a time on a background thread, the waiting rows
/// published on `Session`. A scenario or a missing database means no work at all.
pub fn start_handoffs(cx: &mut App) {
    const TICK: Duration = Duration::from_secs(2);
    cx.spawn(async move |cx| {
        let mut queue: Option<Arc<Mutex<Queue>>> = None;
        let mut last_probe: Option<Instant> = None;
        let mut answered = false;
        loop {
            cx.background_executor().timer(TICK).await;
            let work = cx.update(|cx| {
                let core = cx.global::<Core>();
                if core.db.is_none() || core.scenario.is_some() {
                    return None;
                }
                let settings = RemoteSettings::from_prefs(&core.prefs);
                let approved = settings.state == "approved";
                let offers = approved && settings::capabilities(&core.prefs).ops.contains("handoff");
                let plan = Plan { route: handoff::route(&core.prefs), offers, language: settings::meeting_language(&core.prefs).to_string() };
                let remote = cx.global_mut::<Core>().remote();
                remote.enrollment.load(settings);
                Some((remote.clone(), remote_handoff(cx, &remote), plan, approved))
            });
            let Some((remote, shared, plan, approved)) = work else { continue };
            let queue = queue.get_or_insert_with(|| Arc::new(Mutex::new(Queue::new(shared)))).clone();
            let now = Instant::now();
            let probe = approved && !plan.offers && last_probe.is_none_or(|at| now.duration_since(at) >= PROBE_EVERY);
            if probe {
                last_probe = Some(now);
            }
            let generation = remote.enrollment.generation();
            let client = remote.clone();
            let (tick, offered, after) = cx
                .background_spawn(async move {
                    let offered = if probe { client.enrollment.capabilities() } else { None };
                    let tick = queue.lock().unwrap_or_else(|e| e.into_inner()).tick(&plan, now);
                    (tick, offered, client.enrollment.settings())
                })
                .await;
            cx.update(|cx| {
                if let Some(offered) = offered {
                    cx.global_mut::<Core>().prefs.set("server.capabilities", offered);
                }
                if remote.enrollment.generation() == generation {
                    after.store(&mut cx.global_mut::<Core>().prefs);
                } else {
                    // Turned off during this tick, which may have staged a bundle after the sweep.
                    handoff::forget_staged(&cx.global::<Core>().paths.root.join("Meetings"));
                }
                let Ok(tick) = tick else { return };
                // The only point this client learns a transcript is final: `meetingSpeakersDidSettle`.
                let reached = tick.answered && !answered;
                answered = tick.answered;
                if !tick.merged.is_empty() || reached {
                    let core = cx.global_mut::<Core>();
                    let analysis = core.analysis();
                    if !tick.merged.is_empty() || !analysis.waiting().is_empty() {
                        let route = core.analysis_route();
                        for id in &tick.merged {
                            analysis.settled(id, &route);
                        }
                        if reached {
                            analysis.server_may_be_reachable(&route);
                        }
                    }
                }
                crate::shell::ensure_session(cx);
                if cx.global::<crate::shell::Session>().handoff_waiting != tick.waiting || tick.changed {
                    crate::shell::update_session(cx, |s| {
                        s.handoff_waiting = tick.waiting;
                        s.handoff_revision += u64::from(tick.changed);
                    });
                }
            });
        }
    })
    .detach();
}

/// The summary queue's clock and its way to the page: launch restarts, due re-queues, and a revision
/// on `Session` when something changed. A scenario or a missing database means no work at all.
pub fn start_analysis(cx: &mut App) {
    if cx.global::<Core>().db.is_none() || cx.global::<Core>().scenario.is_some() {
        return;
    }
    let restarts = std::mem::take(&mut cx.global_mut::<Core>().analysis_restarts);
    if !restarts.is_empty() {
        let core = cx.global_mut::<Core>();
        core.analysis().resume(&restarts, &core.analysis_route());
    }
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor().timer(Duration::from_millis(250)).await;
            cx.update(poll_analysis);
        }
    })
    .detach();
}

pub fn poll_analysis(cx: &mut App) {
    let core = cx.global_mut::<Core>();
    let Some(analysis) = core.analysis.clone() else { return };
    if analysis.due() {
        analysis.tick(&core.analysis_route());
    }
    if analysis.take_not_offered() {
        let mut capabilities = settings::capabilities(&core.prefs);
        capabilities.ops.remove("analysis");
        core.prefs.set("server.capabilities", capabilities);
    }
    let revision = analysis.revision();
    crate::shell::ensure_session(cx);
    if cx.global::<crate::shell::Session>().analysis_revision != revision {
        crate::shell::update_session(cx, |s| s.analysis_revision = revision);
    }
}

fn remote_handoff(cx: &App, remote: &Arc<Remote>) -> Arc<Handoff> {
    let paths = &cx.global::<Core>().paths;
    let (database, root) = (paths.database(), paths.root.join("Meetings"));
    remote
        .handoff
        .get_or_init(|| {
            let pool = remote.pool.clone();
            Arc::new(Handoff::new(move |request: &Request| transfer::exchange(&pool, request), &database, &root))
        })
        .clone()
}

/// `meetingWillDelete`: the row is gone, so nothing of the meeting stays on the server either.
pub fn meeting_deleted(id: String, cx: &mut App) {
    let remote = cx.global_mut::<Core>().remote();
    let shared = remote_handoff(cx, &remote);
    cx.background_spawn(async move { shared.meeting_will_delete(&id) }).detach();
}

/// A turn-off meanwhile bumps the generation, and the answer stores nothing.
async fn refresh_and_store(remote: Arc<Remote>, cx: &mut AsyncApp) {
    let generation = remote.enrollment.generation();
    let enrollment = remote.enrollment.clone();
    let after = cx
        .background_spawn(async move {
            enrollment.refresh_now();
            enrollment.settings()
        })
        .await;
    cx.update(|cx| {
        if remote.enrollment.generation() == generation {
            after.store(&mut cx.global_mut::<Core>().prefs);
        }
    });
}

/// SET-048: a pending device asks again when a dictation starts. That dictation doesn't wait for it.
pub fn refresh_if_pending(cx: &mut App) {
    let settings = RemoteSettings::from_prefs(&cx.global::<Core>().prefs);
    if settings.origin.is_none() || settings.state != "pending" {
        return;
    }
    let remote = cx.global_mut::<Core>().remote();
    remote.enrollment.load(settings);
    cx.spawn(async move |cx| refresh_and_store(remote, cx).await).detach();
}

pub fn start_refreshing(cx: &mut App) {
    cx.spawn(async move |cx| {
        let mut launch = true;
        loop {
            let work = cx.update(|cx| {
                let settings = RemoteSettings::from_prefs(&cx.global::<Core>().prefs);
                let pending = launch && settings.origin.is_some() && settings.state == "pending";
                if settings.state != "approved" && !pending {
                    return None;
                }
                let remote = cx.global_mut::<Core>().remote();
                remote.enrollment.load(settings);
                (pending || remote.enrollment.refresh_due()).then_some(remote)
            });
            launch = false;
            if let Some(remote) = work {
                refresh_and_store(remote, cx).await;
            }
            cx.background_executor().timer(Duration::from_secs(60)).await;
        }
    })
    .detach();
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Sheet {
    Pair,
    Address,
}

/// The state of the pairing and address sheets. The token stays in its masked field and goes when
/// the sheet closes.
pub struct PairForm {
    pub address: Entity<InputState>,
    pub token: Entity<InputState>,
    pub sheet: Option<Sheet>,
    pub busy: bool,
    pub error: Option<String>,
    /// This attempt turned the feature on, so Cancel turns it off again.
    turned_on: bool,
    /// Where the sheet opened: a background answer has no window to clear the fields with.
    window: Option<AnyWindowHandle>,
}

fn text(input: &Entity<InputState>, cx: &App) -> String {
    input.read(cx).value().to_string()
}

impl PairForm {
    pub fn new<V: 'static>(window: &mut Window, cx: &mut Context<V>) -> PairForm {
        PairForm { address: cx.new(|cx| InputState::new(window, cx)), token: cx.new(|cx| InputState::new(window, cx).masked(true)), sheet: None, busy: false, error: None, turned_on: false, window: None }
    }

    fn valid(&self, cx: &App) -> bool {
        !self.busy && address::origins(&text(&self.address, cx)).is_some() && PairingToken::parse(&text(&self.token, cx)).is_some()
    }
}

/// A page showing the sheets.
pub trait RemotePage: Sized + 'static {
    fn form(&mut self) -> &mut PairForm;
    fn form_ref(&self) -> &PairForm;
    /// Credentials or the state changed.
    fn remote_changed(&mut self, cx: &mut Context<Self>);
}

/// Opens the pairing sheet, with a link's fields when one was opened or pasted.
pub fn open_pair<V: RemotePage>(this: &mut V, link: Option<&PairingLink>, window: &mut Window, cx: &mut Context<V>) {
    let stored = settings::remote_addresses(&cx.global::<Core>().prefs).join(", ");
    let form = this.form();
    form.sheet = Some(Sheet::Pair);
    form.error = None;
    form.turned_on = false;
    form.window = Some(window.window_handle());
    let address = link.and_then(|l| l.address.clone()).unwrap_or(stored);
    let token = link.map_or(String::new(), |l| l.token.value.clone());
    form.address.update(cx, |s, cx| s.set_value(address, window, cx));
    form.token.update(cx, |s, cx| s.set_value(token, window, cx));
    form.token.read(cx).focus_handle(cx).focus(window, cx);
    cx.notify();
}

pub fn open_address<V: RemotePage>(this: &mut V, window: &mut Window, cx: &mut Context<V>) {
    let stored = settings::remote_addresses(&cx.global::<Core>().prefs).join(", ");
    let form = this.form();
    form.sheet = Some(Sheet::Address);
    form.error = None;
    form.window = Some(window.window_handle());
    form.address.update(cx, |s, cx| s.set_value(stored, window, cx));
    form.address.read(cx).focus_handle(cx).focus(window, cx);
    cx.notify();
}

/// A whole link pasted into the token field fills both fields. Call on the field's change event.
pub fn token_edited<V: RemotePage>(this: &mut V, window: &mut Window, cx: &mut Context<V>) {
    let form = this.form();
    if let Some(link) = PairingLink::parse(&text(&form.token, cx)) {
        if let Some(address) = link.address {
            form.address.update(cx, |s, cx| s.set_value(address, window, cx));
        }
        form.token.update(cx, |s, cx| s.set_value(link.token.value, window, cx));
    }
    cx.notify();
}

pub fn confirm<V: RemotePage>(this: &mut V, cx: &mut Context<V>) {
    match this.form_ref().sheet {
        Some(Sheet::Pair) => confirm_pair(this, cx),
        Some(Sheet::Address) => confirm_address(this, cx),
        None => {}
    }
}

fn confirm_pair<V: RemotePage>(this: &mut V, cx: &mut Context<V>) {
    if !this.form_ref().valid(cx) {
        return;
    }
    let (Some(origins), Some(token)) = (address::origins(&text(&this.form_ref().address, cx)), PairingToken::parse(&text(&this.form_ref().token, cx))) else { return };
    let core = cx.global::<Core>();
    let on = core.prefs.bool_or("remote.enabled", false);
    if on && !this.form_ref().turned_on && !settings::remote_addresses(&core.prefs).iter().any(|known| origins.contains(known)) {
        let word = core.services.device_word();
        this.form().error = Some(format!("This {word} already uses another server. Turn off remote dictation first."));
        cx.notify();
        return;
    }
    if !on {
        this.form().turned_on = true;
    }
    let prefs = &mut cx.global_mut::<Core>().prefs;
    // ponytail: stored before `pair` runs, as the single address always was; a failed pair keeps the typed list.
    prefs.set("remote.serverURL", origins[0].as_str());
    if origins.len() > 1 {
        prefs.set("remote.alternateAddresses", &origins[1..]);
    } else {
        prefs.remove("remote.alternateAddresses");
    }
    prefs.set("remote.consentVersion", settings::CONSENT_VERSION);
    prefs.set("remote.enabled", true);
    let form = this.form();
    form.busy = true;
    form.error = None;
    cx.notify();
    run(cx, move |e| e.pair(&token), finish);
}

fn confirm_address<V: RemotePage>(this: &mut V, cx: &mut Context<V>) {
    let draft = text(&this.form_ref().address, cx);
    if this.form_ref().busy || address::origins(&draft).is_none() {
        return;
    }
    let form = this.form();
    form.busy = true;
    form.error = None;
    cx.notify();
    run(cx, move |e| e.update_address(&draft), finish);
}

fn finish<V: RemotePage>(this: &mut V, result: Result<(), EnrollError>, cx: &mut Context<V>) {
    let form = this.form();
    form.busy = false;
    match result {
        Ok(()) => {
            form.sheet = None;
            form.turned_on = false;
            clear(form, cx);
        }
        // The sheet went with the turn off.
        Err(EnrollError::TurnedOff) => {}
        Err(error) => form.error = Some(failure_message(&error).to_string()),
    }
    this.remote_changed(cx);
}

fn clear(form: &PairForm, cx: &mut App) {
    let (token, address) = (form.token.clone(), form.address.clone());
    if let Some(window) = form.window {
        let _ = window.update(cx, |_, window, cx| {
            token.update(cx, |s, cx| s.set_value("", window, cx));
            address.update(cx, |s, cx| s.set_value("", window, cx));
        });
    }
}

/// Cancel and Esc. A sheet that turned the feature on turns it off again.
pub fn cancel<V: RemotePage>(this: &mut V, window: &mut Window, cx: &mut Context<V>) {
    let form = this.form();
    form.sheet = None;
    form.busy = false;
    form.error = None;
    form.token.update(cx, |s, cx| s.set_value("", window, cx));
    form.address.update(cx, |s, cx| s.set_value("", window, cx));
    if std::mem::take(&mut form.turned_on) {
        cx.global_mut::<Core>().turn_off_remote();
    }
    this.remote_changed(cx);
    cx.notify();
}

fn button(id: &'static str, label: &'static str, cx: &App) -> FlowButton {
    let p = pal(cx);
    native_button(id, label).fill(p.ink.opacity(0.2)).text_color(p.ink)
}

/// The sheet's body, to place on the page's sheet surface.
pub fn sheet_view<V: RemotePage>(this: &V, window: &Window, cx: &mut Context<V>) -> Option<Div> {
    let form = this.form_ref();
    let sheet = form.sheet?;
    let p = pal(cx);
    let draft = text(&form.address, cx);
    let origins = address::origins(&draft);
    let surface = |symbol, hint, input, state: &Entity<InputState>, cx: &App| crate::pages::settings::input_surface(symbol, Some(hint), input, state, window, cx);
    let address_input = surface("server.rack", "https://a.example, https://b.example", Input::new(&form.address).id("settings.remoteServerURL").aria_label("Server address").accessibility_id("settings.remoteServerURL"), &form.address, cx);
    let notice = address::list_notice(&draft);
    let mut body = v_flex().w(px(460.)).p(px(24.)).gap(px(12.));
    match sheet {
        Sheet::Pair => {
            let consent = settings::consent_text(&cx.global::<Core>().prefs);
            body = body
                .child(t("Pair with a token").font(17., 500.))
                .child(address_input)
                .child(surface("key", "lfp_…", Input::new(&form.token).id("settings.remotePairToken").aria_label("Pairing token").accessibility_id("settings.remotePairToken"), &form.token, cx))
                .child(t(consent).size(13.).line_spacing(3.).swift_lines())
                .when_some(notice, |d, n| d.child(t(n).size(12.).color(p.muted)))
                .when_some(origins.as_ref(), |d, o| d.child(t(format!("Server: {}", o.iter().map(|o| settings::origin_host(o)).collect::<Vec<_>>().join(", "))).font(13., 500.)));
        }
        Sheet::Address => {
            body = body
                .child(t("Change the server addresses").font(17., 500.))
                .child(address_input)
                .child(t("It must be the same server.").size(13.).line_spacing(3.).swift_lines())
                .when_some(notice, |d, n| d.child(t(n).size(12.).color(p.muted)));
        }
    }
    let (confirm_id, label, enabled) = match sheet {
        Sheet::Pair => ("settings.remotePairConfirm", "Pair", form.valid(cx)),
        Sheet::Address => ("settings.remoteAddressConfirm", "Change", !form.busy && origins.is_some()),
    };
    let cancel_id = if sheet == Sheet::Pair { "settings.remotePairCancel" } else { "settings.remoteAddressCancel" };
    Some(
        body.when_some(form.error.clone(), |d, e| d.child(div().id("settings.remotePairError").child(t(e).size(12.).color(p.warning)).test_support()))
            .child(h_flex().w_full().justify_end().gap(px(8.)).child(button(cancel_id, "Cancel", cx).on_click(cx.listener(|this, _, w, cx| cancel(this, w, cx)))).child(button(confirm_id, label, cx).disabled(!enabled).on_click(cx.listener(|this, _, _, cx| confirm(this, cx))))),
    )
}

#[cfg(test)]
pub(crate) mod testing {
    use super::*;
        use flow_core::remote::enrollment::IdentityFetching;
    use flow_core::remote::scripted::{Counters, Reply, Script};
    use flow_core::remote::{MemoryDeviceKeys, MemorySecrets};
    use flow_core::settings::{Identity, IdentityError, base64url_encode, fingerprint_of};

    struct Fixed(Identity);
    impl IdentityFetching for Fixed {
        fn fetch(&self, _: &str) -> Result<Identity, IdentityError> {
            Ok(self.0.clone())
        }
    }
    pub struct Installed {
        pub counters: Counters,
        pub key: Vec<u8>,
        pub secrets: Arc<MemorySecrets>,
        pub keys: Arc<MemoryDeviceKeys>,
    }

    impl Installed {
        pub fn token(&self) -> String {
            format!("lfp_{}", base64url_encode(&[self.key.as_slice(), &[9u8; 32]].concat()))
        }
        pub fn link(&self) -> String {
            format!("localflow://pair?address=https%3A%2F%2Flinked.example.com#token={}", self.token())
        }
    }

    /// A scripted server behind a real `Enrollment`. `pinned` stores its key first, as pairing does.
    pub fn install(cx: &mut App, replies: Vec<Reply>, pinned: bool) -> Installed {
        let script = Script::new(replies);
        let (counters, key) = (script.counters(), script.public_key());
        let secrets = Arc::new(MemorySecrets::default());
        if pinned {
            secrets.write("server-key", &key).unwrap();
        }
        let identity = Identity { schema_version: 1, server: serde_json::json!({}), protocol_versions: vec![1], suite: "x25519-hkdfsha256-chacha20poly1305".into(), server_key: base64url_encode(&key), fingerprint: fingerprint_of(&key) };
        let keys = Arc::new(MemoryDeviceKeys::default());
        let remote = Remote::new(Enrollment::new(Parts { secrets: secrets.clone(), keys: keys.clone(), identity: Arc::new(Fixed(identity)), transports: Arc::new(script), now: Box::new(system_now), device_name: "Test".into() }));
        cx.global_mut::<Core>().remote = Some(remote);
        Installed { counters, key, secrets, keys }
    }
}
