//! Users (Feature 028 US3, T046-T048): the server's users with their devices nested, the owner's
//! actions, "Add device for <user>", live tokens and the recent audit log. Shown only while server
//! mode is on. Reads go through `ServerHost` off the UI thread; a pairing token lives in this page's
//! memory until its sheet closes.
use crate::pages::Page;
use crate::pages::onboarding::server_mode::host;
use crate::pages::settings::{group, input_surface, prototype_button, row, val};
use crate::shell::Session;
use flow_core::server_admin::{Action, Kind, Model, ReadError};
use flow_core::server_mode::OwnerToken;
use flow_ui::gpui::base::TestSupportExt;
use flow_ui::prelude::*;
use std::time::{Duration, Instant};

/// FR-017: at least every 5 s while the page and its window are visible.
const POLL: Duration = Duration::from_secs(5);
/// How often the page checks whether a read is due; a check costs nothing while hidden.
const TICK: Duration = Duration::from_secs(1);
const AUDIT_SHOWN: usize = 20;

/// A read is due when the page and its window are visible and the last read is `POLL` old.
fn due(visible: bool, last: Option<Instant>, now: Instant) -> bool {
    visible && last.is_none_or(|at| now.saturating_duration_since(at) >= POLL)
}

/// The token sheet: for a user (`Some`) or, chosen explicitly, a new person (`None`).
pub(crate) struct Sheet {
    pub user: Option<(i64, String)>,
    pub token: Option<OwnerToken>,
    pub error: Option<String>,
}

impl Sheet {
    fn title(&self) -> String {
        match &self.user {
            Some((_, name)) => format!("Add device for {name}"),
            None => "Add a new person".into(),
        }
    }
    /// flowd's 1-64 byte label.
    fn label(&self) -> String {
        let text = match &self.user {
            Some((_, name)) => format!("Device for {name}"),
            None => "New person".into(),
        };
        let mut end = text.len().min(64);
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text[..end].to_string()
    }
}

pub struct UsersPage {
    pub(crate) model: Option<Result<Model, ReadError>>,
    loading: bool,
    pub(crate) last_read: Option<Instant>,
    pub(crate) reads: usize,
    busy: bool,
    message: Option<String>,
    new_name: Entity<InputState>,
    rename_name: Entity<InputState>,
    renaming: Option<(Kind, i64)>,
    pub(crate) sheet: Option<Sheet>,
    _poll: Task<()>,
}

impl UsersPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor().timer(TICK).await;
                if this.update_in(cx, |this, w, cx| this.tick(w, cx)).is_err() {
                    break;
                }
            }
        });
        UsersPage {
            model: None,
            loading: false,
            last_read: None,
            reads: 0,
            busy: false,
            message: None,
            new_name: cx.new(|cx| InputState::new(window, cx).placeholder("Name")),
            rename_name: cx.new(|cx| InputState::new(window, cx)),
            renaming: None,
            sheet: None,
            _poll: poll,
        }
    }

    /// Selected in the sidebar, server mode on, and the window on screen.
    fn visible(window: &Window, cx: &App) -> bool {
        window.is_visible() && cx.try_global::<Session>().is_some_and(|s| s.selection == Page::Users) && host(cx).is_some_and(|h| h.enabled())
    }

    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if due(Self::visible(window, cx), self.last_read, cx.background_executor().now()) {
            self.load(None, cx);
        }
    }

    /// Runs `action` if any, then reads the page again at once.
    fn load(&mut self, action: Option<Action>, cx: &mut Context<Self>) {
        let Some(host) = host(cx) else { return };
        if self.loading {
            return;
        }
        (self.loading, self.last_read, self.busy) = (true, Some(cx.background_executor().now()), action.is_some());
        self.reads += 1;
        cx.spawn(async move |this, cx| {
            let (failed, page) = cx.background_spawn(async move { (action.and_then(|a| host.admin_act(&a).err()), host.users_page()) }).await;
            let _ = this.update(cx, |this, cx| {
                (this.loading, this.busy) = (false, false);
                if failed.is_some() {
                    this.message = failed;
                }
                this.model = Some(page);
                cx.notify();
            });
        })
        .detach();
    }

    fn act(&mut self, action: Action, cx: &mut Context<Self>) {
        if self.busy || self.loading {
            return;
        }
        self.message = None;
        self.load(Some(action), cx);
        cx.notify();
    }

    /// Revoke and reject ask first, as they cut a person or device off.
    fn confirm(&mut self, action: Action, name: String, window: &mut Window, cx: &mut Context<Self>) {
        let (title, detail, button) = match &action {
            Action::Reject(_) => (format!("Reject {name}?"), "This person can't use the server.", "Reject"),
            _ => (format!("Revoke {name}?"), "Its connections close at once and it can't reconnect.", "Revoke"),
        };
        let buttons = [PromptButton::Other(button.into()), PromptButton::Cancel("Cancel".into())];
        let answer = window.prompt(PromptLevel::Warning, &title, Some(detail), &buttons, cx);
        cx.spawn(async move |this, cx| {
            if answer.await == Ok(0) {
                let _ = this.update(cx, |this, cx| this.act(action, cx));
            }
        })
        .detach();
    }

    fn create_user(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let name = val(&self.new_name, cx).trim().to_string();
        if name.is_empty() {
            return;
        }
        self.new_name.update(cx, |s, cx| s.set_value("", window, cx));
        self.act(Action::CreateUser(name), cx);
    }

    fn start_rename(&mut self, kind: Kind, id: i64, current: String, window: &mut Window, cx: &mut Context<Self>) {
        self.renaming = Some((kind, id));
        self.rename_name.update(cx, |s, cx| s.set_value(current, window, cx));
        cx.notify();
    }

    fn save_rename(&mut self, cx: &mut Context<Self>) {
        let Some((kind, id)) = self.renaming.take() else { return };
        let name = val(&self.rename_name, cx).trim().to_string();
        if !name.is_empty() {
            self.act(Action::Rename(kind, id, name), cx);
        }
        cx.notify();
    }

    pub(crate) fn open_sheet(&mut self, user: Option<(i64, String)>, cx: &mut Context<Self>) {
        self.sheet = Some(Sheet { user, token: None, error: None });
        cx.notify();
    }

    /// `token create` with `--user` for the sheet's user; without only for "New person".
    pub(crate) fn create_token(&mut self, cx: &mut Context<Self>) {
        let (Some(host), Some(sheet)) = (host(cx), self.sheet.as_ref()) else { return };
        if self.busy {
            return;
        }
        self.busy = true;
        let (label, user) = (sheet.label(), sheet.user.as_ref().map(|(id, _)| *id));
        cx.spawn(async move |this, cx| {
            let token = cx
                .background_spawn(async move {
                    let status = host.status();
                    let origins: Vec<String> = host.addresses(status.listen.as_deref()).into_iter().map(|a| a.origin).collect();
                    let token = host.create_device_token(&label, user, &origins);
                    (token, host.users_page())
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.busy = false;
                let (token, page) = token;
                if let Some(sheet) = this.sheet.as_mut() {
                    match token {
                        Ok(token) => (sheet.token, sheet.error) = (Some(token), None),
                        Err(e) => sheet.error = Some(e),
                    }
                }
                this.model = Some(page);
                this.last_read = Some(cx.background_executor().now());
                cx.notify();
            });
        })
        .detach();
    }

    /// Closing the sheet drops the token; nothing else holds it.
    fn close_sheet(&mut self, cx: &mut Context<Self>) {
        self.sheet = None;
        cx.notify();
    }

    fn heading(text: &'static str) -> impl IntoElement {
        div().pt(px(24.)).pb(px(8.)).child(t(text).font(14., 500.))
    }

    fn state_line(state: &str, extra: &[String]) -> String {
        let mut parts = vec![capitalised(state)];
        parts.extend(extra.iter().cloned());
        parts.join(" · ")
    }

    fn rename_row(&self, window: &Window, cx: &mut Context<Self>) -> impl IntoElement {
        let field = input_surface("text.insert", None, Input::new(&self.rename_name).id("users.renameField").aria_label("New name").accessibility_id("users.renameField"), &self.rename_name, window, cx);
        h_flex()
            .w_full()
            .gap(px(8.))
            .pb(px(12.))
            .child(div().flex_1().child(field))
            .child(prototype_button("users.renameSave", "Save").on_click(cx.listener(|this, _, _, cx| this.save_rename(cx))))
            .child(prototype_button("users.renameCancel", "Cancel").on_click(cx.listener(|this, _, _, cx| {
                this.renaming = None;
                cx.notify();
            })))
    }

    fn user_card(&self, user: &flow_core::server_admin::User, window: &Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let busy = self.busy;
        let (id, name) = (user.id, user.name.clone());
        let mut buttons = h_flex().gap(px(6.));
        if user.state == "pending" || user.state == "rejected" {
            buttons = buttons.child(prototype_button(SharedString::from(format!("users.approve.user.{id}")), "Approve").disabled(busy).on_click(cx.listener(move |this, _, _, cx| this.act(Action::Approve(Kind::User, id), cx))));
        }
        if user.state == "pending" {
            let n = name.clone();
            buttons = buttons.child(prototype_button(SharedString::from(format!("users.reject.user.{id}")), "Reject…").disabled(busy).on_click(cx.listener(move |this, _, w, cx| this.confirm(Action::Reject(id), n.clone(), w, cx))));
        }
        if user.state != "revoked" {
            let n = name.clone();
            buttons = buttons.child(prototype_button(SharedString::from(format!("users.revoke.user.{id}")), "Revoke…").disabled(busy).on_click(cx.listener(move |this, _, w, cx| this.confirm(Action::Revoke(Kind::User, id), n.clone(), w, cx))));
        }
        let n = name.clone();
        buttons = buttons.child(prototype_button(SharedString::from(format!("users.rename.user.{id}")), "Rename…").disabled(busy).on_click(cx.listener(move |this, _, w, cx| this.start_rename(Kind::User, id, n.clone(), w, cx))));
        if user.state == "approved" {
            let n = name.clone();
            buttons = buttons.child(prototype_button(SharedString::from(format!("users.addDevice.{id}")), "Add device…").disabled(busy).on_click(cx.listener(move |this, _, _, cx| this.open_sheet(Some((id, n.clone())), cx))));
        }
        let detail = Self::state_line(&user.state, &[format!("Signs in with {}", user.sign_in), format!("Created {}", user.created)]);
        let mut card = group(cx).id(SharedString::from(format!("users.user.{id}"))).mb(px(12.)).child(row(user.name.clone(), Some(detail), buttons, cx));
        if self.renaming == Some((Kind::User, id)) {
            card = card.child(self.rename_row(window, cx));
        }
        for device in &user.devices {
            card = card.child(hairline(cx)).child(self.device_row(device, window, cx));
        }
        if user.devices.is_empty() {
            card = card.child(hairline(cx)).child(div().py(px(12.)).child(t("No devices yet.").size(12.).color(p.muted)));
        }
        card.test_support()
    }

    fn device_row(&self, device: &flow_core::server_admin::Device, window: &Window, cx: &mut Context<Self>) -> impl IntoElement {
        let busy = self.busy;
        let (id, name) = (device.id, device.name.clone());
        let mut extra = vec![device.kind.to_string(), device.activity.clone(), format!("Added {}", device.added)];
        if let Some(by) = &device.invited_by {
            extra.push(format!("from {by}"));
        }
        let mut buttons = h_flex().gap(px(6.));
        if device.state == "pending" {
            buttons = buttons.child(prototype_button(SharedString::from(format!("users.approve.device.{id}")), "Approve").disabled(busy).on_click(cx.listener(move |this, _, _, cx| this.act(Action::Approve(Kind::Device, id), cx))));
        }
        if device.state != "revoked" {
            let n = name.clone();
            buttons = buttons.child(prototype_button(SharedString::from(format!("users.revoke.device.{id}")), "Revoke…").disabled(busy).on_click(cx.listener(move |this, _, w, cx| this.confirm(Action::Revoke(Kind::Device, id), n.clone(), w, cx))));
        }
        let n = name.clone();
        buttons = buttons.child(prototype_button(SharedString::from(format!("users.rename.device.{id}")), "Rename…").disabled(busy).on_click(cx.listener(move |this, _, w, cx| this.start_rename(Kind::Device, id, n.clone(), w, cx))));
        v_flex()
            .id(SharedString::from(format!("users.device.{id}")))
            .w_full()
            .pl(px(20.))
            .child(row(device.name.clone(), Some(Self::state_line(&device.state, &extra)), buttons, cx))
            .when(self.renaming == Some((Kind::Device, id)), |d| d.child(self.rename_row(window, cx)))
            .test_support()
    }

    fn sheet_card(&self, sheet: &Sheet, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let explanation = match &sheet.user {
            Some((_, name)) => format!("The token adds one device to {name}. It works once and expires in 24 hours."),
            None => "The token creates a new person with one device. It works once and expires in 24 hours.".into(),
        };
        let mut card = group(cx)
            .id("users.sheet")
            .py(px(12.))
            .gap(px(8.))
            .mb(px(12.))
            .child(t(sheet.title()).font(15., 600.))
            .child(t(explanation).size(12.).color(p.muted));
        if let Some(token) = &sheet.token {
            card = card
                .child(div().id("users.sheetToken").child(t("Pairing token").size(14.)).child(t(token.token.clone()).size(12.).mono().selectable()).test_support())
                .child(div().id("users.sheetLink").child(t(token.link.clone()).size(12.).color(p.muted).selectable()).test_support())
                .child(div().id("users.sheetQr").children(flow_ui::qr::qr_code("users.sheetQrCode", &token.link, 160., "Pairing QR code")).test_support());
        } else {
            card = card.child(prototype_button("users.sheetCreate", "Create token").disabled(self.busy).on_click(cx.listener(|this, _, _, cx| this.create_token(cx))));
        }
        if let Some(error) = &sheet.error {
            card = card.child(t(error.clone()).size(12.).color(p.warning));
        }
        card.child(h_flex().child(prototype_button("users.sheetDone", if sheet.token.is_some() { "Done" } else { "Cancel" }).on_click(cx.listener(|this, _, _, cx| this.close_sheet(cx))))).test_support()
    }

    fn tokens(&self, model: &Model, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let mut list = group(cx).id("users.tokens");
        if model.tokens.is_empty() {
            list = list.child(div().py(px(12.)).child(t("No active tokens.").size(12.).color(p.muted)));
        }
        for (i, token) in model.tokens.iter().enumerate() {
            let id = token.id;
            let target = token.target.clone().map_or("New person".to_string(), |n| format!("For {n}"));
            let revoke = prototype_button(SharedString::from(format!("users.revoke.token.{id}")), "Revoke").disabled(self.busy).on_click(cx.listener(move |this, _, _, cx| this.act(Action::RevokeToken(id), cx)));
            if i > 0 {
                list = list.child(hairline(cx));
            }
            list = list.child(row(token.label.clone(), Some(format!("{target} · Expires {}", token.expires)), revoke, cx));
        }
        list.test_support()
    }

    fn audit(&self, model: &Model, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let mut list = group(cx).id("users.audit").py(px(8.)).gap(px(4.));
        if model.audit.is_empty() {
            list = list.child(t("Nothing yet.").size(12.).color(p.muted));
        }
        for entry in model.audit.iter().take(AUDIT_SHOWN) {
            let target = entry.target.as_deref().map(|t| format!(" {t}")).unwrap_or_default();
            let line = format!("{}  {} {}{} — {}", flow_core::server_admin::when(&entry.at), entry.actor, entry.action, target, entry.outcome);
            list = list.child(t(line).size(12.).mono().color(p.muted).selectable());
        }
        list.test_support()
    }
}

fn capitalised(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().chain(c).collect()).unwrap_or_default()
}

impl Render for UsersPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let mut column = v_flex().w_full().child(div().id("users.pageTitle").child(t("Users").font(26., 500.).tracking(-0.4)).test_support());
        let field = input_surface("person.badge.plus", None, Input::new(&self.new_name).id("users.newName").aria_label("New user's name").accessibility_id("users.newName"), &self.new_name, window, cx);
        column = column.child(
            h_flex()
                .w_full()
                .pt(px(16.))
                .gap(px(8.))
                .child(div().flex_1().child(field))
                .child(prototype_button("users.create", "Create user").disabled(self.busy).on_click(cx.listener(|this, _, w, cx| this.create_user(w, cx))))
                .child(prototype_button("users.newPerson", "New person…").disabled(self.busy).on_click(cx.listener(|this, _, _, cx| this.open_sheet(None, cx)))),
        );
        if let Some(message) = &self.message {
            column = column.child(div().id("users.message").pt(px(8.)).child(t(message.clone()).size(12.).color(p.warning)).test_support());
        }
        if let Some(sheet) = &self.sheet {
            column = column.child(div().pt(px(16.)).child(self.sheet_card(sheet, cx)));
        }
        match &self.model {
            None => column = column.child(div().pt(px(24.)).child(t("Loading…").size(13.).color(p.muted))),
            Some(Err(e)) => column = column.child(div().id("users.error").pt(px(24.)).child(t(e.text()).size(13.).color(p.warning)).test_support()),
            Some(Ok(model)) => {
                let model = model.clone();
                column = column.child(Self::heading("People and devices"));
                if model.truncated {
                    column = column.child(div().id("users.truncated").pb(px(8.)).child(t("Showing the first 500 devices.").size(12.).color(p.muted)).test_support());
                }
                for user in &model.users {
                    column = column.child(self.user_card(user, window, cx));
                }
                column = column.child(Self::heading("Active tokens")).child(self.tokens(&model, cx)).child(Self::heading("Recent activity")).child(self.audit(&model, cx));
            }
        }
        prototype_page("users.page", 860., cx, column)
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::Core;
    use crate::shell::{ensure_session, update_session};
    use crate::testing::{assert_saw, boot, saw};
    use flow_core::server_admin::{decode_audit, decode_list, decode_tokens, merge, parse_time};
    use flow_platform::FakeServer;
    use flow_ui::test::{TestAppContext, TestWindowExt};
    use std::sync::Arc;

    type Win = WindowHandle<UsersPage>;

    /// flowd's captured output (T044's fixtures), with Ana's MacBook connected.
    fn fixture_model() -> Model {
        let list = decode_list(0, include_str!("../../../../fixtures/server-admin/list.json"), "").unwrap();
        let tokens = decode_tokens(0, include_str!("../../../../fixtures/server-admin/tokens.json"), "").unwrap();
        let audit = decode_audit(0, include_str!("../../../../fixtures/server-admin/audit.json"), "").unwrap();
        merge(list, &[1].into(), tokens, audit, parse_time("2026-11-04T12:00:00Z").unwrap())
    }

    fn server(cx: &mut TestAppContext, enabled: bool) -> Arc<FakeServer> {
        let server = Arc::new(FakeServer::default());
        *server.enabled.lock().unwrap() = enabled;
        *server.page.lock().unwrap() = Ok(fixture_model());
        let host: Arc<dyn flow_platform::ServerHost> = server.clone();
        cx.update(|cx| cx.global_mut::<Core>().server = Some(host));
        server
    }

    fn frame(cx: &mut TestAppContext, win: Win) {
        cx.run_until_parked();
        flow_ui::probe::clear();
        cx.update_window(win.into(), |_, w, cx| w.render_frame(cx)).unwrap();
    }

    /// Advances the fake clock, letting the poll run.
    fn wait(cx: &mut TestAppContext, win: Win, secs: u64) {
        for _ in 0..secs {
            cx.executor().advance_clock(TICK);
            cx.run_until_parked();
        }
        frame(cx, win);
    }

    fn click(cx: &mut TestAppContext, win: Win, id: &str) {
        let id = SharedString::from(id.to_string());
        cx.update_window(win.into(), |_, w, cx| w.click(id, cx)).unwrap();
        frame(cx, win);
    }

    fn answer(cx: &mut TestAppContext, win: Win, button: &str) {
        cx.simulate_prompt_answer(button);
        frame(cx, win);
    }

    /// The page in its own window, selected, with server mode on; the first poll has read it.
    fn rig(cx: &mut TestAppContext) -> (Win, Arc<FakeServer>) {
        boot(cx, Mode::Light);
        cx.update(ensure_session);
        cx.update(|cx| update_session(cx, |s| s.selection = Page::Users));
        let server = server(cx, true);
        let bounds = Bounds::new(point(px(0.), px(0.)), size(px(1100.), px(4000.)));
        let win = cx.update(|cx| cx.open_window(WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..Default::default() }, |w, cx| cx.new(|cx| UsersPage::new(w, cx)))).unwrap();
        wait(cx, win, 1);
        (win, server)
    }

    fn reads(cx: &mut TestAppContext, win: Win) -> usize {
        win.update(cx, |p, _, _| p.reads).unwrap()
    }

    fn calls_after_users(server: &FakeServer) -> Vec<String> {
        server.calls().into_iter().filter(|c| c != "users").collect()
    }

    // parity: SET-427
    /// T046: each user with name, sign-in kind, state and created date; devices nested with name,
    /// kind, how recently it was active, when it was added and who added it.
    #[flow_ui::gpui::test]
    async fn lists_users_with_their_devices(cx: &mut TestAppContext) {
        let (win, _) = rig(cx);
        use flow_core::server_admin::when;
        let created = format!("Approved · Signs in with Token · Created {}", when("2026-11-04T17:17:00Z"));
        assert_saw(&["Ana B", created.as_str(), "User 2", "Pending · Signs in with Apple"]);
        let mac = format!("Approved · Mac · Connected now · Added {}", when("2026-11-03T10:00:00Z"));
        assert_saw(&["Ana's MacBook", mac.as_str()]);
        let phone = format!("Pending · iPhone · Never active · Added {} · from Ana's MacBook", when("2026-11-03T10:02:00Z"));
        assert_saw(&["Ana's iPhone", phone.as_str()]);
        assert_saw(&["Old PC", "Revoked · Unknown"]);
        let has = |cx: &mut TestAppContext, id: &'static str| win.update(cx, |_, w, _| w.try_find(id).is_some()).unwrap();
        assert!(has(cx, "users.approve.device.2") && !has(cx, "users.approve.device.1"));
        assert!(!has(cx, "users.revoke.device.3"), "already revoked");
        assert!(has(cx, "users.reject.user.2") && !has(cx, "users.reject.user.1"));
        assert!(has(cx, "users.addDevice.1") && !has(cx, "users.addDevice.2"), "only an approved user gets devices");
    }

    // parity: SET-428
    /// T046: approve, reject, revoke, rename and create, each followed by a read at once.
    #[flow_ui::gpui::test]
    async fn actions_reach_the_server_and_reload(cx: &mut TestAppContext) {
        let (win, server) = rig(cx);
        let before = reads(cx, win);
        click(cx, win, "users.approve.device.2");
        assert_eq!(reads(cx, win), before + 1, "reloaded without waiting for the poll");
        assert_eq!(server.calls().last().map(String::as_str), Some("users"));
        click(cx, win, "users.approve.user.2");
        click(cx, win, "users.reject.user.2");
        answer(cx, win, "Reject");
        click(cx, win, "users.revoke.device.1");
        answer(cx, win, "Cancel");
        click(cx, win, "users.revoke.device.1");
        answer(cx, win, "Revoke");
        click(cx, win, "users.revoke.user.1");
        answer(cx, win, "Revoke");
        click(cx, win, "users.rename.device.2");
        let field = win.update(cx, |p, _, _| p.rename_name.clone()).unwrap();
        assert_eq!(cx.update(|cx| val(&field, cx)), "Ana's iPhone");
        cx.update_window(win.into(), |_, w, cx| field.update(cx, |s, cx| s.set_value("Phone", w, cx))).unwrap();
        click(cx, win, "users.renameSave");
        let field = win.update(cx, |p, _, _| p.new_name.clone()).unwrap();
        cx.update_window(win.into(), |_, w, cx| field.update(cx, |s, cx| s.set_value("  Ben ", w, cx))).unwrap();
        click(cx, win, "users.create");
        click(cx, win, "users.revoke.token.2");
        assert_eq!(
            calls_after_users(&server),
            ["Approve(Device, 2)", "Approve(User, 2)", "Reject(2)", "Revoke(Device, 1)", "Revoke(User, 1)", "Rename(Device, 2, \"Phone\")", "CreateUser(\"Ben\")", "RevokeToken(2)"]
        );
    }

    // parity: SET-429
    /// T047: "Add device for <user>" passes that user; "New person" is its own choice. The token
    /// shows as text, link and QR, and goes with the sheet.
    #[flow_ui::gpui::test]
    async fn add_device_targets_the_user_by_default(cx: &mut TestAppContext) {
        let (win, server) = rig(cx);
        let expires = format!("New person · Expires {}", flow_core::server_admin::when("2026-12-03T10:00:00Z"));
        assert_saw(&["Active tokens", "Ben", expires.as_str(), "For Ana", "For Ana B", "Recent activity", "admin:oliver rename user:1 — ok"]);
        click(cx, win, "users.addDevice.1");
        assert_saw(&["Add device for Ana B", "adds one device to Ana B"]);
        click(cx, win, "users.sheetCreate");
        assert_eq!(calls_after_users(&server), ["token Device for Ana B user Some(1)"]);
        assert_saw(&["lfp_fake", "localflow://pair?token=lfp_fake"]);
        assert!(win.update(cx, |_, w, _| w.try_find("users.sheetQr").is_some()).unwrap());
        click(cx, win, "users.sheetDone");
        assert!(win.update(cx, |p, _, _| p.sheet.is_none()).unwrap());
        assert!(!saw("lfp_fake"), "the token is gone with the sheet");
        click(cx, win, "users.newPerson");
        assert_saw(&["Add a new person"]);
        click(cx, win, "users.sheetCreate");
        assert_eq!(calls_after_users(&server).last().map(String::as_str), Some("token New person user None"));
    }

    // parity: SET-430
    /// T048 (FR-017): every 5 s while the page and its window are visible, never while either is hidden.
    #[flow_ui::gpui::test]
    async fn polls_only_while_visible(cx: &mut TestAppContext) {
        let (win, _) = rig(cx);
        assert_eq!(reads(cx, win), 1, "read as soon as it shows");
        wait(cx, win, 4);
        assert_eq!(reads(cx, win), 1);
        wait(cx, win, 1);
        assert_eq!(reads(cx, win), 2, "5 s later");
        cx.simulate_window_visibility_change(win.into(), WindowVisibility::Hidden);
        wait(cx, win, 30);
        assert_eq!(reads(cx, win), 2, "window hidden");
        cx.simulate_window_visibility_change(win.into(), WindowVisibility::Visible);
        cx.update(|cx| update_session(cx, |s| s.selection = Page::History));
        wait(cx, win, 30);
        assert_eq!(reads(cx, win), 2, "another page selected");
        cx.update(|cx| update_session(cx, |s| s.selection = Page::Users));
        wait(cx, win, 1);
        assert_eq!(reads(cx, win), 3, "back on the page");
    }

    // parity: SET-430
    #[test]
    fn due_rules() {
        let now = Instant::now();
        assert!(due(true, None, now));
        assert!(!due(false, None, now));
        assert!(!due(true, Some(now - Duration::from_secs(4)), now));
        assert!(due(true, Some(now - POLL), now));
        assert!(!due(false, Some(now - Duration::from_secs(60)), now));
    }

    // parity: SET-431
    /// An old flowd and a page that never read: the reason, not a list.
    #[flow_ui::gpui::test]
    async fn an_old_server_needs_updating(cx: &mut TestAppContext) {
        let (win, server) = rig(cx);
        *server.page.lock().unwrap() = Err(ReadError::NeedsUpdate);
        wait(cx, win, 5);
        assert_saw(&["This server needs updating"]);
        assert!(!saw("Ana B"));
    }

    // parity: SET-426
    /// US3 scenario 5: the sidebar shows Users only while server mode is on.
    #[flow_ui::gpui::test]
    async fn the_sidebar_shows_users_only_in_server_mode(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            crate::menu::init(cx);
            cx.global_mut::<Core>().prefs.set("setupVersion", 1);
        });
        let shell = cx.add_window(crate::shell::Shell::new);
        let has = |cx: &mut TestAppContext| {
            cx.run_until_parked();
            cx.update_window(shell.into(), |_, w, cx| w.render_frame(cx)).unwrap();
            shell.update(cx, |_, w, _| w.try_find("navigation.users").is_some()).unwrap()
        };
        assert!(!has(cx), "no server host: Windows, Intel Macs");
        let server = server(cx, false);
        assert!(!has(cx), "server mode off");
        *server.enabled.lock().unwrap() = true;
        cx.update(|cx| update_session(cx, |_| {}));
        assert!(has(cx));
        cx.update_window(shell.into(), |_, w, cx| w.click("navigation.users", cx)).unwrap();
        assert_eq!(cx.update(|cx| cx.global::<Session>().selection), Page::Users);
    }
}
