//! Settings › Server: remote dictation setup, the routing switches and Advanced.
use super::*;

impl SettingsPage {
    pub(super) fn server_section(&self, window: &Window, cx: &mut Context<Self>) -> Div {
        let pl = pal(cx);
        let p = prefs(cx);
        let on = p.bool_or("remote.enabled", false);
        let state = core::remote_state(p);
        let title = if core::meeting_only(p) { "Your server" } else { "Remote dictation" };
        let detail = core::remote_detail(p);
        let r = core::routing(p);
        let server_only = r.server_only;
        let use_all = r.use_for_everything;
        let needs_consent = on && !r.consent_current;
        let toggle = switch("settings.remoteEnabled", title, on, false, cx.listener(|this, _: &bool, w, cx| this.request_remote_toggle(w, cx)));
        let mut body = group(cx).child(row(title, Some(detail), toggle, cx));
        if !on || state != "approved" {
            let button = prototype_button("settings.remotePairWithToken", "Pair with Token").on_click(cx.listener(|this, _, w, cx| crate::remote::open_pair(this, None, w, cx)));
            body = body.child(hairline(cx)).child(row("Pair with a token", Some("Use a token from your server's owner.".into()), button, cx));
        }
        if on && self.pinned.is_some() {
            let url = core::remote_addresses(p).join(", ");
            let shown = flow_core::remote::address::list_notice(&url).map_or(url.clone(), str::to_string);
            let button = prototype_button("settings.remoteAddressEdit", "Change Address").on_click(cx.listener(|this, _, w, cx| crate::remote::open_address(this, w, cx)));
            body = body.child(hairline(cx)).child(row("Server address", Some(shown), button, cx));
        }
        if on && state != "approved"
            && let Some(pinned) = &self.pinned
        {
            let details = v_flex().id("settings.setupDetails").test_support().w_full().items_start().gap(px(12.)).py(px(16.));
            body = body.child(hairline(cx)).child(details.child(selectable("settings.pinnedFingerprint", format!("Pinned fingerprint  {pinned}"), 12., true, pl.muted, 15.)));
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
                .when_some(self.check_result.clone(), |d, s| d.child(div().id("settings.serverCheckResult").child(t(s).size(12.).color(pl.muted)).test_support()))
                .child(prototype_button("settings.serverCheckConnection", if self.checking { "Checking…" } else { "Check connection" }).disabled(self.checking).on_click(cx.listener(|this, _, _, cx| this.check_connection(cx))));
            body = body.child(hairline(cx)).child(div().id("settings.serverServices").w_full().child(row("Services", Some(r.placement()), check, cx)));
            let mut advanced = v_flex().w_full().child(disclosure("settings.serverAdvanced", "Advanced", self.server_advanced, cx.listener(|this, _, _, cx| {
                this.server_advanced = !this.server_advanced;
                cx.notify();
            }), cx));
            if self.server_advanced {
                // `DisclosureGroup` content inherits the muted style and the native row spacing.
                advanced = advanced.child(v_flex().w_full().gap(px(8.)).text_color(pal(cx).muted).children(self.advanced(&r, window, cx)));
            }
            body = body.child(hairline(cx)).child(div().id("settings.serverAdvancedRow").test_support().w_full().py(px(14.)).child(advanced));
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
            row("Dictation", Some("Speech recognition; rewriting follows its own row".into()), muted_picker("settings.serverOverride.dictation", "Dictation runs on", 150., dictation, &TWO, disabled, cx), cx).into_any_element(),
            hairline(cx).into_any_element(),
            row("Rewriting", None, muted_picker("settings.serverOverride.rewriting", "Rewriting runs on", 150., rewriting, &THREE, disabled, cx), cx).into_any_element(),
        ];
        if switch_applies && rewriting == "custom" {
            out.extend(self.rewrite_fields(window, cx));
        }
        let custom_summaries = switch_applies && summaries == "custom";
        out.push(hairline(cx).into_any_element());
        out.push(row("Summaries", custom_summaries.then(|| "Your server is used if this server fails".to_string()), muted_picker("settings.serverOverride.summaries", "Summaries runs on", 150., summaries, &THREE, disabled, cx), cx).into_any_element());
        if custom_summaries {
            out.push(self.summary_fields(window, cx).into_any_element());
        }
        out.push(hairline(cx).into_any_element());
        out.push(row("Meetings", Some("Transcripts, speaker labels and voice matching".into()), muted_picker("settings.serverOverride.meetings", "Meetings runs on", 150., meetings, &TWO, disabled, cx), cx).into_any_element());
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
                stepper("settings.serverFallbackThreshold", "Remote dictation fallback threshold in milliseconds", format!("{} ms", flow_core::insights::grouped(threshold as i64)), cx.listener(step(-250)), cx.listener(step(250)), cx),
                cx,
            )
            .into_any_element(),
        );
        if let Some(fp) = &self.pinned {
            out.push(hairline(cx).into_any_element());
            out.push(
                div().id("settings.serverFingerprint").test_support().w_full().py(px(19.)).child(
                    v_flex().gap(px(5.)).child(t("Server fingerprint").size(14.)).child(selectable("settings.serverFingerprint.text", fp.clone(), 12., false, pal(cx).muted, 15.)),
                )
                .into_any_element(),
            );
        }
        out
    }

    /// Only beside the Swift app. Adds what changed there since the last copy; nothing there changes.
    pub(super) fn swift_import_section(&self, cx: &mut Context<Self>) -> Option<Div> {
        let core = cx.global::<Core>();
        core.paths.swift_root.as_ref()?;
        let detail = match &core.swift_import {
            Some(Ok(summary)) => format!("Copied. {summary}"),
            Some(Err(e)) => format!("The copy didn't finish: {e}"),
            None => "Copy dictations, meetings and settings from the LocalFlow Swift app. That app stays as it is.".to_string(),
        };
        let button = prototype_button("settings.swiftImport", "Copy Again").on_click(cx.listener(|_, _, _, cx| {
            let core = cx.global_mut::<Core>();
            core.swift_import = match (&core.db, &core.paths.swift_root) {
                (Some(db), Some(swift)) => Some(flow_core::migration::import(db, swift, &core.paths.root).map(|i| i.summary())),
                _ => None,
            };
            cx.notify();
        }));
        Some(group(cx).child(row("Data from the Swift app", Some(detail), button, cx)))
    }

    fn request_remote_toggle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if prefs(cx).bool_or("remote.enabled", false) {
            self.prompt_turn_off(window, cx);
        } else {
            crate::remote::open_pair(self, None, window, cx);
        }
        cx.notify();
    }

    pub(super) fn confirm_turn_off(&mut self, cx: &mut Context<Self>) {
        cx.global_mut::<Core>().turn_off_remote();
        self.refresh(cx);
        cx.notify();
    }

    /// `check()`: one fresh sealed channel timed to `ready`, which also refreshes what the server
    /// offers. Without a pinned key or access token Swift's `sessionInputs` is nil: unreachable.
    pub(super) fn check_connection(&mut self, cx: &mut Context<Self>) {
        if self.checking {
            return;
        }
        if !core::routing(prefs(cx)).anything_on_server() {
            self.check_result = Some("Nothing runs on your server".into());
            cx.notify();
            return;
        }
        let addresses = self.remote_base.clone().map_or_else(|| core::remote_addresses(prefs(cx)), |base| vec![base]);
        let services = &cx.global::<Core>().services;
        let key = services.secret_data(&core::remote_keychain("server-key")).ok().flatten();
        let token = services.secret(&core::remote_keychain("access-token")).ok().flatten();
        self.checking = true;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let answer = cx.background_spawn(async move { addresses.iter().find_map(|base| core::ping(base, key.as_deref(), token.as_deref())) }).await;
            let _ = this.update(cx, |this, cx| {
                this.checking = false;
                this.check_result = Some(match answer {
                    Some((ms, offered)) => {
                        if let Some(offered) = offered {
                            prefs_mut(cx).set("server.capabilities", offered);
                        }
                        format!("Answered in {ms} ms")
                    }
                    None => "Server unreachable".to_string(),
                });
                cx.notify();
            });
        })
        .detach();
    }
}

impl crate::remote::RemotePage for SettingsPage {
    fn form(&mut self) -> &mut crate::remote::PairForm {
        &mut self.pair
    }
    fn form_ref(&self) -> &crate::remote::PairForm {
        &self.pair
    }
    fn remote_changed(&mut self, cx: &mut Context<Self>) {
        self.refresh(cx);
    }
}
