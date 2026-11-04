//! The live rewrite: `RewriteCoordinator` for one dictation, over the channel or `POST /v1/rewrite`.
use super::cooling::Cooling;
use super::session::{Progress, Rewriter, Rewritten};
use crate::db::Db;
use crate::history::{Admission, RewriteRequest, admit_rewrite, live_rewrite_notice, record_rewrite_result, send_rewrite, send_rewrite_over_channel, skip_rewrite, terminate_rewrite};
use crate::local_model::{Wait, wait_until_ready};
use crate::remote::pool::Pool;
use crate::settings::RewriteSettings;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::time::{Duration, Instant};

/// From the transcript, how long a live dictation waits for the rewrite model to be working: this
/// Mac's model to report ready, or the server's first sign of generating. Past it the plain text
/// goes in and the model keeps loading for the next dictation.
pub const REWRITE_READY_BUDGET: Duration = Duration::from_secs(3);

/// Everything a press captures about rewriting, so a settings change affects the next one.
#[derive(Clone)]
pub struct Plan {
    pub enabled: bool,
    pub mode: &'static str,
    pub settings: RewriteSettings,
    pub timeout: Duration,
    /// `None` is `POST /v1/rewrite`.
    pub channel: Option<Arc<Pool>>,
    pub secret: Option<String>,
    /// `REWRITE_READY_BUDGET` for a live dictation; `None` where nobody waits to insert, as a retry.
    pub ready: Option<Duration>,
}

/// What one attempt ended with.
pub enum Done {
    NotEligible,
    Text { text: String, attempt: String },
    Failed(&'static str),
    Cancelled,
    /// Not waited for: `model_starting` or `server_unavailable`. Recorded, not a failure.
    Skipped(&'static str),
}

/// Admission, transport, record: `RewriteCoordinator.rewrite`.
// ponytail: live dictations have no `dictation_contexts` row until context capture is ported, so
// these are all v1; History sends v2 for rows that have one.
pub fn run(db: &Db, plan: &Plan, dictation: &str, text: &str, started: &mut dyn FnMut(), cancel: &Arc<AtomicBool>) -> Done {
    if plan.mode == "exact" {
        return Done::NotEligible;
    }
    let attempt = match admit_rewrite(db, dictation, text, plan.mode, plan.enabled, &plan.settings, None) {
        Admission::NotEligible => return Done::NotEligible,
        Admission::Refused(category) => return Done::Failed(category),
        Admission::Admitted(attempt) => attempt,
    };
    started();
    let began = Instant::now();
    let request = RewriteRequest { dictation: dictation.into(), attempt: attempt.clone(), mode: plan.mode, text: text.into(), origin: plan.settings.origin.clone(), context: None };
    let answer = match &plan.channel {
        Some(pool) => send_rewrite_over_channel(pool, &request, plan.timeout, plan.ready, cancel),
        None => send_rewrite(&request, plan.secret.as_deref(), plan.timeout, cancel.clone()),
    };
    let elapsed = Some(began.elapsed().as_millis() as i64);
    match answer {
        Ok(answer) => match record_rewrite_result(db, &attempt, &answer, elapsed) {
            Ok(()) => Done::Text { text: answer.text, attempt },
            Err(_) => Done::Failed("transport_error"),
        },
        Err("cancelled") => {
            let _ = terminate_rewrite(db, &attempt, None, elapsed);
            Done::Cancelled
        }
        Err("model_starting") => {
            let _ = skip_rewrite(db, &attempt, "model_starting", elapsed);
            Done::Skipped("model_starting")
        }
        Err(category) => {
            let _ = terminate_rewrite(db, &attempt, Some(category), elapsed);
            Done::Failed(category)
        }
    }
}

/// A rewrite the dictation won't wait for, admitted as `run` would and recorded as skipped.
pub fn skip(db: &Db, plan: &Plan, dictation: &str, text: &str, reason: &'static str, waited: Duration) -> Done {
    if plan.mode == "exact" {
        return Done::NotEligible;
    }
    match admit_rewrite(db, dictation, text, plan.mode, plan.enabled, &plan.settings, None) {
        Admission::NotEligible => Done::NotEligible,
        Admission::Refused(category) => Done::Failed(category),
        Admission::Admitted(attempt) => {
            let _ = skip_rewrite(db, &attempt, reason, Some(waited.as_millis() as i64));
            Done::Skipped(reason)
        }
    }
}

/// `RewriteActionNotice.canRetry`: never for the attempt limit.
pub fn can_retry(category: &str) -> bool {
    category != "attempt_limit"
}

/// Waits up to the limit for the model a `POST /v1/rewrite` plan reaches, calling the closure once
/// when it isn't up yet. `wait_until_ready` outside tests.
pub type ModelWait = Box<dyn FnMut(&Plan, Duration, &AtomicBool, &mut dyn FnMut()) -> Wait + Send>;

/// `Rewriter` over its own connection: the session's history uses the other.
pub struct Live {
    pub db: Db,
    pub plan: Plan,
    /// The dictation server's state: a rewrite routed there is skipped while it cools.
    pub cooling: Option<Arc<Cooling>>,
    pub wait: ModelWait,
    /// How the last rewrite's wait for this Mac's model went, for the timing log.
    pub waited: Option<Wait>,
}

impl Live {
    pub fn new(db: Db, plan: Plan) -> Live {
        Live { db, plan, cooling: None, wait: Box::new(|plan, limit, cancel, starting| wait_until_ready(&plan.settings.origin, plan.secret.as_deref(), limit, cancel, starting)), waited: None }
    }
}

impl Rewriter for Live {
    fn rewrite(&mut self, id: &str, text: &str, progress: &mut dyn FnMut(Progress), cancel: &Arc<AtomicBool>) -> Rewritten {
        self.waited = None;
        let plan = &self.plan;
        let wanted = plan.enabled && plan.mode != "exact" && !text.trim().is_empty();
        if wanted && plan.channel.is_some() && self.cooling.as_ref().is_some_and(|c| c.skip(&plan.settings.origin).is_some()) {
            // The dictation just lost this server: the rewrite doesn't try it either.
            return outcome(skip(&self.db, plan, id, text, "server_unavailable", Duration::ZERO));
        }
        if wanted && plan.channel.is_none() {
            // "Starting AI…" shows only inside the budget; the wait ends with it.
            let wait = (self.wait)(plan, plan.ready.unwrap_or(plan.timeout), cancel, &mut || progress(Progress::StartingModel));
            self.waited = Some(wait);
            if !wait.ready && !cancel.load(SeqCst) && plan.ready.is_some() {
                return outcome(skip(&self.db, plan, id, text, "model_starting", wait.waited));
            }
        }
        outcome(run(&self.db, &self.plan, id, text, &mut || progress(Progress::Rewriting), cancel))
    }
}

fn outcome(done: Done) -> Rewritten {
    match done {
        Done::NotEligible => Rewritten::NotEligible,
        // `RewriteNotice.cancelled(.live)`.
        Done::Cancelled => Rewritten::Notice { message: "Rewrite cancelled. Original text inserted.".into(), can_retry: true },
        Done::Text { text, attempt } => Rewritten::Text { text, attempt },
        Done::Skipped(reason) => Rewritten::Skipped(reason),
        Done::Failed(category) => Rewritten::Notice { message: live_rewrite_notice(category), can_retry: can_retry(category) },
    }
}

/// `RewriteCoordinator.retry`: same input as the first attempt; the result is stored, never inserted.
/// The notice text when it fails, for the pill.
pub fn retry(db: &Db, plan: &Plan, dictation: &str) -> Option<(String, bool)> {
    let first: Option<String> = db.conn.query_row("SELECT input_text FROM rewrite_attempts WHERE transcription_id=? ORDER BY ordinal LIMIT 1", [dictation], |r| r.get(0)).ok();
    let text = first.or_else(|| db.conn.query_row("SELECT text FROM transcriptions WHERE id=?", [dictation], |r| r.get(0)).ok())?;
    // Nothing is inserted from a retry, so it waits for the model as long as the timeout allows.
    let plan = Plan { ready: None, ..plan.clone() };
    match run(db, &plan, dictation, &text, &mut || {}, &Arc::new(AtomicBool::new(false))) {
        Done::Failed(category) => Some((crate::history::rewrite_notice(category).into(), can_retry(category))),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // parity: PILL-100 PILL-104
    #[test]
    fn a_cancelled_rewrite_says_so_and_the_attempt_limit_offers_no_retry() {
        assert!(matches!(outcome(Done::Cancelled), Rewritten::Notice { ref message, can_retry: true } if message == "Rewrite cancelled. Original text inserted."));
        assert!(matches!(outcome(Done::Failed("attempt_limit")), Rewritten::Notice { ref message, can_retry: false } if message == "This dictation already has ten rewrite attempts."));
    }
}
