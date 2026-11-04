//! Settings › Server: remote dictation setup, the routing switches and Advanced, and "Your devices"
//! with "Add another device" (Feature 028 US4).
use super::*;
use super::sheets::sheet_button;
use flow_core::remote::devices::{self, AccountDevice, DevicesError, Invite, PendingInvite};

/// "Your devices" and the invite sheet. `list` is `None` until the server answered, and stays `None`
/// when it doesn't offer the operations, which hides the controls.
#[derive(Default)]
pub(crate) struct Devices {
    pub list: Option<Vec<AccountDevice>>,
    /// The origin the list was asked of: one load per page and server.
    // ponytail: a failed load waits for the next page open; retry on a timer if that shows.
    asked: Option<String>,
    listing: bool,
    pub error: Option<String>,
    /// The open sheet's invite and this device's key, for the code.
    pub invite: Option<(Invite, Option<Vec<u8>>)>,
    pub sheet_error: Option<String>,
    pub confirming: bool,
    /// What the confirmation did, once it's done.
    pub outcome: Option<&'static str>,
}

impl Devices {
    /// The device that redeemed the sheet's invite.
    pub fn redeemed(&self) -> Option<&PendingInvite> {
        let id = self.invite.as_ref()?.0.id;
        self.list.as_ref()?.iter().find_map(|d| d.invite.as_ref().filter(|i| i.invite_id == id))
    }
    /// The code both screens show.
    pub fn code(&self) -> Option<String> {
        let own = self.invite.as_ref()?.1.as_ref()?;
        let pending = self.redeemed()?;
        Some(devices::device_code(own, &pending.device_key, &pending.pair_binding))
    }
}

fn device_failure(e: &DevicesError) -> String {
    devices::failure_message(e).to_string()
}

impl SettingsPage {
    pub(super) fn server_section(&self, window: &Window, cx: &mut Context<Self>) -> Div {
        let pl = pal(cx);
        let p = prefs(cx);
        let on = p.bool_or("remote.enabled", false);
        let state = core::remote_state(p);
        let title = if core::meeting_only(p) { "Your server" } else { "Remote dictation" };
        // The address row below shows the URL, so this row only needs the state.
        let detail = if on && self.pinned.is_some() { core::remote_status(p).map(String::from) } else { Some(core::remote_detail(p)).filter(|d| !d.is_empty()) };
        let r = core::routing(p);
        let server_only = r.server_only;
        let use_all = r.use_for_everything;
        let needs_consent = on && !r.consent_current;
        let toggle = switch("settings.remoteEnabled", title, on, false, cx.listener(|this, _: &bool, w, cx| this.request_remote_toggle(w, cx)));
        let pair = (!on || state != "approved").then(|| prototype_button("settings.remotePairWithToken", "Pair with Token").on_click(cx.listener(|this, _, w, cx| crate::remote::open_pair(this, None, w, cx))));
        let mut body = group(cx).child(row(title, detail, h_flex().gap(px(12.)).children(pair).child(toggle), cx));
        if on && self.pinned.is_some() {
            let url = core::remote_addresses(p).join(", ");
            let shown = flow_core::remote::address::list_notice(&url).map_or(url.clone(), str::to_string);
            let button = prototype_button("settings.remoteAddressEdit", "Change Address").on_click(cx.listener(|this, _, w, cx| crate::remote::open_address(this, w, cx)));
            body = body.child(hairline(cx)).child(row("Server address", Some(shown), button, cx));
        }
        if on && state != "approved"
            && let Some(pinned) = &self.pinned
        {
            let details = v_flex().id("settings.setupDetails").test_support().w_full().items_start().gap(px(8.)).py(px(12.));
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
                Some("No models on this Mac. Without the server, work waits.".into()),
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
                    Some("Consent needed".into()),
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
                advanced = advanced.child(v_flex().w_full().text_color(pal(cx).muted).children(self.advanced(&r, window, cx)));
            }
            body = body.child(hairline(cx)).child(div().id("settings.serverAdvancedRow").test_support().w_full().py(px(10.)).child(advanced));
        }
        let mut out = v_flex().w_full().gap(px(12.)).child(body);
        if on && state == "approved"
            && let Some(list) = &self.devices.list
        {
            out = out.child(self.your_devices(list, cx));
        }
        match self.server_mode_section(window, cx) {
            Some(server_mode) => out.child(server_mode),
            None => out,
        }
    }

    fn your_devices(&self, list: &[AccountDevice], cx: &mut Context<Self>) -> Div {
        let pl = pal(cx);
        let add = prototype_button("settings.addDevice", "Add Another Device").on_click(cx.listener(|this, _, _, cx| this.open_add_device(cx)));
        let mut body = group(cx).child(div().id("settings.yourDevices").w_full().child(row("Your devices", None, add, cx)).test_support());
        for d in list {
            let mut detail = vec![flow_core::server_admin::kind_label(d.kind.as_deref()).to_string()];
            detail.push(if d.state == "pending" { "Waiting for confirmation".into() } else if d.connected { "Connected".into() } else { d.last_seen_at.as_deref().map_or("Never seen".into(), |at| format!("Last seen {}", &at[..10.min(at.len())])) });
            let name = if d.this_device { format!("{} (this device)", d.name) } else { d.name.clone() };
            let (id, label) = if d.this_device { (format!("settings.yourDeviceNotMe.{}", d.id), "This Wasn't Me") } else { (format!("settings.yourDeviceRemove.{}", d.id), "Remove") };
            let (device, this_device) = (d.id, d.this_device);
            let button = prototype_button(SharedString::from(id), label).on_click(cx.listener(move |this, _, _, cx| this.open_modal(Modal::RemoveDevice(device, this_device), cx)));
            body = body.child(hairline(cx)).child(row(name, Some(detail.join(" · ")), button, cx));
        }
        body.when_some(self.devices.error.clone(), |d, e| d.child(div().id("settings.yourDevicesError").pb(px(12.)).child(t(e).size(12.).color(pl.warning)).test_support()))
    }

    /// Asks the server for this user's devices once per page and server, on an approved device.
    pub(super) fn load_devices(&mut self, cx: &mut Context<Self>) {
        let core = cx.global::<Core>();
        let p = &core.prefs;
        if core.scenario.is_some() || !p.bool_or("remote.enabled", false) || core::remote_state(p) != "approved" {
            return;
        }
        let origin = core::remote_server_url(p);
        if self.devices.listing || self.devices.asked.as_ref() == Some(&origin) {
            return;
        }
        self.devices.asked = Some(origin);
        self.list_devices(cx);
    }

    fn list_devices(&mut self, cx: &mut Context<Self>) {
        self.devices.listing = true;
        crate::remote::run_remote(cx, |r| devices::list(&r.pool), |this: &mut Self, answer, _| {
            this.devices.listing = false;
            match answer {
                Ok(list) => {
                    this.devices.list = Some(list);
                    this.devices.error = None;
                }
                Err(e) if e.not_offered() => this.devices.list = None,
                // Only the list's own failure; the sheet says its own.
                Err(e) if this.devices.list.is_some() && this.modal != Some(Modal::AddDevice) => this.devices.error = Some(device_failure(&e)),
                Err(_) => {}
            }
        });
    }

    fn open_add_device(&mut self, cx: &mut Context<Self>) {
        self.devices.invite = None;
        self.devices.sheet_error = None;
        self.devices.outcome = None;
        self.devices.confirming = false;
        self.open_modal(Modal::AddDevice, cx);
        crate::remote::run_remote(cx, |r| devices::invite(&r.pool).map(|i| (i, r.enrollment.device_public_key())), |this: &mut Self, answer, cx| {
            if this.modal != Some(Modal::AddDevice) {
                return;
            }
            match answer {
                Ok(invite) => {
                    this.devices.invite = Some(invite);
                    this.poll_devices(cx);
                }
                Err(e) => this.devices.sheet_error = Some(device_failure(&e)),
            }
        });
    }

    /// `account_devices` every 2 s while the sheet is open and nothing is confirmed yet.
    fn poll_devices(&mut self, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(2)).await;
                let open = this.update(cx, |this, cx| {
                    let open = this.modal == Some(Modal::AddDevice) && this.devices.outcome.is_none() && this.devices.invite.is_some();
                    if open && !this.devices.listing && !this.devices.confirming {
                        this.list_devices(cx);
                    }
                    open
                });
                if !matches!(open, Ok(true)) {
                    break;
                }
            }
        })
        .detach();
    }

    fn answer_invite(&mut self, accept: bool, cx: &mut Context<Self>) {
        let Some(pending) = self.devices.redeemed().cloned() else { return };
        if self.devices.confirming {
            return;
        }
        self.devices.confirming = true;
        self.devices.sheet_error = None;
        cx.notify();
        crate::remote::run_remote(cx, move |r| devices::confirm(&r.pool, &pending, accept, &|input| r.enrollment.device_sign(input)), |this: &mut Self, answer, cx| {
            this.devices.confirming = false;
            match answer {
                Ok(true) => this.devices.outcome = Some("Added. The other device can use your server now."),
                Ok(false) => this.devices.outcome = Some("Declined. The other device was removed."),
                Err(e) => this.devices.sheet_error = Some(device_failure(&e)),
            }
            this.list_devices(cx);
        });
    }

    pub(super) fn close_add_device(&mut self, cx: &mut Context<Self>) {
        self.devices.invite = None;
        self.modal = None;
        self.list_devices(cx);
        cx.notify();
    }

    pub(super) fn add_device_sheet(&self, cx: &mut Context<Self>) -> Div {
        let pl = pal(cx);
        let d = &self.devices;
        let mut body = v_flex().w(px(460.)).p(px(24.)).gap(px(12.)).child(t("Add another device").font(17., 500.));
        if let Some(outcome) = d.outcome {
            body = body.child(t(outcome).size(13.).swift_lines());
        } else if let Some(code) = d.code() {
            body = body
                .child(t("Your other device shows a code. Confirm only if it's the same as this one.").size(13.).line_spacing(3.).swift_lines())
                .child(div().id("settings.addDeviceCode").child(t(devices::grouped(&code)).font(28., 600.)).test_support());
        } else if let Some((invite, _)) = &d.invite {
            let link = devices::invite_link(&invite.token, &core::remote_addresses(prefs(cx)));
            body = body
                .child(t("On the other device, scan this code or open the link. It works once, for 10 minutes.").size(13.).line_spacing(3.).swift_lines())
                .child(div().id("settings.addDeviceQR").children(flow_ui::qr::qr_code("settings.addDeviceQRCode", &link, 160., "Invite QR code")).test_support())
                .child(selectable("settings.addDeviceLink", link, 12., false, pl.muted, 15.))
                .child(selectable("settings.addDeviceToken", invite.token.value.clone(), 12., true, pl.ink, 15.));
        } else if d.sheet_error.is_none() {
            body = body.child(t("Asking the server…").size(13.).color(pl.muted));
        }
        let mut buttons = h_flex().w_full().justify_end().gap(px(8.));
        if d.outcome.is_none() && d.code().is_some() {
            buttons = buttons
                .child(sheet_button("settings.addDeviceDecline", "Decline", cx).disabled(d.confirming).on_click(cx.listener(|this, _, _, cx| this.answer_invite(false, cx))))
                .child(sheet_button("settings.addDeviceConfirm", "Confirm", cx).disabled(d.confirming).on_click(cx.listener(|this, _, _, cx| this.answer_invite(true, cx))));
        } else {
            let label = if d.outcome.is_some() { "Done" } else { "Cancel" };
            buttons = buttons.child(sheet_button("settings.addDeviceDone", label, cx).on_click(cx.listener(|this, _, _, cx| this.close_add_device(cx))));
        }
        body.when_some(d.sheet_error.clone(), |b, e| b.child(div().id("settings.addDeviceError").child(t(e).size(12.).color(pl.warning)).test_support())).child(buttons)
    }

    /// Removes one of this user's devices. This one goes as a revocation: its credentials go too.
    pub(super) fn remove_device(&mut self, id: i64, this_device: bool, cx: &mut Context<Self>) {
        crate::remote::run_remote(
            cx,
            move |r| {
                let answer = devices::revoke(&r.pool, id, this_device);
                if this_device && answer.is_ok() {
                    r.enrollment.apply("revoked");
                }
                answer
            },
            |this: &mut Self, answer, cx| {
                match answer {
                    Ok(list) => {
                        this.devices.list = Some(list);
                        this.devices.error = None;
                    }
                    Err(e) => this.devices.error = Some(device_failure(&e)),
                }
                this.refresh(cx);
            },
        );
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
            row("Dictation", None, muted_picker("settings.serverOverride.dictation", "Dictation runs on", 150., dictation, &TWO, disabled, cx), cx).into_any_element(),
            hairline(cx).into_any_element(),
            row("Rewriting", None, muted_picker("settings.serverOverride.rewriting", "Rewriting runs on", 150., rewriting, &THREE, disabled, cx), cx).into_any_element(),
        ];
        if switch_applies && rewriting == "custom" {
            out.extend(self.rewrite_fields(window, cx));
        }
        let custom_summaries = switch_applies && summaries == "custom";
        out.push(hairline(cx).into_any_element());
        out.push(row("Summaries", custom_summaries.then(|| "Falls back to your server".to_string()), muted_picker("settings.serverOverride.summaries", "Summaries runs on", 150., summaries, &THREE, disabled, cx), cx).into_any_element());
        if custom_summaries {
            out.push(self.summary_fields(window, cx).into_any_element());
        }
        out.push(hairline(cx).into_any_element());
        out.push(row("Meetings", None, muted_picker("settings.serverOverride.meetings", "Meetings runs on", 150., meetings, &TWO, disabled, cx), cx).into_any_element());
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
                Some("Then dictation uses this Mac".into()),
                stepper("settings.serverFallbackThreshold", "Remote dictation fallback threshold in milliseconds", format!("{} ms", flow_core::insights::grouped(threshold as i64)), cx.listener(step(-250)), cx.listener(step(250)), cx),
                cx,
            )
            .into_any_element(),
        );
        if let Some(fp) = &self.pinned {
            out.push(hairline(cx).into_any_element());
            out.push(
                div().id("settings.serverFingerprint").test_support().w_full().py(px(12.)).child(
                    v_flex().gap(px(2.)).child(t("Server fingerprint").size(14.)).child(selectable("settings.serverFingerprint.text", fp.clone(), 12., false, pal(cx).muted, 15.)),
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
            Some(Ok(summary)) => Some(format!("Copied. {summary}")),
            Some(Err(e)) => Some(format!("The copy didn't finish: {e}")),
            None => None,
        };
        let label = if core.swift_import.is_some() || flow_core::migration::accepted(&core.paths.root) { "Copy Again" } else { "Copy" };
        let button = prototype_button("settings.swiftImport", label).on_click(cx.listener(|_, _, _, cx| {
            let core = cx.global_mut::<Core>();
            let swift_prefs = core.services.swift_prefs();
            core.swift_import = match (&core.db, &core.paths.swift_root) {
                (Some(db), Some(swift)) => Some(flow_core::migration::accept(db, &mut core.prefs, swift, &core.paths.root, swift_prefs).map(|i| i.summary())),
                _ => None,
            };
            cx.notify();
        }));
        Some(group(cx).child(row("Data from the Swift app", detail, button, cx)))
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
