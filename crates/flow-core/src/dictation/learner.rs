//! `CorrectionLearner`, `CorrectionDetector`, `CorrectionCandidateScorer` and `UsageClassifier`:
//! watches the field a confirmed insertion went into, for a bounded time, and learns one in-place
//! correction. Off unless the user enables it; reads only the passage and small margins; logs no text.
use super::normalize::Change;
use super::session::{CapturedTarget, Inserter};
use crate::db::Db;
use crate::dictionary::{self, Entry, fold, is_mark, nfc, term_code};
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::time::{Duration, Instant};

pub const OBSERVATION_WINDOW: Duration = Duration::from_secs(90);
pub const POLL_INTERVAL: Duration = Duration::from_secs(1);
const MARGIN_UNITS: usize = 48;
const GROWTH_UNITS: usize = 64;
const MAXIMUM_INSERTED_UNITS: usize = 4_096;
const MAXIMUM_WORDS: usize = 3;
const MAXIMUM_READS: usize = 8;
/// `UsageClassifier.maximumWords`.
const MAXIMUM_CLASSIFIED_WORDS: usize = 1_024;

const FUNCTION_WORDS: &str = "the a an and or but is are was were be been being to of in on for with this that it he she we they i you me him her us them my your our their its as at by from not no do does did have has had will would can could should if then than so a aj ale alebo je sú som si sme ste na do od z zo v vo pre pri že to ten tá tie ja ty my vy bol bola boli bolo byť sa čo ako keď nie áno už ešte len ho ich nás vás ktorý ktorá";
const COMMON_WORDS: &str = "today tomorrow yesterday good bad server servers computer computers monday tuesday wednesday thursday friday saturday sunday please send sent hello world now later run ran running walk walked walking work worked working go goes went gone make made get got say said new old first last next time day week month year dnes zajtra včera dobrý zlý servera serveru serverom servery urobiť urobil urobila robiť robil prosím poslať poslal deň čas nový starý pondelok utorok";

fn function_word(word: &str) -> bool {
    FUNCTION_WORDS.split(' ').any(|w| w == word)
}
fn common_word(word: &str) -> bool {
    function_word(word) || COMMON_WORDS.split(' ').any(|w| w == word)
}

fn words(text: &str) -> Vec<String> {
    nfc(text).split_whitespace().map(String::from).collect()
}

/// Sentence punctuation and symbols at a term's edges, keeping literal markers such as `/foo`.
// ponytail: anything not alphanumeric, a mark or a kept marker counts as Swift's punctuation-and-symbols set; a table if a category turns out to differ.
fn trimmed(term: &str) -> &str {
    term.trim_matches(|c: char| !c.is_alphanumeric() && !is_mark(c) && !"/\\:@~".contains(c) && !c.is_whitespace())
}

fn is_term_scalar(c: char) -> bool {
    c == '_' || c.is_alphanumeric() || is_mark(c)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub misspelling: String,
    pub correction: String,
}

/// `CorrectionDetector.candidate`: exactly one contiguous run of 1 to 3 inserted words replaced by
/// 1 to 3 words, everything else unchanged and in order.
pub fn candidate(inserted: &str, before: &str, after: &str, current: &str, leading_cut: bool, open_ended: bool) -> Option<Candidate> {
    let (mut before_words, inserted_words, after_words, mut now) = (words(before), words(inserted), words(after), words(current));
    if leading_cut {
        if before_words.is_empty() || now.is_empty() {
            return None;
        }
        before_words.remove(0);
        now.remove(0);
    }
    if inserted_words.is_empty() {
        return None;
    }
    let base = [&before_words[..], &inserted_words[..]].concat();
    let prefix = base.iter().zip(&now).take_while(|(a, b)| a == b).count();
    if prefix < before_words.len() || prefix >= base.len() {
        return None;
    }
    for replaced in 1..=MAXIMUM_WORDS {
        let replaced_end = prefix + replaced;
        if replaced_end > base.len() {
            break;
        }
        let tail = [&base[replaced_end..], &after_words[..]].concat();
        for replacement in 1..=MAXIMUM_WORDS {
            let end = prefix + replacement;
            if end + tail.len() > now.len() {
                break;
            }
            if now[end..end + tail.len()] != tail[..] {
                continue;
            }
            // With no trailing anchor, extra typed words would be mistaken for the correction:
            // the edit must end the read and must not grow the passage.
            if after_words.is_empty() && !open_ended && (end + tail.len() != now.len() || (tail.is_empty() && replacement > replaced)) {
                continue;
            }
            return make(&base[prefix..replaced_end], &now[prefix..end]);
        }
    }
    None
}

fn make(replaced: &[String], replacement: &[String]) -> Option<Candidate> {
    let (misspelling, correction) = (replaced.join(" "), replacement.join(" "));
    let (misspelling, correction) = (trimmed(&misspelling), trimmed(&correction));
    let good = |t: &str| !t.is_empty() && term_code(t).is_none() && t.chars().any(is_term_scalar);
    (misspelling != correction && good(misspelling) && good(correction)).then(|| Candidate { misspelling: misspelling.into(), correction: correction.into() })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Disposition {
    AutoLearn,
    Suggest,
    Ignore,
}

fn letters(text: &str, lower: bool) -> Vec<char> {
    let text = if lower { text.to_lowercase() } else { text.to_string() };
    text.chars().filter(|c| c.is_alphanumeric()).collect()
}

/// Dots, slashes, colons and @ conservatively exclude domains, IPs, URLs, paths and emails.
fn protected_literal(text: &str) -> bool {
    text.contains(['/', '\\', ':', '@', '.', '~']) || !text.chars().any(char::is_alphabetic)
}

fn similarity(a: &[char], b: &[char]) -> f64 {
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for (i, x) in a.iter().enumerate() {
        let mut row = vec![i + 1];
        for (j, y) in b.iter().enumerate() {
            row.push((row[j] + 1).min(previous[j + 1] + 1).min(previous[j] + usize::from(x != y)));
        }
        previous = row;
    }
    1. - previous[b.len()] as f64 / a.len().max(b.len()) as f64
}

/// `CorrectionCandidateScorer.assess`. Hard exclusions can't be overcome by repetition.
pub fn assess(source: &str, replacement: &str, canonical_terms: &[String], previous: i64) -> Disposition {
    let (source, replacement) = (nfc(source), nfc(replacement));
    let (from, to) = (words(&source), words(&replacement));
    if source.len() > 256 || replacement.len() > 256 || !(1..=3).contains(&from.len()) || !(1..=3).contains(&to.len()) || protected_literal(&source) || protected_literal(&replacement) {
        return Disposition::Ignore;
    }
    let (left, right) = (letters(&source, true), letters(&replacement, true));
    if left.is_empty() || right.is_empty() || letters(&source, false) == letters(&replacement, false) {
        return Disposition::Ignore;
    }
    let tokens: Vec<String> = from.iter().chain(&to).map(|t| t.to_lowercase()).collect();
    if tokens.iter().any(|t| function_word(t)) || to.iter().all(|t| common_word(&t.to_lowercase())) {
        return Disposition::Ignore;
    }
    let canonical = canonical_terms.iter().take(dictionary::MAX_ENTRIES).any(|t| t.len() <= 256 && letters(t, true) == right);
    let shape = to.iter().any(|token| {
        let alpha: Vec<char> = token.chars().filter(|c| c.is_alphabetic()).collect();
        !alpha.is_empty() && (alpha.iter().any(|c| c.is_uppercase()) || token.chars().any(char::is_numeric) || (token.contains('-') && alpha.len() >= 4))
    });
    if !shape && !canonical {
        return Disposition::Ignore;
    }
    let close = similarity(&left, &right);
    if close < 0.45 && !canonical {
        return Disposition::Ignore;
    }
    let score = 1 + if shape { 3 } else { 0 } + if canonical { 3 } else { 0 } + if close >= 0.625 { 2 } else { 0 } + if previous >= 1 { 2 } else { 0 };
    // One observed edit only suggests, unless it spells a known canonical.
    if score >= 6 && (previous >= 1 || canonical) { Disposition::AutoLearn } else { Disposition::Suggest }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Kept,
    Reverted,
    Unclassified,
}

/// A word's core: its edges trimmed, or itself when it's all punctuation.
fn core(word: &str) -> String {
    let t = trimmed(word);
    if t.is_empty() { word.to_string() } else { t.to_string() }
}

fn alignment(a: &[String], b: &[String]) -> Vec<bool> {
    let (n, m) = (a.len(), b.len());
    let mut table = vec![0u16; (n + 1) * (m + 1)];
    let at = |i: usize, j: usize| i * (m + 1) + j;
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            table[at(i, j)] = if a[i] == b[j] { table[at(i + 1, j + 1)] + 1 } else { table[at(i + 1, j)].max(table[at(i, j + 1)]) };
        }
    }
    let (mut aligned, mut i, mut j) = (vec![false; n], 0, 0);
    while i < n && j < m {
        if a[i] == b[j] {
            aligned[i] = true;
            i += 1;
            j += 1;
        } else if table[at(i + 1, j)] >= table[at(i, j + 1)] {
            i += 1;
        } else {
            j += 1;
        }
    }
    aligned
}

/// `UsageClassifier.classify`: whether the user kept or undid each change, from the reads.
pub fn classify(changes: &[Change], inserted: &str, before: &str, leading_cut: bool, reads: &[String]) -> Vec<(Change, Outcome)> {
    let unclassified = || changes.iter().map(|c| (c.clone(), Outcome::Unclassified)).collect();
    let inserted: Vec<String> = words(inserted).iter().map(|w| core(w)).collect();
    if changes.is_empty() || inserted.is_empty() || inserted.len() > MAXIMUM_CLASSIFIED_WORDS {
        return unclassified();
    }
    let mut before: Vec<String> = words(before).iter().map(|w| core(w)).collect();
    if leading_cut && !before.is_empty() {
        before.remove(0);
    }
    let needed = inserted.len().div_ceil(2);
    // The latest read in which the passage is still there decides.
    let found = reads.iter().rev().find_map(|read| {
        let mut cores: Vec<String> = words(read).iter().map(|w| core(w)).collect();
        if leading_cut {
            if cores.is_empty() {
                return None;
            }
            cores.remove(0);
        }
        if cores.len() < before.len() || cores[..before.len()] != before[..] || cores.len() - before.len() > MAXIMUM_CLASSIFIED_WORDS * 2 {
            return None;
        }
        let matched = alignment(&inserted, &cores[before.len()..]);
        (matched.iter().filter(|m| **m).count() >= needed).then_some(matched)
    });
    let Some(aligned) = found else { return unclassified() };
    changes
        .iter()
        .map(|change| {
            let target: Vec<String> = words(&change.canonical).iter().map(|w| core(w)).collect();
            let spans: Vec<std::ops::Range<usize>> = if target.is_empty() || target.len() > inserted.len() { vec![] } else { (0..=inserted.len() - target.len()).filter(|s| inserted[*s..s + target.len()] == target[..]).map(|s| s..s + target.len()).collect() };
            if spans.is_empty() {
                return (change.clone(), Outcome::Unclassified);
            }
            let mut reverted = false;
            for span in spans.iter().filter(|s| aligned[s.start..s.end].contains(&false)) {
                let left = span.start == 0 || aligned[span.start - 1];
                let right = span.end == aligned.len() || aligned[span.end];
                if !left || !right {
                    // Changed along with its neighbours: a larger rewrite, not attributable.
                    return (change.clone(), Outcome::Unclassified);
                }
                reverted = true;
            }
            (change.clone(), if reverted { Outcome::Reverted } else { Outcome::Kept })
        })
        .collect()
}

/// What the page's bubble shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Note {
    Learned { entry: String, canonical: String },
    /// `alias` is the retired key's text; the canonical spelling itself for a boost.
    Retired { entry: String, key: String, alias: String },
    /// A word to suggest was recorded, or usage changed.
    DictionaryChanged,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stop {
    Learned,
    WindowElapsed,
    ReadEnded,
    PassageMoved,
    Cancelled,
    Disabled,
    Rejected,
}

pub struct Observation<'a> {
    pub dictation: &'a str,
    pub inserted: &'a str,
    pub target: &'a CapturedTarget,
    pub changes: &'a [Change],
    pub reader: &'a dyn Inserter,
    pub db: &'a Db,
    pub enabled: &'a (dyn Fn() -> bool + Sync),
    pub cancelled: &'a AtomicBool,
    pub poll: Duration,
    pub window: Duration,
    pub sink: &'a mut dyn FnMut(Note),
}

/// `CorrectionLearner.observe`, blocking. Every stop classifies from the reads made so far.
pub fn observe(o: &mut Observation) -> Stop {
    if !(o.enabled)() {
        return Stop::Disabled;
    }
    let length = o.inserted.encode_utf16().count();
    if length == 0 || length > MAXIMUM_INSERTED_UNITS {
        return Stop::Rejected;
    }
    let mut record = (String::new(), false, Vec::new());
    let stop = watch(o, length, &mut record);
    if !o.changes.is_empty() {
        let (before, leading_cut, reads) = record;
        let outcomes = classify(o.changes, o.inserted, &before, leading_cut, &reads);
        settle_usage(o, &outcomes);
    }
    stop
}

fn settle_usage(o: &mut Observation, outcomes: &[(Change, Outcome)]) {
    let Ok(retired) = dictionary::classify_usage(o.db, o.dictation, outcomes, crate::history::now_ms()) else { return };
    if retired.is_empty() {
        return;
    }
    let entries = dictionary::load(o.db).map(|c| c.entries).unwrap_or_default();
    for (entry_id, key) in retired {
        let Some(entry) = entries.iter().find(|e| e.id == entry_id) else { continue };
        let alias = std::iter::once(&entry.canonical).chain(&entry.aliases).find(|a| dictionary::key_id(a) == key).unwrap_or(&entry.canonical).clone();
        (o.sink)(Note::Retired { entry: entry.id.clone(), key: key.clone(), alias });
        let _ = dictionary::mark_notice_shown(o.db, &entry_id, &key);
    }
    (o.sink)(Note::DictionaryChanged);
}

fn watch(o: &mut Observation, length: usize, record: &mut (String, bool, Vec<String>)) -> Stop {
    let location = o.target.selection_location;
    let start = location.saturating_sub(MARGIN_UNITS);
    let leading = location - start;
    let baseline_length = leading + length + MARGIN_UNITS;
    let Ok(baseline) = o.reader.read_text(o.target, start, baseline_length) else { return Stop::ReadEnded };
    let units: Vec<u16> = baseline.encode_utf16().collect();
    if units.len() < leading + length || String::from_utf16_lossy(&units[leading..leading + length]) != o.inserted {
        return Stop::PassageMoved;
    }
    let before = String::from_utf16_lossy(&units[..leading]);
    let mut after = String::from_utf16_lossy(&units[leading + length..]);
    // A full-length read may end mid-word; keep only whole words as the trailing anchor.
    let mut open_ended = false;
    if units.len() == baseline_length {
        match after.rfind(char::is_whitespace) {
            Some(cut) => after.truncate(cut),
            None => {
                after.clear();
                open_ended = true;
            }
        }
    }
    let leading_cut = start > 0;
    record.0 = before.clone();
    record.1 = leading_cut;
    let deadline = Instant::now() + o.window;
    let mut pending: Option<Candidate> = None;
    while Instant::now() < deadline {
        let waking = Instant::now() + o.poll;
        while Instant::now() < waking {
            if o.cancelled.load(SeqCst) {
                return Stop::Cancelled;
            }
            std::thread::sleep(o.poll.min(Duration::from_millis(50)));
        }
        if o.cancelled.load(SeqCst) {
            return Stop::Cancelled;
        }
        if !(o.enabled)() {
            return Stop::Disabled;
        }
        let Ok(current) = o.reader.read_text(o.target, start, baseline_length + GROWTH_UNITS) else {
            // Fixing a word and pressing Return leaves the field before a second read can
            // confirm the fix; the last read before that is the final text.
            return match pending {
                Some(c) => learn(o, &c),
                None => Stop::ReadEnded,
            };
        };
        if record.2.last() != Some(&current) {
            record.2.push(current.clone());
            if record.2.len() > MAXIMUM_READS {
                record.2.remove(0);
            }
        }
        let seen = candidate(o.inserted, &before, &after, &current, leading_cut, open_ended);
        // Two identical reads a second apart mean the user finished typing the correction.
        match seen {
            Some(c) if pending.as_ref() == Some(&c) => return learn(o, &c),
            other => pending = other,
        }
    }
    Stop::WindowElapsed
}

fn learn(o: &mut Observation, c: &Candidate) -> Stop {
    if !(o.enabled)() {
        return Stop::Disabled;
    }
    let (key, target) = (fold(&c.misspelling), fold(&c.correction));
    let now = crate::history::now_ms();
    // A case- or accent-only fix is the canonical spelling itself; it needs no alias.
    let aliases = if key == target { vec![] } else { vec![c.misspelling.clone()] };
    let entry = Entry { id: crate::history::new_uuid(o.db), canonical: c.correction.clone(), aliases, enabled: true, learned_at: Some(now) };
    let Ok(contents) = dictionary::load(o.db) else { return Stop::Rejected };
    // A sighting store failure counts as a first sighting: it can only suggest.
    let previous = dictionary::observe_sighting(o.db, &c.misspelling, &c.correction, now).unwrap_or(0);
    let terms: Vec<String> = contents.entries.iter().filter(|e| e.enabled).map(|e| e.canonical.clone()).collect();
    let disposition = assess(&c.misspelling, &c.correction, &terms, previous);
    // An entry that already maps this misspelling, or is this word, means nothing to learn.
    if contents.entries.iter().any(|e| std::iter::once(&e.canonical).chain(&e.aliases).map(|t| fold(t)).any(|k| k == key || k == target)) {
        return Stop::Rejected;
    }
    if disposition != Disposition::AutoLearn {
        if disposition == Disposition::Suggest {
            let _ = dictionary::record_correction(o.db, &entry.canonical, entry.aliases.first().map_or("", String::as_str), now);
            (o.sink)(Note::DictionaryChanged);
        }
        return Stop::Rejected;
    }
    if dictionary::save(o.db, &entry, Some(contents.state.revision), "provisional").is_err() {
        return Stop::Rejected;
    }
    (o.sink)(Note::Learned { entry: entry.id, canonical: entry.canonical });
    Stop::Learned
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dictation::session::{InsertDelivery, InsertOutcome};
    use std::collections::VecDeque;
    use std::sync::Mutex;

    fn fix(inserted: &str, before: &str, after: &str, current: &str) -> Option<(String, String)> {
        candidate(inserted, before, after, current, false, false).map(|c| (c.misspelling, c.correction))
    }
    fn pair(a: &str, b: &str) -> Option<(String, String)> {
        Some((a.into(), b.into()))
    }

    #[test]
    fn the_detector_finds_one_contiguous_edit_only() {
        assert_eq!(fix("use kubernettes now", "", "", "use Kubernetes now"), pair("kubernettes", "Kubernetes"));
        assert_eq!(fix("ask jon smith today", "", "", "ask John Smyth today"), pair("jon smith", "John Smyth"));
        assert_eq!(fix("use kubernetes.", "see ", "next", "see use Kubernetes. next"), pair("kubernetes", "Kubernetes"), "punctuation isn't part of the term");
        assert_eq!(fix("a b c d e f", "", "", "x b c d e y"), None, "two edits");
        assert_eq!(fix("one two", "", "", "one two"), None, "no change");
        assert_eq!(fix("one two", "", "", "one two three"), None, "typing on isn't a fix");
        assert_eq!(fix("one two", "", "", "one three four"), None, "must not grow the passage with no anchor");
        assert_eq!(fix("one", "before ", "", "changed one"), None, "the edit must sit inside the passage");
        assert_eq!(candidate("one two", "cut before", "", "xcut before one three", true, false).map(|c| c.correction), Some("three".into()), "a read that starts mid-word drops its first word");
        assert_eq!(fix("one two", "", "", "one !!!"), None, "no term in it");
    }

    #[test]
    fn the_scorer_learns_only_repeated_or_known_terms() {
        use Disposition::*;
        assert_eq!(assess("kubernettes", "Kubernetes", &[], 0), Suggest, "first sighting only suggests");
        assert_eq!(assess("kubernettes", "Kubernetes", &[], 1), AutoLearn);
        assert_eq!(assess("kubernettes", "kubernetes", &["Kubernetes".into()], 0), AutoLearn, "spells a known canonical");
        assert_eq!(assess("Kubernetes", "kubernetes", &[], 5), Ignore, "ordinary edit");
        assert_eq!(assess("colour", "color", &[], 3), Ignore, "no name shape");
        assert_eq!(assess("the", "a", &[], 3), Ignore);
        assert_eq!(assess("the cat", "A Cat", &[], 3), Ignore, "a function word");
        assert_eq!(assess("x.com", "X.com", &[], 3), Ignore, "protected literal");
        assert_eq!(assess("foo", "foo", &[], 3), Ignore);
        assert_eq!(assess("banana", "Zqxwv", &[], 3), Ignore, "no orthographic connection");
        assert_eq!(assess("Monday", "MONDAY", &[], 3), Ignore, "a common target");
    }

    fn change(canonical: &str) -> Change {
        Change { entry_id: "e".into(), key_id: dictionary::key_id(canonical), canonical: canonical.into() }
    }
    fn outcome(inserted: &str, reads: &[&str]) -> Outcome {
        let reads: Vec<String> = reads.iter().map(|r| r.to_string()).collect();
        classify(&[change("Kubernetes")], inserted, "", false, &reads)[0].1
    }

    #[test]
    fn the_classifier_tells_kept_from_undone_from_rewritten() {
        let s = "we run Kubernetes in prod today";
        assert_eq!(outcome(s, &[s]), Outcome::Kept);
        assert_eq!(outcome(s, &["we run kubernetes in prod today"]), Outcome::Reverted);
        assert_eq!(outcome(s, &["we run kubernetes in prod today", s]), Outcome::Kept, "the latest read decides");
        assert_eq!(outcome(s, &["we walk kubernetes there prod today"]), Outcome::Unclassified, "changed with its neighbours");
        assert_eq!(outcome(s, &["nothing like it"]), Outcome::Unclassified, "the passage is gone");
        assert_eq!(outcome(s, &[]), Outcome::Unclassified);
        assert_eq!(classify(&[change("absent")], s, "", false, &[s.to_string()])[0].1, Outcome::Unclassified);
    }

    struct Reads(Mutex<VecDeque<Result<String, ()>>>);
    impl Inserter for Reads {
        fn capture_target(&self) -> Option<CapturedTarget> {
            None
        }
        fn insert_once(&self, _: &CapturedTarget, _: &str) -> InsertOutcome {
            InsertOutcome::NotInserted
        }
        fn copy(&self, _: &str) {}
        fn read_text(&self, _: &CapturedTarget, _: usize, _: usize) -> Result<String, ()> {
            self.0.lock().unwrap().pop_front().unwrap_or(Err(()))
        }
    }

    fn run(db: &Db, changes: &[Change], reads: Vec<Result<&str, ()>>) -> (Stop, Vec<Note>) {
        let target = CapturedTarget { bundle_id: "b".into(), own_process: false, delivery: InsertDelivery::Accessibility, selection_location: 0, token: 1 };
        let reader = Reads(Mutex::new(reads.into_iter().map(|r| r.map(String::from)).collect()));
        let mut notes = vec![];
        let cancelled = AtomicBool::new(false);
        let mut sink = |n| notes.push(n);
        let stop = observe(&mut Observation { dictation: "d", inserted: "use kubernettes now", target: &target, changes, reader: &reader, db, enabled: &|| true, cancelled: &cancelled, poll: Duration::from_millis(1), window: Duration::from_secs(5), sink: &mut sink });
        (stop, notes)
    }

    const BASE: Result<&str, ()> = Ok("use kubernettes now");
    const FIXED: Result<&str, ()> = Ok("use Kubernetes now");

    // parity: PILL-072
    #[test]
    fn a_repeated_correction_learns_and_undo_removes_it() {
        let db = Db::memory();
        let (stop, notes) = run(&db, &[], vec![BASE, FIXED, FIXED]);
        assert_eq!((stop, notes), (Stop::Rejected, vec![Note::DictionaryChanged]), "first time: a suggestion");
        assert_eq!(dictionary::load(&db).unwrap().entries.len(), 0);
        let suggested: i64 = db.conn.query_row("SELECT count(*) FROM correction_sightings", [], |r| r.get(0)).unwrap();
        assert_eq!(suggested, 1, "a digest, no text");

        // Leaving the field after one sighting of the fix still counts: that read was final.
        let (stop, notes) = run(&db, &[], vec![BASE, FIXED, Err(())]);
        assert_eq!(stop, Stop::Learned);
        let Note::Learned { entry, canonical } = &notes[0] else { panic!("{notes:?}") };
        assert_eq!(canonical, "Kubernetes");
        let saved = dictionary::load(&db).unwrap().entries;
        assert_eq!((saved[0].aliases.as_slice(), saved[0].learned_at.is_some()), (["kubernettes".to_string()].as_slice(), true));

        // An entry for it already: nothing more to learn.
        assert_eq!(run(&db, &[], vec![BASE, FIXED, FIXED]).0, Stop::Rejected);

        dictionary::delete(&db, entry, None).unwrap();
        assert!(dictionary::load(&db).unwrap().entries.is_empty());
    }

    #[test]
    fn it_stops_for_each_reason() {
        let db = Db::memory();
        assert_eq!(run(&db, &[], vec![]).0, Stop::ReadEnded, "the platform can't read the field");
        assert_eq!(run(&db, &[], vec![Ok("something else entirely")]).0, Stop::PassageMoved);
        assert_eq!(run(&db, &[], vec![BASE, Err(())]).0, Stop::ReadEnded, "nothing pending");
        let target = CapturedTarget { bundle_id: "b".into(), own_process: false, delivery: InsertDelivery::Accessibility, selection_location: 0, token: 1 };
        let reader = Reads(Mutex::new(VecDeque::from([Ok("use kubernettes now".to_string())])));
        let (cancelled, mut sink) = (AtomicBool::new(true), |_| {});
        let mut o = Observation { dictation: "d", inserted: "use kubernettes now", target: &target, changes: &[], reader: &reader, db: &db, enabled: &|| true, cancelled: &cancelled, poll: Duration::from_millis(1), window: Duration::from_secs(5), sink: &mut sink };
        assert_eq!(observe(&mut o), Stop::Cancelled);
        o.enabled = &|| false;
        assert_eq!(observe(&mut o), Stop::Disabled);
        o.enabled = &|| true;
        o.inserted = "";
        assert_eq!(observe(&mut o), Stop::Rejected);
    }

    // parity: PILL-073
    #[test]
    fn a_reverted_key_retires_with_a_notice_and_restore_brings_it_back() {
        let db = Db::memory();
        let entry = Entry { id: "e".into(), canonical: "Kubernetes".into(), aliases: vec!["kubernettes".into()], enabled: true, learned_at: Some(1) };
        dictionary::save(&db, &entry, None, "provisional").unwrap();
        let change = Change { entry_id: "e".into(), key_id: dictionary::key_id("kubernettes"), canonical: "Kubernetes".into() };
        dictionary::record_applied(&db, "d", std::slice::from_ref(&change)).unwrap();
        let target = CapturedTarget { bundle_id: "b".into(), own_process: false, delivery: InsertDelivery::Accessibility, selection_location: 0, token: 1 };
        let reader = Reads(Mutex::new(VecDeque::from(["use Kubernetes now", "use kubernettes now"].map(|r| Ok(r.to_string())))));
        let (mut notes, cancelled) = (vec![], AtomicBool::new(false));
        let mut sink = |n| notes.push(n);
        let mut o = Observation { dictation: "d", inserted: "use Kubernetes now", target: &target, changes: std::slice::from_ref(&change), reader: &reader, db: &db, enabled: &|| true, cancelled: &cancelled, poll: Duration::from_millis(1), window: Duration::from_secs(5), sink: &mut sink };
        observe(&mut o);
        assert_eq!(notes[0], Note::Retired { entry: "e".into(), key: change.key_id.clone(), alias: "kubernettes".into() });
        let state = |db: &Db| dictionary::usage(db).unwrap()["e"].iter().find(|u| u.key_id == change.key_id).unwrap().clone();
        assert_eq!((state(&db).state.as_str(), state(&db).reverted), ("retired", 1));
        let shown: i64 = db.conn.query_row("SELECT notice_shown FROM dictionary_key_usage WHERE key_id=?", [&change.key_id], |r| r.get(0)).unwrap();
        assert_eq!(shown, 1);
        dictionary::restore_key(&db, "e", &change.key_id).unwrap();
        assert_eq!((state(&db).state.as_str(), state(&db).reverted), ("established", 0));
    }
}
