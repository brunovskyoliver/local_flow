//! The server step: `RemoteDictationView` and the older rewrite-only form.
use super::OnboardingPage;
use super::parts::*;
use flow_core::onboarding::*;
use flow_ui::prelude::*;

/// Version `REMOTE_CONSENT_VERSION` of both texts; don't edit without a new consent version.
pub const CONSENT_TEXT: &str = "Dictation audio, transcripts, Dictionary terms and rewrite text will leave this Mac for the server below while remote dictation is on. With Use this server for everything, so will meeting audio, meeting transcripts and the text summaries are made from. The server's administrator can see audio while it is being processed. Nothing is sent until the administrator approves this device; dictation stays local whenever the server can't be reached.";
pub const MEETING_CONSENT_TEXT: &str = "Meeting audio, meeting transcripts and the text summaries are made from will leave this Mac for the server below. The server's administrator can see audio while it is being processed. Meetings handed off to the server stay there until they are merged back, at most 7 days. Nothing is sent until the administrator approves this device; recordings wait on this Mac while the server can't be reached. If you set up dictation later, dictation audio, transcripts, Dictionary terms and rewrite text go to this server too.";

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
            any(lede(format!("Turn on {name} and confirm what the server receives. Compare its fingerprint, then sign in; the administrator approves this {word} once. You can change this later in Settings."), cx)),
            any(setup_card(cx).child(card)),
            any(div().id("onboarding.remoteStatus").w_full().child(note("info.circle", privacy, cx))),
        ];
        if !meeting {
            let p = pal(cx);
            let open = self.legacy_open;
            let toggle = self.click(cx, |this, cx| {
                this.legacy_open = !this.legacy_open;
                cx.notify();
            });
            body.push(any(plain_button("onboarding.legacyRewriteServer", "Advanced: rewrite-only server").toggled(open).on_click(toggle).content(
                h_flex().gap(px(6.)).child(icon(if open { "chevron.down" } else { "chevron.right" }, 11., p.muted)).child(t("Advanced: rewrite-only server").size(13.).color(p.muted).a11y_hidden()),
            )));
            if open {
                body.extend(self.legacy_server(cx));
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
            let url = prefs.string("remote.serverURL").unwrap_or_default();
            let status = remote_status(prefs, self.remote.identity.is_some());
            [Some(url.as_str()), status].into_iter().flatten().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" · ")
        } else if meeting {
            "Run meeting transcripts and notes on a LocalFlow server you run.".to_string()
        } else {
            "Run dictation, rewriting, summaries and meetings on a LocalFlow server you run.".to_string()
        };
        let show_details = on && (state != "approved" || self.remote.identity.is_some() || self.remote.error.is_some());
        let needs_sign_in = on && state == "pinned" && self.remote.identity.is_none();
        let toggle = Switch::new("settings.remoteEnabled").checked(on).accessibility_label(title).on_click(cx.listener(|this, _: &bool, w, cx| this.request_toggle(w, cx)));
        let mut card = v_flex().w_full().child(settings_row(title, Some(detail), toggle, cx));
        if !show_details {
            return card;
        }
        let mut details = v_flex().w_full().items_start().gap(px(12.)).py(px(16.));
        if let Some(fingerprint) = self.remote.identity.clone() {
            let trust = self.click(cx, |this, cx| this.trust_server(cx));
            details = details
                .child(t("Server fingerprint").font(12., 500.).color(p.muted))
                .child(div().id("settings.remoteFingerprint").child(t(fingerprint).mono().size(13.)))
                .child(t("Compare it with `flowd admin identity` on the server before trusting it.").size(12.).color(p.muted))
                .child(prototype_button("settings.remoteTrust", "Trust This Server").on_click(trust));
        } else if state != "approved"
            && let Some(pinned) = self.remote.pinned.clone()
        {
            details = details.child(t(format!("Pinned fingerprint  {pinned}")).mono().size(12.).color(p.muted));
        }
        if needs_sign_in {
            let apple = self.click(cx, |this, cx| this.sign_in("apple", cx));
            let mut row = h_flex().gap(px(8.)).child(prototype_button("settings.remoteSignInApple", "Sign in with Apple").disabled(self.remote.busy).on_click(apple));
            if self.remote.google {
                let google = self.click(cx, |this, cx| this.sign_in("google", cx));
                row = row.child(prototype_button("settings.remoteSignInGoogle", "Sign in with Google").disabled(self.remote.busy).on_click(google));
            }
            details = details.child(row);
        }
        if matches!(state.as_str(), "pin_mismatch" | "revoked" | "rejected") {
            let again = self.click(cx, |this, cx| this.fetch_identity(cx));
            details = details.child(prototype_button("settings.remoteEnrollAgain", "Enroll Again").disabled(self.remote.busy).on_click(again));
        }
        if let Some(e) = self.remote.error.clone() {
            details = details.child(t(e).size(12.).color(p.warning));
        }
        card = card.child(hairline(cx)).child(details);
        card
    }

    fn legacy_server(&mut self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let p = pal(cx);
        let word = self.word(cx);
        let endpoint = self.core(cx).prefs.string("rewriteEndpoint").unwrap_or_default();
        let origin = rewrite_origin(&endpoint);
        let insecure = is_unencrypted_remote(&endpoint);
        let allowed = origin.as_deref().is_some_and(|o| insecure_override(&self.core(cx).prefs, o));
        let connect = self.click(cx, |this, cx| this.connect(cx));
        let mut form = setup_card(cx)
            .child(v_flex().w_full().gap(px(8.)).child(field_label("Server address", cx)).child(input_field("link", Input::new(&self.endpoint_input).aria_label("Server address").accessibility_id("onboarding.serverAddress"), cx)))
            .child(
                v_flex()
                    .w_full()
                    .gap(px(8.))
                    .child(field_label("Access key", cx))
                    .child(input_field("key", Input::new(&self.credential_input).aria_label("Access key").accessibility_id("onboarding.accessKey"), cx))
                    .when_some(self.credential_error.clone(), |d, e| d.child(t(e).size(12.).color(p.warning))),
            );
        if insecure {
            let toggle = Switch::new("onboarding.allowInsecure").checked(allowed).label("Allow unencrypted HTTP to this server").accessibility_label("Allow unencrypted HTTP to this server").on_click(cx.listener(|this, on: &bool, _, cx| this.set_insecure(*on, cx)));
            form = form.child(toggle);
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
                        .child(t("LOCALFLOW_REWRITE_TOKEN=<key> flowd serve --listen 0.0.0.0:8080 \\").mono().size(12.))
                        .child(t("  --backend http://127.0.0.1:8000/v1 --model <served-model-id>").mono().size(12.)),
                )),
        ]
    }

    /// The consent sheet and the turn-off dialog, over the whole page.
    pub(super) fn overlays(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if !self.remote.consent_open && !self.remote.confirm_off {
            return None;
        }
        let p = pal(cx);
        let word = self.word(cx);
        let body = if self.remote.consent_open {
            let draft = self.server_draft.read(cx).value().to_string();
            let origin = remote_origin(&draft);
            let prefs = &self.core(cx).prefs;
            let text = if Purpose::stored(prefs) == Purpose::Meetings || prefs.bool_or("server.only", false) { MEETING_CONSENT_TEXT } else { CONSENT_TEXT };
            let cancel = self.click(cx, |this, cx| this.cancel_consent(cx));
            let confirm = self.click(cx, |this, cx| this.confirm_consent(cx));
            let line = p.card_line;
            v_flex()
                .w(px(460.))
                .p(px(24.))
                .gap(px(16.))
                .child(t("Use your LocalFlow server?").font(17., 500.))
                .child(
                    h_flex().w_full().min_h(px(40.)).px(px(12.)).gap(px(10.)).bg(p.surface).rounded(px(8.)).border_1().border_color(line).child(icon("server.rack", 16., p.muted)).child(div().flex_1().min_w_0().child(Input::new(&self.server_draft).appearance(false).aria_label("Server address").accessibility_id("settings.remoteServerURL"))),
                )
                .child(t(text.replace("Mac", word)).size(13.).line_spacing(3.))
                .when_some(origin.clone(), |d, o| d.child(t(format!("Server: {}", server_host(&o))).font(13., 500.)))
                .when_some(self.remote.error.clone(), |d, e| d.child(t(e).size(12.).color(p.warning)))
                .child(h_flex().w_full().justify_end().gap(px(8.)).child(prototype_button("settings.remoteConsentCancel", "Cancel").on_click(cancel)).child(primary_button("settings.remoteConsentConfirm", "Turn On").disabled(origin.is_none()).on_click(confirm)))
        } else {
            let cancel = self.click(cx, |this, cx| {
                this.remote.confirm_off = false;
                cx.notify();
            });
            let off = self.click(cx, |this, cx| this.confirm_turn_off(cx));
            v_flex()
                .w(px(380.))
                .p(px(24.))
                .gap(px(12.))
                .child(t("Turn off remote dictation?").font(15., 600.))
                .child(t(format!("This {word}'s sign-in, device key and server pin are deleted. Your history stays. You will need approval again to turn it back on.")).size(13.).line_spacing(3.))
                .child(h_flex().w_full().justify_end().gap(px(8.)).pt(px(4.)).child(prototype_button("settings.remoteTurnOffCancel", "Cancel").on_click(cancel)).child(prototype_button("settings.remoteTurnOff", "Turn Off").text_color(p.warning).on_click(off)))
        };
        // Stops clicks reaching the page behind, as a sheet does.
        Some(any(deferred(
            h_flex().id("onboarding.modal").occlude().absolute().inset_0().justify_center().bg(gpui_black(0.25)).child(div().bg(p.canvas).rounded(px(12.)).border_1().border_color(p.line).child(body)),
        )))
    }
}

fn gpui_black(alpha: f32) -> Hsla {
    Hsla { h: 0., s: 0., l: 0., a: alpha }
}
