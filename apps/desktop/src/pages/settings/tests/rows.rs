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

// MARK: Updates

// parity: SET-138 SET-140 SET-142
#[flow_ui::gpui::test]
async fn update_controls_read_and_gate(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert_eq!(label(cx, r.win, "settings.updateDownloads"), "View Downloads");
    click(cx, r.win, "settings.updateDownloads");
    assert!(logged(&r, "open https://github.com/brunovskyoliver/local_flow/releases/latest"));
    set(cx, r.win, |p, _, _| p.updates = Updates::Sparkle { automatic: true, can_check: false });
    assert_eq!(label(cx, r.win, "settings.checkForUpdates"), "Check for Updates…");
    assert_type("Check for Updates…", 13., 500., palette(cx).ink);
    assert!(disabled(cx, r.win, "settings.checkForUpdates"), "unless canCheck");
    assert_eq!(label(cx, r.win, "settings.automaticUpdates"), "Check for updates automatically");
    assert!(checked(cx, r.win, "settings.automaticUpdates"));
    set(cx, r.win, |p, _, _| p.updates = Updates::Sparkle { automatic: false, can_check: true });
    assert!(!disabled(cx, r.win, "settings.checkForUpdates"));
    assert!(!checked(cx, r.win, "settings.automaticUpdates"));
}

// MARK: General

// parity: SET-149 SET-150
#[flow_ui::gpui::test]
async fn set_up_button_size_and_gate(cx: &mut TestAppContext) {
    let r = rig(cx, "meeting-only", |p| p.set("server.only", true));
    assert_eq!(label(cx, r.win, "settings.setUpDictation"), "Set Up");
    assert!(bounds(cx, r.win, "settings.setUpDictation").size.width >= px(99.), "min width");
    set(cx, r.win, |p, _, _| p.performing = true);
    assert!(disabled(cx, r.win, "settings.setUpDictation"));
    set(cx, r.win, |p, _, _| p.performing = false);
    r.ok.set(false);
    click(cx, r.win, "settings.setUpDictation");
    assert_eq!(pref_s(cx, "setup.purpose").as_deref(), Some("both"));
    assert!(logged(&r, "install"), "installs the saved shortcut");
    assert_eq!(read(cx, r.win, |p, _| p.error.clone()), None, "failure isn't on this page");
    assert_eq!(pref_b(cx, "server.only"), Some(true), "stays");
}

// parity: SET-151 SET-153 SET-154
#[flow_ui::gpui::test]
async fn shortcut_button_gates_and_stops_without_a_callback(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert!(bounds(cx, r.win, "settings.shortcut").size.width >= px(99.));
    set(cx, r.win, |p, _, _| p.snapshot.busy = true);
    assert!(disabled(cx, r.win, "settings.shortcut"), "busy");
    set(cx, r.win, |p, _, _| {
        p.snapshot.busy = false;
        p.performing = true;
    });
    assert!(disabled(cx, r.win, "settings.shortcut"), "performing");
    set(cx, r.win, |p, _, _| {
        p.performing = false;
        p.recording_error = Some("old".into());
    });
    click(cx, r.win, "settings.shortcut");
    assert_eq!(label(cx, r.win, "settings.shortcut"), "Listening…");
    assert_saw(&["Press a shortcut, then release. Esc to cancel."]);
    assert_eq!(read(cx, r.win, |p, _| p.recording_error.clone()), None, "cleared on start");
    assert_eq!(r.log.borrow().iter().filter(|l| *l == "record").count(), 1);
    click(cx, r.win, "settings.shortcut");
    assert_eq!(r.log.borrow().iter().filter(|l| *l == "record").count(), 1, "stops with no callback");
    assert!(!logged(&r, "install"));
    assert!(!saw("Press a shortcut, then release. Esc to cancel."));
    r.ok.set(false);
    click(cx, r.win, "settings.shortcut");
    assert!(has(cx, r.win, "settings.recordingError"), "start failure");
}

// parity: SET-166 SET-167 SET-168 SET-169 SET-170 SET-171 SET-172 SET-173
#[flow_ui::gpui::test]
async fn general_menus_and_switches_through_real_clicks(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert_eq!(menu(cx, r.win, "settings.appearance"), ["System", "Light", "Dark"]);
    assert_eq!(menu(cx, r.win, "settings.meetingLanguage"), ["Automatic (English/Slovak)", "Slovak", "English"]);
    assert_eq!(bounds(cx, r.win, "settings.appearance.frame").size.width, px(110.));
    assert_eq!(bounds(cx, r.win, "settings.meetingLanguage.frame").size.width, px(210.));
    assert_eq!(label(cx, r.win, "settings.appearance"), "Appearance");
    let dark = |cx: &mut TestAppContext| palette(cx).mode.is_dark();
    choose(cx, r.win, "settings.appearance", "Dark");
    assert_eq!(pref_s(cx, "appearance").as_deref(), Some("dark"));
    assert!(dark(cx), "applies at once");
    choose(cx, r.win, "settings.appearance", "Light");
    assert_eq!(pref_s(cx, "appearance").as_deref(), Some("light"));
    assert!(!dark(cx));
    choose(cx, r.win, "settings.appearance", "System");
    assert_eq!(pref_s(cx, "appearance").as_deref(), Some("system"));
    choose(cx, r.win, "settings.meetingLanguage", "Slovak");
    assert_eq!(pref_s(cx, "settings.meetingLanguage").as_deref(), Some("slovak"));
    assert_eq!(core::whisper_language("slovak"), "sk");
    assert_eq!(core::whisper_language("english"), "en");
    assert_eq!(core::whisper_language("automatic"), "auto");
    set(cx, r.win, |_, _, cx| prefs_mut(cx).set("settings.meetingLanguage", "czech"));
    assert_saw(&["Automatic (English/Slovak)"]);
    // Swift's defaults: learning off, the meeting pill on.
    assert!(!checked(cx, r.win, "settings.learnCorrections"));
    assert!(checked(cx, r.win, "settings.showsBackgroundProgress"));
    click(cx, r.win, "settings.learnCorrections");
    assert_eq!(pref_b(cx, "learnCorrections"), Some(true));
    click(cx, r.win, "settings.showsBackgroundProgress");
    assert_eq!(pref_b(cx, "showsBackgroundProgress"), Some(false));
    assert!(!checked(cx, r.win, "settings.showsBackgroundProgress"));
}

// MARK: Microphones

// parity: SET-176 SET-178 SET-181 SET-191
#[flow_ui::gpui::test]
async fn microphone_list_and_add_menu(cx: &mut TestAppContext) {
    let r = rig(cx, "microphones", |_| {});
    let muted = palette(cx).muted;
    let copy = "LocalFlow records from the first microphone on this list that is connected.";
    assert_type(copy, 12., 400., muted);
    let (description, list) = (bounds(cx, r.win, "settings.microphones.description"), bounds(cx, r.win, "settings.microphones.list"));
    assert_eq!(list.top() - description.bottom(), px(0.), "the padding is inside the description");
    assert!(has(cx, r.win, "settings.microphones.row.e-usb"));
    // A one point line after every row, the last included: each row's bottom is 1 above the next top.
    let (usb, gone) = (bounds(cx, r.win, "settings.microphones.row.e-usb"), bounds(cx, r.win, "settings.microphones.row.e-gone"));
    assert_eq!(gone.top() - usb.bottom(), px(1.));
    let default_row = bounds(cx, r.win, "settings.row.System default");
    assert_eq!(bounds(cx, r.win, "settings.row.Add microphone").top() - default_row.bottom(), px(1.), "after the last too");
    assert_saw(&["Currently: MacBook Pro Microphone"]);
    let removes = r.win.update(cx, |_, w, _| w.find_all("settings.microphones.remove").len()).unwrap();
    assert_eq!(removes, 2, "system default has none");
    let default_id = read(cx, r.win, |p, _| p.mics.as_ref().unwrap().entries.iter().find(|e| e.name == "System default").map(|e| e.id.clone()).unwrap());
    let scope: &'static str = format!("settings.microphones.row.{default_id}").leak();
    let inside = r.win.update(cx, |_, w, _| w.within(scope).try_find("settings.microphones.remove").is_some()).unwrap();
    assert!(!inside, "not in the system default row");
    assert_eq!(label(cx, r.win, "settings.microphones.add"), "Add…");
    assert_eq!(menu(cx, r.win, "settings.microphones.add"), ["MacBook Pro Microphone · Built-in", "AirPods Pro · Bluetooth"]);
    choose(cx, r.win, "settings.microphones.add", "AirPods Pro · Bluetooth");
    let entries = read(cx, r.win, |p, _| p.mics.as_ref().unwrap().entries.iter().map(|e| e.name.clone()).collect::<Vec<_>>());
    assert_eq!(entries.last().map(String::as_str), Some("System default"), "inserted above it");
    assert!(entries.iter().any(|n| n == "AirPods Pro"));
}

// MARK: App context

// parity: SET-210
#[flow_ui::gpui::test]
async fn excluded_defaults_are_the_nine_and_localflow(cx: &mut TestAppContext) {
    let _r = rig(cx, "", |_| {});
    let got = cx.update(|cx| core::exclusions(&cx.global::<Core>().prefs));
    for id in ["com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass", "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal", "com.moneymoney-app.retail", core::BUNDLE_ID] {
        assert!(got.iter().any(|g| g == id), "{id}");
    }
    assert_eq!(got.len(), 10);
    assert_saw(&["10 apps"]);
}

// parity: SET-213 SET-214 SET-224 SET-226 SET-229 SET-230 SET-231 SET-237
#[flow_ui::gpui::test]
async fn kinds_sheet_type_menus_and_add_row(cx: &mut TestAppContext) {
    let r = rig(cx, "kinds", |_| {});
    let pl = palette(cx);
    assert_type("App kinds", 17., 500., pl.ink);
    assert_type("Sets the kind of app used for writing style.", 13., 400., pl.muted);
    assert_type("No apps yet", 14., 400., pl.muted);
    assert_eq!(label(cx, r.win, "settings.contextBundleID"), "Bundle ID");
    let placeholder = r.win.update(cx, |_, w, _| w.find("settings.contextBundleID").placeholder().map(String::from)).unwrap();
    assert_eq!(placeholder.as_deref(), Some("Bundle ID"));
    assert_eq!(bounds(cx, r.win, "settings.contextField").size.height, px(30.));
    assert_eq!(label(cx, r.win, "context.addKind"), "Work chat", "default");
    let kinds = ["Email", "Work chat", "Personal chat", "Code", "Terminal", "Document", "Other"];
    assert_eq!(menu(cx, r.win, "context.addKind"), kinds);
    assert_eq!(menu(cx, r.win, "context.running"), ["Arc", "Zed"], "natural name order");
    assert_eq!(label(cx, r.win, "context.running"), "Running app");
    assert_symbols(&["chevron.down"]);
    let (running, field) = (bounds(cx, r.win, "context.running"), bounds(cx, r.win, "settings.contextField"));
    assert_eq!(field.left() - running.right(), px(8.), "add row spacing");
    assert!(disabled(cx, r.win, "settings.contextAdd"));
    assert_type("Add", 13., 400., pl.ink);
    type_into(cx, r.win, |p| p.bundle_draft.clone(), "   ");
    assert!(disabled(cx, r.win, "settings.contextAdd"), "blank after trimming");
    choose(cx, r.win, "context.addKind", "Code");
    assert_eq!(label(cx, r.win, "context.addKind"), "Code");
    type_into(cx, r.win, |p| p.bundle_draft.clone(), "com.example.App");
    assert!(!disabled(cx, r.win, "settings.contextAdd"));
    click(cx, r.win, "settings.contextAdd");
    assert_eq!(cx.update(|cx| core::overrides(&cx.global::<Core>().prefs).get("com.example.App").cloned()).as_deref(), Some("code"));
    assert_eq!(menu(cx, r.win, "context.kind.com.example.App"), kinds);
    choose(cx, r.win, "context.kind.com.example.App", "Email");
    assert_eq!(cx.update(|cx| core::overrides(&cx.global::<Core>().prefs).get("com.example.App").cloned()).as_deref(), Some("email"));
    let (done, sheet) = (bounds(cx, r.win, "settings.contextDone"), bounds(cx, r.win, "settings.sheet"));
    assert_eq!(sheet.right() - done.right(), px(22.), "right aligned");
    assert_type("Done", 15., 500., pl.surface);
    press(cx, r.win, "enter");
    assert_eq!(read(cx, r.win, |p, _| p.modal), None, "Return dismisses");
}

// parity: SET-236
#[flow_ui::gpui::test]
async fn a_sheet_error_outlives_the_sheet(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    click(cx, r.win, "settings.contextExclusions");
    type_into(cx, r.win, |p| p.bundle_draft.clone(), "has space");
    click(cx, r.win, "settings.contextAdd");
    let copy = "Enter a bundle ID such as com.example.App. At most 200 apps can be excluded.";
    assert_type(copy, 12., 400., palette(cx).warning);
    click(cx, r.win, "settings.contextDone");
    click(cx, r.win, "settings.contextExclusions");
    assert_saw(&[copy]);
}

// parity: SET-217 SET-218
#[flow_ui::gpui::test]
async fn app_row_uses_the_lookup_and_falls_back_to_the_id(cx: &mut TestAppContext) {
    let r = rig(cx, "exclusions", |_| {});
    let muted = palette(cx).muted;
    assert_saw(&["Alpha Keys"]);
    assert_eq!(style("Alpha Keys").size, 14.);
    assert_type("com.apple.Passwords", 12., 400., muted);
    assert_saw(&["com.bitwarden.desktop"]);
    let row = bounds(cx, r.win, "context.row.com.apple.Passwords");
    assert_eq!(row.size.height, px(56.));
    assert!(!has(cx, r.win, "context.icon.com.apple.Passwords"), "the stub has no icon, so the tint square shows");
}

// MARK: Models

// parity: SET-242 SET-249 SET-264 SET-263 SET-266 SET-269
#[flow_ui::gpui::test]
async fn model_buttons_read_and_gate(cx: &mut TestAppContext) {
    let r = rig(cx, "installed", |_| {});
    assert!(!has(cx, r.win, "settings.speechDownload"));
    assert_eq!(label(cx, r.win, "settings.speechLoad"), "Load");
    assert_eq!(label(cx, r.win, "settings.test.speech"), "Test Parakeet Ultra");
    let (load, test) = (bounds(cx, r.win, "settings.speechLoad"), bounds(cx, r.win, "settings.test.speech"));
    assert_eq!(test.left() - load.right(), px(8.), "spacing 8, extras then Test");
    set(cx, r.win, |p, _, _| p.snapshot.controls_available = false);
    assert!(disabled(cx, r.win, "settings.speechLoad"), "runtime controls unavailable");
    set(cx, r.win, |p, _, _| {
        p.snapshot.controls_available = true;
        p.performing = true;
    });
    assert!(disabled(cx, r.win, "settings.speechLoad") && disabled(cx, r.win, "settings.test.speech"), "performing");
    set(cx, r.win, |p, _, _| {
        p.performing = false;
        p.snapshot.busy = true;
    });
    assert!(disabled(cx, r.win, "settings.speechLoad") && disabled(cx, r.win, "settings.test.speech"), "busy");
    let r = rig(cx, "loaded", |_| {});
    assert_eq!(label(cx, r.win, "settings.speechLoad"), "Unload");
    click(cx, r.win, "settings.speechLoad");
    assert!(logged(&r, "action unload"));
    let r = rig(cx, "alt-installed", |_| {});
    assert_eq!(label(cx, r.win, "settings.alternateUse"), "Use Parakeet Ultra for dictation");
    set(cx, r.win, |p, _, _| p.performing = true);
    assert!(disabled(cx, r.win, "settings.alternateUse"));
    let r = rig(cx, "alternate", |_| {});
    assert_eq!(label(cx, r.win, "settings.alternateDownload"), "Download…");
    set(cx, r.win, |p, _, _| p.snapshot.installing = true);
    assert!(disabled(cx, r.win, "settings.alternateDownload"), "while the main install runs");
    let r = rig(cx, "alt-downloading", |_| {});
    assert_eq!(label(cx, r.win, "settings.alternateCancel"), "Cancel");
    assert!(has(cx, r.win, "settings.alternateProgress"));
    set(cx, r.win, |p, _, _| p.snapshot.alternate.as_mut().unwrap().total = 0);
    assert!(!has(cx, r.win, "settings.alternateProgress"), "only when total is above 0");
}

// parity: SET-253 SET-254 SET-267
#[flow_ui::gpui::test]
async fn download_dialogs_read_exactly(cx: &mut TestAppContext) {
    let v3 = "NVIDIA parakeet-tdt-0.6b-v3, Core ML conversion by FluidInference. License: CC BY 4.0.";
    let ultra = "Moondream parakeet-ultra (post-trained from NVIDIA parakeet-tdt-0.6b-v3), Core ML conversion by FluidInference. License: CC BY 4.0.";
    assert_eq!(core::speech_attribution("parakeet-v3"), v3);
    assert_eq!(core::speech_attribution("parakeet-ultra"), ultra);
    let r = rig(cx, "download", |_| {});
    let (title, message) = read(cx, r.win, |p, _| p.download_copy(false));
    assert_eq!(title, "Download Parakeet Ultra?");
    let size = read(cx, r.win, |p, _| core::byte_count(p.snapshot.download_bytes.unwrap()));
    assert_eq!(message, format!("{size}\n{ultra}"));
    assert_eq!(label(cx, r.win, "settings.alert.confirm"), "Download");
    assert_eq!(label(cx, r.win, "settings.alert.cancel"), "Cancel");
    set(cx, r.win, |p, _, _| p.snapshot.download_bytes = None);
    assert_eq!(read(cx, r.win, |p, _| p.download_copy(false)).1, format!("Download size unavailable.\n{ultra}"));
    set(cx, r.win, |p, _, _| p.snapshot.alternate = None);
    assert_eq!(read(cx, r.win, |p, _| p.download_copy(true)).0, "Download speech model?");
}

// parity: SET-258
#[flow_ui::gpui::test]
async fn install_progress_bar_or_spinner(cx: &mut TestAppContext) {
    let r = rig(cx, "installing", |_| {});
    assert_saw(&["Downloading…"]);
    assert_eq!(style("Downloading…").size, 12.);
    assert!(has(cx, r.win, "settings.installProgressBar"), "determinate when total is known");
    assert_eq!(label(cx, r.win, "settings.installCancel"), "Cancel");
    let (bar, cancel) = (bounds(cx, r.win, "settings.installProgress"), bounds(cx, r.win, "settings.installCancel"));
    assert_eq!(cancel.right(), bar.right(), "Cancel at the right");
    assert_eq!(cancel.top() - bar.bottom(), px(10.), "spacing 10");
    set(cx, r.win, |p, _, _| p.snapshot.total = 0);
    assert!(!has(cx, r.win, "settings.installProgressBar"), "spinner when it isn't");
    let r = rig(cx, "verifying", |_| {});
    assert_saw(&["Verifying…"]);
    assert!(has(cx, r.win, "settings.installProgress"));
}

// parity: SET-272 SET-276 SET-280 SET-241
#[flow_ui::gpui::test]
async fn other_model_buttons_hide_when_installed_or_installing(cx: &mut TestAppContext) {
    let ids = ["settings.meetingDownload", "settings.meetingImport", "settings.speakerDownload", "settings.speakerImport", "settings.boostDownload"];
    let r = rig(cx, "", |_| {});
    for id in ids {
        assert!(has(cx, r.win, id), "{id}");
    }
    for (id, name) in [("settings.meetingDownload", "Download"), ("settings.speakerImport", "Import…"), ("settings.boostDownload", "Download")] {
        assert_eq!(label(cx, r.win, id), name);
    }
    for scenario in ["all-installed", "others-installing"] {
        let r = rig(cx, scenario, |_| {});
        for id in ids {
            assert!(!has(cx, r.win, id), "{scenario} {id}");
        }
    }
    // Who said what follows its own capability: a server that transcribes but won't diarize.
    let _r = rig(cx, "approved", |p| {
        p.set("server.capabilities", core::Capabilities { ops: ["dictation_start".into(), "rewrite".into(), "analysis".into(), "meeting_job".into()].into(), meeting_jobs: ["transcribe".into()].into() });
    });
    assert_saw(&["Meeting transcripts · On your server · Not installed · 1.63 GB", "Who said what · On this Mac · Not installed"]);
}

// parity: SET-285 SET-286 SET-287 SET-288 SET-289 SET-290
#[flow_ui::gpui::test]
async fn keep_loaded_and_rewrite_model_rows(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert!(!saw("Applies when dictating on this Mac"));
    assert_eq!(label(cx, r.win, "settings.keepModelReady"), "Keep Parakeet loaded");
    set(cx, r.win, |p, _, _| p.snapshot.controls_available = false);
    assert!(disabled(cx, r.win, "settings.keepModelReady"));
    let r = rig(cx, "approved", |_| {});
    assert_saw(&["Applies when dictating on this Mac"]);
    let endpoint = core::loopback_endpoint();
    let e = endpoint.clone();
    let r2 = rig(cx, "", move |p| p.set("rewriteEndpoint", e.as_str()));
    assert_eq!(menu(cx, r2.win, "settings.localModelIdleUnload"), ["Never", "After 15 min", "After 1 hour"]);
    assert_eq!(bounds(cx, r2.win, "settings.localModelIdleUnload.frame").size.width, px(130.));
    choose(cx, r2.win, "settings.localModelIdleUnload", "After 1 hour");
    assert_eq!(pref_i(cx, "localModelIdleUnload", 0), 3600);
    assert!(checked(cx, r2.win, "settings.unloadLocalModelDuringGames"), "on by default");
    click(cx, r2.win, "settings.unloadLocalModelDuringGames");
    assert_eq!(pref_b(cx, "unloadLocalModelDuringGames"), Some(false));
    let e = endpoint.clone();
    let r3 = rig(cx, "server-only", move |p| {
        p.set("rewriteEndpoint", e.as_str());
        p.set("server.capabilities", core::Capabilities { ops: ["dictation_start".into(), "rewrite".into(), "analysis".into()].into(), meeting_jobs: Default::default() });
    });
    assert!(!has(cx, r3.win, "settings.localModelIdleUnload"), "stopped by routing");
    drop(r);
}

// MARK: Rewriting

// parity: SET-294
#[flow_ui::gpui::test]
async fn unencrypted_warning_sits_above_the_group(cx: &mut TestAppContext) {
    let r = rig(cx, "rewrite-insecure", |_| {});
    let copy = "Transcripts and the credential travel unencrypted to 10.0.0.5. Authentication does not encrypt them. Use this only on a network you trust.";
    assert_type(copy, 12., 400., palette(cx).warning);
    let warning = bounds(cx, r.win, "settings.rewriteWarning");
    assert_eq!(bounds(cx, r.win, "settings.row.Enable rewriting").top() - warning.bottom(), px(0.), "padding 12 inside it");
}

// parity: SET-296 SET-298 SET-303 SET-304 SET-305
#[flow_ui::gpui::test]
async fn rewrite_row_tips_menu_and_definitions(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert!(disabled(cx, r.win, "settings.rewriteEnabled"), "blocked and off");
    set(cx, r.win, |_, _, cx| prefs_mut(cx).set("rewriteEnabled", true));
    assert!(!disabled(cx, r.win, "settings.rewriteEnabled"), "blocked and on can still go off");
    let shift = core::bypass_note(&cx.update(|cx| Shortcut::load(&cx.global::<Core>().prefs)));
    assert_eq!(shift, "Hold Shift on release to skip rewriting once.");
    flow_ui::probe::clear();
    cx.update_window(r.win.into(), |_, w, cx| w.hover("settings.rewriteEnabled.tip", cx)).unwrap();
    cx.executor().advance_clock(Duration::from_secs(2));
    cx.run_until_parked();
    assert_saw(&[shift]);
    assert_eq!(menu(cx, r.win, "settings.rewriteDefaultMode"), ["Exact", "Clean", "Polished", "Concise"]);
    assert_eq!(bounds(cx, r.win, "settings.rewriteDefaultMode.frame").size.width, px(120.));
    choose(cx, r.win, "settings.rewriteDefaultMode", "Concise");
    assert_eq!(pref_s(cx, "rewriteDefaultMode").as_deref(), Some("concise"));
    let definition = "Remove repetition and clutter while keeping every fact and action.";
    assert_eq!(core::mode_definition("concise"), definition);
    assert_eq!(core::mode_definition("exact"), "Insert the saved transcript unchanged. No request is sent.");
    assert_eq!(core::mode_definition("clean"), "Keep wording and meaning; fix punctuation, grammar and capitalization, and remove fillers, stutters and self-corrections.");
    assert_eq!(core::mode_definition("polished"), "Restructure sentences into natural professional writing while keeping every fact and action.");
    cx.update_window(r.win.into(), |_, w, cx| w.hover("settings.rewriteDefaultMode.tip", cx)).unwrap();
    cx.executor().advance_clock(Duration::from_secs(2));
    cx.run_until_parked();
    assert_saw(&[definition]);
}

// parity: SET-307 SET-311 SET-312 SET-313 SET-314 SET-316 SET-318 SET-320
#[flow_ui::gpui::test]
async fn secret_controls_read_exactly(cx: &mut TestAppContext) {
    let r = rig(cx, "", |p| p.set("rewriteEndpoint", "https://flow.example.com"));
    let pl = palette(cx);
    assert_symbols(&["link", "key"]);
    assert_type("Server secret", 12., 500., pl.muted);
    assert_eq!(label(cx, r.win, "settings.rewriteEndpoint"), "Rewrite server endpoint");
    assert_eq!(label(cx, r.win, "settings.rewriteCredential"), "Rewrite server credential");
    let hint = r.win.update(cx, |_, w, _| w.find("settings.rewriteCredential").placeholder().map(String::from)).unwrap();
    assert_eq!(hint.as_deref(), Some("Enter server secret"));
    assert_eq!(label(cx, r.win, "settings.rewriteCredentialSave"), "Set rewrite server credential");
    assert!(disabled(cx, r.win, "settings.rewriteCredentialSave"), "empty draft");
    type_into(cx, r.win, |p| p.credential.clone(), "s3cret");
    assert!(!disabled(cx, r.win, "settings.rewriteCredentialSave"));
    press(cx, r.win, "enter");
    assert!(has(cx, r.win, "Server secret saved"), "Return saves");
    assert_eq!(label(cx, r.win, "Server secret saved"), "Server secret saved");
    assert_symbols(&["checkmark.shield"]);
    assert_eq!(style("Saved in Keychain").size, 11.);
    assert_eq!(label(cx, r.win, "settings.rewriteCredentialEdit"), "Edit rewrite server credential");
    click(cx, r.win, "settings.rewriteCredentialEdit");
    assert_saw(&["Reveal saved secret", "Remove", "Cancel"]);
    assert_eq!(style("Reveal saved secret").size, 12.);
    assert_eq!(label(cx, r.win, "settings.rewriteCredentialRemove"), "Remove rewrite server credential");
    let (reveal, remove) = (bounds(cx, r.win, "settings.rewriteCredentialReveal"), bounds(cx, r.win, "settings.rewriteCredentialRemove"));
    assert!(reveal.right() < remove.left());
    assert_eq!(style("Remove").color, pl.warning, "destructive");
    click(cx, r.win, "settings.rewriteCredentialReveal");
    assert_saw(&["Hide saved secret"]);
    assert_eq!(read(cx, r.win, |p, cx| p.credential_draft(cx)), "s3cret");
    click(cx, r.win, "settings.rewriteCredentialCancel");
    assert!(has(cx, r.win, "Server secret saved"), "Cancel leaves edit mode");
    assert_eq!(read(cx, r.win, |p, cx| p.credential_draft(cx)), "", "hides the secret");
}

// parity: SET-323 SET-325 SET-330 SET-331
#[flow_ui::gpui::test]
async fn insecure_switch_connection_button_and_timeout(cx: &mut TestAppContext) {
    let r = rig(cx, "rewrite-insecure", |_| {});
    assert_eq!(label(cx, r.win, "settings.rewriteInsecureOverride"), "Allow unencrypted connection to this server (insecure)");
    assert_eq!(label(cx, r.win, "settings.rewriteTestConnection"), "Test connection");
    set(cx, r.win, |p, _, _| p.connection_testing = true);
    assert_eq!(label(cx, r.win, "settings.rewriteTestConnection"), "Testing…");
    assert!(disabled(cx, r.win, "settings.rewriteTestConnection"), "while testing");
    let r = rig(cx, "", |_| {});
    assert!(disabled(cx, r.win, "settings.rewriteTestConnection"), "endpoint invalid");
    click(cx, r.win, "settings.rewriteAdvanced");
    assert_eq!(label(cx, r.win, "settings.rewriteTimeout.up"), "Rewrite timeout in seconds, increase");
    assert_eq!(label(cx, r.win, "settings.rewriteTimeout.down"), "Rewrite timeout in seconds, decrease");
    set(cx, r.win, |_, _, cx| prefs_mut(cx).set("rewriteTimeoutSeconds", 60));
    assert_saw(&["60 seconds"]);
    click(cx, r.win, "settings.rewriteTimeout.up");
    assert_eq!(pref_i(cx, "rewriteTimeoutSeconds", 0), 60, "ceiling");
    set(cx, r.win, |_, _, cx| prefs_mut(cx).set("rewriteTimeoutSeconds", 5));
    click(cx, r.win, "settings.rewriteTimeout.down");
    assert_eq!(pref_i(cx, "rewriteTimeoutSeconds", 0), 5, "floor");
    click(cx, r.win, "settings.rewriteTimeout.up");
    assert_eq!(pref_i(cx, "rewriteTimeoutSeconds", 0), 6, "step 1");
}

// MARK: Summaries

// parity: SET-336 SET-337 SET-339 SET-341 SET-343 SET-344 SET-345
#[flow_ui::gpui::test]
async fn summary_fields_read_and_save(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert_eq!(menu(cx, r.win, "settings.summaryServer"), ["Remote", "This Mac"]);
    assert_eq!(bounds(cx, r.win, "settings.summaryServer.frame").size.width, px(110.));
    choose(cx, r.win, "settings.summaryServer", "Remote");
    assert_eq!(pref_s(cx, "summaryServer").as_deref(), Some("remote"));
    let link = cx.update(|cx| pal(cx).link());
    assert_type("http://host:8000/v1", 13., 400., link);
    assert_symbols(&["link", "cpu", "key"]);
    assert_eq!(label(cx, r.win, "settings.summaryServerURL"), "Server URL");
    assert_eq!(label(cx, r.win, "settings.summaryServerModel"), "Model");
    let hint = |cx: &mut TestAppContext, id: &'static str| r.win.update(cx, |_, w, _| w.find(id).placeholder().map(String::from)).unwrap();
    assert_eq!(hint(cx, "settings.summaryServerModel").as_deref(), Some("Model"));
    assert_eq!(hint(cx, "settings.summaryServerKey").as_deref(), Some("API key"));
    assert!(disabled(cx, r.win, "settings.summaryServerKeySave"), "empty");
    assert!(!has(cx, r.win, "settings.summaryServerKeyCancel"), "only if already saved");
    type_into(cx, r.win, |p| p.summary_key.clone(), "k3y");
    press(cx, r.win, "enter");
    assert_eq!(r.secrets.borrow().get(&core::rewrite_keychain(core::SUMMARY_ACCOUNT)).map(String::as_str), Some("k3y"), "Return saves, on summary-server");
    assert_eq!(label(cx, r.win, "API key saved"), "API key saved");
    assert_eq!(read(cx, r.win, |p, cx| val(&p.summary_key, cx)), "", "clears the draft");
    click(cx, r.win, "settings.summaryServerKeyEdit");
    assert_eq!(label(cx, r.win, "settings.summaryServerKeyCancel"), "Cancel");
    let row = bounds(cx, r.win, "settings.summaryKeyRow");
    assert_eq!(row.size.width, bounds(cx, r.win, "settings.summaryURLField").size.width, "same width as the fields");
}

// parity: SET-328
#[flow_ui::gpui::test]
async fn analysis_status_line_reads_small_and_muted(cx: &mut TestAppContext) {
    let r = rig(cx, "", |_| {});
    assert!(!has(cx, r.win, "settings.analysisStatus"), "absent before a test");
    set(cx, r.win, |p, _, _| p.analysis = Some("Meeting analysis: available (model m).".into()));
    assert!(has(cx, r.win, "settings.analysisStatus"));
    assert_type("Meeting analysis: available (model m).", 12., 400., palette(cx).muted);
}

// MARK: Permissions and stored text

// parity: SET-352 SET-353 SET-354 SET-355 SET-356
#[flow_ui::gpui::test]
async fn permission_requests_write_swifts_status(cx: &mut TestAppContext) {
    let r = rig(cx, "permissions-refused", |_| {});
    assert_eq!(label(cx, r.win, "settings.allow.Microphone"), "Allow Microphone");
    assert_saw(&["Allow…"]);
    assert!(bounds(cx, r.win, "settings.allow.Microphone").size.width >= px(99.));
    set(cx, r.win, |p, _, _| p.performing = true);
    assert!(disabled(cx, r.win, "settings.allow.Microphone"));
    set(cx, r.win, |p, _, _| p.performing = false);
    click(cx, r.win, "settings.allow.Microphone");
    assert!(logged(&r, "settings Microphone"), "denied opens the pane");
    assert_eq!(read(cx, r.win, |p, _| p.snapshot.status.clone()), "Microphone permission is needed for dictation.");
    let installs = |r: &Rig| r.log.borrow().iter().filter(|l| *l == "install").count();
    let before = installs(&r);
    click(cx, r.win, "settings.allow.Input Monitoring");
    assert!(logged(&r, "settings InputMonitoring"));
    assert_eq!(installs(&r), before + 1, "reinstalls the saved shortcut");
    let r = rig(cx, "", |_| {});
    r.permissions.set(PermissionState::Granted);
    click(cx, r.win, "settings.allow.Microphone");
    assert_eq!(read(cx, r.win, |p, _| p.snapshot.status.clone()), "Microphone allowed.");
    // Meetings never see the row, so the Swift guard has nothing to stop here.
    let r = rig(cx, "meeting-only", |_| {});
    assert!(!has(cx, r.win, "settings.allow.Input Monitoring"));
    assert!(has(cx, r.win, "settings.allow.Microphone"));
}

// parity: SET-388 SET-389 SET-393
#[flow_ui::gpui::test]
async fn text_prefs_start_empty_and_store_raw_text(cx: &mut TestAppContext) {
    let r = rig(cx, "summary-remote", |_| {});
    assert_eq!(read(cx, r.win, |p, cx| val(&p.endpoint, cx)), "");
    assert_eq!(read(cx, r.win, |p, cx| val(&p.summary_url, cx)), "");
    assert_eq!(read(cx, r.win, |p, cx| val(&p.summary_model, cx)), "");
    type_into(cx, r.win, |p| p.endpoint.clone(), " not a url ");
    assert_eq!(pref_s(cx, "rewriteEndpoint").as_deref(), Some(" not a url "));
    type_into(cx, r.win, |p| p.summary_url.clone(), " u ");
    assert_eq!(pref_s(cx, "summaryServerURL").as_deref(), Some(" u "));
    type_into(cx, r.win, |p| p.summary_model.clone(), "m");
    assert_eq!(pref_s(cx, "summaryServerModel").as_deref(), Some("m"));
}
