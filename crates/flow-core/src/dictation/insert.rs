//! `TextInsertionService` and `UnicodeTextDelivery`: the decisions of one insertion attempt, over a
//! target only the platform can touch. Field text passes through here and is never logged.
use super::session::InsertOutcome;
use std::time::{Duration, Instant};

pub const MAX_TEXT_BYTES: usize = 64 * 1024;
pub const MAX_CHUNK_UNITS: usize = 20;
pub const CONFIRM_EVERY: usize = 16;
pub const CONTEXT_UNITS: i64 = 4_096;
const READBACK_POLLS: usize = 50;
const READBACK_WAIT: Duration = Duration::from_millis(10);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Issue {
    AccessibilityDenied,
    SecureField,
    Unsupported,
    StaleProcess,
    FocusChanged,
    SelectionChanged,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dispatch {
    NoMutation,
    MutationMayHaveOccurred,
    /// Handed to a paste target, which offers no readback.
    Pasted,
}

/// What a platform can do with the field captured at key-down.
pub trait Target {
    /// `validate`: `None` is eligible.
    fn rejected(&self) -> Option<Issue>;
    fn is_paste(&self) -> bool;
    fn paste(&self, text: &str) -> Dispatch;
    /// Same app, element and window, and no password field.
    fn same_field(&self) -> bool;
    /// One keyboard event pair. False posted nothing.
    fn post(&self, chunk: &str) -> bool;
    /// One read of what the caret says was just delivered, `len` UTF-16 units.
    fn read_back(&self, units: i64) -> Result<String, Issue>;
}

/// A range in UTF-16 units.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    pub location: i64,
    pub length: i64,
}

/// `comparisonRange`: the selection whole, and what fits of the text before it.
pub fn comparison_range(selection: Span) -> Option<Span> {
    if selection.location < 0 || selection.length < 0 || selection.length > CONTEXT_UNITS {
        return None;
    }
    let start = (selection.location - (CONTEXT_UNITS - selection.length)).max(0);
    Some(Span { location: start, length: selection.location - start + selection.length })
}

/// `afterComparisonRange`: `limit` units after the selection, empty at the field's end.
pub fn after_range(selection: Span, characters: i64, limit: i64) -> Option<Span> {
    if selection.location < 0 || selection.length < 0 {
        return None;
    }
    let start = selection.location + selection.length;
    (characters >= start).then(|| Span { location: start, length: limit.min(characters - start) })
}

/// `confirmationRange`: the text ends at a collapsed caret, or stays selected in full. The caret
/// after typing is the only stable anchor: Slate drops a placeholder on the first key.
pub fn confirmation_range(units: i64, selection: Span) -> Option<Span> {
    if units <= 0 || selection.location < 0 || selection.length < 0 {
        return None;
    }
    if selection.length == 0 {
        return (selection.location >= units).then(|| Span { location: selection.location - units, length: units });
    }
    (selection.length == units).then_some(selection)
}

fn joins_previous(c: char) -> bool {
    crate::dictionary::is_mark(c) || crate::dictionary::is_format(c) || ('\u{1F3FB}'..='\u{1F3FF}').contains(&c) || ('\u{FE00}'..='\u{FE0F}').contains(&c)
}

/// `chunks`: at most 20 UTF-16 units per event, keeping a base with its marks and joiners. A cluster
/// longer than one event splits on scalars, so a surrogate pair is never divided.
// ponytail: approximates grapheme clusters without a Unicode table crate; a flag pair can land in two
// events, which still type in order.
pub fn chunks(text: &str) -> Vec<String> {
    if text.is_empty() || text.len() > MAX_TEXT_BYTES {
        return vec![];
    }
    let mut clusters: Vec<String> = vec![];
    let mut joined = false;
    for c in text.chars() {
        match clusters.last_mut() {
            Some(last) if joined || joins_previous(c) => last.push(c),
            _ => clusters.push(c.to_string()),
        }
        joined = c == '\u{200D}';
    }
    let (mut out, mut chunk, mut units) = (vec![], String::new(), 0);
    let mut add = |piece: &str, chunk: &mut String, units: &mut usize| {
        let count = piece.encode_utf16().count();
        if *units + count > MAX_CHUNK_UNITS {
            out.push(std::mem::take(chunk));
            *units = 0;
        }
        chunk.push_str(piece);
        *units += count;
    };
    for cluster in &clusters {
        if cluster.encode_utf16().count() > MAX_CHUNK_UNITS {
            let mut scalar = [0u8; 4];
            for c in cluster.chars() {
                add(c.encode_utf8(&mut scalar), &mut chunk, &mut units);
            }
        } else {
            add(cluster, &mut chunk, &mut units);
        }
    }
    if !chunk.is_empty() {
        out.push(chunk);
    }
    out
}

/// `dispatchWindow`: ten seconds, or 5 ms per unit for long text.
pub fn dispatch_window(units: usize) -> Duration {
    Duration::from_secs(10).max(Duration::from_millis(5 * units as u64))
}

/// Swift compares Strings by canonical equivalence; apps may hand back either form.
fn same_text(a: &str, b: &str) -> bool {
    a == b || crate::dictionary::nfc(a) == crate::dictionary::nfc(b)
}

/// `readback`: web editors acknowledge input late, so confirmation polls and delivery never repeats.
fn read_back(target: &dyn Target, text: &str) -> Result<String, Issue> {
    let units = text.encode_utf16().count() as i64;
    for attempt in 0..READBACK_POLLS {
        if !target.same_field() {
            return Err(Issue::FocusChanged);
        }
        match target.read_back(units) {
            Ok(value) if same_text(&value, text) => return Ok(value),
            Err(Issue::FocusChanged) => return Err(Issue::FocusChanged),
            _ => {}
        }
        if attempt + 1 < READBACK_POLLS {
            std::thread::sleep(READBACK_WAIT);
        }
    }
    Err(Issue::Unsupported)
}

/// `UnicodeTextDelivery.send`.
fn type_text(target: &dyn Target, text: &str) -> Dispatch {
    let parts = chunks(text);
    if parts.is_empty() {
        return Dispatch::NoMutation;
    }
    let deadline = Instant::now() + dispatch_window(text.encode_utf16().count());
    let (mut submitted, mut prefix) = (false, String::new());
    let partial = |submitted| if submitted { Dispatch::MutationMayHaveOccurred } else { Dispatch::NoMutation };
    for (index, part) in parts.iter().enumerate() {
        let current = if submitted { target.same_field() } else { target.rejected().is_none() };
        if Instant::now() >= deadline || !current || !target.post(part) {
            return partial(submitted);
        }
        submitted = true;
        prefix.push_str(part);
        if (index + 1 == parts.len() || (index + 1) % CONFIRM_EVERY == 0) && read_back(target, &prefix).is_err() {
            return Dispatch::MutationMayHaveOccurred;
        }
    }
    Dispatch::MutationMayHaveOccurred
}

/// `insertOnce`. The caller serializes attempts, and makes one per saved attempt.
pub fn insert_once(target: &dyn Target, text: &str) -> InsertOutcome {
    if text.is_empty() || text.len() > MAX_TEXT_BYTES || target.rejected().is_some() {
        return InsertOutcome::NotInserted;
    }
    let dispatch = if target.is_paste() {
        target.paste(text)
    } else {
        type_text(target, text)
    };
    match dispatch {
        Dispatch::NoMutation => InsertOutcome::NotInserted,
        Dispatch::Pasted => InsertOutcome::Confirmed,
        Dispatch::MutationMayHaveOccurred => match read_back(target, text) {
            Ok(_) => InsertOutcome::Confirmed,
            Err(_) => InsertOutcome::Uncertain,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    #[derive(Default)]
    struct Fake {
        rejected: Option<Issue>,
        paste: Option<Dispatch>,
        field_lost_after_posts: Option<usize>,
        refuse_post: bool,
        /// What the app's field really holds: dropped text models an app that ate the keys.
        swallow: bool,
        typed: RefCell<String>,
        posts: Cell<usize>,
        reads: Cell<usize>,
        late_reads: usize,
    }
    impl Target for Fake {
        fn rejected(&self) -> Option<Issue> {
            self.rejected
        }
        fn is_paste(&self) -> bool {
            self.paste.is_some()
        }
        fn paste(&self, _: &str) -> Dispatch {
            self.paste.unwrap()
        }
        fn same_field(&self) -> bool {
            self.field_lost_after_posts.is_none_or(|n| self.posts.get() < n)
        }
        fn post(&self, chunk: &str) -> bool {
            if self.refuse_post {
                return false;
            }
            self.posts.set(self.posts.get() + 1);
            if !self.swallow {
                self.typed.borrow_mut().push_str(chunk);
            }
            true
        }
        fn read_back(&self, units: i64) -> Result<String, Issue> {
            self.reads.set(self.reads.get() + 1);
            if self.reads.get() <= self.late_reads {
                return Err(Issue::Unsupported);
            }
            let typed: Vec<u16> = self.typed.borrow().encode_utf16().collect();
            Ok(String::from_utf16_lossy(&typed[typed.len().saturating_sub(units as usize)..]))
        }
    }

    #[test]
    fn typed_text_read_back_is_confirmed() {
        let fake = Fake::default();
        assert_eq!(insert_once(&fake, "hello world"), InsertOutcome::Confirmed);
        assert_eq!((fake.typed.borrow().as_str(), fake.posts.get()), ("hello world", 1));
    }

    #[test]
    fn a_late_acknowledgement_polls_and_never_types_again() {
        let fake = Fake { late_reads: 3, ..Default::default() };
        assert_eq!(insert_once(&fake, "hello"), InsertOutcome::Confirmed);
        assert_eq!(fake.posts.get(), 1);
    }

    #[test]
    fn nothing_reaches_a_rejected_field() {
        for issue in [Issue::SecureField, Issue::AccessibilityDenied, Issue::StaleProcess, Issue::FocusChanged, Issue::SelectionChanged] {
            let fake = Fake { rejected: Some(issue), ..Default::default() };
            assert_eq!(insert_once(&fake, "secret"), InsertOutcome::NotInserted);
            assert_eq!(fake.posts.get(), 0);
        }
    }

    #[test]
    fn empty_or_oversized_text_is_refused() {
        let fake = Fake::default();
        assert_eq!(insert_once(&fake, ""), InsertOutcome::NotInserted);
        assert_eq!(insert_once(&fake, &"x".repeat(MAX_TEXT_BYTES + 1)), InsertOutcome::NotInserted);
        assert_eq!(fake.posts.get(), 0);
    }

    #[test]
    fn keys_that_never_show_up_are_uncertain() {
        let fake = Fake { swallow: true, ..Default::default() };
        assert_eq!(insert_once(&fake, "hello"), InsertOutcome::Uncertain);
    }

    #[test]
    fn a_focus_change_midway_is_uncertain_and_stops_typing() {
        let fake = Fake { field_lost_after_posts: Some(2), ..Default::default() };
        assert_eq!(insert_once(&fake, &"word ".repeat(40)), InsertOutcome::Uncertain);
        assert_eq!(fake.posts.get(), 2);
    }

    #[test]
    fn a_refused_first_event_inserted_nothing() {
        let fake = Fake { refuse_post: true, ..Default::default() };
        assert_eq!(insert_once(&fake, "hello"), InsertOutcome::NotInserted);
    }

    #[test]
    fn a_paste_is_confirmed_or_not_inserted_without_a_readback() {
        let fake = Fake { paste: Some(Dispatch::Pasted), ..Default::default() };
        assert_eq!(insert_once(&fake, "ls"), InsertOutcome::Confirmed);
        assert_eq!(fake.reads.get(), 0);
        let fake = Fake { paste: Some(Dispatch::NoMutation), ..Default::default() };
        assert_eq!(insert_once(&fake, "ls"), InsertOutcome::NotInserted);
    }

    #[test]
    fn a_decomposed_readback_counts_as_the_same_text() {
        assert!(same_text("caf\u{e9}", "cafe\u{301}"));
        assert!(!same_text("cafe", "caf\u{e9}"));
    }

    #[test]
    fn chunks_stay_within_one_event_and_lose_nothing() {
        let text = "a\u{301}".repeat(30) + &"😀".repeat(30) + "👩\u{200D}💻 end";
        let parts = chunks(&text);
        assert_eq!(parts.concat(), text);
        assert!(parts.iter().all(|p| p.encode_utf16().count() <= MAX_CHUNK_UNITS));
        assert!(parts.iter().all(|p| !p.starts_with('\u{301}') && !p.starts_with('\u{200D}')), "{parts:?}");
    }

    #[test]
    fn a_cluster_longer_than_an_event_splits_on_scalars() {
        let text = format!("a{}", "\u{301}".repeat(45));
        let parts = chunks(&text);
        assert_eq!(parts.concat(), text);
        assert_eq!(parts.len(), 3);
        assert!(chunks("").is_empty() && chunks(&"x".repeat(MAX_TEXT_BYTES + 1)).is_empty());
    }

    #[test]
    fn ranges_match_swift() {
        assert_eq!(comparison_range(Span { location: 10, length: 2 }), Some(Span { location: 0, length: 12 }));
        assert_eq!(comparison_range(Span { location: 5_000, length: 96 }), Some(Span { location: 1_000, length: 4_096 }));
        assert_eq!(comparison_range(Span { location: 0, length: 4_097 }), None);
        assert_eq!(after_range(Span { location: 3, length: 1 }, 4, 100), Some(Span { location: 4, length: 0 }));
        assert_eq!(after_range(Span { location: 3, length: 1 }, 3, 100), None);
        assert_eq!(after_range(Span { location: 0, length: 0 }, 500, 100), Some(Span { location: 0, length: 100 }));
        assert_eq!(confirmation_range(3, Span { location: 10, length: 0 }), Some(Span { location: 7, length: 3 }));
        assert_eq!(confirmation_range(3, Span { location: 2, length: 0 }), None);
        assert_eq!(confirmation_range(3, Span { location: 2, length: 3 }), Some(Span { location: 2, length: 3 }));
        assert_eq!(confirmation_range(3, Span { location: 2, length: 4 }), None);
        assert_eq!(dispatch_window(100), Duration::from_secs(10));
        assert_eq!(dispatch_window(4_000), Duration::from_secs(20));
    }
}
