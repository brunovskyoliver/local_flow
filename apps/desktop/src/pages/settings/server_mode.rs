//! Settings › Server mode (Feature 028 T032): Swift's `ServerModeView`. Shown only where this Mac
//! can host a server, so never on Windows. Dictation on this Mac doesn't depend on any of it.
use super::*;
use crate::pages::onboarding::server_mode::{self as sm, ServerPage, ServerUi, status_line};
use flow_core::onboarding::{CATALOG, RowState};
use flow_core::server_mode::{Ownership, PlanItem, PlanPart};

impl ServerPage for SettingsPage {
    fn server_ui(&mut self) -> &mut ServerUi {
        &mut self.server_mode
    }
}

#[derive(Clone, Copy)]
enum Confirm {
    TurnOn,
    TurnOnExisting,
    TurnOff,
    Download,
}

impl Confirm {
    fn text(self, size: &str) -> (&'static str, String, &'static str) {
        match self {
            Confirm::TurnOn => ("Turn on server mode?", "It starts at login and listens only on this Mac until you open it to the network. Nothing downloads until you confirm.".into(), "Turn On"),
            Confirm::TurnOnExisting => ("Start the server on this Mac?", "It keeps its address and settings.".into(), "Start"),
            Confirm::TurnOff => ("Turn off server mode?", "The server stops until you turn it on again. Accounts, tokens, models and its key stay on this Mac.".into(), "Turn Off"),
            Confirm::Download => ("Download models?", format!("About {size} for the server. It restarts and is unavailable until the download finishes."), "Download"),
        }
    }
}

impl SettingsPage {
    pub(super) fn server_mode_section(&self, window: &Window, cx: &mut Context<Self>) -> Option<Div> {
        sm::host(cx)?;
        let pl = pal(cx);
        let ui = &self.server_mode;
        let s = &ui.status;
        let toggle = switch("settings.serverMode", "Server mode", s.loaded, ui.busy, cx.listener(|this, _: &bool, w, cx| this.request_server_toggle(w, cx)));
        let line = if ui.fetched { status_line(s) } else { "Checking…".into() };
        let mut body = group(cx).child(row("Server mode", Some(line), toggle, cx));
        let small = |id: &'static str, text: String, color| div().id(id).w_full().pb(px(12.)).child(t(text).size(12.).color(color).line_spacing(4.)).test_support();
        if let Some(progress) = &ui.progress {
            let progress = match *ui.downloaded.lock().unwrap() {
                Some((done, total)) => format!("{progress} {} of {}", core::byte_count(done), core::byte_count(total)),
                None => progress.clone(),
            };
            body = body.child(small("settings.serverModeProgress", progress, pl.muted));
        }
        if let Some(message) = &ui.message {
            body = body.child(small("settings.serverModeMessage", message.clone(), pl.warning));
        }
        if s.ownership == Ownership::Adopted {
            body = body.child(small("settings.serverModeAdopted", "Set up outside LocalFlow. Its address and settings stay as they are.".into(), pl.muted));
        }
        if s.loaded {
            body = body.child(hairline(cx)).child(div().id("settings.serverModeAddress").w_full().child(row("Addresses", Some(self.address_text()), div(), cx)).test_support());
            if s.can_open_to_network() && s.ownership == Ownership::Managed {
                let open = prototype_button("settings.serverModeOpen", "Open…").disabled(ui.busy).on_click(cx.listener(|_, _: &ClickEvent, w, cx| sm::confirm_open(w, cx)));
                body = body.child(hairline(cx)).child(row("Open to the network", Some("Tokens control who connects.".into()), open, cx));
            }
            let field = input_surface("link", Some("https://ai.example.ts.net"), Input::new(&self.server_custom).id("settings.serverModeCustomAddress").aria_label("Custom address").accessibility_id("settings.serverModeCustomAddress"), &self.server_custom, window, cx);
            let save = prototype_button("settings.serverModeCustomSave", "Save").on_click(cx.listener(|this, _, _, cx| this.save_custom_address(cx)));
            body = body.child(hairline(cx)).child(row("Custom address", Some("Another name or proxy for this Mac".into()), h_flex().gap(px(8.)).child(div().w(px(240.)).child(field)).child(save), cx));
            if let Some(fingerprint) = &s.fingerprint {
                body = body.child(hairline(cx)).child(
                    v_flex().id("settings.serverModeFingerprint").w_full().py(px(12.)).gap(px(2.)).child(t("Fingerprint").size(14.)).child(selectable("settings.serverModeFingerprintValue", fingerprint.clone(), 12., true, pl.muted, 15.)).test_support(),
                );
            }
            if !s.client_connected {
                body = body.child(small("settings.serverModeNoClient", "No client yet. If one can't connect, allow flowd in macOS Firewall.".into(), pl.muted));
            }
            body = body.child(small("settings.serverModeLogin", "Keeps running while this Mac is logged in.".into(), pl.muted));
        }
        if !s.missing.is_empty() {
            // A server Mac downloads from Settings › Models instead.
            let download = (s.missing_model_bytes > 0 && s.ownership != Ownership::None && !sm::is_server_mac(cx)).then(|| prototype_button("settings.serverModeDownload", "Download…").disabled(ui.busy).on_click(cx.listener(|this, _, w, cx| this.confirm_server(Confirm::Download, w, cx))));
            body = body.child(hairline(cx)).child(div().id("settings.serverModeMissing").w_full().child(row("Not available yet", Some(s.missing.join("\n")), div().children(download), cx)).test_support());
        }
        Some(body)
    }

    fn address_text(&self) -> String {
        let lines: Vec<String> = self.server_mode.addresses.iter().map(|a| a.title.clone()).collect();
        if !lines.is_empty() {
            return lines.join("\n");
        }
        if self.server_mode.status.can_open_to_network() { "None yet. Open to the network, or add a custom address.".into() } else { "No network address found.".into() }
    }

    fn request_server_toggle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let s = &self.server_mode.status;
        let confirm = if s.loaded { Confirm::TurnOff } else if s.ownership == Ownership::Adopted { Confirm::TurnOnExisting } else { Confirm::TurnOn };
        self.confirm_server(confirm, window, cx);
    }

    /// `.confirmationDialog`: native, then the action off the UI thread.
    fn confirm_server(&mut self, confirm: Confirm, window: &mut Window, cx: &mut Context<Self>) {
        let bytes = match (confirm, self.server_download(cx)) {
            (Confirm::Download, Some(download)) => download.bytes,
            _ => self.server_mode.status.missing_model_bytes,
        };
        let size = core::byte_count(bytes);
        let (title, explanation, button) = confirm.text(&size);
        let buttons = [PromptButton::Other(button.into()), PromptButton::Cancel("Cancel".into())];
        let answer = window.prompt(PromptLevel::Warning, title, Some(&explanation), &buttons, cx);
        cx.spawn(async move |this, cx| {
            if answer.await == Ok(0) {
                let _ = this.update(cx, |this, cx| this.perform_server(confirm, cx));
            }
        })
        .detach();
    }

    fn perform_server(&mut self, confirm: Confirm, cx: &mut Context<Self>) {
        if let (Confirm::Download, Some(download)) = (confirm, self.server_download(cx)) {
            return self.download_server_models(download, cx);
        }
        let shared = self.server_mode.downloaded.clone();
        type Op = Box<dyn FnOnce(&dyn flow_platform::ServerHost) -> Result<(), String> + Send>;
        let (progress, op): (&str, Op) = match confirm {
            Confirm::TurnOn | Confirm::TurnOnExisting => ("Starting the server…", Box::new(|h| h.turn_on())),
            Confirm::TurnOff => ("Stopping the server…", Box::new(|h| h.turn_off())),
            Confirm::Download => (
                "Downloading models…",
                Box::new(move |h| {
                    let result = h.download_models(&|done, total| *shared.lock().unwrap() = Some((done, total)));
                    *shared.lock().unwrap() = None;
                    result
                }),
            ),
        };
        sm::perform(self, progress, move |h| {
            let failed = op(h).err();
            Box::new(move |ui: &mut ServerUi| ui.message = failed)
        }, cx);
    }

    pub(super) fn save_custom_address(&mut self, cx: &mut Context<Self>) {
        let Some(host) = sm::host(cx) else { return };
        let ok = host.set_custom_address(&val(&self.server_custom, cx));
        self.server_mode.message = (!ok).then(|| "That isn't an address clients can use.".into());
        self.server_mode.addresses = host.addresses(self.server_mode.status.listen.as_deref());
        cx.notify();
    }
}

/// What a server Mac's Download fetches: the missing speech models through `flowd-speech`, and the
/// runtime and language model when the plan fits this Mac.
#[derive(Clone, Copy)]
struct ServerDownload {
    bytes: u64,
    speech: bool,
    model: Option<usize>,
}

fn model_id(part: PlanPart) -> &'static str {
    match part {
        PlanPart::Dictation => "dictation",
        PlanPart::Meetings => "meetings",
        PlanPart::Speakers => "speakers",
        PlanPart::Runtime => "runtime",
        PlanPart::LanguageModel(_) => "languageModel",
    }
}

/// A server model's row detail: its state, with the size while it isn't on this Mac.
fn model_detail(item: &PlanItem, state: &RowState) -> String {
    let size = core::byte_count(item.bytes);
    match state {
        RowState::Done => format!("Ready · {size}"),
        RowState::Progress(done, total) => format!("Downloading · {} of {}", core::byte_count(*done as u64), core::byte_count(*total as u64)),
        RowState::Working(what) => what.clone(),
        RowState::Failed(why) => why.clone(),
        RowState::Waiting(what) if !what.is_empty() => format!("{what} · {size}"),
        RowState::Waiting(_) => format!("Not downloaded · {size}"),
    }
}

impl SettingsPage {
    fn server_download(&self, cx: &App) -> Option<ServerDownload> {
        if !sm::is_server_mac(cx) {
            return None;
        }
        let plan = self.server_plan.as_ref()?;
        let missing = |speech: bool| plan.items.iter().filter(move |i| sm::is_speech(i.part) == speech && !i.installed);
        let model = plan.model.filter(|_| plan.fits() && missing(false).next().is_some());
        let bytes = missing(true).chain(missing(false).filter(|_| model.is_some())).map(|i| i.bytes).sum();
        Some(ServerDownload { bytes, speech: missing(true).next().is_some(), model })
    }

    fn download_server_models(&mut self, download: ServerDownload, cx: &mut Context<Self>) {
        let Some(host) = sm::host(cx) else { return };
        let ui = &mut self.server_mode;
        (ui.models_started, ui.download_error, ui.message) = (true, None, None);
        if let Some(i) = download.model {
            match host.install_language_model(CATALOG[i].id) {
                Ok(()) => ui.ai_started = true,
                Err(e) => ui.message = Some(format!("This build can't use {} yet.", e.0)),
            }
            cx.notify();
        }
        if download.speech {
            let shared = ui.downloaded.clone();
            sm::perform(self, "Downloading models…", move |h| {
                let result = h.download_models(&|done, total| *shared.lock().unwrap() = Some((done, total)));
                *shared.lock().unwrap() = None;
                Box::new(move |ui: &mut ServerUi| (ui.download_error, ui.models_started) = (result.err(), false))
            }, cx);
        }
    }

    /// Settings › Models on a server Mac: the server's own models, from the plan onboarding uses.
    pub(super) fn server_models(&self, cx: &mut Context<Self>) -> AnyElement {
        let pl = pal(cx);
        let wrap = |body: Div| div().id("settings.serverModels").w_full().child(body).test_support().into_any_element();
        let mut body = group(cx);
        let Some(plan) = &self.server_plan else { return wrap(body.child(row("Server models", Some("Checking…".into()), div(), cx))) };
        let ui = &self.server_mode;
        let waiting = RowState::Waiting(if ui.busy && ui.models_started { "Queued".into() } else { String::new() });
        let states = sm::row_states(plan, ui, ui.ai_phase.as_ref(), &waiting);
        for (i, (item, state)) in plan.items.iter().zip(&states).enumerate() {
            if i > 0 {
                body = body.child(hairline(cx));
            }
            let id = SharedString::from(format!("settings.serverModel.{}", model_id(item.part)));
            body = body.child(div().id(id).w_full().child(row(item.name, Some(model_detail(item, state)), div(), cx)).test_support());
        }
        for problem in &plan.problems {
            body = body.child(div().w_full().pb(px(12.)).child(t(problem.clone()).size(12.).color(pl.warning).line_spacing(4.)));
        }
        let download = self.server_download(cx).filter(|d| d.bytes > 0);
        let working = states.iter().any(|s| matches!(s, RowState::Working(_) | RowState::Progress(..)));
        if let Some(download) = download.filter(|_| !working) {
            let button = prototype_button("settings.serverModelsDownload", "Download…").disabled(ui.busy).on_click(cx.listener(|this, _, w, cx| this.confirm_server(Confirm::Download, w, cx)));
            body = body.child(hairline(cx)).child(row("Missing models", Some(format!("{} to download", core::byte_count(download.bytes))), button, cx));
        }
        wrap(body)
    }
}
