//! Explicit insertion: the review sheet, the confirmation panel and the state machine behind them
//! (Swift's `ExplicitInsertionCoordinator`). Focused-field capture is `Services`; until it's built,
//! the panel reports no supported field rather than pretending to find one.
use crate::core::Core;
use crate::shell::{DictState, modal, update_session};
use flow_core::history;
use flow_platform::{CapturedTarget, InsertDelivery, InsertOutcome};
use flow_ui::prelude::*;
use flow_ui::tokens::pill;
use std::time::Duration;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Phase {
    #[default]
    Idle,
    Reviewing,
    Selecting,
    Confirming,
    Inserting,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Quality {
    Complete,
    Incomplete,
    DurationLimited,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Delivery {
    None,
    Attempting,
    Uncertain,
    Confirmed,
}

/// The saved transcript or chosen rewrite the History page asks to insert.
#[derive(Clone)]
pub struct ReviewEntry {
    pub id: String,
    pub text: String,
    pub quality: Quality,
    pub delivery: Delivery,
}

#[derive(Default)]
pub struct Insertion {
    pub phase: Phase,
    pub entry: Option<ReviewEntry>,
    pub message: String,
    pub target: Option<CapturedTarget>,
    pub capturing: bool,
    pub cancelled: bool,
    pub expired: bool,
    /// The row's revision when the review opened, and the rewrite attempt this text came from.
    source: Option<(i64, Option<String>)>,
    generation: u64,
    /// The last `finish` message, which Swift stores in `coordinator.status` (SHELL-234).
    pub finished: Option<String>,
}

impl Insertion {
    /// Changes when an operation starts or finishes; History reloads on it (`refreshHistory`).
    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn is_active(&self) -> bool {
        self.phase != Phase::Idle
    }
    pub fn is_reviewing(&self) -> bool {
        self.phase == Phase::Reviewing
    }
    pub fn panel_visible(&self) -> bool {
        matches!(self.phase, Phase::Selecting | Phase::Confirming | Phase::Inserting)
    }
    pub fn warnings(&self) -> Vec<&'static str> {
        let Some(e) = &self.entry else { return vec![] };
        let mut v = vec![];
        match e.quality {
            Quality::Incomplete => v.push("This transcription is incomplete. Review the text before inserting."),
            Quality::DurationLimited => v.push("Recording stopped at 180 seconds. The ending may be missing."),
            Quality::Complete => {}
        }
        match e.delivery {
            Delivery::Uncertain | Delivery::Attempting => v.push("This text may already be in the destination. Inserting again could duplicate it."),
            Delivery::Confirmed => v.push("This text was already inserted. Inserting again creates another copy."),
            Delivery::None => {}
        }
        v
    }
}

/// `services.reviewInsertion`: silent `false` when anything refuses, as in Swift.
pub fn begin_review(entry: ReviewEntry, cx: &mut App) -> bool {
    let source = cx.global::<Core>().db.as_ref().and_then(|db| {
        let row = history::get(db, &entry.id).ok()??;
        // ponytail: found by text because History passes only the text; two attempts with the same words mark the first as delivered.
        let attempt = if row.text == entry.text { None } else { history::attempts(db, &entry.id).ok()?.into_iter().find(|a| a.deliverable() == Some(entry.text.as_str())).map(|a| a.id) };
        Some((row.revision, attempt))
    });
    update_session(cx, |s| {
        if s.installing || s.model_command || s.insertion.phase != Phase::Idle {
            return false;
        }
        // `acquireExplicitInsertion`.
        let Some(d) = s.dictation.as_mut() else { return false };
        if d.busy || d.unsaved.is_some() || d.storage_blocked || d.cleanup_blocked {
            return false;
        }
        d.busy = true;
        let i = &mut s.insertion;
        i.generation += 1;
        i.cancelled = false;
        i.expired = false;
        i.entry = Some(entry);
        i.source = source;
        i.message = "Review the text, then choose a destination.".into();
        i.phase = Phase::Reviewing;
        true
    })
}

/// `armSelection`: closes the sheet, shows the panel, starts the 60 s deadline.
pub fn arm_selection(cx: &mut App) {
    let token = update_session(cx, |s| {
        let i = &mut s.insertion;
        if i.phase != Phase::Reviewing {
            return None;
        }
        i.phase = Phase::Selecting;
        i.message = "Focus the destination field, then click Use focused field here.".into();
        Some(i.generation)
    });
    let Some(token) = token else { return };
    sync_panel(cx);
    cx.spawn(async move |cx| {
        cx.background_executor().timer(Duration::from_secs(60)).await;
        let _ = cx.update(|cx| {
            let i = &cx.global::<crate::shell::Session>().insertion;
            if i.generation == token && i.phase == Phase::Selecting {
                update_session(cx, |s| s.insertion.expired = true);
                cancel(cx);
            }
        });
    })
    .detach();
}

/// `selectTarget`: checking shows for at least a frame, because the capture is asynchronous in Swift.
pub fn select_target(cx: &mut App) {
    let token = update_session(cx, |s| {
        let i = &mut s.insertion;
        if i.phase != Phase::Selecting || i.capturing || i.cancelled {
            return None;
        }
        i.capturing = true;
        i.message = "Checking the focused field…".into();
        Some(i.generation)
    });
    let Some(token) = token else { return };
    cx.spawn(async move |cx| {
        cx.background_executor().timer(Duration::from_millis(1)).await;
        let _ = cx.update(|cx| {
            // A failed or missing capture reads as no supported field, the state Swift has for `nil`.
            let selected = cx.global::<Core>().services.capture_insertion_target().ok().flatten().filter(|t| !t.own_process);
            update_session(cx, |s| {
                let i = &mut s.insertion;
                if i.generation != token {
                    return;
                }
                i.capturing = false;
                if i.cancelled {
                    return;
                }
                match selected {
                    Some(t) => {
                        i.message = match t.delivery {
                            InsertDelivery::Paste => format!("Paste into the focused {} window?", t.bundle_id),
                            InsertDelivery::Accessibility => format!("Insert into {}, selected field at character {}?", t.bundle_id, t.selection_location + 1),
                        };
                        i.target = Some(t);
                        i.phase = Phase::Confirming;
                    }
                    None => i.message = "Choose a supported editable field in another app, then click Use focused field.".into(),
                }
            });
            let i = &cx.global::<crate::shell::Session>().insertion;
            if i.generation == token && i.cancelled && i.phase == Phase::Selecting {
                let message = stop_message(i.expired);
                finish(message, cx);
            }
        });
    })
    .detach();
}

fn stop_message(expired: bool) -> &'static str {
    if expired { "Selection expired. Your text remains saved." } else { "Insertion cancelled. The text remains saved." }
}

const PREPARE_FAILED: &str = "Could not prepare insertion. The text remains saved; refresh history and try again.";

/// `confirm`: once, with the attempt recorded before dispatch and the outcome after.
pub fn confirm(cx: &mut App) {
    let ready = update_session(cx, |s| {
        let i = &mut s.insertion;
        if i.phase != Phase::Confirming || i.target.is_none() || i.entry.is_none() {
            return false;
        }
        i.phase = Phase::Inserting;
        i.message = "Inserting…".into();
        true
    });
    if !ready {
        return;
    }
    cx.spawn(async move |cx| {
        cx.background_executor().timer(Duration::from_millis(1)).await;
        let _ = cx.update(|cx| {
            let s = cx.global::<crate::shell::Session>();
            let (cancelled, target, entry, source) = (s.insertion.cancelled, s.insertion.target.clone(), s.insertion.entry.clone(), s.insertion.source.clone());
            let (Some(entry), Some((revision, rewrite))) = (entry, source) else {
                finish(PREPARE_FAILED, cx);
                return;
            };
            let core = cx.global::<Core>();
            let Some(Ok((attempt, revision))) = core.db.as_ref().map(|db| history::begin_attempt(db, &entry.id, revision)) else {
                finish(PREPARE_FAILED, cx);
                return;
            };
            let outcome = match (cancelled, target) {
                (false, Some(t)) => core.services.insert_once(&t, &entry.text).unwrap_or(InsertOutcome::NotInserted),
                _ => InsertOutcome::NotInserted,
            };
            let recorded = match outcome {
                InsertOutcome::Confirmed => history::Outcome::Confirmed,
                InsertOutcome::NotInserted => history::Outcome::NotInserted,
                InsertOutcome::Uncertain => history::Outcome::Uncertain,
            };
            match core.db.as_ref().map(|db| history::record_outcome(db, &entry.id, revision, &attempt, recorded, rewrite.as_deref())) {
                Some(Ok(_)) => finish(outcome_message(Ok(outcome)), cx),
                _ => outcome_not_saved(cx),
            }
        });
    })
    .detach();
}

/// The finish copy for an outcome, or for one that couldn't be recorded.
pub fn outcome_message(result: Result<InsertOutcome, ()>) -> &'static str {
    match result {
        Ok(InsertOutcome::Confirmed) => "Text inserted. The original remains in history.",
        Ok(InsertOutcome::NotInserted) => "Nothing was inserted. Review the saved text and choose the field again.",
        Ok(InsertOutcome::Uncertain) => "Delivery is uncertain. Check the destination before inserting again.",
        Err(()) => "Delivery status could not be saved. Retry storage before continuing.",
    }
}

/// `preserveExplicitOutcome`: a recorded failure keeps the outcome and blocks storage.
pub fn outcome_not_saved(cx: &mut App) {
    update_session(cx, |s| s.dictation.as_mut().unwrap().storage_blocked = true);
    finish(outcome_message(Err(())), cx);
}

pub fn cancel(cx: &mut App) {
    let i = &cx.global::<crate::shell::Session>().insertion;
    let (phase, capturing, expired) = (i.phase, i.capturing, i.expired);
    if phase == Phase::Idle {
        return;
    }
    update_session(cx, |s| s.insertion.cancelled = true);
    match phase {
        Phase::Selecting if capturing => update_session(cx, |s| s.insertion.message = "Cancelling selection…".into()),
        Phase::Selecting => finish(stop_message(expired), cx),
        Phase::Inserting => update_session(cx, |s| s.insertion.message = "Finishing delivery status…".into()),
        _ => finish(stop_message(false), cx),
    }
}

/// Clears the operation, closes the panel, releases busy.
fn finish(message: &str, cx: &mut App) {
    update_session(cx, |s| {
        let generation = s.insertion.generation + 1;
        s.insertion = Insertion { generation, finished: Some(message.to_string()), message: message.to_string(), ..Default::default() };
        if let Some(d) = s.dictation.as_mut() {
            d.busy = false;
            d.status = message.to_string();
            d.state = if d.state == DictState::Failed { DictState::Failed } else { DictState::Idle };
        }
    });
    sync_panel(cx);
}

/// Sheet width 520, padding 26, spacing 18.
pub fn review_sheet(cx: &mut App) -> impl IntoElement {
    let p = pal(cx);
    let i = &cx.global::<crate::shell::Session>().insertion;
    let warnings = i.warnings();
    let text = i.entry.as_ref().map(|e| e.text.clone()).unwrap_or_default();
    modal(
        "insertion.review",
        520.,
        26.,
        cx,
        v_flex()
            .gap(px(18.))
            .child(t("Review before inserting").font(26., 600.))
            .children(warnings.into_iter().map(|w| sf_label("exclamationmark.triangle", w, 14., p.ink)))
            .child(div().id("insertion.text").max_h(px(300.)).overflow_y_scroll().child(t(text)))
            .child(t("Choose a destination, then switch to the app and click an editable field. LocalFlow will ask you to confirm before inserting.").color(p.muted))
            .child(
                h_flex()
                    .justify_between()
                    .child(prototype_button("insertion.cancel", "Cancel").on_click(|_, _, cx| cancel(cx)))
                    .child(primary_button("insertion.choose", "Choose destination").fill(p.accent).on_click(|_, _, cx| arm_selection(cx))),
            ),
    )
}

/// `InsertionConfirmationPanel`: a floating window that never takes focus from the destination.
pub struct ConfirmationPanel {
    _sub: Subscription,
}

impl ConfirmationPanel {
    pub fn new(cx: &mut Context<Self>) -> Self {
        ConfirmationPanel { _sub: cx.observe_global::<crate::shell::Session>(|_, cx| cx.notify()) }
    }
}

impl Render for ConfirmationPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = pal(cx);
        let i = &cx.global::<crate::shell::Session>().insertion;
        let selecting = i.phase == Phase::Selecting;
        let enabled = if selecting { !i.capturing && !i.cancelled } else { i.phase == Phase::Confirming };
        let message = i.message.clone();
        v_flex()
            .id("insertion.panel")
            .size_full()
            .justify_center()
            .gap(px(16.))
            .px(px(20.))
            .bg(pill::window_background(p.mode.is_dark()))
            .text_color(p.ink)
            .font_family(FIGTREE)
            .child(t(message).size(13.))
            .child(
                h_flex()
                    .gap(px(12.))
                    .child(prototype_button("insertion.panel.cancel", "Cancel").on_click(|_, _, cx| cancel(cx)))
                    .child(
                        prototype_button("insertion.panel.confirm", if selecting { "Use focused field" } else { "Confirm insertion" })
                            .disabled(!enabled)
                            .on_click(move |_, _, cx| if selecting { select_target(cx) } else { confirm(cx) }),
                    ),
            )
    }
}

struct PanelWindow(AnyWindowHandle);
impl Global for PanelWindow {}

/// x = visible `midX - 210`, y = visible `minY + 70`, in GPUI's top-left coordinates.
pub fn panel_bounds(visible: Bounds<Pixels>) -> Bounds<Pixels> {
    let origin = point(visible.origin.x + visible.size.width / 2. - px(210.), visible.origin.y + visible.size.height - px(70.) - px(138.));
    Bounds { origin, size: size(px(420.), px(138.)) }
}

/// Opens or closes the panel to match the phase.
fn sync_panel(cx: &mut App) {
    let show = cx.global::<crate::shell::Session>().insertion.panel_visible();
    let open = cx.try_global::<PanelWindow>().map(|p| p.0);
    match (show, open) {
        (true, None) => {
            let visible = cx.primary_display().map(|d| d.visible_bounds()).unwrap_or(Bounds { origin: point(px(0.), px(0.)), size: size(px(1280.), px(800.)) });
            let options = WindowOptions { window_bounds: Some(WindowBounds::Windowed(panel_bounds(visible))), titlebar: None, focus: false, kind: WindowKind::PopUp, is_movable: false, is_resizable: false, ..Default::default() };
            if let Ok((handle, _)) = flow_ui::open_window(options, cx, |_, cx| cx.new(ConfirmationPanel::new)) {
                cx.set_global(PanelWindow(handle));
            }
        }
        (false, Some(handle)) => {
            cx.remove_global::<PanelWindow>();
            let _ = handle.update(cx, |_, w, _| w.remove_window());
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::{Dictation, Session, Shell, ensure_session};
    use crate::testing::{assert_saw, boot};
    use flow_platform::Fake;
    use flow_ui::test::{TestAppContext, TestWindowExt};

    fn row_id() -> String {
        history::seed_id(20)
    }

    fn entry() -> ReviewEntry {
        ReviewEntry { id: row_id(), text: "Saved words".into(), quality: Quality::Complete, delivery: Delivery::None }
    }

    fn phase(cx: &mut TestAppContext) -> Phase {
        cx.update(|cx| cx.global::<Session>().insertion.phase)
    }

    fn message(cx: &mut TestAppContext) -> String {
        cx.update(|cx| cx.global::<Session>().insertion.message.clone())
    }

    fn start(cx: &mut TestAppContext, target: Option<CapturedTarget>, outcome: Option<InsertOutcome>) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            ensure_session(cx);
            let fake = Fake::default();
            *fake.target.borrow_mut() = target;
            fake.insert_outcome.set(outcome);
            cx.global_mut::<Core>().services = Box::new(fake);
            assert!(begin_review(entry(), cx));
        });
    }

    fn field() -> CapturedTarget {
        CapturedTarget { bundle_id: "com.example.app".into(), own_process: false, delivery: InsertDelivery::Accessibility, selection_location: 4 }
    }

    // parity: SHELL-145 SHELL-146
    #[flow_ui::gpui::test]
    async fn begin_review_refuses_silently(cx: &mut TestAppContext) {
        boot(cx, Mode::Light);
        cx.update(|cx| {
            ensure_session(cx);
            for block in [
                (|s: &mut Session| s.installing = true) as fn(&mut Session),
                |s| s.model_command = true,
                |s| s.dictation.as_mut().unwrap().busy = true,
                |s| s.dictation.as_mut().unwrap().unsaved = Some("x".into()),
                |s| s.dictation.as_mut().unwrap().storage_blocked = true,
                |s| s.dictation.as_mut().unwrap().cleanup_blocked = true,
            ] {
                update_session(cx, block);
                assert!(!begin_review(entry(), cx));
                update_session(cx, |s| {
                    s.installing = false;
                    s.model_command = false;
                    s.dictation = Some(Dictation::default());
                });
            }
            assert!(begin_review(entry(), cx));
            assert!(cx.global::<Session>().dictation.as_ref().unwrap().busy);
            assert!(!begin_review(entry(), cx));
        });
    }

    // parity: SHELL-147 SHELL-148 SHELL-149 SHELL-150 SHELL-151 SHELL-152 SHELL-153 SHELL-154 SHELL-155 SHELL-156 SHELL-172 SHELL-178
    #[flow_ui::gpui::test]
    async fn review_sheet_shows_warnings_and_buttons_work(cx: &mut TestAppContext) {
        start(cx, None, None);
        cx.update(|cx| cx.global_mut::<Core>().prefs.set("setupVersion", 1));
        let window = cx.add_window(|w, cx| Shell::new(w, cx));
        cx.run_until_parked();
        flow_ui::probe::clear();
        cx.update_window(window.into(), |_, w, cx| w.render_frame(cx)).unwrap();
        assert_saw(&["Review before inserting", "Saved words", "Choose a destination, then switch to the app and click an editable field. LocalFlow will ask you to confirm before inserting.", "Cancel", "Choose destination"]);
        for (q, d, expect) in [
            (Quality::Incomplete, Delivery::None, "This transcription is incomplete. Review the text before inserting."),
            (Quality::DurationLimited, Delivery::None, "Recording stopped at 180 seconds. The ending may be missing."),
            (Quality::Complete, Delivery::Uncertain, "This text may already be in the destination. Inserting again could duplicate it."),
            (Quality::Complete, Delivery::Attempting, "This text may already be in the destination. Inserting again could duplicate it."),
            (Quality::Complete, Delivery::Confirmed, "This text was already inserted. Inserting again creates another copy."),
        ] {
            cx.update(|cx| update_session(cx, |s| {
                let e = s.insertion.entry.as_mut().unwrap();
                e.quality = q;
                e.delivery = d;
            }));
            flow_ui::probe::clear();
            cx.run_until_parked();
            cx.update_window(window.into(), |_, w, cx| w.render_frame(cx)).unwrap();
            assert_saw(&[expect]);
        }
        cx.update_window(window.into(), |_, w, cx| w.click("insertion.cancel", cx)).unwrap();
        cx.run_until_parked();
        assert_eq!(phase(cx), Phase::Idle);
        cx.update(|cx| {
            let d = cx.global::<Session>().dictation.clone().unwrap();
            assert!(!d.busy);
            assert_eq!(d.status, "Insertion cancelled. The text remains saved.");
            assert!(cx.global::<Session>().insertion.entry.is_none());
            assert!(begin_review(entry(), cx));
        });
        cx.run_until_parked();
        cx.update_window(window.into(), |_, w, cx| w.render_frame(cx)).unwrap();
        cx.update_window(window.into(), |_, w, cx| w.click("insertion.choose", cx)).unwrap();
        assert_eq!(phase(cx), Phase::Selecting);
        cx.update(cancel);
    }

    // parity: SHELL-157 SHELL-158 SHELL-160 SHELL-161 SHELL-162 SHELL-163 SHELL-165 SHELL-168 SHELL-167 SHELL-173
    #[flow_ui::gpui::test]
    async fn panel_runs_select_confirm_insert(cx: &mut TestAppContext) {
        start(cx, Some(field()), Some(InsertOutcome::Confirmed));
        cx.update(arm_selection);
        let panel = cx.add_window(|_, cx| ConfirmationPanel::new(cx));
        cx.update_window(panel.into(), |_, w, cx| w.render_frame(cx)).unwrap();
        assert_saw(&["Focus the destination field, then click Use focused field here.", "Use focused field", "Cancel"]);
        cx.update_window(panel.into(), |_, w, cx| w.click("insertion.panel.confirm", cx)).unwrap();
        assert_eq!(message(cx), "Checking the focused field…");
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        assert_eq!(phase(cx), Phase::Confirming);
        assert_eq!(message(cx), "Insert into com.example.app, selected field at character 5?");
        flow_ui::probe::clear();
        cx.update_window(panel.into(), |_, w, cx| w.render_frame(cx)).unwrap();
        assert_saw(&["Confirm insertion"]);
        cx.update_window(panel.into(), |_, w, cx| w.click("insertion.panel.confirm", cx)).unwrap();
        assert_eq!((phase(cx), message(cx).as_str()), (Phase::Inserting, "Inserting…"));
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        assert_eq!(phase(cx), Phase::Idle);
        cx.update(|cx| assert_eq!(cx.global::<Session>().insertion.finished.as_deref(), Some("Text inserted. The original remains in history.")));
    }

    // parity: SHELL-159
    #[test]
    fn panel_sits_near_the_bottom_center() {
        let visible = Bounds { origin: point(px(0.), px(25.)), size: size(px(1440.), px(800.)) };
        let b = panel_bounds(visible);
        assert_eq!((b.origin.x, b.origin.y, b.size.width, b.size.height), (px(510.), px(617.), px(420.), px(138.)));
    }

    // parity: SHELL-163 SHELL-164
    #[flow_ui::gpui::test]
    async fn unsupported_and_paste_targets(cx: &mut TestAppContext) {
        start(cx, Some(CapturedTarget { own_process: true, ..field() }), None);
        cx.update(arm_selection);
        cx.update(select_target);
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        assert_eq!(message(cx), "Choose a supported editable field in another app, then click Use focused field.");
        assert_eq!(phase(cx), Phase::Selecting);
        cx.update(|cx| {
            let fake = Fake::default();
            *fake.target.borrow_mut() = Some(CapturedTarget { delivery: InsertDelivery::Paste, ..field() });
            cx.global_mut::<Core>().services = Box::new(fake);
            select_target(cx);
        });
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        assert_eq!(message(cx), "Paste into the focused com.example.app window?");
        cx.update(cancel);
    }

    // parity: SHELL-169 SHELL-170 SHELL-171 SHELL-174 SHELL-175 SHELL-176 SHELL-177
    #[flow_ui::gpui::test]
    async fn cancelling_and_failure_copy(cx: &mut TestAppContext) {
        start(cx, Some(field()), Some(InsertOutcome::Uncertain));
        cx.update(arm_selection);
        cx.update(select_target);
        cx.update(cancel);
        assert_eq!(message(cx), "Cancelling selection…");
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        assert_eq!(phase(cx), Phase::Idle);
        let finished = |cx: &mut TestAppContext| cx.update(|cx| cx.global::<Session>().insertion.finished.clone().unwrap());
        assert_eq!(finished(cx), "Insertion cancelled. The text remains saved.");

        // Cancel before dispatch records not inserted.
        cx.update(|cx| assert!(begin_review(entry(), cx)));
        cx.update(arm_selection);
        cx.update(select_target);
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        cx.update(confirm);
        cx.update(cancel);
        assert_eq!(message(cx), "Finishing delivery status…");
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        assert_eq!(finished(cx), "Nothing was inserted. Review the saved text and choose the field again.");

        // The outcome the destination reported.
        cx.update(|cx| assert!(begin_review(entry(), cx)));
        cx.update(arm_selection);
        cx.update(select_target);
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        cx.update(confirm);
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        assert_eq!(finished(cx), "Delivery is uncertain. Check the destination before inserting again.");

        // Selection expires after 60 s.
        cx.update(|cx| assert!(begin_review(entry(), cx)));
        cx.update(arm_selection);
        cx.executor().advance_clock(Duration::from_secs(61));
        cx.run_until_parked();
        assert_eq!(finished(cx), "Selection expired. Your text remains saved.");

        // An outcome that can't be recorded blocks storage.
        cx.update(|cx| assert!(begin_review(entry(), cx)));
        cx.update(outcome_not_saved);
        assert_eq!(finished(cx), "Delivery status could not be saved. Retry storage before continuing.");
        cx.update(|cx| assert!(cx.global::<Session>().dictation.as_ref().unwrap().storage_blocked));

        // A store that can't open never starts the attempt.
        cx.update(|cx| {
            update_session(cx, |s| s.dictation.as_mut().unwrap().storage_blocked = false);
            assert!(begin_review(entry(), cx));
        });
        cx.update(arm_selection);
        cx.update(select_target);
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        cx.update(|cx| {
            cx.global_mut::<Core>().db = None;
            confirm(cx);
        });
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        assert_eq!(finished(cx), "Could not prepare insertion. The text remains saved; refresh history and try again.");
    }

    fn run_to_outcome(cx: &mut TestAppContext) {
        cx.update(arm_selection);
        cx.update(select_target);
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        cx.update(confirm);
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
    }

    fn row(cx: &mut TestAppContext) -> history::Entry {
        cx.update(|cx| history::get(cx.global::<Core>().db.as_ref().unwrap(), &row_id()).unwrap().unwrap())
    }

    // parity: SHELL-166 SHELL-174 SHELL-175 SHELL-176 SHELL-177
    /// The attempt is written before dispatch and the outcome after, against the row's revision.
    #[flow_ui::gpui::test]
    async fn delivery_is_recorded_around_the_insert(cx: &mut TestAppContext) {
        start(cx, Some(field()), Some(InsertOutcome::Uncertain));
        let before = row(cx).revision;
        run_to_outcome(cx);
        let saved = row(cx);
        assert_eq!((saved.delivery_state.as_str(), saved.revision), ("uncertain", before + 2));
        assert_eq!(saved.delivered_source.as_deref(), Some("faithful"));

        // A row that changed after the review opened is never dispatched.
        cx.update(|cx| assert!(begin_review(entry(), cx)));
        cx.update(|cx| cx.global::<Core>().db.as_ref().unwrap().conn.execute("UPDATE transcriptions SET revision=revision+1 WHERE id=?", [row_id()]).unwrap());
        let stale = row(cx).revision;
        run_to_outcome(cx);
        cx.update(|cx| assert_eq!(cx.global::<Session>().insertion.finished.as_deref(), Some(PREPARE_FAILED)));
        assert_eq!((row(cx).delivery_state.as_str(), row(cx).revision), ("uncertain", stale));

        // An outcome the store refuses blocks storage. A trigger fails only the outcome write.
        cx.update(|cx| {
            cx.global::<Core>().db.as_ref().unwrap().conn.execute_batch("CREATE TEMP TRIGGER refuse BEFORE UPDATE OF delivery_state ON transcriptions WHEN NEW.delivery_state <> 'attempting' BEGIN SELECT RAISE(ABORT, 'refused'); END;").unwrap();
            assert!(begin_review(entry(), cx));
        });
        run_to_outcome(cx);
        cx.update(|cx| {
            let s = cx.global::<Session>();
            assert_eq!(s.insertion.finished.as_deref(), Some("Delivery status could not be saved. Retry storage before continuing."));
            assert!(s.dictation.as_ref().unwrap().storage_blocked);
        });
    }

    // parity: SHELL-145 SHELL-166
    /// Text from a succeeded rewrite marks that attempt delivered; the transcript marks the source faithful.
    #[flow_ui::gpui::test]
    async fn a_rewrite_marks_its_attempt_delivered(cx: &mut TestAppContext) {
        start(cx, Some(field()), Some(InsertOutcome::Confirmed));
        cx.update(cancel);
        cx.executor().advance_clock(Duration::from_millis(5));
        cx.run_until_parked();
        let (id, text, attempt) = cx.update(|cx| {
            let db = cx.global::<Core>().db.as_ref().unwrap();
            db.conn.execute("INSERT INTO rewrite_attempts (id,transcription_id,ordinal,mode,state,input_text,input_hash,output_text,output_hash,unchanged,started_at,protocol_version,endpoint_origin,delivered) VALUES ('att1',?,1,'clean','succeeded','in','h','Rewritten words','h',0,0,1,'https://rewrite.example.test',0)", [row_id()]).unwrap();
            (row_id(), "Rewritten words".to_string(), "att1")
        });
        cx.update(|cx| assert!(begin_review(ReviewEntry { id, text, quality: Quality::Complete, delivery: Delivery::None }, cx)));
        run_to_outcome(cx);
        let saved = row(cx);
        assert_eq!((saved.delivery_state.as_str(), saved.delivered_source.as_deref(), saved.delivered_rewrite_attempt_id.as_deref()), ("confirmed", Some("rewrite"), Some(attempt)));
    }
}
