//! `AnalysisValidator`, `ProtectedLiteralDetector`, `DueDateResolver` and `OverlayMatcher`. The pipeline
//! order is Swift's: meeting, sources, identity, due dates, literals, support, duplicates, merge.
use super::wire::{AnalysisResult, WireDue, WireItem, WireOwner, WireSource};
use super::{Failure, Note, Participant, Policy, upper};
use crate::dictionary::strip_marks;
use crate::meetings::SourceRef;
use std::collections::{HashMap, HashSet};

/// `AnalysisEvidence`. Segments are keyed by upper-case id.
#[derive(Default)]
pub struct Evidence {
    pub meeting: String,
    pub segments: HashMap<String, (String, String)>,
    pub notes: Vec<Note>,
    pub participants: Vec<Participant>,
    pub candidates: HashSet<String>,
    pub started_ms: Option<i64>,
    /// The meeting's UTC offset in seconds at its start. Swift's `Meeting.timeZone` is the current zone.
    pub offset: i32,
}
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Counts {
    pub items: i64,
    pub dropped_literal: i64,
    pub dropped_unsupported: i64,
    pub identity_downgrades: i64,
    pub unresolved_owners: i64,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Topic {
    pub title: String,
    pub summary: String,
    pub bullets: Vec<String>,
    pub sources: Vec<SourceRef>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub text: String,
    pub evidence_class: Option<String>,
    pub sources: Vec<SourceRef>,
}
#[derive(Clone, Debug, PartialEq)]
pub enum Owner {
    Participant { speaker: String, known: Option<String>, certainty: &'static str },
    Mentioned(String),
    None,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Due {
    pub state: String,
    pub date: Option<String>,
    pub original: Option<String>,
    pub source: Option<SourceRef>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Action {
    pub text: String,
    pub owner: Owner,
    pub ownership_state: String,
    pub due: Due,
    pub sources: Vec<SourceRef>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Validated {
    pub language: String,
    pub summary: String,
    pub whole_meeting: bool,
    pub summary_sources: Vec<SourceRef>,
    pub topics: Vec<Topic>,
    pub decisions: Vec<Item>,
    pub action_items: Vec<Action>,
    pub next_steps: Vec<Item>,
    pub open_questions: Vec<Item>,
    pub risks: Vec<Item>,
}

fn resolve(refs: &[WireSource], e: &Evidence, p: &Policy) -> Result<Vec<SourceRef>, Failure> {
    if refs.len() > p.sources_per_item {
        return Err(Failure::with("source_validation", "too_many_sources"));
    }
    refs.iter()
        .map(|r| {
            if r.note {
                let ordinal: i64 = r.id[5..].parse().unwrap_or(0);
                let note = e.notes.iter().find(|n| n.ordinal == ordinal).ok_or_else(|| Failure::with("source_validation", "unknown_note"))?;
                Ok(SourceRef::Note(ordinal, note.hash.clone()))
            } else {
                let (stored, _) = e.segments.get(&upper(&r.id)).ok_or_else(|| Failure::with("source_validation", "unknown_segment"))?;
                Ok(SourceRef::Segment(stored.clone()))
            }
        })
        .collect()
}
fn item(w: &WireItem, e: &Evidence, p: &Policy) -> Result<Item, Failure> {
    let sources = resolve(&w.sources, e, p)?;
    if sources.is_empty() {
        return Err(Failure::with("source_validation", "missing_source"));
    }
    Ok(Item { text: w.text.clone(), evidence_class: w.evidence_class.clone(), sources })
}
fn items(list: &[WireItem], e: &Evidence, p: &Policy) -> Result<Vec<Item>, Failure> {
    list.iter().map(|w| item(w, e, p)).collect()
}
fn due(w: &WireDue, e: &Evidence, p: &Policy) -> Due {
    // A fabricated due source doesn't fail the run: the due step drops the item's date instead.
    let source = w.source.as_ref().and_then(|s| resolve(std::slice::from_ref(s), e, p).ok()?.pop());
    Due { state: w.state.clone(), date: w.date.clone(), original: w.original.clone(), source }
}
fn folded_eq(a: &str, b: &str) -> bool {
    fold(a) == fold(b)
}
fn fold(text: &str) -> String {
    strip_marks(text).to_lowercase()
}

/// `AnalysisValidator.validate`.
pub fn validate(result: &AnalysisResult, e: &Evidence, p: &Policy) -> Result<(Validated, Counts), Failure> {
    if !result.meeting_id.eq_ignore_ascii_case(&e.meeting) {
        return Err(Failure::new("meeting_mismatch"));
    }
    let mut counts = Counts::default();
    let summary_sources = resolve(&result.summary.sources, e, p)?;
    let mut topics: Vec<Topic> = result.topics.iter().map(|t| Ok(Topic { title: t.title.clone(), summary: t.summary.clone(), bullets: t.bullets.clone(), sources: resolve(&t.sources, e, p)? })).collect::<Result<_, Failure>>()?;
    let mut decisions = items(&result.decisions, e, p)?;
    let mut actions: Vec<Action> = result
        .action_items
        .iter()
        .map(|w| {
            let sources = resolve(&w.sources, e, p)?;
            if sources.is_empty() {
                return Err(Failure::with("source_validation", "missing_source"));
            }
            let owner = match &w.owner {
                WireOwner::Participant(id) => e.participants.iter().find(|x| x.speaker_id.eq_ignore_ascii_case(id)).map_or(Owner::None, |x| Owner::Participant { speaker: x.speaker_id.clone(), known: x.known_id.clone(), certainty: x.certainty }),
                WireOwner::Mentioned(name) => Owner::Mentioned(name.clone()),
                WireOwner::None => Owner::None,
            };
            Ok(Action { text: w.text.clone(), owner, ownership_state: w.ownership_state.clone(), due: due(&w.due, e, p), sources })
        })
        .collect::<Result<_, _>>()?;
    let mut next_steps = items(&result.next_steps, e, p)?;
    let mut questions = items(&result.open_questions, e, p)?;
    let mut risks = items(&result.risks, e, p)?;

    // Identity: the named-owner rule, a second time on the result. Never fails the run.
    for a in &mut actions {
        let mut downgraded = false;
        match &a.owner {
            Owner::Participant { certainty, .. } => {
                if !matches!(*certainty, "confirmed" | "recognized" | "local_name" | "local_user") {
                    a.owner = Owner::None;
                    downgraded = true;
                }
            }
            Owner::Mentioned(name) => {
                if e.candidates.iter().any(|c| folded_eq(c, name)) {
                    a.owner = Owner::None;
                    downgraded = true;
                } else if a.ownership_state == "explicit" {
                    a.ownership_state = "supported".into();
                }
            }
            Owner::None => {}
        }
        counts.identity_downgrades += i64::from(downgraded);
        if a.owner == Owner::None {
            a.ownership_state = "unresolved".into();
            counts.unresolved_owners += 1;
        }
    }
    for a in &mut actions {
        resolve_due(&mut a.due, e);
    }

    // Protected literals: a summary sentence with an invented one goes; only an empty summary fails.
    let labels: String = e.participants.iter().enumerate().map(|(i, x)| x.name.clone().or_else(|| x.label.clone()).unwrap_or_else(|| format!("Speaker {}", i + 1))).collect::<Vec<_>>().join("\n");
    let mut parts: Vec<&str> = e.segments.values().map(|s| s.1.as_str()).collect();
    parts.sort();
    let mut notes: Vec<&Note> = e.notes.iter().collect();
    notes.sort_by_key(|n| n.ordinal);
    parts.extend(notes.iter().map(|n| n.text.as_str()));
    parts.push(&labels);
    let all = parts.join(" ");
    let sentences: Vec<String> = sentences(&result.summary.text).into_iter().filter(|s| violations(s, &all).is_empty()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
    if sentences.is_empty() {
        return Err(Failure::new("protected_literal"));
    }
    let before = topics.len();
    topics.retain(|t| [&t.title, &t.summary].into_iter().chain(&t.bullets).all(|x| violations(x, &all).is_empty()));
    counts.dropped_literal += (before - topics.len()) as i64;
    let keeps = |text: &str, sources: &[SourceRef]| violations(text, &(source_text(sources, e) + "\n" + &labels)).is_empty();
    counts.dropped_literal += retain(&mut decisions, |i| keeps(&i.text, &i.sources));
    counts.dropped_literal += retain(&mut actions, |i| keeps(&i.text, &i.sources));
    counts.dropped_literal += retain(&mut next_steps, |i| keeps(&i.text, &i.sources));
    counts.dropped_literal += retain(&mut questions, |i| keeps(&i.text, &i.sources));
    counts.dropped_literal += retain(&mut risks, |i| keeps(&i.text, &i.sources));

    // Support: lenient on purpose. One content word of the item must appear in what it cites.
    let supported = |text: &str, sources: &[SourceRef]| {
        let tokens = content_tokens(text);
        if tokens.is_empty() {
            return true;
        }
        let words = source_text(sources, e);
        let source = word_tokens(&words);
        tokens.iter().any(|t| source.iter().any(|w| stem_match(t, w)))
    };
    counts.dropped_unsupported += retain(&mut decisions, |i| supported(&i.text, &i.sources));
    counts.dropped_unsupported += retain(&mut actions, |i| supported(&i.text, &i.sources));
    counts.dropped_unsupported += retain(&mut next_steps, |i| supported(&i.text, &i.sources));
    counts.dropped_unsupported += retain(&mut questions, |i| supported(&i.text, &i.sources));
    counts.dropped_unsupported += retain(&mut risks, |i| supported(&i.text, &i.sources));

    let action_texts: HashSet<String> = actions.iter().map(|a| normalize(&a.text)).collect();
    next_steps.retain(|s| !action_texts.contains(&normalize(&s.text)));
    merge(&mut decisions, |i| (i.text.clone(), i.sources.clone()));
    merge(&mut actions, |i| (i.text.clone(), i.sources.clone()));
    merge(&mut next_steps, |i| (i.text.clone(), i.sources.clone()));
    merge(&mut questions, |i| (i.text.clone(), i.sources.clone()));
    merge(&mut risks, |i| (i.text.clone(), i.sources.clone()));
    counts.items = (decisions.len() + actions.len() + next_steps.len() + questions.len() + risks.len()) as i64;
    Ok((Validated { language: result.language.clone(), summary: sentences.join(" "), whole_meeting: result.summary.whole_meeting, summary_sources, topics, decisions, action_items: actions, next_steps, open_questions: questions, risks }, counts))
}
fn retain<T>(list: &mut Vec<T>, keep: impl Fn(&T) -> bool) -> i64 {
    let before = list.len();
    list.retain(keep);
    (before - list.len()) as i64
}
/// Same sources and same normalized text collapse to the first.
fn merge<T>(list: &mut Vec<T>, key: impl Fn(&T) -> (String, Vec<SourceRef>)) {
    let mut seen = HashSet::new();
    list.retain(|i| {
        let (text, sources) = key(i);
        let mut keys: Vec<String> = sources.iter().map(SourceRef::sort_key).collect();
        keys.sort();
        seen.insert(format!("{}|{}", normalize(&text), keys.join(",")))
    });
}
fn source_text(sources: &[SourceRef], e: &Evidence) -> String {
    sources
        .iter()
        .map(|s| match s {
            SourceRef::Segment(id) => e.segments.get(&upper(id)).map_or("", |x| x.1.as_str()),
            SourceRef::Note(o, _) => e.notes.iter().find(|n| n.ordinal == *o).map_or("", |n| n.text.as_str()),
        })
        .collect::<Vec<_>>()
        .join(" ")
}
fn resolve_due(d: &mut Due, e: &Evidence) {
    let resolution = d.original.as_deref().zip(e.started_ms).and_then(|(o, ms)| resolve_phrase(o, ms, e.offset));
    if let Some(Resolution::Vague) = resolution {
        (d.state, d.date) = ("unresolved".into(), None);
        return;
    }
    match d.state.as_str() {
        "explicit_absolute" | "explicit_relative_resolved" => {
            let keep = d.source.is_some() && d.date.as_deref().is_some_and(is_iso_date);
            let mismatch = matches!(&resolution, Some(Resolution::Date(_, r)) if d.date.as_deref() != Some(r));
            if !keep || mismatch {
                (d.state, d.date) = ("unresolved".into(), None);
            }
        }
        _ => d.date = None,
    }
}
fn is_iso_date(date: &str) -> bool {
    let parts: Vec<&str> = date.split('-').collect();
    let [y, m, d] = parts[..] else { return false };
    y.len() == 4 && m.len() == 2 && d.len() == 2 && y.parse::<i64>().is_ok() && m.parse::<i64>().is_ok_and(|m| (1..=12).contains(&m)) && d.parse::<i64>().is_ok_and(|d| (1..=31).contains(&d))
}
/// `String.enumerateSubstrings(.bySentences)`.
// ponytail: ends at . ! ? or … before whitespace and an uppercase or non-letter start, and at line
// breaks; ICU's table also knows abbreviations. An unknown abbreviation only makes a shorter sentence
// to remove. Add a segmenter if summaries lose text they shouldn't.
pub fn sentences(text: &str) -> Vec<&str> {
    let mut out = vec![];
    let mut start = 0;
    let indexed: Vec<(usize, char)> = text.char_indices().collect();
    for (at, (i, c)) in indexed.iter().enumerate() {
        let end = i + c.len_utf8();
        if *c == '\n' {
            out.push(&text[start..end]);
            start = end;
        } else if matches!(*c, '.' | '!' | '?' | '…') {
            let next = indexed.get(at + 1).map(|x| x.1);
            if next.is_some_and(char::is_whitespace) {
                let after = indexed[at + 1..].iter().map(|x| x.1).find(|c| !c.is_whitespace());
                if !after.is_some_and(char::is_lowercase) {
                    out.push(&text[start..end]);
                    start = end;
                }
            }
        }
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out
}

// MARK: protected literals

const EDGE: &str = ".,;:!?()[]{}\"'„“”‚‘’«»";
fn trim_edge(token: &str) -> &str {
    token.trim_matches(|c| EDGE.contains(c))
}
fn word_tokens(text: &str) -> Vec<&str> {
    text.split_whitespace().map(trim_edge).filter(|t| !t.is_empty()).collect()
}
const STOP_WORDS: &str = "a an and or but in on at to for of with by from is are was were be been being it its this that these those we you they he she i will would can could should shall must may might do does did done have has had not no so if then than as about before after when what who how why which all any each every some more most other another new one two out up down over under again also just only very there here now us our ours your yours their theirs his her hers my mine me him them the into onto per via off too such same own both few many much between during until while because through against without within next last still already yet back well even really let lets make makes made get gets got go goes going went gone say says said see seen know think take took need needs want wants sure yes yeah okay ok please thanks ill im ive dont wont ale aj aby ak že som si je sme ste sú bol bola bolo boli byť bude budem budeš budeme budú na v vo za po pod nad pri pre od z zo s k ku o u ten tá tí tie tento toto táto ono ona oni ony vy ja ty náš naša naše váš vaša vaše ich jeho jej nie niečo nič všetko všetci ako tak takže už ešte len veľmi tu tam kde kedy čo kto prečo lebo pretože keď potom teraz dnes včera mal mala malo mali má mám máš máme máte majú môže môžem môžeme musí musím musíme treba chce chcem chceme mne mi ma mu ho nám vám nej nich sa či teda tiež prosím ďakujem monday tuesday wednesday thursday friday saturday sunday january february march april june july august september october november december pondelok utorok streda štvrtok piatok sobota nedeľa január januára február februára marec marca apríl apríla máj mája jún júna júl júla augusta septembra október októbra novembra decembra";
fn content_tokens(text: &str) -> Vec<String> {
    let stop: HashSet<String> = STOP_WORDS.split(' ').map(fold).collect();
    word_tokens(text).into_iter().map(fold).filter(|t| t.chars().count() >= 4 && !stop.contains(t)).collect()
}
/// `stemMatch`: a common prefix of at least `max(4, shorter - 3)` characters. Case and marks count.
fn stem_match(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    let prefix = a.chars().zip(b.chars()).take_while(|(x, y)| x == y).count();
    prefix >= 4.max(a.chars().count().min(b.chars().count()).saturating_sub(3))
}
fn word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}
fn digit(c: char) -> bool {
    c.is_ascii_digit()
}
fn digits(s: &str) -> bool {
    !s.is_empty() && s.chars().all(digit)
}
fn ipv4(t: &str) -> bool {
    let p: Vec<&str> = t.split('.').collect();
    p.len() == 4 && p.iter().all(|x| digits(x) && x.len() <= 3)
}
fn ipv6(t: &str) -> bool {
    let p: Vec<&str> = t.split(':').collect();
    p.len() >= 3 && p.iter().all(|x| x.len() <= 4 && x.chars().all(|c| c.is_ascii_hexdigit()))
}
fn url(t: &str) -> bool {
    let l = t.to_ascii_lowercase();
    ["http://", "https://", "ftp://"].iter().any(|s| l.strip_prefix(s).is_some_and(|r| !r.is_empty() && !r.chars().any(char::is_whitespace)))
}
fn email(t: &str) -> bool {
    let Some((local, host)) = t.split_once('@') else { return false };
    let labels: Vec<&str> = host.split('.').collect();
    !local.is_empty() && local.chars().all(|c| word(c) || ".+-".contains(c)) && labels.len() >= 2 && labels.iter().all(|l| !l.is_empty() && l.chars().all(|c| word(c) || c == '-'))
}
fn hostname(t: &str) -> bool {
    let labels: Vec<&str> = t.split('.').collect();
    let Some((tld, rest)) = labels.split_last() else { return false };
    !rest.is_empty() && tld.len() >= 2 && tld.chars().all(|c| c.is_ascii_alphabetic()) && rest.iter().all(|l| !l.is_empty() && l.chars().all(|c| word(c) || c == '-'))
}
fn time(t: &str) -> bool {
    t.split_once(':').is_some_and(|(h, m)| digits(h) && h.len() <= 2 && digits(m) && m.len() == 2)
}
fn version(t: &str) -> bool {
    let dotted = t.split('.').collect::<Vec<_>>();
    (t.starts_with(['v', 'V']) && dotted.iter().enumerate().all(|(i, p)| digits(if i == 0 { &p[1..] } else { p }))) || (dotted.len() == 3 && dotted.iter().all(|p| digits(p)))
}
fn digit_and_letter(t: &str) -> bool {
    t.chars().all(|c| word(c) || ".-".contains(c)) && t.chars().any(digit) && t.chars().any(char::is_alphabetic)
}
const UNITS: [&str; 16] = ["€", "eur", "usd", "gbp", "czk", "gb", "mb", "kb", "tb", "km", "kg", "cm", "mm", "%", "ms", "min"];
const MONTHS: [&str; 34] = ["january", "január", "januára", "february", "február", "februára", "march", "marec", "marca", "april", "apríl", "apríla", "may", "máj", "mája", "june", "jún", "júna", "july", "júl", "júla", "august", "augusta", "september", "septembra", "october", "október", "októbra", "november", "novembra", "december", "decembra", "", ""];
struct Scan {
    c: Vec<char>,
    lower: Vec<char>,
}
impl Scan {
    fn at(&self, i: usize) -> Option<char> {
        self.c.get(i).copied()
    }
    /// `(?<![\w.])`.
    fn free_before(&self, i: usize) -> bool {
        i == 0 || !(word(self.c[i - 1]) || self.c[i - 1] == '.')
    }
    /// `\b`.
    fn boundary(&self, i: usize) -> bool {
        let before = i > 0 && word(self.c[i - 1]);
        let after = self.at(i).is_some_and(word);
        before != after
    }
    fn digits_from(&self, mut i: usize, max: usize) -> usize {
        let start = i;
        while i - start < max && self.at(i).is_some_and(digit) {
            i += 1;
        }
        i - start
    }
    /// `\d[\d.,]*(?:\s\d{3})*`: every end the group can stop at, longest first.
    fn number_ends(&self, i: usize) -> Vec<usize> {
        if !self.at(i).is_some_and(digit) {
            return vec![];
        }
        let mut e = i + 1;
        while self.at(e).is_some_and(|c| digit(c) || c == '.' || c == ',') {
            e += 1;
        }
        let mut ends = vec![e];
        while self.at(e).is_some_and(char::is_whitespace) && self.digits_from(e + 1, 3) == 3 {
            e += 4;
            ends.push(e);
        }
        ends.reverse();
        ends
    }
    fn word_at(&self, i: usize, w: &str) -> Option<usize> {
        let w: Vec<char> = w.chars().collect();
        (!w.is_empty() && self.lower.get(i..i + w.len()) == Some(&w[..])).then_some(i + w.len())
    }
    fn currency(&self, i: usize) -> Option<usize> {
        if !self.free_before(i) || !matches!(self.at(i)?, '$' | '€' | '£') {
            return None;
        }
        let d = if self.at(i + 1).is_some_and(char::is_whitespace) && self.at(i + 2).is_some_and(digit) { i + 2 } else { i + 1 };
        self.number_ends(d).first().copied()
    }
    fn amount(&self, i: usize) -> Option<usize> {
        if !self.free_before(i) {
            return None;
        }
        for end in self.number_ends(i) {
            let from = [end, end + 1].into_iter().filter(|f| *f == end || self.at(end).is_some_and(char::is_whitespace));
            for f in from {
                if let Some(e) = UNITS.iter().find_map(|u| self.word_at(f, u).filter(|e| self.boundary(*e))) {
                    return Some(e);
                }
            }
        }
        None
    }
    fn numeric_date(&self, i: usize) -> Option<usize> {
        if !self.free_before(i) {
            return None;
        }
        let free = |e: usize| !self.at(e).is_some_and(|c| word(c) || c == '.');
        let run = |at: usize, min: usize, max: usize| -> Vec<usize> { (min..=self.digits_from(at, max)).rev().map(|n| at + n).collect() };
        let is = |at: usize, c: char| self.at(at) == Some(c);
        if self.digits_from(i, 4) == 4 && is(i + 4, '-') && self.digits_from(i + 5, 2) == 2 && is(i + 7, '-') && self.digits_from(i + 8, 2) == 2 && free(i + 10) {
            return Some(i + 10);
        }
        for d in run(i, 1, 2) {
            if is(d, '.') {
                for m in run(d + 1, 1, 2) {
                    if is(m, '.') {
                        for y in run(m + 1, 2, 4) {
                            if is(y, '.') && free(y + 1) {
                                return Some(y + 1);
                            }
                            if free(y) {
                                return Some(y);
                            }
                        }
                        if free(m + 1) {
                            return Some(m + 1);
                        }
                    }
                    if free(m) {
                        return Some(m);
                    }
                }
            }
            if is(d, '/') {
                for m in run(d + 1, 1, 2) {
                    if is(m, '/') {
                        for y in run(m + 1, 2, 4) {
                            if free(y) {
                                return Some(y);
                            }
                        }
                    }
                }
            }
        }
        None
    }
    fn month_end(&self, i: usize) -> Option<usize> {
        MONTHS.iter().find_map(|m| self.word_at(i, m).filter(|e| self.boundary(*e)))
    }
    fn spaces(&self, mut i: usize) -> Option<usize> {
        let start = i;
        while self.at(i).is_some_and(char::is_whitespace) {
            i += 1;
        }
        (i > start).then_some(i)
    }
    fn day_month(&self, i: usize) -> Option<usize> {
        if !self.boundary(i) {
            return None;
        }
        (1..=self.digits_from(i, 2)).rev().find_map(|n| {
            let after = i + n;
            let dotted = if self.at(after) == Some('.') { Some(after + 1) } else { None };
            dotted.into_iter().chain([after]).find_map(|f| self.month_end(self.spaces(f)?))
        })
    }
    fn month_day(&self, i: usize) -> Option<usize> {
        if !self.boundary(i) {
            return None;
        }
        let from = self.spaces(MONTHS.iter().find_map(|m| self.word_at(i, m).filter(|e| self.at(*e).is_some_and(char::is_whitespace)))?)?;
        (1..=self.digits_from(from, 2)).rev().map(|n| from + n).find(|e| self.boundary(*e))
    }
}
/// `ProtectedLiteralDetector.extract`, written by hand: `regex` isn't a dependency of this crate.
fn extract(text: &str) -> Vec<String> {
    let c: Vec<char> = text.chars().collect();
    let lower: Vec<char> = c.iter().map(|x| x.to_lowercase().next().unwrap_or(*x)).collect();
    let scan = Scan { c, lower };
    let mut literals: Vec<String> = vec![];
    let mut covered: Vec<(usize, usize)> = vec![];
    let matchers: [&dyn Fn(usize) -> Option<usize>; 5] = [&|i| scan.currency(i), &|i| scan.amount(i), &|i| scan.numeric_date(i), &|i| scan.day_month(i), &|i| scan.month_day(i)];
    for matcher in matchers {
        let mut i = 0;
        while i < scan.c.len() {
            match matcher(i) {
                Some(e) if e > i => {
                    literals.push(scan.c[i..e].iter().collect());
                    covered.push((i, e));
                    i = e;
                }
                _ => i += 1,
            }
        }
    }
    let mut i = 0;
    while i < scan.c.len() {
        if scan.c[i].is_whitespace() {
            i += 1;
            continue;
        }
        let start = i;
        while i < scan.c.len() && !scan.c[i].is_whitespace() {
            i += 1;
        }
        if covered.iter().any(|(a, b)| *a <= start && i <= *b) {
            continue;
        }
        let token: String = scan.c[start..i].iter().collect();
        let inner = trim_edge(&token);
        if !inner.is_empty() && (ipv4(inner) || ipv6(inner) || url(inner) || email(inner) || hostname(inner) || time(inner) || version(inner) || digit_and_letter(inner)) {
            literals.push(inner.to_string());
        }
    }
    let mut seen = HashSet::new();
    literals.retain(|l| !l.is_empty() && seen.insert(l.clone()));
    literals
}
/// Literals in `text` absent from `evidence`.
pub fn violations(text: &str, evidence: &str) -> Vec<String> {
    let literals = extract(text);
    if literals.is_empty() {
        return vec![];
    }
    let haystack = evidence.split_whitespace().collect::<Vec<_>>().join(" ");
    literals.into_iter().filter(|l| !haystack.contains(l.as_str())).collect()
}

// MARK: due dates

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolution {
    Vague,
    /// State and `YYYY-MM-DD`.
    Date(&'static str, String),
}
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    // Out-of-range months and days carry over, as `Calendar.date(from:)` does.
    let y = y + (m - 1).div_euclid(12);
    let m = (m - 1).rem_euclid(12) + 1;
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468 + d - 1
}
fn iso(days: i64) -> String {
    let (y, m, d) = crate::meetings::civil(days);
    format!("{y:04}-{m:02}-{d:02}")
}
fn phrase_normal(phrase: &str) -> String {
    fold(phrase).split_whitespace().collect::<Vec<_>>().join(" ").trim_matches(|c| ".,;:!?".contains(c)).to_string()
}
fn weekday(name: &str) -> Option<i64> {
    Some(match name {
        "sunday" | "nedela" => 1,
        "monday" | "pondelok" => 2,
        "tuesday" | "utorok" => 3,
        "wednesday" | "streda" => 4,
        "thursday" | "stvrtok" => 5,
        "friday" | "piatok" => 6,
        "saturday" | "sobota" => 7,
        _ => return None,
    })
}
fn month(name: &str) -> Option<i64> {
    Some(match name {
        "january" | "januara" => 1,
        "february" | "februara" => 2,
        "march" | "marca" => 3,
        "april" | "aprila" => 4,
        "may" | "maja" => 5,
        "june" | "juna" => 6,
        "july" | "jula" => 7,
        "august" | "augusta" => 8,
        "september" | "septembra" => 9,
        "october" | "oktobra" => 10,
        "november" | "novembra" => 11,
        "december" | "decembra" => 12,
        _ => return None,
    })
}
/// `DueDateResolver.resolve`. None for a phrase outside the table: the client can't check that one.
pub fn resolve_phrase(phrase: &str, started_ms: i64, offset: i32) -> Option<Resolution> {
    let n = phrase_normal(phrase);
    if n.is_empty() {
        return None;
    }
    const VAGUE: [&str; 10] = ["soon", "later", "eventually", "at some point", "next time", "čoskoro", "neskôr", "niekedy", "nabudúce", "časom"];
    if VAGUE.iter().any(|v| phrase_normal(v) == n) {
        return Some(Resolution::Vague);
    }
    let base = (started_ms.div_euclid(1000) + i64::from(offset)).div_euclid(86_400);
    let relative = |days: i64| Some(Resolution::Date("explicit_relative_resolved", iso(base + days)));
    let until = |day: i64| {
        let today = (base + 4).rem_euclid(7) + 1;
        match (day - today).rem_euclid(7) {
            0 => 7,
            d => d,
        }
    };
    match n.as_str() {
        "tomorrow" | "zajtra" => return relative(1),
        "the day after tomorrow" | "day after tomorrow" | "pozajtra" => return relative(2),
        "next week" | "buduci tyzden" => return relative(until(2)),
        _ => {}
    }
    for prefix in ["next ", "buduci "] {
        if let Some(day) = n.strip_prefix(prefix).and_then(weekday) {
            return relative(until(day) + 7);
        }
    }
    for prefix in ["on ", "by ", "vo ", "v ", "na "] {
        if let Some(day) = n.strip_prefix(prefix).and_then(weekday) {
            return relative(until(day));
        }
    }
    if let Some(day) = weekday(&n) {
        return relative(until(day));
    }
    let absolute = |days: i64| Some(Resolution::Date("explicit_absolute", iso(days)));
    let roll = |year: Option<i64>, m: i64, d: i64| -> Option<Option<Resolution>> {
        if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
            return Some(None);
        }
        if let Some(y) = year {
            return Some(absolute(days_from_civil(y, m, d)));
        }
        let (by, ..) = crate::meetings::civil(base);
        let candidate = days_from_civil(by, m, d);
        Some(absolute(if candidate >= base { candidate } else { days_from_civil(by + 1, m, d) }))
    };
    let dashed: Vec<&str> = n.split('-').collect();
    if let [y, m, d] = dashed[..]
        && y.len() == 4
        && let (Ok(y), Ok(m), Ok(d)) = (y.parse(), m.parse(), d.parse())
    {
        return absolute(days_from_civil(y, m, d));
    }
    let dotted: Vec<&str> = n.split('.').collect();
    if (dotted.len() == 2 || dotted.len() == 3)
        && let (Ok(d), Ok(m)) = (dotted[0].trim().parse(), dotted[1].trim().parse())
    {
        let year = dotted.get(2).and_then(|y| y.trim().parse().ok());
        return roll(year, m, d)?;
    }
    let words: Vec<&str> = n.split(' ').collect();
    if !(2..=4).contains(&words.len()) {
        return None;
    }
    let (mut found_month, mut found_day) = (None, None);
    for word in words {
        if let Some(m) = month(word) {
            found_month = Some(m);
        } else if word != "of" && word != "the" {
            let inner = word.trim_matches(|c: char| !c.is_ascii_digit());
            if let Ok(value) = inner.parse::<i64>() {
                found_day = Some(value);
            }
        }
    }
    roll(None, found_month?, found_day?)?
}

// MARK: overlays

/// `OverlayMatcher.normalize`: lowercased, everything but letters and digits collapsed to one space.
pub fn normalize(text: &str) -> String {
    let lower = text.to_lowercase();
    lower.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ")
}
fn jaccard<'a>(a: impl Iterator<Item = &'a str>, b: impl Iterator<Item = &'a str>) -> f64 {
    let (a, b): (HashSet<&str>, HashSet<&str>) = (a.collect(), b.collect());
    let union = a.union(&b).count();
    if union == 0 { 0.0 } else { a.intersection(&b).count() as f64 / union as f64 }
}
pub struct OverlayRow {
    pub id: String,
    pub item_kind: Option<String>,
    pub field: String,
    pub is_summary: bool,
    pub orphaned: bool,
    pub item_text: Option<String>,
    pub source_key: Option<String>,
}
pub struct NewItem {
    pub id: String,
    pub kind: String,
    pub text: String,
    pub source_keys: Vec<String>,
}
/// `OverlayMatcher.match` (`overlay_match_v1`). `existing` is oldest first. Returns (overlay, item)
/// pairs and the overlays left without one. Already orphaned and summary overlays appear in neither.
pub fn match_overlays(existing: &[OverlayRow], new_items: &[NewItem]) -> (Vec<(String, String)>, Vec<String>) {
    let (mut matched, mut orphaned) = (vec![], vec![]);
    let mut claimed = HashSet::new();
    for overlay in existing {
        let Some(kind) = overlay.item_kind.as_deref().filter(|_| !overlay.is_summary && !overlay.orphaned) else { continue };
        let source = overlay.source_key.as_deref().unwrap_or("");
        let text = normalize(overlay.item_text.as_deref().unwrap_or(""));
        let mut best: Option<(&NewItem, f64, f64)> = None;
        for item in new_items.iter().filter(|i| i.kind == kind) {
            let sources = jaccard(source.split(',').filter(|s| !s.is_empty()), item.source_keys.iter().map(String::as_str));
            let normal = normalize(&item.text);
            let words = jaccard(text.split(' ').filter(|s| !s.is_empty()), normal.split(' ').filter(|s| !s.is_empty()));
            if sources < 0.5 && words < 0.8 {
                continue;
            }
            if best.is_some_and(|b| sources < b.1 || (sources == b.1 && words <= b.2)) {
                continue;
            }
            best = Some((item, sources, words));
        }
        match best {
            Some((item, ..)) if claimed.insert(format!("{}|{}", item.id, overlay.field)) => matched.push((overlay.id.clone(), item.id.clone())),
            _ => orphaned.push(overlay.id.clone()),
        }
    }
    (matched, orphaned)
}
