//! The server path (Feature 028 US2): models, opening to the network and the ready step, plus the
//! state and background runner that Settings › Server mode shares. Every `ServerHost` call blocks,
//! so it runs off the UI thread.
use super::OnboardingPage;
use super::parts::*;
use super::parts::t;
use crate::core::Core;
use flow_core::onboarding::*;
use flow_core::onboarding::Role;
use flow_core::server_mode::*;
use flow_platform::ServerHost;
use flow_ui::gpui::base::TestSupportExt;
use flow_ui::prelude::*;
use std::sync::{Arc, Mutex};

type Body = Vec<AnyElement>;
type Apply = Box<dyn FnOnce(&mut ServerUi) + Send>;

fn any(e: impl IntoElement) -> AnyElement {
    e.into_any_element()
}

/// What a page shows of server mode. The owner's token lives here until the page goes, and
/// nowhere else (T031).
#[derive(Default)]
pub(crate) struct ServerUi {
    pub status: ServerModeStatus,
    pub addresses: Vec<ServerAddress>,
    /// `status` has been read at least once.
    pub fetched: bool,
    fetching: bool,
    fetched_at: Option<std::time::Instant>,
    pub busy: bool,
    /// What runs now, as Swift's `progress`.
    pub progress: Option<String>,
    /// The last outcome, as Swift's `message`.
    pub message: Option<String>,
    /// (completed, total) bytes of the running model download.
    pub downloaded: Arc<Mutex<Option<(u64, u64)>>>,
    pub download_error: Option<String>,
    /// The owner's pick when the default plan doesn't fit: `Some(None)` is without rewriting.
    pub model: Option<Option<usize>>,
    pub models_started: bool,
    /// The language model install this page started; the phase counts only after it.
    pub ai_started: bool,
    pub ai_phase: Option<AiPhase>,
    pub turned_on: bool,
    pub token: Option<OwnerToken>,
    pub token_error: Option<String>,
}

pub(crate) trait ServerPage: Sized + 'static {
    fn server_ui(&mut self) -> &mut ServerUi;
}

pub(crate) fn host(cx: &App) -> Option<Arc<dyn ServerHost>> {
    cx.global::<Core>().server.clone()
}

/// Runs `op` off the UI thread with `progress` showing, then reads the status again.
pub(crate) fn perform<P: ServerPage>(page: &mut P, progress: &str, op: impl FnOnce(&dyn ServerHost) -> Apply + Send + 'static, cx: &mut Context<P>) {
    let Some(host) = host(cx) else { return };
    let ui = page.server_ui();
    if ui.busy {
        return;
    }
    ui.busy = true;
    ui.progress = Some(progress.into());
    ui.message = None;
    cx.notify();
    cx.spawn(async move |this, cx| {
        let (apply, status, addresses) = cx
            .background_spawn(async move {
                let apply = op(&*host);
                let status = host.status();
                let addresses = host.addresses(status.listen.as_deref());
                (apply, status, addresses)
            })
            .await;
        let _ = this.update(cx, |this, cx| {
            let ui = this.server_ui();
            (ui.busy, ui.progress, ui.fetched) = (false, None, true);
            (ui.status, ui.addresses) = (status, addresses);
            apply(ui);
            cx.notify();
        });
    })
    .detach();
}

/// Reads the status in the background unless a read or an action is already running, at most every
/// 2 s: each read runs `launchctl print`, `flowd admin list` and a loopback request.
pub(crate) fn refresh_status<P: ServerPage>(page: &mut P, cx: &mut Context<P>) {
    let Some(host) = host(cx) else { return };
    let ui = page.server_ui();
    ui.ai_phase = host.language_model_phase();
    if ui.fetching || ui.busy || ui.fetched_at.is_some_and(|at| at.elapsed() < std::time::Duration::from_secs(2)) {
        return;
    }
    (ui.fetching, ui.fetched_at) = (true, Some(std::time::Instant::now()));
    cx.spawn(async move |this, cx| {
        let (status, addresses) = cx
            .background_spawn(async move {
                let status = host.status();
                let addresses = host.addresses(status.listen.as_deref());
                (status, addresses)
            })
            .await;
        let _ = this.update(cx, |this, cx| {
            let ui = this.server_ui();
            ui.fetching = false;
            if ui.busy {
                return;
            }
            if (&ui.status, &ui.addresses, ui.fetched) != (&status, &addresses, true) {
                (ui.status, ui.addresses, ui.fetched) = (status, addresses, true);
                cx.notify();
            }
        });
    })
    .detach();
}

/// Swift's `statusLine`.
pub(crate) fn status_line(s: &ServerModeStatus) -> String {
    if !s.loaded {
        return if s.ownership == Ownership::Adopted { "Off. The server already on this Mac stays as it was set up.".into() } else { "Off".into() };
    }
    if !s.running {
        return "Starting…".into();
    }
    match &s.listen {
        None => "Running".into(),
        Some(listen) if s.can_open_to_network() => format!("Running on {listen}, reachable only through a local proxy or tunnel"),
        Some(listen) => format!("Running on {listen}, open to all networks"),
    }
}

pub(crate) fn open_message(outcome: OpenOutcome) -> String {
    match outcome {
        OpenOutcome::Opened => "The server is open to the network.".into(),
        OpenOutcome::RolledBack(reason) => format!("Previous settings restored. {reason}"),
        OpenOutcome::Failed(reason) => reason,
    }
}

pub(crate) const OPEN_TITLE: &str = "Open this server to the network?";
pub(crate) const OPEN_EXPLANATION: &str = "The server restarts and listens on all networks, not just this Mac. Anyone who can reach it can try to connect, and tokens control who gets in. If it isn't healthy within 60 seconds, the previous settings come back.";
pub(crate) const OPEN_BUTTON: &str = "Open and Restart";

/// Asks, then opens: the bind changes only after the owner confirms (FR-009).
pub(crate) fn confirm_open<P: ServerPage>(window: &mut Window, cx: &mut Context<P>) {
    let buttons = [PromptButton::Other(OPEN_BUTTON.into()), PromptButton::Cancel("Cancel".into())];
    let answer = window.prompt(PromptLevel::Warning, OPEN_TITLE, Some(OPEN_EXPLANATION), &buttons, cx);
    cx.spawn(async move |this, cx| {
        if answer.await == Ok(0) {
            let _ = this.update(cx, |this, cx| {
                perform(this, "Waiting up to 60 s for the server to report healthy…", |h| {
                    let message = open_message(h.open_to_network());
                    Box::new(move |ui: &mut ServerUi| ui.message = Some(message))
                }, cx)
            });
        }
    })
    .detach();
}

impl ServerPage for OnboardingPage {
    fn server_ui(&mut self) -> &mut ServerUi {
        &mut self.server
    }
}

impl OnboardingPage {
    /// The plan on screen: the default, or the owner's smaller pick.
    pub(super) fn server_plan(&self, cx: &App) -> Option<ServerModelPlan> {
        let host = host(cx)?;
        let input = host.plan_input(self.memory, cx.global::<Core>().services.free_disk_bytes(), self.downloaded);
        Some(match self.server.model {
            Some(model) => plan_for(&input, model),
            None => server_model_plan(&input),
        })
    }

    /// The server parts of the snapshot, from the last status and plan.
    pub(super) fn server_snapshot(&self, next: &mut Snapshot, cx: &App) {
        next.can_host_server = host(cx).is_some();
        if !next.can_host_server || self.setup.role != Role::Server {
            return;
        }
        let ui = &self.server;
        next.server_models_ready = self.server_plan(cx).is_some_and(|plan| {
            let speech = plan.items.iter().filter(|i| matches!(i.part, PlanPart::Dictation | PlanPart::Meetings | PlanPart::Speakers)).all(|i| i.installed);
            speech && (plan.model.is_none() || (ui.ai_started && ui.ai_phase == Some(AiPhase::Ready)))
        });
        next.server_reachable = ui.status.running && ui.status.listen.is_some() && !ui.status.can_open_to_network();
    }

    /// On entering a server step: start the server on loopback, or make the owner's token.
    pub(super) fn server_step_entered(&mut self, cx: &mut Context<Self>) {
        match self.setup.step {
            Step::ServerNetwork if !self.server.turned_on => {
                self.server.turned_on = true;
                perform(self, "Starting the server…", |h| {
                    let failed = h.turn_on().err();
                    Box::new(move |ui: &mut ServerUi| ui.message = failed)
                }, cx);
            }
            Step::ServerReady if self.server.token.is_none() => self.create_owner_token(cx),
            Step::Complete => self.server.token = None,
            _ => {}
        }
    }

    /// T031: labelled with the owner's name, valid 24 h, for this server's addresses. Held only here.
    fn create_owner_token(&mut self, cx: &mut Context<Self>) {
        let origins: Vec<String> = self.server.addresses.iter().map(|a| a.origin.clone()).collect();
        perform(self, "Making your pairing token…", move |h| {
            let token = h.create_owner_token(&h.owner_name(), &origins);
            Box::new(move |ui: &mut ServerUi| match token {
                Ok(token) => (ui.token, ui.token_error) = (Some(token), None),
                Err(e) => ui.token_error = Some(e),
            })
        }, cx);
    }

    /// Starts every download the plan needs: speech and meeting models through the server's own
    /// `flowd-speech`, the runtime and language model through the installer without client agents.
    pub(super) fn start_server_models(&mut self, cx: &mut Context<Self>) {
        let Some(plan) = self.server_plan(cx).filter(|p| p.fits()) else { return };
        self.server.models_started = true;
        self.download_server_models(cx);
        if plan.model.is_some() {
            self.start_server_language_model(plan.model, cx);
        }
    }

    fn download_server_models(&mut self, cx: &mut Context<Self>) {
        self.server.download_error = None;
        let shared = self.server.downloaded.clone();
        perform(self, "Downloading models…", move |h| {
            let result = h.download_models(&|done, total| *shared.lock().unwrap() = Some((done, total)));
            *shared.lock().unwrap() = None;
            Box::new(move |ui: &mut ServerUi| ui.download_error = result.err())
        }, cx);
    }

    fn start_server_language_model(&mut self, model: Option<usize>, cx: &mut Context<Self>) {
        let (Some(i), Some(host)) = (model, host(cx)) else { return };
        match host.install_language_model(CATALOG[i].id) {
            Ok(()) => self.server.ai_started = true,
            Err(e) => self.server.ai_phase = Some(AiPhase::Failed(format!("This build can't use {} yet.", e.0))),
        }
        cx.notify();
    }

    pub(super) fn role_choice(&mut self, cx: &mut Context<Self>) -> Body {
        let word = self.word(cx);
        let card = |this: &mut Self, role: Role, id: &'static str, symbol: &str, title: &str, detail: String, cx: &mut Context<Self>| {
            let choose = this.click(cx, move |this, cx| {
                this.setup.role = role;
                cx.notify();
            });
            selectable_card(id, format!("{title}, {detail}"), this.setup.role == role, true, choose, choice_label(symbol, title, None, detail.clone(), cx), cx)
        };
        let client = card(self, Role::Client, "onboarding.roleClient", "laptopcomputer", &format!("This {word}"), format!("Dictate and take meeting notes on this {word}."), cx);
        let server = card(self, Role::Server, "onboarding.roleServer", "server.rack", "This is the server", "Other Macs, PCs and phones send their dictation, rewriting and meetings here. It doesn't dictate itself.".into(), cx);
        vec![
            any(headline("How will you use this ", word, "?")),
            any(lede("A server runs speech and AI models for your other devices. You can change this later in Settings.".into(), cx)),
            any(v_flex().w_full().gap(px(10.)).child(client).child(server)),
        ]
    }

    pub(super) fn server_models(&mut self, cx: &mut Context<Self>) -> Body {
        let mut body = vec![
            any(headline("Download the server's ", "models", ".")),
            any(lede("Speech, meeting transcription, speaker labels and a language model for rewriting and summaries. Downloads resume where they stopped.".into(), cx)),
        ];
        let Some(plan) = self.server_plan(cx) else { return body };
        let ui = &self.server;
        let progress = *ui.downloaded.lock().unwrap();
        let waiting = RowState::Waiting(if ui.models_started { "Queued".into() } else { String::new() });
        let speech_state = |installed: bool| match (installed, &ui.download_error, progress) {
            (true, _, _) => RowState::Done,
            (_, Some(e), _) => RowState::Failed(e.clone()),
            (_, _, Some((done, total))) => RowState::Progress(done as i64, total as i64),
            _ if ui.busy && ui.models_started => RowState::Working("Downloading…".into()),
            _ => waiting.clone(),
        };
        let ai = ui.ai_phase.as_ref().filter(|_| ui.ai_started).map(ai_state);
        let states: Vec<RowState> = plan
            .items
            .iter()
            .map(|item| match item.part {
                PlanPart::Dictation | PlanPart::Meetings | PlanPart::Speakers => speech_state(item.installed),
                PlanPart::Runtime | PlanPart::LanguageModel(_) => ai.clone().unwrap_or(waiting.clone()),
            })
            .collect();
        let mut card = setup_card(cx).id("onboarding.serverModels");
        for (item, state) in plan.items.iter().zip(states) {
            let (symbol, retry) = match item.part {
                PlanPart::Dictation | PlanPart::Meetings | PlanPart::Speakers => {
                    let symbol = if item.part == PlanPart::Dictation { "waveform" } else { "person.2.wave.2" };
                    (symbol, self.click(cx, |this, cx| this.download_server_models(cx)))
                }
                PlanPart::Runtime | PlanPart::LanguageModel(_) => {
                    let model = plan.model;
                    (if item.part == PlanPart::Runtime { "cpu" } else { "sparkles" }, self.click(cx, move |this, cx| this.start_server_language_model(model, cx)))
                }
            };
            let retry = Some(retry);
            let detail = if item.installed { format!("{} · already on this Mac", bytes(item.bytes as i64)) } else { bytes(item.bytes as i64) };
            card = card.child(download_row(symbol, item.name, detail, state, retry, cx));
        }
        body.push(any(card.test_support()));
        let total = format!("Total {}, {} to download.", bytes(plan.total_bytes() as i64), bytes(plan.download_bytes as i64));
        body.push(any(div().id("onboarding.serverTotal").child(t(total).size(12.).color(pal(cx).muted)).test_support()));
        if plan.model.is_none() {
            body.push(any(note("info.circle", "Rewriting and summaries stay unavailable on this server until a language model fits.".into(), cx)));
        }
        for problem in &plan.problems {
            body.push(any(note("exclamationmark.triangle", problem.clone(), cx)));
        }
        if !plan.fits() && !self.server.models_started {
            let offer = match plan.offer {
                PlanOffer::Smaller(i) => Some(("onboarding.serverSmaller", format!("Use {} instead", CATALOG[i].name), Some(i))),
                PlanOffer::WithoutRewriting => Some(("onboarding.serverWithoutRewriting", "Continue without rewriting".to_string(), None)),
                PlanOffer::Fits | PlanOffer::FreeSpace => None,
            };
            if let Some((id, title, model)) = offer {
                let pick = self.click(cx, move |this, cx| {
                    this.server.model = Some(model);
                    cx.notify();
                });
                body.push(any(prototype_button(id, title).on_click(pick)));
            }
        }
        body
    }

    pub(super) fn server_network(&mut self, cx: &mut Context<Self>) -> Body {
        let ui = &self.server;
        let mut body = vec![
            any(headline("Open the server to your ", "network", ".")),
            any(lede("Until you confirm, the server listens only on this Mac and nothing else can reach it. Opening it changes only the listen address; tokens control who connects.".into(), cx)),
        ];
        let open = (ui.status.can_open_to_network() && ui.status.ownership == Ownership::Managed).then(|| {
            prototype_button("onboarding.serverOpen", "Open to the network…").disabled(ui.busy).on_click(cx.listener(|_, _: &ClickEvent, w, cx| confirm_open(w, cx)))
        });
        let status = if ui.fetched { status_line(&ui.status) } else { "Checking…".into() };
        body.push(any(setup_card(cx).child(div().id("onboarding.serverStatus").w_full().child(settings_row("Server", Some(status), div().children(open), cx)).test_support())));
        body.extend(self.server_messages(cx));
        if ui.status.ownership == Ownership::Adopted {
            body.push(any(note("info.circle", "This server was set up outside LocalFlow, so its settings stay as they are.".into(), cx)));
        }
        body
    }

    pub(super) fn server_ready_step(&mut self, cx: &mut Context<Self>) -> Body {
        let p = pal(cx);
        let retry = self.click(cx, |this, cx| this.create_owner_token(cx));
        let ui = &self.server;
        let mut body = vec![any(headline("Your server is ", "ready", ".")), any(lede("Pair your own devices with this token. It works once and expires in 24 hours.".into(), cx))];
        let addresses = ui.addresses.iter().map(|a| a.title.clone()).collect::<Vec<_>>().join("\n");
        let mut card = setup_card(cx).child(div().id("onboarding.serverAddresses").w_full().child(settings_row("Addresses", Some(addresses), div(), cx)).test_support());
        if let Some(fingerprint) = &ui.status.fingerprint {
            card = card.child(div().id("onboarding.serverFingerprint").w_full().child(t("Fingerprint").size(14.)).child(t(fingerprint.clone()).size(12.).mono().color(p.muted).selectable()).test_support());
        }
        if let Some(token) = &ui.token {
            card = card
                .child(div().id("onboarding.serverToken").w_full().child(t("Pairing token").size(14.)).child(t(token.token.clone()).size(12.).mono().selectable()).test_support())
                .child(div().id("onboarding.serverLink").w_full().child(t(token.link.clone()).size(12.).color(p.muted).selectable()).test_support())
                .child(div().id("onboarding.serverQr").children(flow_ui::qr::qr_code("onboarding.serverQrCode", &token.link, 160., "Pairing QR code")).test_support());
        }
        body.push(any(card));
        if let Some(error) = &ui.token_error {
            body.push(any(h_flex().w_full().gap(px(8.)).child(div().flex_1().child(t(error.clone()).size(12.).color(p.warning))).child(prototype_button("onboarding.serverTokenRetry", "Retry").on_click(retry))));
        }
        body.extend(self.server_messages(cx));
        body.push(any(note("lock.shield", "The token isn't saved anywhere. Make another in Settings › Server when you need one.".into(), cx)));
        body
    }

    fn server_messages(&self, cx: &App) -> Body {
        let p = pal(cx);
        let ui = &self.server;
        let mut out = vec![];
        if let Some(progress) = &ui.progress {
            out.push(any(div().id("onboarding.serverProgress").child(t(progress.clone()).size(12.).color(p.muted)).test_support()));
        }
        if let Some(message) = &ui.message {
            out.push(any(div().id("onboarding.serverMessage").child(t(message.clone()).size(12.).color(p.warning)).test_support()));
        }
        out
    }
}
