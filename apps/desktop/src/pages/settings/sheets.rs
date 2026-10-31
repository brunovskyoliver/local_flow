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
    TurnOff,
    /// `true` for the second speech model.
    Download(bool),
}

/// An installed app's name and icon, or the bundle ID and no icon.
#[derive(Clone)]
pub(crate) struct AppInfo {
    pub name: String,
    pub icon: Option<std::sync::Arc<Image>>,
}

impl SettingsPage {
    pub(super) fn open_modal(&mut self, modal: Modal, cx: &mut Context<Self>) {
        self.apps.borrow_mut().clear(); // One lookup per ID for the sheet's lifetime.
        self.modal = Some(modal);
        cx.notify();
    }

    /// `ContextApp.Cache`.
    fn app_info(&self, id: &str, cx: &App) -> AppInfo {
        self.apps
            .borrow_mut()
            .entry(id.to_string())
            .or_insert_with(|| {
                let services = &cx.global::<Core>().services;
                AppInfo { name: services.app_name(id).unwrap_or_else(|| id.to_string()), icon: services.app_icon_png(id).map(|png| std::sync::Arc::new(Image::from_bytes(ImageFormat::Png, png))) }
            })
            .clone()
    }

    fn close_modal(&mut self, cx: &mut Context<Self>) {
        // Consent's Cancel leaves nothing stored; the draft goes with it (done in `key` and on the button).
        self.modal = None;
        cx.notify();
    }

    /// `.confirmationDialog`. The switch stays on until Turn Off is answered.
    pub(super) fn prompt_turn_off(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        self.open_modal(Modal::TurnOff, cx);
    }

    /// `alternate` picks the second speech model's copy and action.
    pub(super) fn prompt_download(&mut self, alternate: bool, _window: &mut Window, cx: &mut Context<Self>) {
        self.open_modal(Modal::Download(alternate), cx);
    }

    fn confirm_alert(&mut self, cx: &mut Context<Self>) {
        let modal = self.modal.take();
        match modal {
            Some(Modal::TurnOff) => self.confirm_turn_off(cx),
            Some(Modal::Download(alternate)) => self.run(if alternate { "downloadAlternateSpeechModel" } else { "download" }, cx),
            _ => {}
        }
        cx.notify();
    }

    /// A macOS alert, 260 wide; the geometry is measured from `audit/mac/settings/turn-off-light-ref.png`.
    /// Its glass can't be drawn here, so the fill is what it averages to over the dimmed window, and
    /// the type is Figtree where AppKit's is SF.
    fn alert(&self, title: String, message: String, destructive: bool, action: &'static str, cx: &mut Context<Self>) -> impl IntoElement {
        let pl = pal(cx);
        let fill = if pl.mode.is_dark() { hsla(0., 0., 0.164, 0.92) } else { hsla(0., 0., 0.862, 0.96) };
        let confirm = if destructive { destructive_prompt_button("settings.alert.confirm", action) } else { prompt_button("settings.alert.confirm", action) };
        v_flex()
            .id("settings.alert")
            .test_support()
            .w(px(260.))
            .px(px(16.))
            .pt(px(21.))
            .pb(px(16.))
            .bg(fill)
            .rounded(px(26.))
            .border_1()
            .border_color(pl.ink.opacity(0.1))
            .shadow_lg()
            .child(div().px(px(6.)).child(t(title).font(13., 600.)))
            .child(div().px(px(6.)).pt(px(10.)).pb(px(16.)).child(t(message).size(13.)))
            .child(h_flex().w_full().justify_between().child(prompt_button("settings.alert.cancel", "Cancel").on_click(cx.listener(|this, _, _, cx| this.close_modal(cx)))).child(confirm.on_click(cx.listener(|this, _, _, cx| this.confirm_alert(cx)))))
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
            ("enter", Some(Modal::Download(_))) => self.confirm_alert(cx),
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
            Modal::TurnOff => self.alert("Turn off remote dictation?".into(), "This Mac's sign-in, device key and server pin are deleted. Your history stays. You will need approval again to turn it back on.".into(), true, "Turn Off", cx).into_any_element(),
            Modal::Download(alternate) => {
                let (title, message) = self.download_copy(alternate);
                self.alert(title, message, false, "Download", cx).into_any_element()
            }
        };
        if matches!(modal, Modal::TurnOff | Modal::Download(_)) {
            return Some(sheet_overlay("settings.modal", window, cx, body).into_any_element());
        }
        // The context sheet sets its own surface; the consent sheets stay on the native sheet's fill.
        let fill = if matches!(modal, Modal::Context(_)) { pl.surface } else { sheet_fill(cx) };
        Some(sheet_overlay("settings.modal", window, cx, div().id("settings.sheet").bg(fill).rounded(px(12.)).text_color(pl.ink).child(body).test_support()).into_any_element())
    }

    pub(super) fn download_copy(&self, alternate: bool) -> (String, String) {
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
            .child(input_surface("server.rack", Some("https://server.example.com"), Input::new(&self.server_draft).id("settings.remoteServerURL").aria_label("Server address").accessibility_id("settings.remoteServerURL"), &self.server_draft, window, cx))
            .child(div().id("settings.consentBody").w_full().child(t(text).size(13.).line_spacing(3.).swift_lines()).test_support())
            .when_some(origin.as_ref(), |d, o| d.child(t(format!("Server: {}", core::origin_host(o))).font(13., 500.)))
            .when_some(self.remote_error.clone(), |d, e| d.child(t(e).size(12.).color(pl.warning)))
            .child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.))
                    .child(sheet_button("settings.remoteConsentCancel", "Cancel", cx).on_click(cx.listener(|this, _, w, cx| this.cancel_consent(w, cx))))
                    .child(sheet_button("settings.remoteConsentConfirm", "Turn On", cx).disabled(origin.is_none()).on_click(cx.listener(|this, _, _, cx| this.confirm_consent(cx)))),
            )
    }

    fn consent_update(&self, cx: &mut Context<Self>) -> Div {
        let text = core::consent_text(prefs(cx));
        v_flex()
            .w(px(460.))
            .p(px(24.))
            .gap(px(16.))
            .child(t("Send summaries and meetings to your server?").font(17., 500.))
            .child(t(text).size(13.).line_spacing(3.).swift_lines())
            .child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.))
                    .child(sheet_button("settings.serverConsentCancel", "Cancel", cx).on_click(cx.listener(|this, _, _, cx| this.close_modal(cx))))
                    .child(sheet_button("settings.serverConsentConfirm", "Confirm", cx).on_click(cx.listener(|this, _, _, cx| this.confirm_consent_update(cx)))),
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
        let mut ids: Vec<String> = if exclusions { core::exclusions(p) } else { core::overrides(p).into_keys().collect() };
        if exclusions {
            ids.sort_by(|a, b| core::natural_cmp(&self.app_info(a, cx).name, &self.app_info(b, cx).name));
        }
        let overrides = core::overrides(p);
        let height = (ids.len() as f32 * 57.).min(308.);
        let list = if ids.is_empty() {
            div().w_full().py(px(28.)).flex().justify_center().rounded(px(12.)).border_1().border_color(pl.line).child(t("No apps yet").size(14.).color(pl.muted)).into_any_element()
        } else {
            let last = ids.len() - 1;
            let rows = ids.iter().enumerate().map(|(i, id)| {
                let current = overrides.get(id).map_or("other", String::as_str);
                let row = self.app_row(id, exclusions, current, window, cx);
                v_flex().child(row).when(i != last, |d| d.child(hairline(cx))).into_any_element()
            }).collect::<Vec<_>>();
            // `strokeBorder` overlays: the rows keep the full width, 56 high with a one-point line between.
            div()
                .w_full()
                .relative()
                .child(div().id("settings.contextList").w_full().h(px(height)).overflow_y_scroll().rounded(px(12.)).children(rows).test_support())
                .child(div().absolute().inset_0().rounded(px(12.)).border_1().border_color(pl.line))
                .into_any_element()
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
                    .text_size(px(13.))
                    .flex()
                    .items_center()
                    .bg(pl.surface)
                    .rounded(px(8.))
                    .border(px(if focused { 2. } else { 1. }))
                    .border_color(if focused { pl.accent } else { pl.line })
                    .test_support()
                    .child(div().flex_1().min_w_0().text_size(px(13.)).child(Input::new(draft).id("settings.contextBundleID").aria_label("Bundle ID").accessibility_id("settings.contextBundleID").appearance(false).px_0().text_size(px(13.)))),
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

    fn app_row(&self, id: &str, exclusions: bool, kind: &str, window: &Window, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let pl = pal(cx);
        let group_name = SharedString::from(format!("context.row.{id}"));
        let own = id == core::BUNDLE_ID;
        let bundle = id.to_string();
        let info = self.app_info(id, cx);
        let name = info.name.clone();
        let focus = self.remove_focus.borrow_mut().entry(id.to_string()).or_insert_with(|| cx.focus_handle()).clone();
        let remove = pill_button(SharedString::from(format!("context.remove.{id}")), "Remove", cx)
            .a11y_label(if exclusions { format!("Stop excluding {name}") } else { format!("Use the built-in kind for {name}") })
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
                .child(focus_revealed(group_name.clone(), self.voice_over, &focus, window, cx, div()).child(remove))
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
            .child(match info.icon {
                Some(icon) => img(icon).id(SharedString::from(format!("context.icon.{id}"))).size(px(24.)).flex_none().test_support().into_any_element(),
                None => div().size(px(24.)).flex_none().rounded(px(6.)).bg(pl.tint).into_any_element(),
            })
            .child(v_flex().flex_1().min_w_0().gap(px(2.)).child(t(info.name.clone()).size(14.).lines(1)).child(t(id.to_string()).size(12.).color(pl.muted).lines(1)))
            .child(trailing)
    }
}

const EXCLUSION_ERROR: &str = "Enter a bundle ID such as com.example.App. At most 200 apps can be excluded.";
const KIND_ERROR: &str = "Enter a bundle ID such as com.example.App. At most 200 apps can have a kind.";

/// A SwiftUI default `Button` in a sheet, which doesn't inherit the page's button style: 24 high,
/// 208 on white in light and 68 on 27 in dark, sampled from `audit/mac/settings/consent-*-ref.png`.
fn sheet_button(id: impl Into<ElementId>, label: &'static str, cx: &App) -> FlowButton {
    let pl = pal(cx);
    native_button(id, label).fill(pl.ink.opacity(0.2)).text_color(pl.ink)
}

/// `DictionaryPillButtonStyle`: 13 regular on `button`.
fn pill_button(id: impl Into<ElementId>, label: &'static str, cx: &App) -> FlowButton {
    let pl = pal(cx);
    prototype_button(id, label).fill(pl.button).content(t(label).size(13.).a11y_hidden())
}
