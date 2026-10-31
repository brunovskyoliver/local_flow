//! Row-by-row checks from the full review of inventory 03: labels, type, colours, symbols, menu
//! options and the branches the section tests don't reach.
use super::*;
use flow_ui::gpui::Role;
use flow_ui::probe::{self, style_of, symbols};

fn style(text: &str) -> probe::TextStyle {
    style_of(text).unwrap_or_else(|| panic!("{text:?} was not laid out"))
}
fn assert_type(text: &str, size: f32, weight: f32, color: Hsla) {
    let s = style(text);
    assert_eq!((s.size, s.weight, s.color), (size, weight, color), "{text:?}");
}
fn palette(cx: &mut TestAppContext) -> flow_ui::tokens::Palette {
    cx.update(|cx| pal(cx))
}
fn label(cx: &mut TestAppContext, win: Win, id: &'static str) -> String {
    win.update(cx, |_, w, _| w.find(id).label().unwrap_or_default().to_string()).unwrap()
}
fn checked(cx: &mut TestAppContext, win: Win, id: &'static str) -> bool {
    win.update(cx, |_, w, _| w.find(id).checked().unwrap_or(false)).unwrap()
}
fn assert_symbols(names: &[&str]) {
    let drawn = symbols();
    for name in names {
        assert!(drawn.iter().any(|s| s == name), "no symbol {name:?} in {drawn:?}");
    }
}
/// Opens the control's menu and returns what it offers, in order. Esc closes it again.
fn menu(cx: &mut TestAppContext, win: Win, id: &'static str) -> Vec<String> {
    click(cx, win, id);
    let items = win.update(cx, |_, w, _| w.find_all_by_role(Role::MenuItem).iter().filter_map(|e| e.label().map(String::from)).collect::<Vec<_>>()).unwrap();
    cx.update_window(win.into(), |_, w, cx| w.press("escape", cx)).unwrap();
    frame(cx, win);
    items
}
/// Clicks a menu item, the path a person takes through `dropdown_menu`.
fn choose(cx: &mut TestAppContext, win: Win, id: &'static str, item: &str) {
    click(cx, win, id);
    let target = win.update(cx, |_, w, _| w.find_all_by_role(Role::MenuItem).iter().find(|e| e.label() == Some(item)).map(|e| e.bounds().center())).unwrap().unwrap_or_else(|| panic!("no menu item {item:?}"));
    cx.update_window(win.into(), |_, w, cx| {
        w.drag(target, target, cx);
    })
    .unwrap();
    frame(cx, win);
}
fn press(cx: &mut TestAppContext, win: Win, key: &str) {
    cx.update_window(win.into(), |_, w, cx| w.press(key, cx)).unwrap();
    frame(cx, win);
}

// MARK: Page

// parity: SET-004
#[flow_ui::gpui::test]
async fn section_titles_are_14_medium(cx: &mut TestAppContext) {
    let _r = rig(cx, "", |_| {});
    let ink = palette(cx).ink;
    assert_type("General", 14., 500., ink);
    let s = style("Updates");
    assert_eq!((s.size, s.weight), (14., 500.));
    let (outer, text) = (bounds(cx, _r.win, "settings.section.General"), bounds(cx, _r.win, "settings.section.General.text"));
    assert_eq!((text.top() - outer.top(), outer.bottom() - text.bottom()), (px(29.), px(13.)), "padding");
}

// parity: SET-015
#[flow_ui::gpui::test]
async fn the_page_takes_focus_from_a_field(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    let page = read(cx, r.win, |p, _| p.focus.clone());
    let focused = |cx: &mut TestAppContext, h: &FocusHandle| cx.update_window(r.win.into(), |_, w, _| h.is_focused(w)).unwrap();
    assert!(focused(cx, &page), "default focus is the page, not the first field");
    let field = read(cx, r.win, |p, cx| p.endpoint.read(cx).focus_handle(cx));
    set(cx, r.win, |_, w, cx| field.focus(w, cx));
    assert!(!focused(cx, &page));
    press(cx, r.win, "escape");
    assert!(focused(cx, &page), "Esc");
    set(cx, r.win, |_, w, cx| field.focus(w, cx));
    click(cx, r.win, "settings.section.General");
    assert!(focused(cx, &page), "a click on empty page space");
}

// parity: SET-016
#[flow_ui::gpui::test]
async fn refresh_assigns_only_a_changed_snapshot(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    let notified = Rc::new(Cell::new(0));
    let n = notified.clone();
    let _sub = cx.update(|cx| cx.observe(&r.win.entity(cx).unwrap(), move |_, _| n.set(n.get() + 1)));
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    let first = notified.get();
    r.win.update(cx, |p, _, cx| p.refresh(cx)).unwrap();
    cx.run_until_parked();
    assert_eq!(notified.get(), first, "the same state doesn't notify");
    r.permissions.set(PermissionState::Granted);
    r.win.update(cx, |p, _, cx| p.refresh(cx)).unwrap();
    cx.run_until_parked();
    assert!(notified.get() > first, "a changed one does");
}

// parity: SET-023
#[flow_ui::gpui::test]
async fn recording_error_sits_above_the_general_error(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    set(cx, r.win, |p, _, _| {
        p.recording_error = Some("Recording failed".into());
        p.error = Some("Action failed".into());
    });
    let warning = palette(cx).warning;
    assert_type("Recording failed", 14., 400., warning);
    let (rec, general) = (bounds(cx, r.win, "settings.recordingError"), bounds(cx, r.win, "settings.error"));
    assert!(rec.top() < general.top(), "recording error, then general error");
    assert_eq!(general.top() - rec.bottom(), px(16.), "padding top 16");
    // Only the general line selects (SET-024): a drag over the recording line copies nothing.
    let selected = cx.update_window(r.win.into(), |_, w, cx| {
        w.drag(point(rec.left() + px(1.), rec.center().y), point(rec.left() + px(300.), rec.center().y), cx);
        base::TextSelection::selected_text(w, cx)
    })
    .unwrap();
    assert_eq!(selected, "");
}

// parity: SET-025
#[flow_ui::gpui::test]
async fn run_is_ignored_while_performing_and_clears_the_error(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    set(cx, r.win, |p, _, _| p.performing = true);
    set(cx, r.win, |p, _, cx| p.run("first", cx));
    assert!(!logged(&r, "action first"), "ignored while performing");
    set(cx, r.win, |p, _, _| {
        p.performing = false;
        p.error = Some("Old".into());
    });
    set(cx, r.win, |p, _, cx| p.run("second", cx));
    assert!(logged(&r, "action second"));
    assert_eq!(read(cx, r.win, |p, _| p.error.clone()), None, "cleared at the start of a run");
    assert!(!read(cx, r.win, |p, _| p.performing));
    r.ok.set(false);
    set(cx, r.win, |p, _, cx| p.run("third", cx));
    assert_eq!(read(cx, r.win, |p, _| p.error.clone()).as_deref(), Some("Error type flow_platform.Unavailable, code 0."), "mapped through describe");
}

// MARK: Server, setup details

fn pinned(p: &mut flow_core::prefs::Prefs) {
    p.set("remote.enabled", true);
    p.set("remote.serverURL", "https://flow.example.com");
    p.set("remote.state", "pinned");
    p.set("remote.consentVersion", 2);
}

// parity: SET-053 SET-054 SET-055 SET-056 SET-057
#[flow_ui::gpui::test]
async fn fetched_identity_reads_with_swifts_type(cx: &mut TestAppContext) {
    let r = rig(cx, "pending", |_| {});
    let pl = palette(cx);
    let key = core::base64url_encode(&[7u8; 32]);
    set(cx, r.win, |p, _, _| p.identity = Some(identity(&key, "aaaa-bbbb")));
    assert_type("Server fingerprint", 12., 500., pl.muted);
    assert_eq!(style("aaaa-bbbb").size, 13., "fingerprint value");
    assert!(has(cx, r.win, "settings.remoteFingerprint"));
    assert_type("Compare it with flowd admin identity on the server before trusting it.", 12., 400., pl.muted);
    assert_eq!(label(cx, r.win, "settings.remoteTrust"), "Trust This Server");
    let (details, value) = (bounds(cx, r.win, "settings.setupDetails"), bounds(cx, r.win, "settings.remoteFingerprint"));
    let row = bounds(cx, r.win, "settings.row.Remote dictation");
    assert_eq!(details.top() - row.bottom(), px(1.), "one point line above");
    assert_eq!(details.size.width, row.size.width, "full width");
    let caption = bounds(cx, r.win, "settings.remoteFingerprintLabel");
    assert_eq!((caption.top() - details.top(), value.top() - caption.bottom()), (px(16.), px(12.)), "padding 16, spacing 12");
    let trust = bounds(cx, r.win, "settings.remoteTrust");
    assert_eq!(details.bottom() - trust.bottom(), px(16.), "bottom padding 16");
    assert_eq!(trust.left(), details.left(), "leading");
}

// parity: SET-058
#[flow_ui::gpui::test]
async fn trust_refuses_a_key_that_does_not_validate(cx: &mut TestAppContext) {
    let r = rig(cx, "pending", |_| {});
    set(cx, r.win, |p, _, _| p.identity = Some(identity("not-a-key", "fp")));
    click(cx, r.win, "settings.remoteTrust");
    assert_saw(&["The server identity could not be saved."]);
    assert_eq!(pref_s(cx, "remote.state").as_deref(), Some("pending"), "state unmoved");
    assert!(r.log.borrow().is_empty(), "no credential touched: {:?}", r.log.borrow());
}

// parity: SET-060 SET-061 SET-062
#[flow_ui::gpui::test]
async fn sign_in_buttons_follow_state_google_and_busy(cx: &mut TestAppContext) {
    let r = rig(cx, "", pinned);
    assert_eq!(label(cx, r.win, "settings.remoteSignInApple"), "Sign in with Apple");
    assert!(!has(cx, r.win, "settings.remoteSignInGoogle"), "hidden without a client ID");
    r.google.set(true);
    set(cx, r.win, |_, _, _| {});
    assert_eq!(label(cx, r.win, "settings.remoteSignInGoogle"), "Sign in with Google");
    let (apple, google) = (bounds(cx, r.win, "settings.remoteSignInApple"), bounds(cx, r.win, "settings.remoteSignInGoogle"));
    assert_eq!(google.left() - apple.right(), px(8.), "spacing 8");
    assert!(!disabled(cx, r.win, "settings.remoteSignInApple"));
    set(cx, r.win, |p, _, _| p.busy = true);
    assert!(disabled(cx, r.win, "settings.remoteSignInApple") && disabled(cx, r.win, "settings.remoteSignInGoogle"), "disabled while busy");
    set(cx, r.win, |p, _, _| {
        p.busy = false;
        p.identity = Some(identity("k", "fp"));
    });
    assert!(!has(cx, r.win, "settings.remoteSignInApple"), "identity nil only");
}

// parity: SET-059
#[flow_ui::gpui::test]
async fn pinned_line_is_12_muted_with_two_spaces(cx: &mut TestAppContext) {
    let r = rig(cx, "", pinned);
    let key = core::base64url_encode(&[1u8; 32]);
    r.secrets.borrow_mut().insert(core::remote_keychain("server-key"), key);
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    let fp = read(cx, r.win, |p, _| p.pinned.clone()).unwrap();
    assert_eq!(fp, core::fingerprint_of(&[1u8; 32]));
    assert_eq!(fp.split('-').map(str::len).collect::<Vec<_>>(), vec![4; 8], "eight groups of four");
    assert_eq!(style(&format!("Pinned fingerprint  {fp}")).size, 12.);
    assert!(has(cx, r.win, "settings.pinnedFingerprint"));
}

// parity: SET-069 SET-073
#[flow_ui::gpui::test]
async fn enroll_again_and_the_setup_error(cx: &mut TestAppContext) {
    let r = rig(cx, "revoked", |_| {});
    let warning = palette(cx).warning;
    assert_eq!(label(cx, r.win, "settings.remoteEnrollAgain"), "Enroll Again");
    assert!(!disabled(cx, r.win, "settings.remoteEnrollAgain"));
    set(cx, r.win, |p, _, _| {
        p.busy = true;
        p.remote_error = Some("It failed".into());
    });
    assert!(disabled(cx, r.win, "settings.remoteEnrollAgain"), "disabled while busy");
    assert_type("It failed", 12., 400., warning);
}

// parity: SET-079
#[flow_ui::gpui::test]
async fn consent_address_field_has_symbol_hint_and_id(cx: &mut TestAppContext) {
    let r = rig(cx, "consent", |_| {});
    let link = cx.update(|cx| pal(cx).link());
    assert_symbols(&["server.rack"]);
    assert_type("https://server.example.com", 13., 400., link);
    assert_eq!(label(cx, r.win, "settings.remoteServerURL"), "Server address");
    type_into(cx, r.win, |p| p.server_draft.clone(), "https://a.example.com");
    assert!(!saw("https://server.example.com"), "the hint leaves when there's text");
    assert_eq!(pref_s(cx, "remote.serverURL"), None, "the draft is not persisted");
}

// parity: SET-080 SET-107
#[flow_ui::gpui::test]
async fn consent_body_pitch_is_18(cx: &mut TestAppContext) {
    let r = rig(cx, "consent", |_| {});
    let body = bounds(cx, r.win, "settings.consentBody");
    // The reference's baselines are 18 apart: Figtree 13 is 15, plus spacing 3. The test font wraps
    // differently, so the height is checked as a whole number of pitches.
    assert_eq!((f32::from(body.size.height) + 3.) % 18., 0., "{:?}", body.size.height);
    let text = cx.update(|cx| core::consent_text(&cx.global::<Core>().prefs));
    assert_eq!(style(&text).size, 13.);
    let r2 = rig(cx, "consent-update-sheet", |_| {});
    assert_type("Send summaries and meetings to your server?", 17., 500., palette(cx).ink);
    assert_eq!(style(&text).size, 13.);
    assert_eq!(bounds(cx, r2.win, "settings.sheet").size.width, px(460.));
}

// parity: SET-085 SET-088
#[flow_ui::gpui::test]
async fn return_follows_the_disabled_turn_on(cx: &mut TestAppContext) {
    let r = rig(cx, "consent", |_| {});
    assert!(disabled(cx, r.win, "settings.remoteConsentConfirm"));
    type_into(cx, r.win, |p| p.server_draft.clone(), "http://not-https.example");
    assert!(disabled(cx, r.win, "settings.remoteConsentConfirm"));
    press(cx, r.win, "enter");
    assert_eq!(read(cx, r.win, |p, _| p.modal), Some(Modal::Consent), "Return does nothing");
    assert_eq!(read(cx, r.win, |p, _| p.remote_error.clone()), None, "and shows no error");
    set(cx, r.win, |p, _, _| p.remote_error = Some("Sheet error".into()));
    assert_type("Sheet error", 12., 400., palette(cx).warning);
    assert_eq!(label(cx, r.win, "settings.remoteConsentConfirm"), "Turn On");
    type_into(cx, r.win, |p| p.server_draft.clone(), "https://flow.example.com");
    press(cx, r.win, "enter");
    assert_eq!(read(cx, r.win, |p, _| p.modal), None, "Return confirms a valid one");
    assert_eq!(pref_s(cx, "remote.serverURL").as_deref(), Some("https://flow.example.com"));
}

// parity: SET-100 SET-101 SET-104
#[flow_ui::gpui::test]
async fn routing_switches_clear_the_check_and_force_the_server(cx: &mut TestAppContext) {
    let r = rig(cx, "advanced", |_| {});
    assert!(checked(cx, r.win, "settings.serverUseForEverything"), "unset reads as routes to server");
    assert_eq!(pref_b(cx, "server.useForEverything"), None, "and isn't written by reading");
    set(cx, r.win, |p, _, _| p.check_result = Some("Answered in 3 ms".into()));
    click(cx, r.win, "settings.serverUseForEverything");
    assert_eq!(pref_b(cx, "server.useForEverything"), Some(false));
    assert_eq!(read(cx, r.win, |p, _| p.check_result.clone()), None, "clears the check");
    set(cx, r.win, |p, _, _| p.check_result = Some("Answered in 3 ms".into()));
    click(cx, r.win, "settings.serverOnly");
    assert_eq!(pref_b(cx, "server.only"), Some(true));
    assert_eq!(read(cx, r.win, |p, _| p.check_result.clone()), None);
    assert!(checked(cx, r.win, "settings.serverUseForEverything"), "server only forces it on");
    assert!(disabled(cx, r.win, "settings.serverUseForEverything"), "row disabled");
    for id in ["settings.serverOverride.dictation", "settings.serverOverride.rewriting", "settings.serverOverride.summaries", "settings.serverOverride.meetings"] {
        assert!(disabled(cx, r.win, id), "{id}");
    }
    assert_saw(&["Your server"]);
}

// parity: SET-114 SET-116
#[flow_ui::gpui::test]
async fn check_button_and_result(cx: &mut TestAppContext) {
    let r = rig(cx, "advanced", |_| {});
    let muted = palette(cx).muted;
    assert_eq!(label(cx, r.win, "settings.serverCheckConnection"), "Check connection");
    assert!(!disabled(cx, r.win, "settings.serverCheckConnection"));
    set(cx, r.win, |p, _, _| p.checking = true);
    assert_eq!(label(cx, r.win, "settings.serverCheckConnection"), "Checking…");
    assert!(disabled(cx, r.win, "settings.serverCheckConnection"), "disabled while running");
    set(cx, r.win, |p, _, _| {
        p.checking = false;
        p.check_result = Some("Answered in 9 ms".into());
    });
    assert!(has(cx, r.win, "settings.serverCheckResult"));
    assert_type("Answered in 9 ms", 12., 400., muted);
    choose(cx, r.win, "settings.serverOverride.meetings", "This Mac");
    assert!(!has(cx, r.win, "settings.serverCheckResult"), "cleared by a routing control");
}

// parity: SET-120
#[flow_ui::gpui::test]
async fn server_advanced_starts_closed(cx: &mut TestAppContext) {
    let r = rig(cx, "approved", |_| {});
    let muted = palette(cx).muted;
    assert!(!has(cx, r.win, "settings.serverOverride.dictation"), "collapsed by default");
    assert_type("Advanced", 12., 400., muted);
    assert_symbols(&["chevron.right"]);
    let (outer, inner) = (bounds(cx, r.win, "settings.serverAdvancedRow"), bounds(cx, r.win, "settings.serverAdvanced"));
    assert_eq!((inner.top() - outer.top(), outer.bottom() - inner.bottom()), (px(14.), px(14.)), "vertical padding 14");
    click(cx, r.win, "settings.serverAdvanced");
    assert!(has(cx, r.win, "settings.serverOverride.dictation"));
    assert_symbols(&["chevron.down"]);
    assert_eq!(cx.update(|cx| cx.global::<Core>().prefs.contains("settings.serverAdvanced")), false, "not persisted");
}

// parity: SET-121 SET-122 SET-123 SET-124 SET-125 SET-126 SET-127 SET-128 SET-129
#[flow_ui::gpui::test]
async fn override_menus_offer_swifts_options_and_write_through_a_click(cx: &mut TestAppContext) {
    let r = rig(cx, "advanced", |_| {});
    let (two, three) = (vec!["Your server", "This Mac"], vec!["Your server", "This Mac", "Custom server"]);
    assert_eq!(menu(cx, r.win, "settings.serverOverride.dictation"), two);
    assert_eq!(menu(cx, r.win, "settings.serverOverride.rewriting"), three);
    assert_eq!(menu(cx, r.win, "settings.serverOverride.summaries"), three);
    assert_eq!(menu(cx, r.win, "settings.serverOverride.meetings"), two);
    for (id, name) in [("settings.serverOverride.dictation", "Dictation"), ("settings.serverOverride.rewriting", "Rewriting"), ("settings.serverOverride.summaries", "Summaries"), ("settings.serverOverride.meetings", "Meetings")] {
        assert_eq!(label(cx, r.win, id), format!("{name} runs on"));
        let frame_id: &'static str = format!("{id}.frame").leak();
        assert_eq!(bounds(cx, r.win, frame_id).size.width, px(150.), "{id}");
    }
    assert_saw(&["Speech recognition; rewriting follows its own row", "Transcripts, speaker labels and voice matching"]);
    assert!(!saw("Your server is used if this server fails"), "only with the custom fields");

    set(cx, r.win, |p, _, _| p.check_result = Some("x".into()));
    choose(cx, r.win, "settings.serverOverride.dictation", "This Mac");
    assert_eq!(pref_s(cx, "server.override.dictation").as_deref(), Some("thisMac"));
    assert_eq!(read(cx, r.win, |p, _| p.check_result.clone()), None);
    set(cx, r.win, |p, _, _| p.check_result = Some("x".into()));
    choose(cx, r.win, "settings.serverOverride.meetings", "This Mac");
    assert_eq!(pref_s(cx, "server.override.meetings").as_deref(), Some("thisMac"));
    assert_eq!(read(cx, r.win, |p, _| p.check_result.clone()), None);

    set(cx, r.win, |p, _, _| p.check_result = Some("x".into()));
    choose(cx, r.win, "settings.serverOverride.rewriting", "Custom server");
    assert_eq!(pref_s(cx, "server.override.rewrite").as_deref(), Some("custom"));
    assert_eq!(read(cx, r.win, |p, _| p.check_result.clone()), None);
    assert_saw(&["Server URL", "Server secret"]);
    choose(cx, r.win, "settings.serverOverride.rewriting", "This Mac");
    assert_eq!(pref_s(cx, "server.override.rewrite").as_deref(), Some("thisMac"));

    choose(cx, r.win, "settings.serverOverride.summaries", "Custom server");
    assert_eq!(pref_s(cx, "server.override.summaries").as_deref(), Some("custom"));
    assert_eq!(pref_s(cx, "summaryServer").as_deref(), Some("remote"), "custom also writes it");
    assert_saw(&["Your server is used if this server fails", "API key"]);
    choose(cx, r.win, "settings.serverOverride.summaries", "This Mac");
    assert_eq!(pref_s(cx, "server.override.summaries").as_deref(), Some("thisMac"));
    assert_eq!(pref_s(cx, "summaryServer").as_deref(), Some("remote"), "another option doesn't revert it");
}

// parity: SET-130 SET-131
#[flow_ui::gpui::test]
async fn fallback_stepper_label_and_steps(cx: &mut TestAppContext) {
    let r = rig(cx, "advanced", |_| {});
    let ms = |n: i64| format!("{} ms", flow_core::insights::grouped(n));
    assert_saw(&["Fallback threshold", "Dictation uses this Mac after this wait", &ms(1500)]);
    assert_eq!(label(cx, r.win, "settings.serverFallbackThreshold.up"), "Remote dictation fallback threshold in milliseconds, increase");
    assert_eq!(label(cx, r.win, "settings.serverFallbackThreshold.down"), "Remote dictation fallback threshold in milliseconds, decrease");
    click(cx, r.win, "settings.serverFallbackThreshold.up");
    assert_eq!(pref_i(cx, "remote.fallbackThresholdMs", 0), 1750, "step 250");
    assert_saw(&[&ms(1750)]);
    set(cx, r.win, |_, _, cx| prefs_mut(cx).set("remote.fallbackThresholdMs", 10_000));
    click(cx, r.win, "settings.serverFallbackThreshold.up");
    assert_eq!(pref_i(cx, "remote.fallbackThresholdMs", 0), 10_000, "ceiling");
    set(cx, r.win, |_, _, cx| prefs_mut(cx).set("remote.fallbackThresholdMs", 250));
    click(cx, r.win, "settings.serverFallbackThreshold.down");
    assert_eq!(pref_i(cx, "remote.fallbackThresholdMs", 0), 250, "floor");
}

// parity: SET-133
#[flow_ui::gpui::test]
async fn advanced_fingerprint_row_has_its_id_and_selects(cx: &mut TestAppContext) {
    let r = rig(cx, "advanced", |_| {});
    assert!(!has(cx, r.win, "settings.serverFingerprint.text"), "only when pinned");
    r.secrets.borrow_mut().insert(core::remote_keychain("server-key"), core::base64url_encode(&[2u8; 32]));
    set(cx, r.win, |p, _, cx| p.refresh(cx));
    let fp = core::fingerprint_of(&[2u8; 32]);
    let muted = palette(cx).muted;
    assert_eq!(style(&fp).size, 12.);
    assert_type("Server fingerprint", 14., 400., muted);
    assert!(has(cx, r.win, "settings.serverFingerprint"));
    let b = bounds(cx, r.win, "settings.serverFingerprint.text");
    let selected = cx.update_window(r.win.into(), |_, w, cx| {
        w.drag(point(b.left() + px(1.), b.center().y), point(b.left() + px(500.), b.center().y), cx);
        base::TextSelection::selected_text(w, cx)
    })
    .unwrap();
    assert_eq!(selected, fp);
}
