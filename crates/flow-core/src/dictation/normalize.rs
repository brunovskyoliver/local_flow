//! `TranscriptNormalizer`: formatting N001-N004 and vocabulary V001, run to a fixed point. Text is
//! only compared and rebuilt here, never logged.
use crate::db::Db;
use crate::dictionary::{self, fold, nfc};
use std::collections::{BTreeSet, HashMap, HashSet};

pub const VERSION: &str = "formatting-n001-n006-vocabulary-v001-v1";
const MAX_TEXT: usize = 65_536;
const MAX_SPANS: usize = 16_384;
const MAX_MATCHES: usize = 8_192;
const MAX_PASSES: usize = 32;
pub const EMPTY_VOCABULARY_HASH: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

#[derive(Clone, Debug)]
struct Key {
    scalars: Vec<char>,
    entry_id: String,
    canonical: String,
    key_id: String,
}

/// `VocabularySnapshot`: the enabled terms at key-down, without keys the user kept undoing.
#[derive(Clone, Debug, Default)]
pub struct Vocabulary {
    pub revision: i64,
    pub hash: String,
    by_first: HashMap<char, Vec<Key>>,
    /// Canonical spellings for the worker's boost, and every governed key.
    pub boost: Vec<(String, String)>,
    pub governed: Vec<String>,
}

impl Vocabulary {
    pub fn empty() -> Vocabulary {
        Vocabulary { hash: EMPTY_VOCABULARY_HASH.into(), ..Default::default() }
    }
    pub fn new(revision: i64, hash: String, entries: &[dictionary::Entry], retired: &HashSet<(String, String)>) -> Vocabulary {
        let mut vocabulary = Vocabulary { revision, hash, ..Default::default() };
        for entry in entries.iter().filter(|e| e.enabled) {
            if !retired.contains(&(entry.id.clone(), dictionary::BOOST.to_string())) {
                vocabulary.boost.push((entry.id.clone(), entry.canonical.clone()));
            }
            for term in std::iter::once(&entry.canonical).chain(&entry.aliases) {
                let key_id = dictionary::key_id(term);
                if retired.contains(&(entry.id.clone(), key_id.clone())) {
                    continue;
                }
                let scalars: Vec<char> = fold(term).chars().collect();
                let Some(first) = scalars.first().copied() else { continue };
                vocabulary.governed.push(term.clone());
                vocabulary.by_first.entry(first).or_default().push(Key { scalars, entry_id: entry.id.clone(), canonical: entry.canonical.clone(), key_id });
            }
        }
        for keys in vocabulary.by_first.values_mut() {
            keys.sort_by(|a, b| b.scalars.len().cmp(&a.scalars.len()).then_with(|| a.entry_id.cmp(&b.entry_id)));
        }
        vocabulary
    }
    pub fn load(db: &Db) -> Result<Vocabulary, String> {
        let contents = dictionary::load(db).map_err(|_| "damaged".to_string())?;
        let usage = dictionary::usage(db).map_err(|e| e.to_string())?;
        let retired = usage.values().flatten().filter(|u| u.state == "retired").map(|u| (u.entry_id.clone(), u.key_id.clone())).collect();
        Ok(Vocabulary::new(contents.state.revision, contents.state.content_hash.clone(), &contents.entries, &retired))
    }
    fn is_empty(&self) -> bool {
        self.by_first.is_empty()
    }
}

/// `DictionaryChange`.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Change {
    pub entry_id: String,
    pub key_id: String,
    pub canonical: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Normalized {
    pub text: String,
    pub rules: Vec<String>,
    pub entries: Vec<String>,
    pub ambiguous: Vec<String>,
    /// `completionReasons` codes.
    pub reasons: Vec<&'static str>,
    pub changes: Vec<Change>,
}

struct Full;

fn push_str(out: &mut String, s: &str) -> Result<(), Full> {
    if out.len() + s.len() > MAX_TEXT {
        return Err(Full);
    }
    out.push_str(s);
    Ok(())
}
fn push(out: &mut String, c: char) -> Result<(), Full> {
    if out.len() + c.len_utf8() > MAX_TEXT {
        return Err(Full);
    }
    out.push(c);
    Ok(())
}

fn line_endings(input: &str) -> Result<String, Full> {
    let mut out = String::new();
    let mut previous_cr = false;
    for c in input.chars() {
        if c == '\r' {
            push(&mut out, '\n')?;
        } else if c != '\n' || !previous_cr {
            push(&mut out, c)?;
        }
        previous_cr = c == '\r';
    }
    Ok(out)
}

fn horizontal_whitespace(input: &str) -> Result<String, Full> {
    let mut out = String::new();
    let (mut pending, mut line_start) = (false, true);
    for c in input.chars() {
        if c == ' ' || c == '\t' {
            pending = !line_start;
        } else if c == '\n' {
            push(&mut out, c)?;
            pending = false;
            line_start = true;
        } else {
            if pending {
                push(&mut out, ' ')?;
            }
            push(&mut out, c)?;
            pending = false;
            line_start = false;
        }
    }
    Ok(out)
}

#[derive(Clone)]
struct Span {
    start: usize,
    end: usize,
    core: (usize, usize),
    quoted: bool,
    technical: bool,
    technical_core: bool,
}

fn is_technical(c: char) -> bool {
    c.is_numeric() || "_/:\\@`.=+<>[]{}()|#%$&*~^-".contains(c)
}

fn spans(s: &[char]) -> Result<Vec<Span>, Full> {
    let mut out: Vec<Span> = Vec::new();
    let mut start = None;
    let (mut quoted, mut technical) = (false, false);
    let mut quote: Option<char> = None;
    let close = |out: &mut Vec<Span>, lower: usize, upper: usize, quoted: bool, technical: bool| -> Result<(), Full> {
        if out.len() >= MAX_SPANS {
            return Err(Full);
        }
        let mut core = (lower, upper);
        while core.1 - core.0 > 1 && "([{".contains(s[core.0]) {
            core.0 += 1;
        }
        while core.1 - core.0 > 1 && ".,;:!?)]}".contains(s[core.1 - 1]) {
            core.1 -= 1;
        }
        out.push(Span { start: lower, end: upper, core, quoted, technical, technical_core: s[core.0..core.1].iter().any(|c| is_technical(*c)) });
        Ok(())
    };
    for (i, &c) in s.iter().enumerate() {
        if c.is_whitespace() {
            if let Some(lower) = start.take() {
                close(&mut out, lower, i, quoted, technical)?;
            }
            continue;
        }
        if start.is_none() {
            start = Some(i);
            quoted = quote.is_some();
            technical = false;
        }
        let apostrophe = c == '\'' && i > 0 && i + 1 < s.len() && s[i - 1].is_alphabetic() && s[i + 1].is_alphabetic();
        if c == '`' && i > 0 && s[i - 1] == '`' {
            quoted = true;
        } else if let Some(closing) = quote {
            quoted = true;
            if c == closing && !apostrophe {
                quote = None;
            }
        } else {
            if !apostrophe {
                let opened = match c {
                    '"' | '\'' | '`' => Some(c),
                    '\u{201C}' => Some('\u{201D}'),
                    '\u{2018}' => Some('\u{2019}'),
                    _ => None,
                };
                if opened.is_some() {
                    quote = opened;
                    quoted = true;
                }
            }
            if is_technical(c) {
                technical = true;
            }
        }
    }
    if let Some(lower) = start {
        close(&mut out, lower, s.len(), quoted, technical)?;
    }
    Ok(out)
}

fn commas(input: &str) -> Result<String, Full> {
    let s: Vec<char> = input.chars().collect();
    let spans = spans(&s)?;
    let mut removals = HashSet::new();
    for w in spans.windows(3) {
        let (l, m, r) = (&w[0], &w[1], &w[2]);
        let protected = |x: &Span| x.quoted || x.technical;
        if protected(l) || protected(m) || protected(r) || m.end - m.start != 1 || s[m.start] != ',' {
            continue;
        }
        if l.end + 1 != m.start || s[l.end] != ' ' || m.end + 1 != r.start || s[m.end] != ' ' || !s[l.end - 1].is_alphabetic() || !s[r.start].is_alphabetic() {
            continue;
        }
        if removals.len() >= MAX_MATCHES {
            return Err(Full);
        }
        removals.insert(l.end);
    }
    let mut out = String::new();
    for (i, c) in s.iter().enumerate() {
        if !removals.contains(&i) {
            push(&mut out, *c)?;
        }
    }
    Ok(out)
}

/// `VocabularyValidation.isTermScalar`: letters, marks, numbers, underscore.
fn is_term(c: char) -> bool {
    c == '_' || c.is_alphanumeric() || dictionary::is_mark(c)
}

fn covers_protected(start: usize, end: usize, spans: &[Span]) -> bool {
    let low = spans.partition_point(|s| s.end <= start);
    spans[low..].iter().take_while(|s| s.start < end).all(|s| !(s.quoted || s.technical_core) || (s.core.0 >= start && s.core.1 <= end))
}

fn vocabulary_terms(input: &str, vocabulary: &Vocabulary, applied: &mut BTreeSet<String>, ambiguous: &mut BTreeSet<String>, changes: &mut BTreeSet<Change>) -> Result<String, Full> {
    ambiguous.clear();
    if vocabulary.is_empty() {
        return Ok(input.into());
    }
    let source: Vec<char> = input.chars().collect();
    let spans = spans(&source)?;
    let (mut folded, mut origin) = (Vec::with_capacity(source.len()), Vec::with_capacity(source.len()));
    for (i, c) in source.iter().enumerate() {
        for mapped in c.to_lowercase() {
            folded.push(mapped);
            origin.push(i);
        }
    }
    struct Candidate<'a> {
        start: usize,
        end: usize,
        key: &'a Key,
    }
    let mut candidates = Vec::new();
    let mut seen = HashSet::new();
    for start in 0..folded.len() {
        let Some(keys) = vocabulary.by_first.get(&folded[start]) else { continue };
        for key in keys {
            let end = start + key.scalars.len();
            if end > folded.len() || folded[start..end] != key.scalars[..] {
                continue;
            }
            if (start > 0 && origin[start - 1] == origin[start]) || (end < folded.len() && origin[end - 1] == origin[end]) {
                continue;
            }
            let (a, b) = (origin[start], origin[end - 1] + 1);
            if (a > 0 && is_term(source[a - 1])) || (b < source.len() && is_term(source[b])) || !covers_protected(a, b, &spans) {
                continue;
            }
            if source[a..b].iter().collect::<String>() == key.canonical || !seen.insert((a, b, key.canonical.as_str())) {
                continue;
            }
            if candidates.len() >= MAX_MATCHES {
                return Err(Full);
            }
            candidates.push(Candidate { start: a, end: b, key });
        }
    }
    candidates.sort_by_key(|c| (c.start, c.end));
    let mut out = String::new();
    let mut cursor = 0;
    let mut i = 0;
    while i < candidates.len() {
        let (mut group_end, mut reach) = (i + 1, candidates[i].end);
        while group_end < candidates.len() && candidates[group_end].start < reach {
            reach = reach.max(candidates[group_end].end);
            group_end += 1;
        }
        if group_end - i == 1 {
            let c = &candidates[i];
            for p in cursor..c.start {
                push(&mut out, source[p])?;
            }
            push_str(&mut out, &c.key.canonical)?;
            applied.insert(c.key.entry_id.clone());
            changes.insert(Change { entry_id: c.key.entry_id.clone(), key_id: c.key.key_id.clone(), canonical: c.key.canonical.clone() });
            cursor = c.end;
        } else {
            ambiguous.extend(candidates[i..group_end].iter().map(|c| c.key.entry_id.clone()));
        }
        i = group_end;
    }
    for p in cursor..source.len() {
        push(&mut out, source[p])?;
    }
    Ok(out)
}

pub fn normalize(input: &str, vocabulary: &Vocabulary) -> Normalized {
    let fallback = |reason| Normalized { text: input.into(), reasons: vec![reason], ..Default::default() };
    if input.len() > MAX_TEXT {
        return fallback("normalization_capacity");
    }
    let unexpected = input.chars().any(|c| (c.is_control() || dictionary::is_format(c)) && !matches!(c, '\r' | '\n' | '\t'));
    let (mut rules, mut entries, mut ambiguous, mut changes) = (BTreeSet::new(), BTreeSet::new(), BTreeSet::new(), BTreeSet::new());
    let mut text = input.to_string();
    for _ in 0..MAX_PASSES {
        let mut changed = false;
        for rule in 1..=5 {
            let next = match rule {
                1 => Ok(nfc(&text)).and_then(|t| if t.len() > MAX_TEXT { Err(Full) } else { Ok(t) }),
                2 => line_endings(&text),
                3 => horizontal_whitespace(&text),
                4 => commas(&text),
                _ => vocabulary_terms(&text, vocabulary, &mut entries, &mut ambiguous, &mut changes),
            };
            let Ok(next) = next else { return fallback("normalization_capacity") };
            if next != text {
                rules.insert(if rule == 5 { "V001".to_string() } else { format!("N00{rule}") });
                changed = true;
            }
            text = next;
        }
        if !changed {
            let mut reasons = Vec::new();
            if unexpected {
                reasons.push("unexpected_control");
            }
            if !ambiguous.is_empty() {
                reasons.push("ambiguous_vocabulary");
            }
            return Normalized { text, rules: rules.into_iter().collect(), entries: entries.into_iter().collect(), ambiguous: ambiguous.into_iter().collect(), reasons, changes: changes.into_iter().collect() };
        }
    }
    fallback("normalization_nonconvergent")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vocab(entries: &[(&str, &str, &[&str])]) -> Vocabulary {
        let entries: Vec<dictionary::Entry> = entries.iter().map(|(id, canonical, aliases)| dictionary::Entry { id: id.to_string(), canonical: canonical.to_string(), aliases: aliases.iter().map(|a| a.to_string()).collect(), enabled: true, learned_at: None }).collect();
        Vocabulary::new(3, "h".into(), &entries, &HashSet::new())
    }
    fn plain(s: &str) -> String {
        normalize(s, &Vocabulary::empty()).text
    }

    #[test]
    fn formatting_rules() {
        assert_eq!(plain("a\r\nb\rc"), "a\nb\nc");
        assert_eq!(plain("  a \t  b  \n  c "), "a b\nc");
        assert_eq!(plain("hello , world"), "hello, world");
        assert_eq!(plain("Zu\u{308}rich"), "Zürich");
        let r = normalize("a  b", &Vocabulary::empty());
        assert_eq!(r.rules, ["N003"]);
        assert!(r.reasons.is_empty());
    }

    #[test]
    fn protected_spans_keep_their_comma() {
        assert_eq!(plain("x1 , y"), "x1 , y", "a number is technical");
        assert_eq!(plain("\"a , b\""), "\"a , b\"", "quoted");
        assert_eq!(plain("don't , go"), "don't, go", "an apostrophe in a word is no quote");
    }

    #[test]
    fn reasons_and_capacity() {
        assert_eq!(normalize("a\u{7}b", &Vocabulary::empty()).reasons, ["unexpected_control"]);
        assert_eq!(normalize("a\u{200B}b", &Vocabulary::empty()).reasons, ["unexpected_control"]);
        let long = "a".repeat(MAX_TEXT + 1);
        let r = normalize(&long, &Vocabulary::empty());
        assert_eq!((r.reasons.as_slice(), r.text == long), (["normalization_capacity"].as_slice(), true));
    }

    #[test]
    fn vocabulary_whole_terms() {
        let v = vocab(&[("e1", "Zabbix", &["zabix"])]);
        let r = normalize("check zabix, and ZABIX. not zabixes", &v);
        assert_eq!(r.text, "check Zabbix, and Zabbix. not zabixes");
        assert_eq!(r.rules, ["V001"]);
        assert_eq!(r.entries, ["e1"]);
        assert_eq!(r.changes[0].key_id, dictionary::key_id("zabix"));
        assert_eq!(normalize("Zabbix", &v).rules, Vec::<String>::new(), "already canonical");
        assert_eq!(normalize("foo/zabix", &v).text, "foo/zabix", "part of a path");
        assert_eq!(normalize("\"zabix\"", &v).text, "\"zabix\"", "the quote is outside the match");
    }

    #[test]
    fn overlaps_stay_and_are_reported() {
        let v = vocab(&[("e1", "New York", &[]), ("e2", "York City", &[])]);
        let r = normalize("new york city", &v);
        assert_eq!(r.text, "new york city");
        assert_eq!(r.ambiguous, ["e1", "e2"]);
        assert_eq!(r.reasons, ["ambiguous_vocabulary"]);
    }

    #[test]
    fn retired_keys_and_disabled_entries_do_nothing() {
        let entry = dictionary::Entry { id: "e".into(), canonical: "Zabbix".into(), aliases: vec!["zabix".into()], enabled: true, learned_at: None };
        let retired = HashSet::from([("e".to_string(), dictionary::key_id("zabix"))]);
        assert_eq!(normalize("zabix", &Vocabulary::new(1, "h".into(), std::slice::from_ref(&entry), &retired)).text, "zabix");
        let off = dictionary::Entry { enabled: false, ..entry };
        assert_eq!(normalize("zabix", &Vocabulary::new(1, "h".into(), &[off], &HashSet::new())).text, "zabix");
    }
}
