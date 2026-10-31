//! The sheets Settings draws over the whole window, and its native confirmation alerts.
use super::*;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum ContextKind {
    Exclusions,
    Kinds,
}
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Modal {
    Consent,
    ConsentUpdate,
    Context(ContextKind),
}

impl SettingsPage {
    pub(super) fn open_modal(&mut self, modal: Modal, cx: &mut Context<Self>) {
        self.modal = Some(modal);
        cx.notify();
    }
    fn close_modal(&mut self, cx: &mut Context<Self>) {
        // Consent's Cancel leaves nothing stored; the draft goes with it (done in `key` and on the button).
        self.modal = None;
        cx.notify();
    }

    /// `.confirmationDialog` is a native alert on macOS. The switch stays on until Turn Off is answered.
    pub(super) fn prompt_turn_off(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let buttons = [PromptButton::Other("Turn Off".into()), PromptButton::Cancel("Cancel".into())];
        let answer = window.prompt(PromptLevel::Warning, "Turn off remote dictation?", Some("This Mac's sign-in, device key and server pin are deleted. Your history stays. You will need approval again to turn it back on."), &buttons, cx);
        cx.spawn(async move |this, cx| {
            if answer.await == Ok(0) {
                let _ = this.update(cx, |this, cx| this.confirm_turn_off(cx));
            }
        })
        .detach();
    }

    /// The native download confirmation; `alternate` picks the second speech model's copy and action.
    pub(super) fn prompt_download(&mut self, alternate: bool, window: &mut Window, cx: &mut Context<Self>) {
        let (title, message) = self.download_copy(alternate);
        let action = if alternate { "downloadAlternateSpeechModel" } else { "download" };
        let buttons = [PromptButton::Ok("Download".into()), PromptButton::Cancel("Cancel".into())];
        let answer = window.prompt(PromptLevel::Info, &title, Some(&message), &buttons, cx);
        cx.spawn(async move |this, cx| {
            if answer.await == Ok(0) {
                let _ = this.update(cx, |this, cx| this.run(action, cx));
            }
        })
        .detach();
    }

    fn cancel_consent(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.server_draft.update(cx, |s, cx| s.set_value("", window, cx));
        self.close_modal(cx);
    }

    fn confirm_consent_update(&mut self, cx: &mut Context<Self>) {
        prefs_mut(cx).set("remote.consentVersion", core::CONSENT_VERSION);
        self.close_modal(cx);
    }

    /// Esc is the cancel action, Return the default action; with no sheet Esc focuses the page.
    pub(super) fn key(&mut self, key: &str, window: &mut Window, cx: &mut Context<Self>) {
        match (key, self.modal) {
            ("escape", None) => window.focus(&self.focus, cx),
            ("escape", Some(Modal::Consent)) => self.cancel_consent(window, cx),
            ("escape", Some(_)) => self.close_modal(cx),
            ("enter", Some(Modal::Consent)) => self.confirm_consent(cx),
            ("enter", Some(Modal::ConsentUpdate)) => self.confirm_consent_update(cx),
            ("enter", Some(Modal::Context(_))) => self.close_modal(cx),
            _ => {}
        }
    }

    pub(super) fn modal_overlay(&self, window: &Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let modal = self.modal?;
        let pl = pal(cx);
        let body: AnyElement = match modal {
            Modal::Consent => self.consent(window, cx).into_any_element(),
            Modal::ConsentUpdate => self.consent_update(cx).into_any_element(),
            Modal::Context(kind) => self.context_sheet(kind, window, cx).into_any_element(),
        };
        let size = window.viewport_size();
        // Stops clicks reaching the page behind, as a sheet does.
        Some(
            deferred(anchored().position(point(px(0.), px(0.))).child(
                h_flex()
                    .id("settings.modal")
                    .occlude()
                    .w(size.width)
                    .h(size.height)
                    .justify_center()
                    .bg(Hsla { h: 0., s: 0., l: 0., a: 0.25 })
                    .child(div().id("settings.sheet").bg(pl.surface).rounded(px(12.)).text_color(pl.ink).child(body).test_support()),
            ))
            .into_any_element(),
        )
    }

    fn download_copy(&self, alternate: bool) -> (String, String) {
        let s = &self.snapshot;
        let current = core::speech_name(s.speech_model);
        if !alternate {
            let size = s.download_bytes.map_or("Download size unavailable.".to_string(), core::byte_count);
            return (format!("Download {current}?"), format!("{size}\n{}", core::speech_attribution(s.speech_model)));
        }
        match &s.alternate {
            Some(a) => (
                format!("Download {}?", a.name()),
                format!("{} from Hugging Face, verified against pinned hashes.\n{}\nDictation keeps using {current} until you switch.", core::byte_count(a.bytes), core::speech_attribution(a.choice)),
            ),
            None => ("Download speech model?".into(), String::new()),
        }
    }

    fn consent(&self, window: &Window, cx: &mut Context<Self>) -> Div {
        let pl = pal(cx);
        let origin = core::remote_origin(&val(&self.server_draft, cx));
        let text = core::consent_text(prefs(cx));
        v_flex()
            .w(px(460.))
            .p(px(24.))
            .gap(px(16.))
            .child(t("Use your LocalFlow server?").font(17., 500.))
            .child(input_surface("server.rack", Input::new(&self.server_draft).aria_label("Server address").accessibility_id("settings.remoteServerURL"), &self.server_draft, window, cx))
            .child(div().id("settings.consentBody").w_full().child(t(text).size(13.).line_spacing(3.)).test_support())
            .when_some(origin.as_ref(), |d, o| d.child(t(format!("Server: {}", core::origin_host(o))).font(13., 500.)))
            .when_some(self.remote_error.clone(), |d, e| d.child(t(e).size(12.).color(pl.warning)))
            .child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.))
                    .child(prototype_button("settings.remoteConsentCancel", "Cancel").on_click(cx.listener(|this, _, w, cx| this.cancel_consent(w, cx))))
                    .child(prototype_button("settings.remoteConsentConfirm", "Turn On").disabled(origin.is_none()).on_click(cx.listener(|this, _, _, cx| this.confirm_consent(cx)))),
            )
    }

    fn consent_update(&self, cx: &mut Context<Self>) -> Div {
        let text = core::consent_text(prefs(cx));
        v_flex()
            .w(px(460.))
            .p(px(24.))
            .gap(px(16.))
            .child(t("Send summaries and meetings to your server?").font(17., 500.))
            .child(t(text).size(13.).line_spacing(3.))
            .child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.))
                    .child(prototype_button("settings.serverConsentCancel", "Cancel").on_click(cx.listener(|this, _, _, cx| this.close_modal(cx))))
                    .child(prototype_button("settings.serverConsentConfirm", "Confirm").on_click(cx.listener(|this, _, _, cx| this.confirm_consent_update(cx)))),
            )
    }

    fn pick_kinds() -> Vec<(String, String)> {
        core::KINDS.iter().map(|(raw, title)| (title.to_string(), raw.to_string())).collect()
    }

    /// Running app, kinds sheet: fills the draft. Exclusions: adds at once.
    pub(super) fn pick_running_app(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        if self.modal == Some(Modal::Context(ContextKind::Exclusions)) {
            self.exclusion_error = (!core::add_exclusion(prefs_mut(cx), id)).then_some(EXCLUSION_ERROR);
        } else {
            self.bundle_draft.update(cx, |s, cx| s.set_value(id.to_string(), window, cx));
        }
    }

    pub(super) fn add_context_app(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let draft = val(&self.bundle_draft, cx);
        if self.modal == Some(Modal::Context(ContextKind::Exclusions)) {
            let ok = core::add_exclusion(prefs_mut(cx), &draft);
            self.exclusion_error = (!ok).then_some(EXCLUSION_ERROR);
            if ok {
                self.bundle_draft.update(cx, |s, cx| s.set_value("", window, cx));
            }
        } else if self.modal == Some(Modal::Context(ContextKind::Kinds)) {
            let kind = self.add_category;
            let ok = core::set_kind(prefs_mut(cx), &draft, Some(kind));
            self.kind_error = (!ok).then_some(KIND_ERROR);
            if ok {
                self.bundle_draft.update(cx, |s, cx| s.set_value("", window, cx));
            }
        }
        cx.notify();
    }

    fn context_sheet(&self, kind: ContextKind, window: &Window, cx: &mut Context<Self>) -> Div {
        let pl = pal(cx);
        let p = prefs(cx);
        let exclusions = kind == ContextKind::Exclusions;
        // ponytail: no LaunchServices yet, so the name is the bundle ID and the icon a tint square,
        // Swift's own reading for an app that isn't installed.
        let mut ids: Vec<String> = if exclusions { core::exclusions(p) } else { core::overrides(p).into_keys().collect() };
        if exclusions {
            ids.sort_by(|a, b| core::natural_cmp(a, b));
        }
        let overrides = core::overrides(p);
        let height = (ids.len() as f32 * 57.).min(308.);
        let list = if ids.is_empty() {
            div().w_full().py(px(28.)).flex().justify_center().rounded(px(12.)).border_1().border_color(pl.line).child(t("No apps yet").size(14.).color(pl.muted)).into_any_element()
        } else {
            let last = ids.len() - 1;
            let rows = ids.iter().enumerate().map(|(i, id)| {
                let current = overrides.get(id).map_or("other", String::as_str);
                self.app_row(id, exclusions, current, i == last, cx).into_any_element()
            }).collect::<Vec<_>>();
            div().id("settings.contextList").w_full().h(px(height)).overflow_y_scroll().rounded(px(12.)).border_1().border_color(pl.line).children(rows).test_support().into_any_element()
        };
        let running: Vec<(String, String)> = {
            let excluded = core::exclusions(prefs(cx));
            let mut apps = cx.global::<Core>().services.running_apps();
            apps.sort_by(|a, b| core::natural_cmp(&a.0, &b.0));
            apps.into_iter().filter(|a| !exclusions || !excluded.contains(&a.1)).collect()
        };
        let blank = val(&self.bundle_draft, cx).trim().is_empty();
        let error = if exclusions { self.exclusion_error } else { self.kind_error };
        let draft = &self.bundle_draft;
        let focused = draft.read(cx).focus_handle(cx).is_focused(window);
        let add_row = h_flex()
            .w_full()
            .gap(px(8.))
            .child(pill_menu("context.running", "Running app".into(), running, cx))
            .child(
                div()
                    .id("settings.contextField")
                    .flex_1()
                    .min_w_0()
                    .px(px(10.))
                    .h(px(30.))
                    .flex()
                    .items_center()
                    .bg(pl.surface)
                    .rounded(px(8.))
                    .border(px(if focused { 2. } else { 1. }))
                    .border_color(if focused { pl.accent } else { pl.line })
                    .test_support()
                    .child(Input::new(draft).aria_label("Bundle ID").accessibility_id("settings.contextBundleID").appearance(false)),
            )
            .when(!exclusions, |d| d.child(pill_menu("context.addKind", core::kind_title(self.add_category).into(), Self::pick_kinds(), cx)))
            .child(pill_button("settings.contextAdd", "Add", cx).disabled(blank).on_click(cx.listener(|this, _, w, cx| this.add_context_app(w, cx))));
        v_flex()
            .w(px(480.))
            .p(px(22.))
            .gap(px(18.))
            .child(
                v_flex()
                    .id("settings.contextHeader")
                    .gap(px(4.))
                    .child(t(if exclusions { "Excluded apps" } else { "App kinds" }).font(17., 500.))
                    .child(t(if exclusions { "App context is never read in these apps." } else { "Sets the kind of app used for writing style." }).size(13.).color(pl.muted))
                    .test_support(),
            )
            .child(list)
            .child(add_row)
            .when_some(error, |d, e| d.child(t(e).size(12.).color(pl.warning)))
            .child(
                h_flex().w_full().justify_end().child(
                    plain_button("settings.contextDone", "Done")
                        .content(div().px(px(18.)).py(px(10.)).rounded(px(8.)).bg(pl.ink).child(t("Done").font(15., 500.).color(pl.surface)))
                        .on_click(cx.listener(|this, _, _, cx| this.close_modal(cx))),
                ),
            )
    }

    fn app_row(&self, id: &str, exclusions: bool, kind: &str, last: bool, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let pl = pal(cx);
        let group_name = SharedString::from(format!("context.row.{id}"));
        let own = id == core::BUNDLE_ID;
        let bundle = id.to_string();
        let remove = pill_button(SharedString::from(format!("context.remove.{id}")), "Remove", cx)
            .a11y_label(if exclusions { format!("Stop excluding {id}") } else { format!("Use the built-in kind for {id}") })
            .on_click(cx.listener(move |this, _, _, cx| {
                if exclusions {
                    core::remove_exclusion(prefs_mut(cx), &bundle);
                } else {
                    core::set_kind(prefs_mut(cx), &bundle, None);
                }
                this.refresh(cx);
                cx.notify();
            }));
        let trailing = if exclusions && own {
            t("Always").size(12.).color(pl.muted).into_any_element()
        } else {
            h_flex()
                .gap(px(8.))
                .child(hover_revealed(group_name.clone(), false, div()).child(remove))
                .when(!exclusions, |d| d.child(pill_menu(SharedString::from(format!("context.kind.{id}")), core::kind_title(kind).into(), Self::pick_kinds(), cx)))
                .into_any_element()
        };
        h_flex()
            .group(group_name)
            .id(SharedString::from(format!("context.row.{id}")))
            .test_support()
            .w_full()
            .h(px(56.))
            .px(px(16.))
            .gap(px(12.))
            .when(!last, |d| d.border_b_1().border_color(pl.line))
            .child(div().size(px(24.)).flex_none().rounded(px(6.)).bg(pl.tint))
            .child(v_flex().flex_1().min_w_0().gap(px(2.)).child(t(id.to_string()).size(14.).lines(1)).child(t(id.to_string()).size(12.).color(pl.muted).lines(1)))
            .child(trailing)
    }
}

const EXCLUSION_ERROR: &str = "Enter a bundle ID such as com.example.App. At most 200 apps can be excluded.";
const KIND_ERROR: &str = "Enter a bundle ID such as com.example.App. At most 200 apps can have a kind.";

/// `DictionaryPillButtonStyle`: 13 regular on `button`.
fn pill_button(id: impl Into<ElementId>, label: &'static str, cx: &App) -> FlowButton {
    let pl = pal(cx);
    prototype_button(id, label).fill(pl.button)
}
