//! The server step: `RemoteDictationView` and the older rewrite-only form.
use super::OnboardingPage;
use super::parts::*;
use super::parts::t;
use flow_core::onboarding::*;
use flow_ui::gpui::base::TestSupportExt;
use flow_ui::prelude::*;

fn any(e: impl IntoElement) -> AnyElement {
    e.into_any_element()
}

impl OnboardingPage {
    pub(super) fn remote_server(&mut self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let word = self.word(cx);
        let meeting = self.meeting_only();
        let name = if meeting { "Your server" } else { "Remote dictation" };
        let privacy = remote_privacy(&self.core(cx).prefs).replace("Mac", word);
        let card = self.remote_card(cx);
        let mut body = vec![
            any(headline("Connect ", "your server", ".")),
            any(lede(format!("Turn on {name} with the address and token from your server. You can change this later in Settings."), cx)),
            any(setup_card(cx).child(card)),
            any(div().id("onboarding.remoteStatus").w_full().child(note("info.circle", privacy, cx)).test_support()),
        ];
        if !meeting {
            let p = pal(cx);
            let open = self.legacy_open;
            let toggle = self.click(cx, |this, cx| {
                this.legacy_open = !this.legacy_open;
                cx.notify();
            });
            body.push(any(plain_button("onboarding.legacyRewriteServer", "Advanced: rewrite-only server").toggled(open).on_click(toggle).content(
                h_flex().py(px(4.)).gap(px(2.5)).child(disclosure_chevron(open, &p)).child(t("Advanced: rewrite-only server").size(13.).color(p.muted).a11y_hidden()),
            )));
            if open {
                // The page's spacing is 24; `DisclosureGroup` puts its content 12 below the title.
                body.push(any(v_flex().id("onboarding.legacyContent").w_full().items_start().mt(px(-12.)).gap(px(16.)).children(self.legacy_server(cx)).test_support()));
            }
        }
        body
    }

    fn remote_card(&mut self, cx: &mut Context<Self>) -> Div {
        let p = pal(cx);
        let prefs = &self.core(cx).prefs;
        let on = remote_on(prefs);
        let state = remote_state(prefs);
        let meeting = Purpose::stored(prefs) == Purpose::Meetings;
        let title = if meeting { "Your server" } else { "Remote dictation" };
        let detail = if on {
            let url = flow_core::settings::remote_addresses(prefs).join(", ");
            let status = remote_status(prefs);
            [Some(url.as_str()), status].into_iter().flatten().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" · ")
        } else if meeting {
            "Run meeting transcripts and notes on a LocalFlow server you run.".to_string()
        } else {
            "Run dictation, rewriting, summaries and meetings on a LocalFlow server you run.".to_string()
        };
        let toggle = FlowSwitch::new("settings.remoteEnabled").checked(on).accessibility_label(title).on_click(cx.listener(|this, _: &bool, w, cx| this.request_toggle(w, cx)));
        let mut card = v_flex().w_full().child(settings_row(title, Some(detail), toggle, cx));
        if !on || state != "approved" {
            let open = cx.listener(|this: &mut Self, _: &ClickEvent, w, cx| crate::remote::open_pair(this, None, w, cx));
            let button = native_button("settings.remotePairWithToken", "Pair with Token").on_click(open);
            card = card.child(hairline(cx)).child(settings_row("Pair with a token", Some("Use a token from your server's owner.".to_string()), button, cx));
        }
        if on && self.remote.pinned.is_some() {
            let url = flow_core::settings::remote_addresses(&self.core(cx).prefs).join(", ");
            let shown = flow_core::remote::address::list_notice(&url).map_or(url.clone(), str::to_string);
            let open = cx.listener(|this: &mut Self, _: &ClickEvent, w, cx| crate::remote::open_address(this, w, cx));
            let button = native_button("settings.remoteAddressEdit", "Change Address").on_click(open);
            card = card.child(hairline(cx)).child(settings_row("Server address", Some(shown), button, cx));
        }
        if on && state != "approved"
            && let Some(pinned) = self.remote.pinned.clone()
        {
            card = card.child(hairline(cx)).child(v_flex().w_full().items_start().py(px(16.)).child(t(format!("Pinned fingerprint  {pinned}")).mono().size(12.).color(p.muted).selectable()));
        }
        card
    }

    fn legacy_server(&mut self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let p = pal(cx);
        let word = self.word(cx);
        let endpoint = self.core(cx).prefs.string("rewriteEndpoint").unwrap_or_default();
        let origin = rewrite_origin(&endpoint);
        let insecure = is_unencrypted_remote(&endpoint);
        let allowed = origin.as_deref().is_some_and(|o| insecure_override(&self.core(cx).prefs, o));
        let key_empty = self.credential_input.read(cx).value().is_empty();
        let connect = self.click(cx, |this, cx| this.connect(cx));
        let mut form = setup_card(cx)
            .child(v_flex().w_full().gap(px(8.)).child(field_label("Server address", cx)).child(input_field("link", Input::new(&self.endpoint_input).aria_label("Server address").accessibility_id("onboarding.serverAddress"), endpoint.is_empty().then(|| t("https://studio.local:8080").size(14.).color(p.link())), cx)))
            .child(
                v_flex()
                    .w_full()
                    .gap(px(8.))
                    .child(field_label("Access key", cx))
                    .child(input_field("key", Input::new(&self.credential_input).aria_label("Access key").accessibility_id("onboarding.accessKey"), key_empty.then(|| t("The server's LOCALFLOW_REWRITE_TOKEN").size(14.).color(p.placeholder())), cx))
                    .when_some(self.credential_error.clone(), |d, e| d.child(t(e).size(12.).color(p.warning))),
            );
        if insecure {
            let toggle = FlowSwitch::new("onboarding.allowInsecure").checked(allowed).accessibility_label("Allow unencrypted HTTP to this server").on_click(cx.listener(|this, on: &bool, _, cx| this.set_insecure(*on, cx)));
            form = form.child(h_flex().gap(px(8.)).child(toggle).child(t("Allow unencrypted HTTP to this server").size(13.).a11y_hidden()));
        }
        let mut result = h_flex().w_full().gap(px(12.)).child(prototype_button("onboarding.connect", if self.connection_testing { "Connecting…" } else { "Connect" }).disabled(self.connection_testing || origin.is_none()).on_click(connect));
        match &self.connection {
            Some(Ok(parts)) => {
                let text = std::iter::once("Connected".to_string()).chain(parts.iter().cloned()).collect::<Vec<_>>().join(" · ");
                result = result.child(h_flex().gap(px(6.)).child(icon("checkmark.circle.fill", 14., p.accent)).child(t(text).font(13., 500.).color(p.accent)));
            }
            Some(Err(e)) => result = result.child(div().flex_1().min_w_0().child(t(e.clone()).size(13.).color(p.warning))),
            None => {}
        }
        form = form.child(result).when_some(self.analysis.clone(), |d, a| d.child(t(a).size(12.).color(p.muted)));
        vec![
            any(t(format!("Only rewriting uses this server; dictation and meetings stay on this {word}. Use HTTPS, or plain HTTP only on a network you trust.")).size(13.).color(p.muted)),
            any(form),
            any(v_flex()
                .w_full()
                .gap(px(8.))
                .child(t("On the server, run flowd next to an OpenAI-compatible model server:").size(13.).color(p.muted))
                .child(
                    v_flex()
                        .w_full()
                        .p(px(12.))
                        .bg(p.tint)
                        .rounded(px(10.))
                        .gap(px(1.))
                        .child(t("LOCALFLOW_REWRITE_TOKEN=<key> flowd serve --listen 0.0.0.0:8080 \\").mono().size(12.).selectable())
                        .child(t("  --backend http://127.0.0.1:8000/v1 --model <served-model-id>").mono().size(12.).selectable()),
                )),
        ]
    }

    /// The pairing and address sheets, over the whole page.
    pub(super) fn overlays(&mut self, window: &Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let body = crate::remote::sheet_view(self, window, cx)?;
        Some(any(sheet_overlay("onboarding.modal", window, cx, div().bg(sheet_fill(cx)).rounded(px(12.)).child(body))))
    }
}

impl crate::remote::RemotePage for OnboardingPage {
    fn form(&mut self) -> &mut crate::remote::PairForm {
        &mut self.pair
    }
    fn form_ref(&self) -> &crate::remote::PairForm {
        &self.pair
    }
    fn remote_changed(&mut self, cx: &mut Context<Self>) {
        self.remote.pinned = cx.global::<crate::core::Core>().services.secret_data(&flow_core::settings::remote_keychain("server-key")).ok().flatten().map(|k| flow_core::settings::fingerprint_of(&k));
        cx.notify();
    }
}
