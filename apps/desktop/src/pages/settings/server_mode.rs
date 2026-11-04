//! Settings › Server mode (Feature 028 T032): Swift's `ServerModeView`. Shown only where this Mac
//! can host a server, so never on Windows. Dictation on this Mac doesn't depend on any of it.
use super::*;
use crate::pages::onboarding::server_mode::{self as sm, ServerPage, ServerUi, status_line};
use flow_core::server_mode::Ownership;

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
            Confirm::TurnOn => ("Turn on server mode?", "The server starts at login and listens only on this Mac until you open it to the network. Dictation on this Mac keeps working, and the server loads its own models beside this Mac's, so the two together use more memory. Nothing is downloaded until you confirm it.".into(), "Turn On"),
            Confirm::TurnOnExisting => ("Start the server on this Mac?", "The server keeps the address and settings it already has.".into(), "Start"),
            Confirm::TurnOff => ("Turn off server mode?", "The server stops and stays off until you turn it on. Accounts, tokens, models and the server's identity stay on this Mac.".into(), "Turn Off"),
            Confirm::Download => ("Download models?", format!("About {size} of speech and meeting models for the server. The server restarts for the download and is unavailable until it finishes."), "Download"),
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
            body = body.child(small("settings.serverModeAdopted", "This server was set up outside LocalFlow. LocalFlow starts, stops and administers it, but leaves its address and settings as they are.".into(), pl.muted));
        }
        if s.loaded {
            body = body.child(hairline(cx)).child(div().id("settings.serverModeAddress").w_full().child(row("Addresses", Some(self.address_text()), div(), cx)).test_support());
            if s.can_open_to_network() && s.ownership == Ownership::Managed {
                let open = prototype_button("settings.serverModeOpen", "Open…").disabled(ui.busy).on_click(cx.listener(|_, _: &ClickEvent, w, cx| sm::confirm_open(w, cx)));
                body = body.child(hairline(cx)).child(row("Open to the network", Some("Changes only the listen address. Tokens control who can connect.".into()), open, cx));
            }
            let field = input_surface("link", Some("https://server.example.com"), Input::new(&self.server_custom).id("settings.serverModeCustomAddress").aria_label("Custom address").accessibility_id("settings.serverModeCustomAddress"), &self.server_custom, window, cx);
            let save = prototype_button("settings.serverModeCustomSave", "Save").on_click(cx.listener(|this, _, _, cx| this.save_custom_address(cx)));
            body = body.child(hairline(cx)).child(row("Custom address", Some("A proxy or a name that reaches this Mac".into()), h_flex().gap(px(8.)).child(div().w(px(240.)).child(field)).child(save), cx));
            if let Some(fingerprint) = &s.fingerprint {
                body = body.child(hairline(cx)).child(
                    v_flex().id("settings.serverModeFingerprint").w_full().py(px(12.)).gap(px(2.)).child(t("Fingerprint").size(14.)).child(selectable("settings.serverModeFingerprintValue", fingerprint.clone(), 12., true, pl.muted, 15.)).test_support(),
                );
            }
            if !s.client_connected {
                body = body.child(small("settings.serverModeNoClient", "No client has connected yet. If one can't reach this Mac, check that macOS Firewall allows flowd.".into(), pl.muted));
            }
            body = body.child(small("settings.serverModeLogin", "The server runs in your login session and its key is in your login Keychain, so this Mac needs to stay logged in. Turn on automatic login if it restarts unattended.".into(), pl.muted));
        }
        if !s.missing.is_empty() {
            let download = (s.missing_model_bytes > 0 && s.ownership != Ownership::None).then(|| prototype_button("settings.serverModeDownload", "Download…").disabled(ui.busy).on_click(cx.listener(|this, _, w, cx| this.confirm_server(Confirm::Download, w, cx))));
            body = body.child(hairline(cx)).child(div().id("settings.serverModeMissing").w_full().child(row("Not available yet", Some(s.missing.join("\n")), div().children(download), cx)).test_support());
        }
        Some(body)
    }

    fn address_text(&self) -> String {
        let lines: Vec<String> = self.server_mode.addresses.iter().map(|a| a.title.clone()).collect();
        if !lines.is_empty() {
            return lines.join("\n");
        }
        if self.server_mode.status.can_open_to_network() { "This server listens only on this Mac. Use your proxy's address, or open it to the network.".into() } else { "None found on this Mac's network connections.".into() }
    }

    fn request_server_toggle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let s = &self.server_mode.status;
        let confirm = if s.loaded { Confirm::TurnOff } else if s.ownership == Ownership::Adopted { Confirm::TurnOnExisting } else { Confirm::TurnOn };
        self.confirm_server(confirm, window, cx);
    }

    /// `.confirmationDialog`: native, then the action off the UI thread.
    fn confirm_server(&mut self, confirm: Confirm, window: &mut Window, cx: &mut Context<Self>) {
        let size = core::byte_count(self.server_mode.status.missing_model_bytes);
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
