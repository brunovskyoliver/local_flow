//! The live rewrite: `RewriteCoordinator` for one dictation, over the channel or `POST /v1/rewrite`.
use super::session::{Rewriter, Rewritten};
use crate::db::Db;
use crate::history::{Admission, RewriteRequest, admit_rewrite, live_rewrite_notice, record_rewrite_result, send_rewrite, send_rewrite_over_channel, terminate_rewrite};
use crate::remote::pool::Pool;
use crate::settings::RewriteSettings;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

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
}

/// What one attempt ended with. `Cancelled` keeps the original text without a notice.
pub enum Done {
    NotEligible,
    Text { text: String, attempt: String },
    Failed(&'static str),
    Cancelled,
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
        Some(pool) => send_rewrite_over_channel(pool, &request, plan.timeout, cancel),
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
        Err(category) => {
            let _ = terminate_rewrite(db, &attempt, Some(category), elapsed);
            Done::Failed(category)
        }
    }
}

/// `RewriteActionNotice.canRetry`: never for the attempt limit.
pub fn can_retry(category: &str) -> bool {
    category != "attempt_limit"
}

/// `Rewriter` over its own connection: the session's history uses the other.
pub struct Live {
    pub db: Db,
    pub plan: Plan,
}

impl Rewriter for Live {
    fn rewrite(&mut self, id: &str, text: &str, started: &mut dyn FnMut(), cancel: &Arc<AtomicBool>) -> Rewritten {
        match run(&self.db, &self.plan, id, text, started, cancel) {
            Done::NotEligible | Done::Cancelled => Rewritten::NotEligible,
            Done::Text { text, attempt } => Rewritten::Text { text, attempt },
            Done::Failed(category) => Rewritten::Notice { message: live_rewrite_notice(category), can_retry: can_retry(category) },
        }
    }
}

/// `RewriteCoordinator.retry`: same input as the first attempt; the result is stored, never inserted.
/// The notice text when it fails, for the pill.
pub fn retry(db: &Db, plan: &Plan, dictation: &str) -> Option<(String, bool)> {
    let first: Option<String> = db.conn.query_row("SELECT input_text FROM rewrite_attempts WHERE transcription_id=? ORDER BY ordinal LIMIT 1", [dictation], |r| r.get(0)).ok();
    let text = first.or_else(|| db.conn.query_row("SELECT text FROM transcriptions WHERE id=?", [dictation], |r| r.get(0)).ok())?;
    match run(db, plan, dictation, &text, &mut || {}, &Arc::new(AtomicBool::new(false))) {
        Done::Failed(category) => Some((crate::history::rewrite_notice(category).into(), can_retry(category))),
        _ => None,
    }
}
