//! Settings › Server: remote dictation setup, the routing switches and Advanced.
use super::*;

impl SettingsPage {
    pub(super) fn server_section(&self, window: &Window, cx: &mut Context<Self>) -> Div {
        let pl = pal(cx);
        let p = prefs(cx);
        let on = p.bool_or("remote.enabled", false);
        let state = core::remote_state(p);
        let title = if core::meeting_only(p) { "Your server" } else { "Remote dictation" };
        let detail = core::remote_detail(p, self.identity.is_some());
        let r = core::routing(p);
        let server_only = r.server_only;
        let use_all = r.use_for_everything;
        let needs_consent = on && !r.consent_current;
        let toggle = switch("settings.remoteEnabled", title, on, false, cx.listener(|this, _: &bool, w, cx| this.request_remote_toggle(w, cx)));
        let mut body = group(cx).child(row(title, Some(detail), toggle, cx));
        if on && (state != "approved" || self.identity.is_some() || self.remote_error.is_some()) {
            let mut details = v_flex().w_full().items_start().gap(px(12.)).py(px(16.));
            if let Some(identity) = &self.identity {
                details = details
                    .child(t("Server fingerprint").font(12., 500.).color(pl.muted))
                    .child(t(identity.fingerprint.clone()).mono().size(13.).id("settings.remoteFingerprint"))
                    .child(rich(vec![span("Compare it with "), span("flowd admin identity").serif(false), span(" on the server before trusting it.")]).size(12.).color(pl.muted))
                    .child(prototype_button("settings.remoteTrust", "Trust This Server").on_click(cx.listener(|this, _, _, cx| this.trust_server(cx))));
            } else if state != "approved"
                && let Some(pinned) = &self.pinned
            {
                details = details.child(t(format!("Pinned fingerprint  {pinned}")).mono().size(12.).color(pl.muted));
            }
            if on && state == "pinned" && self.identity.is_none() {
                let services = &cx.global::<Core>().services;
                let google = services.google_sign_in_available();
                details = details.child(
                    h_flex()
                        .gap(px(8.))
                        .child(prototype_button("settings.remoteSignInApple", "Sign in with Apple").disabled(self.busy).on_click(cx.listener(|this, _, _, cx| this.sign_in("apple", cx))))
                        .when(google, |d| d.child(prototype_button("settings.remoteSignInGoogle", "Sign in with Google").disabled(self.busy).on_click(cx.listener(|this, _, _, cx| this.sign_in("google", cx))))),
                );
            }
            if matches!(state, "pin_mismatch" | "revoked" | "rejected") {
                details = details.child(prototype_button("settings.remoteEnrollAgain", "Enroll Again").disabled(self.busy).on_click(cx.listener(|this, _, _, cx| this.fetch_identity(cx))));
            }
            if let Some(e) = &self.remote_error {
                details = details.child(t(e.clone()).size(12.).color(pl.warning));
            }
            body = body.child(hairline(cx)).child(details);
        }
        if r.routes {
            body = body.child(hairline(cx)).child(row(
                "Use this server for everything",
                None,
                switch("settings.serverUseForEverything", "Use this server for everything", use_all, server_only, cx.listener(|this, on: &bool, _, cx| {
                    this.check_result = None;
                    this.set_bool("server.useForEverything", *on, cx);
                })),
                cx,
            ));
        }
        if r.routes || server_only {
            body = body.child(hairline(cx)).child(row(
                "Server only",
                Some("Never load models on this Mac. Without the server, dictation keeps the audio for a retry and meetings wait.".into()),
                switch("settings.serverOnly", "Server only", server_only, false, cx.listener(|this, on: &bool, _, cx| {
                    this.check_result = None;
                    this.set_bool("server.only", *on, cx);
                })),
                cx,
            ));
        }
        if r.routes {
            if needs_consent && use_all {
                body = body.child(hairline(cx)).child(row(
                    "Summaries and meetings",
                    Some("Confirm the updated consent to send them to your server.".into()),
                    prototype_button("settings.serverConsentUpdate", "Review…").on_click(cx.listener(|this, _, _, cx| this.open_modal(Modal::ConsentUpdate, cx))),
                    cx,
                ));
            }
            let check = h_flex()
                .gap(px(10.))
                .when_some(self.check_result.clone(), |d, s| d.child(t(s).size(12.).color(pl.muted).id("settings.serverCheckResult")))
                .child(prototype_button("settings.serverCheckConnection", if self.checking { "Checking…" } else { "Check connection" }).disabled(self.checking).on_click(cx.listener(|this, _, _, cx| this.check_connection(cx))));
            body = body.child(hairline(cx)).child(div().id("settings.serverServices").w_full().child(row("Services", Some(r.placement()), check, cx)));
            let mut advanced = v_flex().w_full().child(disclosure("settings.serverAdvanced", "Advanced", self.server_advanced, cx.listener(|this, _, _, cx| {
                this.server_advanced = !this.server_advanced;
                cx.notify();
            }), cx));
            if self.server_advanced {
                advanced = advanced.children(self.advanced(&r, window, cx));
            }
            body = body.child(hairline(cx)).child(div().w_full().py(px(14.)).child(advanced));
        }
        body
    }

    fn advanced(&self, r: &core::Routing, window: &Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let p = prefs(cx);
        let threshold = core::fallback_threshold(p);
        let ov = |key| if r.server_only { "server" } else { core::override_of(p, key) };
        let (dictation, rewriting, summaries, meetings) = (ov("server.override.dictation"), ov("server.override.rewrite"), ov("server.override.summaries"), ov("server.override.meetings"));
        let switch_applies = r.switch_applies();
        const TWO: [(&str, &str); 2] = [("Your server", "server"), ("This Mac", "thisMac")];
        const THREE: [(&str, &str); 3] = [("Your server", "server"), ("This Mac", "thisMac"), ("Custom server", "custom")];
        let disabled = r.server_only;
        let mut out = vec![
            row("Dictation", Some("Speech recognition; rewriting follows its own row".into()), picker("settings.serverOverride.dictation", "Dictation runs on", 150., dictation, &TWO, disabled, cx), cx).into_any_element(),
            hairline(cx).into_any_element(),
            row("Rewriting", None, picker("settings.serverOverride.rewriting", "Rewriting runs on", 150., rewriting, &THREE, disabled, cx), cx).into_any_element(),
        ];
        if switch_applies && rewriting == "custom" {
            out.extend(self.rewrite_fields(window, cx));
        }
        let custom_summaries = switch_applies && summaries == "custom";
        out.push(hairline(cx).into_any_element());
        out.push(row("Summaries", custom_summaries.then(|| "Your server is used if this server fails".to_string()), picker("settings.serverOverride.summaries", "Summaries runs on", 150., summaries, &THREE, disabled, cx), cx).into_any_element());
        if custom_summaries {
            out.push(self.summary_fields(window, cx).into_any_element());
        }
        out.push(hairline(cx).into_any_element());
        out.push(row("Meetings", Some("Transcripts, speaker labels and voice matching".into()), picker("settings.serverOverride.meetings", "Meetings runs on", 150., meetings, &TWO, disabled, cx), cx).into_any_element());
        out.push(hairline(cx).into_any_element());
        let step = |delta: i64| {
            move |_: &mut Self, _: &ClickEvent, _: &mut Window, cx: &mut Context<Self>| {
                let v = core::fallback_threshold(prefs(cx));
                prefs_mut(cx).set("remote.fallbackThresholdMs", (v + delta).clamp(250, 10_000));
                cx.notify();
            }
        };
        out.push(
            row(
                "Fallback threshold",
                Some("Dictation uses this Mac after this wait".into()),
                stepper("settings.serverFallbackThreshold", "Remote dictation fallback threshold in milliseconds", format!("{threshold} ms"), cx.listener(step(-250)), cx.listener(step(250)), cx),
                cx,
            )
            .into_any_element(),
        );
        if let Some(fp) = &self.pinned {
            out.push(hairline(cx).into_any_element());
            out.push(div().id("settings.serverFingerprint").w_full().child(row("Server fingerprint", Some(fp.clone()), div(), cx)).into_any_element());
        }
        out
    }

    fn request_remote_toggle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if prefs(cx).bool_or("remote.enabled", false) {
            self.modal = Some(Modal::TurnOff);
        } else {
            self.remote_error = None;
            let stored = core::remote_server_url(prefs(cx));
            self.server_draft.update(cx, |s, cx| s.set_value(stored, window, cx));
            self.modal = Some(Modal::Consent);
        }
        cx.notify();
    }

    /// The consent step: only now are the address and the switch stored.
    pub(super) fn confirm_consent(&mut self, cx: &mut Context<Self>) {
        if self.modal != Some(Modal::Consent) {
            return;
        }
        let Some(origin) = core::remote_origin(&val(&self.server_draft, cx)) else {
            self.remote_error = Some("Enter the server's https:// address without a path.".into());
            cx.notify();
            return;
        };
        let p = prefs_mut(cx);
        p.set("remote.serverURL", origin);
        p.set("remote.consentVersion", core::CONSENT_VERSION);
        p.set("remote.enabled", true);
        self.modal = None;
        self.fetch_identity(cx);
    }

    pub(super) fn fetch_identity(&mut self, cx: &mut Context<Self>) {
        let base = self.remote_base.clone().unwrap_or_else(|| core::remote_server_url(prefs(cx)));
        self.busy = true;
        self.remote_error = None;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let answer = cx.background_spawn(async move { core::fetch_identity(&base) }).await;
            let _ = this.update(cx, |this, cx| {
                this.busy = false;
                match answer {
                    Ok(identity) => this.identity = Some(identity),
                    Err(()) => {
                        this.identity = None;
                        this.remote_error = Some("The server did not answer with a LocalFlow identity. Check the address.".into());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// `pin`: credentials go, the key is stored, the state moves to pinned.
    pub(super) fn trust_server(&mut self, cx: &mut Context<Self>) {
        let Some(identity) = self.identity.clone() else { return };
        let services = &cx.global::<Core>().services;
        for account in ["device-key", "refresh-token", "access-token"] {
            let _ = services.remove_secret(&core::remote_keychain(account));
        }
        if services.set_secret(&core::remote_keychain("server-key"), &identity.server_key).is_err() {
            self.remote_error = Some("The server identity could not be saved.".into());
            cx.notify();
            return;
        }
        let p = prefs_mut(cx);
        p.remove("remote.notice");
        p.set("remote.state", "pinned");
        self.identity = None;
        self.refresh(cx);
        cx.notify();
    }

    /// Apple and Google need the Mac's sign-in services and a Secure Enclave key.
    pub(super) fn sign_in(&mut self, provider: &str, cx: &mut Context<Self>) {
        self.remote_error = None;
        match cx.global::<Core>().services.enroll_device(provider) {
            Ok(state) => prefs_mut(cx).set("remote.state", state),
            Err(_) => self.remote_error = Some("Sign-in did not finish.".into()),
        }
        self.refresh(cx);
        cx.notify();
    }

    pub(super) fn confirm_turn_off(&mut self, cx: &mut Context<Self>) {
        self.modal = None;
        self.identity = None;
        self.remote_error = None;
        let services = &cx.global::<Core>().services;
        for account in ["device-key", "server-key", "refresh-token", "access-token"] {
            let _ = services.remove_secret(&core::remote_keychain(account));
        }
        core::reset_remote(prefs_mut(cx));
        self.refresh(cx);
        cx.notify();
    }

    /// ponytail: times the public identity request, not Swift's channel round trip; see `core::ping`.
    pub(super) fn check_connection(&mut self, cx: &mut Context<Self>) {
        if self.checking {
            return;
        }
        if !core::routing(prefs(cx)).anything_on_server() {
            self.check_result = Some("Nothing runs on your server".into());
            cx.notify();
            return;
        }
        let base = self.remote_base.clone().unwrap_or_else(|| core::remote_server_url(prefs(cx)));
        self.checking = true;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let ms = cx.background_spawn(async move { core::ping(&base) }).await;
            let _ = this.update(cx, |this, cx| {
                this.checking = false;
                this.check_result = Some(ms.map_or("Server unreachable".to_string(), |ms| format!("Answered in {ms} ms")));
                cx.notify();
            });
        })
        .detach();
    }
}
