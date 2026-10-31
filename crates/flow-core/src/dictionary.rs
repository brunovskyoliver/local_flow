//! Store and logic behind the dictionary views: ports of `VocabularyStore`, `DictionaryUsageStore`,
//! `TermSuggestionStore`, `TermSuggestionMiner` and `VocabularyViewModel`.
use crate::db::Db;
use crate::history::{new_uuid, now_ms, short_day, sha256_hex};
use rusqlite::{OptionalExtension, params};
use std::collections::{HashMap, HashSet};

pub const MAX_ENTRIES: usize = 512;
pub const MAX_ALIASES: usize = 8;
pub const MAX_KEYS: usize = 4608;
pub const MAX_PAYLOAD: usize = 1_048_576;
const PREFIX: &str = "localflow-vocabulary-v1:";
pub const BOOST: &str = "boost";

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Entry {
    pub id: String,
    pub canonical: String,
    pub aliases: Vec<String>,
    pub enabled: bool,
    pub learned_at: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct State {
    pub revision: i64,
    pub content_hash: String,
    pub payload_bytes: i64,
}

pub struct Contents {
    pub state: State,
    pub entries: Vec<Entry>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Field {
    Canonical,
    Alias(usize),
    Aliases,
    Entry,
    Store,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Code {
    Empty,
    Multiline,
    Control,
    EdgeWhitespace,
    Spacing,
    TooManyBytes,
    TooManyScalars,
    NotCanonicalForm,
    UnstableFormatting,
    TooManyAliases,
    DuplicateAlias,
    ConflictingSource,
    TargetChain,
    TooManyEntries,
    TooManyKeys,
    PayloadCapacity,
    MissingEntry,
    StaleRevision,
    InvalidId,
    Damaged,
}

impl Code {
    pub fn message(self) -> &'static str {
        match self {
            Code::Empty => "Enter a term.",
            Code::Multiline => "Use one line.",
            Code::Control => "Remove control characters.",
            Code::EdgeWhitespace => "Remove leading or trailing spaces.",
            Code::Spacing => "Separate words with single spaces.",
            Code::TooManyBytes => "At most 256 bytes.",
            Code::TooManyScalars => "At most 64 characters.",
            Code::NotCanonicalForm => "Use composed Unicode characters.",
            Code::UnstableFormatting => "Canonical spelling must already be formatted.",
            Code::TooManyAliases => "At most 8 aliases.",
            Code::DuplicateAlias => "This alias repeats another term in the entry.",
            Code::ConflictingSource => "This term already maps to another entry.",
            Code::TargetChain => "This alias is another entry's canonical spelling.",
            Code::TooManyEntries => "At most 512 entries.",
            Code::TooManyKeys => "At most 4608 terms in total.",
            Code::PayloadCapacity => "Vocabulary storage is full.",
            Code::MissingEntry => "This entry no longer exists.",
            Code::StaleRevision => "The vocabulary changed. Review and save again.",
            Code::InvalidId => "Entry identity is invalid.",
            Code::Damaged => "Stored vocabulary is invalid and cannot be used.",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditError {
    pub field: Field,
    pub code: Code,
    pub conflicting: Option<String>,
}

fn edit(field: Field, code: Code) -> EditError {
    EditError { field, code, conflicting: None }
}

#[derive(Debug)]
pub enum VocabError {
    Edit(EditError),
    Sql(rusqlite::Error),
}

impl From<rusqlite::Error> for VocabError {
    fn from(e: rusqlite::Error) -> Self {
        VocabError::Sql(e)
    }
}
impl From<EditError> for VocabError {
    fn from(e: EditError) -> Self {
        VocabError::Edit(e)
    }
}

/// `DictationErrorMessage.describe`. An unknown error names its type and code, never its text.
pub fn describe(e: &VocabError) -> String {
    match e {
        VocabError::Edit(f) => match f.code {
            Code::Damaged => "Preferred spellings could not be loaded. Repair or delete entries in Settings.".into(),
            Code::StaleRevision => f.code.message().into(),
            _ => format!("Preferred spelling rejected: {}", f.code.message()),
        },
        VocabError::Sql(e) => format!("Error type DatabaseError, code {}.", e.sqlite_error_code().map(|c| c as i32).unwrap_or(1)),
    }
}

// ---- Unicode helpers ----

/// (combining mark, base + composed pairs).
const COMPOSE: &[(char, &str)] = &[
    ('\u{300}', "AÀEÈIÌOÒUÙaàeèiìoòuùNǸnǹ"),
    ('\u{301}', "AÁEÉIÍOÓUÚYÝaáeéiíoóuúyýCĆcćLĹlĺNŃnńRŔrŕSŚsśZŹzź"),
    ('\u{302}', "AÂEÊIÎOÔUÛaâeêiîoôuûCĈcĉGĜgĝHĤhĥJĴjĵSŜsŝWŴwŵYŶyŷ"),
    ('\u{303}', "AÃNÑOÕaãnñoõIĨiĩUŨuũ"),
    ('\u{304}', "AĀaāEĒeēIĪiīOŌoōUŪuū"),
    ('\u{306}', "AĂaăEĔeĕGĞgğIĬiĭOŎoŏUŬuŭ"),
    ('\u{307}', "CĊcċEĖeėGĠgġIİZŻzż"),
    ('\u{308}', "AÄEËIÏOÖUÜaäeëiïoöuüyÿYŸ"),
    ('\u{30A}', "AÅaåUŮuů"),
    ('\u{30B}', "OŐoőUŰuű"),
    ('\u{30C}', "CČcčDĎdďEĚeěNŇnňRŘrřSŠsšTŤtťZŽzž"),
    ('\u{327}', "CÇcçGĢgģKĶkķLĻlļNŅnņRŖrŗSŞsşTŢtţ"),
    ('\u{328}', "AĄaąEĘeęIĮiįUŲuų"),
];

/// NFC. // ponytail: Latin base + one mark only, so flow-core adds no Unicode table dependency; a
/// decomposed non-Latin term passes as already composed. Add `unicode-normalization` to close it.
pub fn nfc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if let Some((_, pairs)) = COMPOSE.iter().find(|(m, _)| *m == c)
            && let Some(last) = out.chars().last()
        {
            let list: Vec<char> = pairs.chars().collect();
            if let Some(pair) = list.chunks(2).find(|p| p[0] == last) {
                out.pop();
                out.push(pair[1]);
                continue;
            }
        }
        out.push(c);
    }
    out
}

/// NFD with the combining marks removed. // ponytail: Latin only, from the same table as `nfc`; a
/// non-Latin base keeps its mark, so `ContextCopyGuard` treats й and и as different. Same fix as `nfc`.
pub fn strip_marks(s: &str) -> String {
    s.chars()
        .filter(|c| !matches!(*c as u32, 0x300..=0x36F))
        .map(|c| COMPOSE.iter().find_map(|(_, pairs)| pairs.chars().collect::<Vec<_>>().chunks(2).find(|p| p[1] == c).map(|p| p[0])).unwrap_or(c))
        .collect()
}

/// `TermFolding.fold`: NFC plus lowercase mapping per scalar, no other folding.
pub fn fold(term: &str) -> String {
    nfc(term).chars().flat_map(char::to_lowercase).collect()
}

/// General category Cf.
fn is_format(c: char) -> bool {
    matches!(c as u32, 0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x180E | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB | 0xE0001 | 0xE0020..=0xE007F)
}

pub fn term_code(term: &str) -> Option<Code> {
    if term.is_empty() {
        return Some(Code::Empty);
    }
    let first = term.chars().next()?;
    let last = term.chars().last()?;
    if term.contains(['\n', '\r']) {
        return Some(Code::Multiline);
    }
    if term.chars().any(|c| c.is_control() || is_format(c)) {
        return Some(Code::Control);
    }
    if first.is_whitespace() || last.is_whitespace() {
        return Some(Code::EdgeWhitespace);
    }
    let mut prev = false;
    for c in term.chars() {
        if c.is_whitespace() {
            if c != ' ' || prev {
                return Some(Code::Spacing);
            }
            prev = true;
        } else {
            prev = false;
        }
    }
    if term.len() > 256 {
        return Some(Code::TooManyBytes);
    }
    if term.chars().count() > 64 {
        return Some(Code::TooManyScalars);
    }
    if nfc(term) != term {
        return Some(Code::NotCanonicalForm);
    }
    None
}

/// N004, the one `TranscriptNormalizer` rule that can change a term `term_code` already accepted:
/// a lone comma between two plain words loses the space before it.
fn formatted(term: &str) -> String {
    const TECHNICAL: &str = "_/:\\@`.=+<>[]{}()|#%$&*~^-";
    let chars: Vec<char> = term.chars().collect();
    // (range, protected): whitespace-separated spans; quotes run across spans.
    let mut spans: Vec<(usize, usize, bool)> = vec![];
    let (mut start, mut quote, mut prot) = (None::<usize>, None::<char>, false);
    for (i, &c) in chars.iter().enumerate() {
        if c.is_whitespace() {
            if let Some(s) = start.take() {
                spans.push((s, i, prot));
            }
            continue;
        }
        if start.is_none() {
            start = Some(i);
            prot = quote.is_some();
        }
        let in_word = c == '\'' && i > 0 && i + 1 < chars.len() && chars[i - 1].is_alphabetic() && chars[i + 1].is_alphabetic();
        if let Some(q) = quote {
            prot = true;
            if c == q && !in_word {
                quote = None;
            }
        } else {
            if !in_word {
                let closing = match c {
                    '"' | '\'' | '`' => Some(c),
                    '\u{201C}' => Some('\u{201D}'),
                    '\u{2018}' => Some('\u{2019}'),
                    _ => None,
                };
                if closing.is_some() {
                    quote = closing;
                    prot = true;
                }
            }
            if c.is_numeric() || TECHNICAL.contains(c) {
                prot = true;
            }
        }
    }
    if let Some(s) = start {
        spans.push((s, chars.len(), prot));
    }
    let mut removals = HashSet::new();
    for w in spans.windows(3) {
        let ((_, le, lp), (cs, ce, cp), (rs, _, rp)) = (w[0], w[1], w[2]);
        if !lp && !cp && !rp && ce - cs == 1 && chars[cs] == ',' && le + 1 == cs && ce + 1 == rs && chars[le - 1].is_alphabetic() && chars[rs].is_alphabetic() {
            removals.insert(le);
        }
    }
    chars.iter().enumerate().filter(|(i, _)| !removals.contains(i)).map(|(_, c)| *c).collect()
}

pub fn validate_fields(e: &Entry, verify_formatting: bool) -> Result<(), EditError> {
    if e.id.is_empty() || e.id.len() > 128 || e.id.chars().any(|c| c.is_control() || is_format(c)) {
        return Err(edit(Field::Entry, Code::InvalidId));
    }
    if let Some(code) = term_code(&e.canonical) {
        return Err(edit(Field::Canonical, code));
    }
    if verify_formatting && formatted(&e.canonical) != e.canonical {
        return Err(edit(Field::Canonical, Code::UnstableFormatting));
    }
    if e.aliases.len() > MAX_ALIASES {
        return Err(edit(Field::Aliases, Code::TooManyAliases));
    }
    for (i, a) in e.aliases.iter().enumerate() {
        if let Some(code) = term_code(a) {
            return Err(edit(Field::Alias(i), code));
        }
    }
    Ok(())
}

#[derive(Default, Clone)]
pub struct KeyTable {
    owners: HashMap<String, (String, bool)>,
}

impl KeyTable {
    fn remove(&mut self, id: &str) {
        self.owners.retain(|_, v| v.0 != id);
    }
    fn register(&mut self, e: &Entry) -> Result<(), EditError> {
        let key = fold(&e.canonical);
        if let Some((owner, _)) = self.owners.get(&key) {
            return Err(EditError { field: Field::Canonical, code: Code::ConflictingSource, conflicting: Some(owner.clone()) });
        }
        let mut own: HashSet<String> = HashSet::from([key.clone()]);
        let mut pending = vec![(key, true)];
        for (i, alias) in e.aliases.iter().enumerate() {
            let key = fold(alias);
            if !own.insert(key.clone()) {
                return Err(edit(Field::Alias(i), Code::DuplicateAlias));
            }
            if let Some((owner, canonical)) = self.owners.get(&key) {
                return Err(EditError { field: Field::Alias(i), code: if *canonical { Code::TargetChain } else { Code::ConflictingSource }, conflicting: Some(owner.clone()) });
            }
            pending.push((key, false));
        }
        if self.owners.len() + pending.len() > MAX_KEYS {
            return Err(edit(Field::Entry, Code::TooManyKeys));
        }
        for (k, c) in pending {
            self.owners.insert(k, (e.id.clone(), c));
        }
        Ok(())
    }
}

fn json_string(s: &str, out: &mut Vec<u8>) {
    out.push(b'"');
    for &b in s.as_bytes() {
        match b {
            b'"' | b'\\' => out.extend([b'\\', b]),
            0..=0x1F => out.extend(format!("\\u{b:04x}").bytes()),
            _ => out.push(b),
        }
    }
    out.push(b'"');
}

fn json_array(v: &[String], out: &mut Vec<u8>) {
    out.push(b'[');
    for (i, s) in v.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        json_string(s, out);
    }
    out.push(b']');
}

pub fn encode_aliases(a: &[String]) -> String {
    let mut out = vec![];
    json_array(a, &mut out);
    String::from_utf8(out).expect("utf-8 in, utf-8 out")
}

/// The bytes Swift hashes: must stay identical, so this writes them by hand as Swift does.
pub fn serialize(entries: &[Entry]) -> Vec<u8> {
    let mut out: Vec<u8> = PREFIX.bytes().collect();
    out.push(b'[');
    let mut sorted: Vec<&Entry> = entries.iter().collect();
    sorted.sort_by(|a, b| a.id.as_bytes().cmp(b.id.as_bytes()));
    for (i, e) in sorted.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        out.extend(b"{\"aliases\":");
        json_array(&e.aliases, &mut out);
        out.extend(b",\"canonical\":");
        json_string(&e.canonical, &mut out);
        out.extend(if e.enabled { &b",\"enabled\":true,\"id\":"[..] } else { &b",\"enabled\":false,\"id\":"[..] });
        json_string(&e.id, &mut out);
        if let Some(l) = e.learned_at {
            out.extend(format!(",\"learned_at\":{l}").bytes());
        }
        out.push(b'}');
    }
    out.push(b']');
    out
}

fn payload_bytes(serialized: &[u8]) -> i64 {
    serialized.len() as i64 - (PREFIX.len() as i64 + 2)
}

/// Swift's strict decoder accepts only a bounded string array; serde gives the same answer on
/// everything `encode_aliases` writes.
fn decode_aliases(json: &str) -> Option<Vec<String>> {
    if json.len() > 4096 {
        return None;
    }
    let v: Vec<String> = serde_json::from_str(json).ok()?;
    (v.len() <= MAX_ALIASES).then_some(v)
}

fn load_with_table(db: &Db) -> Result<(Contents, KeyTable), VocabError> {
    let damaged = || VocabError::Edit(edit(Field::Store, Code::Damaged));
    let state = db
        .conn
        .query_row("SELECT schema_version, revision, content_hash, payload_bytes FROM vocabulary_state WHERE id=1", [], |r| {
            Ok((r.get::<_, i64>(0)?, State { revision: r.get(1)?, content_hash: r.get(2)?, payload_bytes: r.get(3)? }))
        })
        .optional()?
        .ok_or_else(damaged)?;
    let count: i64 = db.conn.query_row("SELECT count(*) FROM vocabulary_entries", [], |r| r.get(0))?;
    if state.0 != 1 || count as usize > MAX_ENTRIES {
        return Err(damaged());
    }
    let state = state.1;
    let mut stmt = db.conn.prepare("SELECT id, canonical_text, aliases_json, enabled, learned_at FROM vocabulary_entries ORDER BY id LIMIT 513")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, bool>(3)?, r.get::<_, Option<i64>>(4)?)))?;
    let mut entries = vec![];
    for row in rows {
        let (id, canonical, aliases, enabled, learned_at) = row?;
        let aliases = decode_aliases(&aliases).ok_or_else(damaged)?;
        if learned_at.is_some_and(|l| l < 0) {
            return Err(damaged());
        }
        entries.push(Entry { id, canonical, aliases, enabled, learned_at });
    }
    let bytes = serialize(&entries);
    if payload_bytes(&bytes) != state.payload_bytes || state.payload_bytes as usize > MAX_PAYLOAD || sha256_hex(&bytes) != state.content_hash {
        return Err(damaged());
    }
    let mut table = KeyTable::default();
    let mut ids = HashSet::new();
    for e in &entries {
        if validate_fields(e, false).is_err() || !ids.insert(e.id.clone()) || table.register(e).is_err() {
            return Err(damaged());
        }
    }
    Ok((Contents { state, entries }, table))
}

pub fn load(db: &Db) -> Result<Contents, VocabError> {
    load_with_table(db).map(|l| l.0)
}

/// Rejections roll back; identical content returns the current state without a new revision.
fn mutate(db: &Db, expected: Option<i64>, change: impl FnOnce(&[Entry], &KeyTable) -> Result<Vec<Entry>, EditError>, write: impl FnOnce(&Db) -> rusqlite::Result<()>) -> Result<State, VocabError> {
    let tx = db.conn.unchecked_transaction()?;
    let (current, table) = load_with_table(db)?;
    if expected.is_some_and(|r| r != current.state.revision) {
        return Err(edit(Field::Store, Code::StaleRevision).into());
    }
    let updated = change(&current.entries, &table)?;
    if updated.len() > MAX_ENTRIES {
        return Err(edit(Field::Entry, Code::TooManyEntries).into());
    }
    let bytes = serialize(&updated);
    let payload = payload_bytes(&bytes);
    if payload as usize > MAX_PAYLOAD {
        return Err(edit(Field::Entry, Code::PayloadCapacity).into());
    }
    let hash = sha256_hex(&bytes);
    if hash == current.state.content_hash && updated.len() == current.entries.len() {
        return Ok(current.state);
    }
    write(db)?;
    let next = State { revision: current.state.revision + 1, content_hash: hash, payload_bytes: payload };
    db.conn.execute("UPDATE vocabulary_state SET revision=?, content_hash=?, payload_bytes=? WHERE id=1", params![next.revision, next.content_hash, next.payload_bytes])?;
    tx.commit()?;
    Ok(next)
}

/// `state` is "established" for an editor save, "provisional" for the correction learner's.
pub fn save(db: &Db, e: &Entry, expected: Option<i64>, state: &str) -> Result<State, VocabError> {
    validate_fields(e, true)?;
    let aliases = encode_aliases(&e.aliases);
    mutate(
        db,
        expected,
        |entries, table| {
            let mut others: Vec<Entry> = entries.iter().filter(|o| o.id != e.id).cloned().collect();
            if others.len() >= MAX_ENTRIES {
                return Err(edit(Field::Entry, Code::TooManyEntries));
            }
            let mut table = table.clone();
            table.remove(&e.id);
            table.register(e)?;
            others.push(e.clone());
            Ok(others)
        },
        |db| {
            db.conn.execute(
                "INSERT INTO vocabulary_entries (id, canonical_text, aliases_json, enabled, learned_at) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET canonical_text=excluded.canonical_text, aliases_json=excluded.aliases_json, enabled=excluded.enabled, learned_at=excluded.learned_at",
                params![e.id, e.canonical, aliases, e.enabled, e.learned_at],
            )?;
            entry_saved(db, e, state)
        },
    )
}

fn entry_saved(db: &Db, e: &Entry, state: &str) -> rusqlite::Result<()> {
    let mut keys: HashSet<String> = std::iter::once(&e.canonical).chain(&e.aliases).map(|t| key_id(t)).collect();
    keys.insert(BOOST.into());
    let existing: Vec<String> = db.conn.prepare("SELECT key_id FROM dictionary_key_usage WHERE entry_id = ?")?.query_map([&e.id], |r| r.get(0))?.collect::<Result<_, _>>()?;
    for k in existing.iter().filter(|k| !keys.contains(*k)) {
        db.conn.execute("DELETE FROM dictionary_key_usage WHERE entry_id = ? AND key_id = ?", params![e.id, k])?;
    }
    for k in &keys {
        db.conn.execute(
            "INSERT INTO dictionary_key_usage (entry_id, key_id, state) VALUES (?, ?, ?) ON CONFLICT(entry_id, key_id) DO UPDATE SET state = excluded.state, reverted = CASE WHEN state = 'retired' THEN 0 ELSE reverted END, retired_at = NULL, retired_from = NULL, notice_shown = 0",
            params![e.id, k, state],
        )?;
    }
    bump_usage(db)
}

fn bump_usage(db: &Db) -> rusqlite::Result<()> {
    db.conn.execute("UPDATE dictionary_usage_state SET revision = revision + 1 WHERE id = 1", []).map(|_| ())
}

pub fn set_enabled(db: &Db, id: &str, enabled: bool, expected: Option<i64>) -> Result<State, VocabError> {
    mutate(
        db,
        expected,
        |entries, _| {
            if !entries.iter().any(|e| e.id == id) {
                return Err(edit(Field::Entry, Code::MissingEntry));
            }
            Ok(entries.iter().map(|e| if e.id == id { Entry { enabled, ..e.clone() } } else { e.clone() }).collect())
        },
        |db| db.conn.execute("UPDATE vocabulary_entries SET enabled=? WHERE id=?", params![enabled, id]).map(|_| ()),
    )
}

pub fn delete(db: &Db, id: &str, expected: Option<i64>) -> Result<State, VocabError> {
    mutate(
        db,
        expected,
        |entries, _| {
            if !entries.iter().any(|e| e.id == id) {
                return Err(edit(Field::Entry, Code::MissingEntry));
            }
            Ok(entries.iter().filter(|e| e.id != id).cloned().collect())
        },
        |db| {
            db.conn.execute("DELETE FROM vocabulary_entries WHERE id=?", [id])?;
            db.conn.execute("DELETE FROM dictionary_usage_events WHERE entry_id = ?", [id])?;
            bump_usage(db)
        },
    )
}

/// `DictionaryChange.keyID`: first 32 hex characters of SHA-256 over the folded term.
pub fn key_id(term: &str) -> String {
    sha256_hex(fold(term).as_bytes())[..32].to_string()
}

/// `DictionaryUsagePolicy.state(after:kept:reverted:)`.
pub fn next_key_state<'a>(current: &'a str, kept: i64, reverted: i64) -> &'a str {
    match current {
        "retired" => "retired",
        "provisional" if reverted >= 1 => "retired",
        "provisional" if kept >= 3 => "established",
        "provisional" => "provisional",
        _ if reverted >= 2 && reverted as f64 / (kept + reverted) as f64 > 0.30 => "retired",
        _ => "established",
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyUsage {
    pub entry_id: String,
    pub key_id: String,
    pub state: String,
    pub applied: i64,
    pub kept: i64,
    pub reverted: i64,
    pub last_used_at: Option<i64>,
}

pub fn usage(db: &Db) -> rusqlite::Result<HashMap<String, Vec<KeyUsage>>> {
    let mut stmt = db.conn.prepare("SELECT entry_id, key_id, state, applied, kept, reverted, last_used_at FROM dictionary_key_usage")?;
    let rows = stmt.query_map([], |r| Ok(KeyUsage { entry_id: r.get(0)?, key_id: r.get(1)?, state: r.get(2)?, applied: r.get(3)?, kept: r.get(4)?, reverted: r.get(5)?, last_used_at: r.get(6)? }))?;
    let mut out: HashMap<String, Vec<KeyUsage>> = HashMap::new();
    for row in rows {
        let u = row?;
        out.entry(u.entry_id.clone()).or_default().push(u);
    }
    Ok(out)
}

pub fn restore_key(db: &Db, entry_id: &str, key: &str) -> rusqlite::Result<()> {
    let tx = db.conn.unchecked_transaction()?;
    let n = db.conn.execute("UPDATE dictionary_key_usage SET state = 'established', reverted = 0, retired_at = NULL, retired_from = NULL, notice_shown = 0 WHERE entry_id = ? AND key_id = ? AND state = 'retired'", params![entry_id, key])?;
    if n > 0 {
        bump_usage(db)?;
    }
    tx.commit()
}

/// `usageText`. `now_year`-relative date; months are English in the current scheme.
pub fn usage_text(db: &Db, applied: i64, kept: i64, reverted: i64, last_used: Option<i64>) -> String {
    if applied <= 0 {
        return "Unused".into();
    }
    let mut parts = vec![format!("Used {applied}")];
    if kept + reverted == 0 {
        parts.push("not checked yet".into());
    } else {
        parts.push(format!("kept {kept}"));
        if reverted > 0 {
            parts.push(format!("undone {reverted}"));
        }
    }
    if let Some(l) = last_used {
        parts.push(short_day(db, l));
    }
    parts.join(" · ")
}

// ---- Suggestions ----

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    Correction,
    Context,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Suggestion {
    pub canonical: String,
    pub alias: String,
    pub sightings: i64,
    pub source: Source,
}

#[derive(Default)]
pub struct SuggestionContents {
    pub corrections: Vec<(String, String, i64)>,
    pub dismissed: HashSet<(String, String)>,
    pub context_terms: Vec<Vec<String>>,
}

pub fn suggestion_contents(db: &Db) -> rusqlite::Result<SuggestionContents> {
    let mut c = SuggestionContents::default();
    let mut stmt = db.conn.prepare("SELECT canonical, alias, sightings, dismissed FROM term_suggestions")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?, r.get::<_, bool>(3)?)))?;
    for row in rows {
        let (canonical, alias, sightings, dismissed) = row?;
        if dismissed {
            c.dismissed.insert((canonical, alias));
        } else {
            c.corrections.push((canonical, alias, sightings));
        }
    }
    let mut stmt = db.conn.prepare("SELECT c.snapshot_json FROM dictation_contexts c JOIN transcriptions t ON t.id = c.transcription_id WHERE c.snapshot_json IS NOT NULL ORDER BY t.created_at DESC LIMIT 1000")?;
    let snapshots = stmt.query_map([], |r| r.get::<_, String>(0))?;
    for json in snapshots {
        // A damaged snapshot only loses its sightings.
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&json?) else { continue };
        let Some(terms) = v.get("terms").and_then(|t| t.as_array()) else { continue };
        let mut seen = HashSet::new();
        let list = terms.iter().filter_map(|t| t.get("text").and_then(|x| x.as_str())).filter(|t| seen.insert(t.to_string())).map(String::from).collect();
        c.context_terms.push(list);
    }
    Ok(c)
}

/// A name or code term rather than a word.
pub fn is_term_shaped(t: &str) -> bool {
    if !t.chars().any(char::is_alphabetic) || !t.chars().any(|c| c.is_uppercase() || c.is_numeric()) || t.chars().any(|c| "./\\:@~_#".contains(c)) {
        return false;
    }
    let compact: Vec<char> = t.chars().filter(|c| *c != '-').collect();
    !(compact.iter().all(char::is_ascii_hexdigit) && compact.iter().any(|c| c.is_numeric()))
}

pub fn mine_suggestions(c: &SuggestionContents, dictionary: &[Entry], is_english: impl Fn(&str) -> bool) -> Vec<Suggestion> {
    let governed: HashSet<String> = dictionary.iter().flat_map(|e| std::iter::once(&e.canonical).chain(&e.aliases)).map(|t| fold(t)).collect();
    let savable = |t: &str| term_code(t).is_none() && formatted(t) == t;
    let open = |canonical: &str, alias: &str| {
        !c.dismissed.contains(&(canonical.to_string(), alias.to_string())) && !governed.contains(&fold(canonical)) && (alias.is_empty() || !governed.contains(&fold(alias))) && savable(canonical)
    };
    let mut corrections: Vec<Suggestion> =
        c.corrections.iter().filter(|(a, b, _)| open(a, b)).map(|(a, b, n)| Suggestion { canonical: a.clone(), alias: b.clone(), sightings: *n, source: Source::Correction }).collect();
    corrections.sort_by(|a, b| b.sightings.cmp(&a.sightings).then_with(|| a.canonical.cmp(&b.canonical)));
    let mut counts: HashMap<&str, i64> = HashMap::new();
    for terms in &c.context_terms {
        let distinct: HashSet<&str> = terms.iter().map(String::as_str).collect();
        for t in distinct {
            *counts.entry(t).or_default() += 1;
        }
    }
    let mut context: Vec<Suggestion> = counts
        .into_iter()
        .filter(|(t, n)| *n >= 3 && is_term_shaped(t) && open(t, "") && !t.split(' ').all(&is_english))
        .map(|(t, n)| Suggestion { canonical: t.to_string(), alias: String::new(), sightings: n, source: Source::Context })
        .collect();
    context.sort_by(|a, b| b.sightings.cmp(&a.sightings).then_with(|| a.canonical.cmp(&b.canonical)));
    corrections.into_iter().chain(context).take(12).collect()
}

fn prune_suggestions(db: &Db) -> rusqlite::Result<()> {
    db.conn.execute("DELETE FROM term_suggestions WHERE (canonical, alias) IN (SELECT canonical, alias FROM term_suggestions ORDER BY last_seen DESC LIMIT -1 OFFSET 500)", []).map(|_| ())
}

pub fn dismiss_suggestion(db: &Db, canonical: &str, alias: &str, now: i64) -> rusqlite::Result<()> {
    if term_code(canonical).is_some() || (!alias.is_empty() && term_code(alias).is_some()) {
        return Ok(());
    }
    db.conn.execute("INSERT INTO term_suggestions (canonical, alias, sightings, dismissed, last_seen) VALUES (?, ?, 0, 1, ?) ON CONFLICT(canonical, alias) DO UPDATE SET dismissed=1, last_seen=excluded.last_seen", params![canonical, alias, now])?;
    prune_suggestions(db)
}

pub fn record_correction(db: &Db, canonical: &str, alias: &str, now: i64) -> rusqlite::Result<()> {
    if term_code(canonical).is_some() || (!alias.is_empty() && term_code(alias).is_some()) {
        return Ok(());
    }
    db.conn.execute("INSERT INTO term_suggestions (canonical, alias, sightings, dismissed, last_seen) VALUES (?, ?, 1, 0, ?) ON CONFLICT(canonical, alias) DO UPDATE SET sightings=sightings+1, last_seen=excluded.last_seen", params![canonical, alias, now])?;
    prune_suggestions(db)
}

// ---- View model ----

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Filter {
    All,
    Enabled,
    Disabled,
    Learned,
}

impl Filter {
    pub const ALL: [Filter; 4] = [Filter::All, Filter::Enabled, Filter::Disabled, Filter::Learned];
    pub fn name(self) -> &'static str {
        match self {
            Filter::All => "All",
            Filter::Enabled => "Enabled",
            Filter::Disabled => "Disabled",
            Filter::Learned => "Learned",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Draft {
    pub id: Option<String>,
    pub canonical: String,
    pub aliases: Vec<String>,
    pub enabled: bool,
    pub learned_at: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RetiredTerm {
    pub key_id: String,
    pub term: String,
}
impl RetiredTerm {
    pub fn is_boost(&self) -> bool {
        self.key_id == BOOST
    }
}

/// `VocabularyViewModel`. // ponytail: writes run synchronously on one bounded local transaction,
/// so `saving` is only true for a scenario; move to a background executor if a write ever shows.
#[derive(Default)]
pub struct Model {
    pub entries: Vec<Entry>,
    pub revision: i64,
    pub loaded: bool,
    pub load_error: Option<String>,
    pub draft: Option<Draft>,
    pub field_errors: HashMap<Field, String>,
    pub saving: bool,
    pub status: Option<String>,
    pub suggestions: Vec<Suggestion>,
    pub usage: HashMap<String, Vec<KeyUsage>>,
}

fn blank(s: &str) -> bool {
    s.trim_matches(|c: char| c == ' ' || (c.is_whitespace() && c != '\n' && c != '\r' && c != '\u{85}' && c != '\u{2028}' && c != '\u{2029}' && !('\u{B}'..='\u{C}').contains(&c))).is_empty()
}

impl Model {
    pub fn can_add(&self) -> bool {
        self.loaded && self.load_error.is_none() && self.entries.len() < MAX_ENTRIES
    }
    pub fn can_save(&self) -> bool {
        self.draft.is_some() && !self.saving && self.load_error.is_none()
    }
    pub fn can_add_alias(&self) -> bool {
        self.draft.as_ref().map_or(0, |d| d.aliases.len()) < MAX_ALIASES
    }
    pub fn is_full(&self) -> bool {
        self.entries.len() >= MAX_ENTRIES
    }
    pub fn duplicate_alias_indices(&self) -> Vec<usize> {
        let Some(d) = &self.draft else { return vec![] };
        let mut seen = HashSet::from([fold(&d.canonical)]);
        d.aliases.iter().enumerate().filter(|(_, a)| !blank(a) && !seen.insert(fold(a))).map(|(i, _)| i).collect()
    }

    pub fn refresh(&mut self, db: &Db, is_english: impl Fn(&str) -> bool) {
        match load(db) {
            Ok(c) => {
                let mut keyed: Vec<(String, Entry)> = c.entries.into_iter().map(|e| (fold(&e.canonical), e)).collect();
                // Rust's `str` order is scalar order, as Swift's `{ $0.value < $1.value }`.
                keyed.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.id.cmp(&b.1.id)));
                self.entries = keyed.into_iter().map(|k| k.1).collect();
                self.revision = c.state.revision;
                self.load_error = None;
            }
            Err(e) => self.load_error = Some(describe(&e)),
        }
        self.loaded = true;
        // Usage and suggestions are advisory: a read failure hides them.
        self.usage = usage(db).unwrap_or_default();
        self.suggestions = match (&self.load_error, suggestion_contents(db)) {
            (None, Ok(c)) => mine_suggestions(&c, &self.entries, is_english),
            _ => vec![],
        };
    }

    pub fn usage_summary(&self, db: &Db, e: &Entry) -> String {
        let rows = self.usage.get(&e.id).map(Vec::as_slice).unwrap_or(&[]);
        usage_text(db, rows.iter().map(|r| r.applied).sum(), rows.iter().map(|r| r.kept).sum(), rows.iter().map(|r| r.reverted).sum(), rows.iter().filter_map(|r| r.last_used_at).max())
    }
    pub fn is_provisional(&self, e: &Entry) -> bool {
        let rows: Vec<&KeyUsage> = self.usage.get(&e.id).map(|v| v.iter().filter(|r| r.key_id != BOOST).collect()).unwrap_or_default();
        if rows.is_empty() { e.learned_at.is_some() } else { rows.iter().any(|r| r.state == "provisional") }
    }
    pub fn retired_terms(&self, e: &Entry) -> Vec<RetiredTerm> {
        let retired: HashSet<&str> = self.usage.get(&e.id).map(|v| v.iter().filter(|r| r.state == "retired").map(|r| r.key_id.as_str()).collect()).unwrap_or_default();
        if retired.is_empty() {
            return vec![];
        }
        let mut terms: Vec<RetiredTerm> = std::iter::once(&e.canonical)
            .chain(&e.aliases)
            .filter_map(|t| {
                let k = key_id(t);
                retired.contains(k.as_str()).then(|| RetiredTerm { key_id: k, term: t.clone() })
            })
            .collect();
        if retired.contains(BOOST) {
            terms.push(RetiredTerm { key_id: BOOST.into(), term: e.canonical.clone() });
        }
        terms
    }
    pub fn restore(&mut self, db: &Db, e: &Entry, term: &RetiredTerm, is_english: impl Fn(&str) -> bool) {
        // Single writer: a write is ignored while one runs.
        if self.saving {
            return;
        }
        if restore_key(db, &e.id, &term.key_id).is_err() {
            self.status = Some(format!("Could not restore {}. Try again.", term.term));
            return;
        }
        self.status = Some(if term.is_boost() { format!("Listening for {} again.", e.canonical) } else { format!("Restored {}.", term.term) });
        self.refresh(db, is_english);
    }

    pub fn begin_add(&mut self) {
        if self.can_add() && !self.saving {
            self.draft = Some(Draft { id: None, canonical: String::new(), aliases: vec![String::new()], enabled: true, learned_at: None });
            self.field_errors.clear();
            self.status = None;
        }
    }
    pub fn begin_add_suggestion(&mut self, s: &Suggestion) {
        if self.can_add() && !self.saving {
            self.draft = Some(Draft { id: None, canonical: s.canonical.clone(), aliases: if s.alias.is_empty() { vec![] } else { vec![s.alias.clone()] }, enabled: true, learned_at: None });
            self.field_errors.clear();
            self.status = None;
        }
    }
    pub fn begin_edit(&mut self, e: &Entry) {
        if !self.saving {
            self.draft = Some(Draft { id: Some(e.id.clone()), canonical: e.canonical.clone(), aliases: e.aliases.clone(), enabled: e.enabled, learned_at: e.learned_at });
            self.field_errors.clear();
            self.status = None;
        }
    }
    pub fn dismiss(&mut self, db: &Db, s: &Suggestion) {
        self.suggestions.retain(|o| o != s);
        // Write errors are ignored, as in Swift.
        let _ = dismiss_suggestion(db, &s.canonical, &s.alias, now_ms());
    }
    pub fn cancel_draft(&mut self) {
        if !self.saving {
            self.draft = None;
            self.field_errors.clear();
        }
    }
    pub fn set_canonical(&mut self, v: String) {
        if let Some(d) = &mut self.draft {
            d.canonical = v;
            self.field_errors.remove(&Field::Canonical);
        }
    }
    pub fn set_alias(&mut self, v: String, i: usize) {
        if let Some(d) = &mut self.draft
            && i < d.aliases.len()
        {
            d.aliases[i] = v;
            self.field_errors.remove(&Field::Alias(i));
            self.field_errors.remove(&Field::Aliases);
        }
    }
    pub fn add_alias(&mut self) {
        if self.can_add_alias()
            && let Some(d) = &mut self.draft
        {
            d.aliases.push(String::new());
            self.field_errors.remove(&Field::Aliases);
        }
    }
    pub fn remove_alias(&mut self, i: usize) {
        if let Some(d) = &mut self.draft
            && i < d.aliases.len()
        {
            d.aliases.remove(i);
            self.field_errors.retain(|k, _| !matches!(k, Field::Alias(_)));
        }
    }
    pub fn is_correcting(&self) -> bool {
        self.draft.as_ref().is_some_and(|d| !d.aliases.is_empty())
    }
    pub fn set_correcting(&mut self, on: bool) {
        let Some(d) = &mut self.draft else { return };
        if on {
            if d.aliases.is_empty() {
                d.aliases = vec![String::new()];
            }
        } else {
            d.aliases.clear();
            self.field_errors.retain(|k, _| !matches!(k, Field::Alias(_) | Field::Aliases));
        }
    }
    pub fn draft_is_filled(&self) -> bool {
        self.draft.as_ref().is_some_and(|d| !blank(&d.canonical) && !d.aliases.iter().any(|a| blank(a)))
    }
    pub fn visible(&self, filter: Filter, search: &str) -> Vec<Entry> {
        let query = fold(search.trim_matches(|c: char| c == ' ' || c == '\t' || (c.is_whitespace() && !c.is_control() && c != '\u{2028}' && c != '\u{2029}')));
        self.entries
            .iter()
            .filter(|e| match filter {
                Filter::All => true,
                Filter::Enabled => e.enabled,
                Filter::Disabled => !e.enabled,
                Filter::Learned => e.learned_at.is_some(),
            })
            .filter(|e| query.is_empty() || std::iter::once(&e.canonical).chain(&e.aliases).any(|t| fold(t).contains(&query)))
            .cloned()
            .collect()
    }
    pub fn deduplicate(&mut self) {
        let dup = self.duplicate_alias_indices();
        if dup.is_empty() {
            return;
        }
        if let Some(d) = &mut self.draft {
            let mut i = 0;
            d.aliases.retain(|_| {
                i += 1;
                !dup.contains(&(i - 1))
            });
        }
        self.field_errors.clear();
        self.status = Some(format!("Removed {} duplicate alias{}.", dup.len(), if dup.len() == 1 { "" } else { "es" }));
    }

    pub fn save_draft(&mut self, db: &Db, is_english: impl Fn(&str) -> bool) {
        if !self.can_save() {
            return;
        }
        let Some(d) = self.draft.clone() else { return };
        if let Some(i) = self.duplicate_alias_indices().first() {
            self.field_errors.insert(Field::Alias(*i), Code::DuplicateAlias.message().into());
            return;
        }
        let id = d.id.clone().unwrap_or_else(|| new_uuid(db));
        let entry = Entry { id, canonical: d.canonical, aliases: d.aliases, enabled: d.enabled, learned_at: d.learned_at };
        let revision = self.revision;
        let msg = if d.id.is_none() { "Entry added." } else { "Entry saved." };
        let r = save(db, &entry, Some(revision), "established");
        self.finish(db, r, msg, |m| m.draft = None, is_english);
    }
    pub fn set_enabled(&mut self, db: &Db, e: &Entry, on: bool, is_english: impl Fn(&str) -> bool) {
        if self.saving {
            return;
        }
        let r = set_enabled(db, &e.id, on, Some(self.revision));
        self.finish(db, r, if on { "Entry enabled." } else { "Entry disabled." }, |_| {}, is_english);
    }
    pub fn delete(&mut self, db: &Db, e: &Entry, is_english: impl Fn(&str) -> bool) {
        if self.saving {
            return;
        }
        let r = delete(db, &e.id, Some(self.revision));
        let id = e.id.clone();
        self.finish(
            db,
            r,
            "Entry deleted.",
            move |m| {
                if m.draft.as_ref().is_some_and(|d| d.id.as_deref() == Some(id.as_str())) {
                    m.draft = None;
                }
            },
            is_english,
        );
    }
    fn finish(&mut self, db: &Db, r: Result<State, VocabError>, ok: &str, on_ok: impl FnOnce(&mut Self), is_english: impl Fn(&str) -> bool) {
        self.field_errors.clear();
        self.status = None;
        match r {
            Ok(_) => {
                on_ok(self);
                self.status = Some(ok.into());
            }
            Err(VocabError::Edit(e)) => {
                let mut msg = e.code.message().to_string();
                if let Some(other) = e.conflicting.as_ref().and_then(|id| self.entries.iter().find(|x| &x.id == id)) {
                    msg += &format!(" Conflicts with “{}”.", other.canonical);
                }
                self.field_errors.insert(e.field, msg);
                if matches!(e.code, Code::StaleRevision | Code::MissingEntry) {
                    self.status = Some(e.code.message().into());
                }
            }
            Err(e) => self.status = Some(format!("Could not save. {}", describe(&e))),
        }
        self.refresh(db, is_english);
    }
}

/// Synthetic rows for tests, the audit and the Swift reference app.
pub fn seed(db: &Db) {
    let now = now_ms();
    let day = 86_400_000;
    let mk = |id: &str, c: &str, a: &[&str], on: bool, l: Option<i64>| Entry { id: id.into(), canonical: c.into(), aliases: a.iter().map(|s| s.to_string()).collect(), enabled: on, learned_at: l };
    let rows = [
        mk("7A8B0001-0000-4000-8000-000000000001", "Acme Robotics", &["acme robotic", "akme robotics"], true, None),
        mk("7A8B0001-0000-4000-8000-000000000002", "Brunel", &[], true, None),
        mk("7A8B0001-0000-4000-8000-000000000003", "Kubernetes", &["cube nets"], true, Some(now - 3 * day)),
        mk("7A8B0001-0000-4000-8000-000000000004", "Northwind", &[], false, None),
        mk("7A8B0001-0000-4000-8000-000000000005", "Qwen", &["quen", "kwen"], true, Some(now - 40 * day)),
        mk("7A8B0001-0000-4000-8000-000000000006", "Tallinn", &["talin"], true, None),
        mk("7A8B0001-0000-4000-8000-000000000007", "Zürich", &[], true, None),
    ];
    for e in &rows {
        let state = if e.learned_at.is_some() { "provisional" } else { "established" };
        save(db, e, None, state).expect("seed entry");
    }
    let id = |n: usize| rows[n].id.as_str();
    let set = |e: &str, k: &str, st: &str, a: i64, kept: i64, r: i64, last: Option<i64>| {
        let retired = st == "retired";
        db.conn
            .execute(
                "UPDATE dictionary_key_usage SET state=?, applied=?, kept=?, reverted=?, last_used_at=?, retired_at=?, retired_from=? WHERE entry_id=? AND key_id=?",
                params![st, a, kept, r, last, retired.then_some(now - day), retired.then_some("established"), e, k],
            )
            .expect("seed usage");
    };
    set(id(0), &key_id("acme robotic"), "established", 14, 12, 0, Some(now - 2 * day));
    set(id(0), &key_id("akme robotics"), "retired", 3, 0, 3, Some(now - 9 * day));
    set(id(2), &key_id("cube nets"), "provisional", 2, 0, 0, Some(now - day));
    set(id(4), &key_id("quen"), "established", 6, 5, 1, Some(now - 400 * day));
    set(id(5), BOOST, "retired", 4, 1, 3, Some(now - 5 * day));
    set(id(6), &key_id("Zürich"), "retired", 2, 0, 2, Some(now - 6 * day));
    record_correction(db, "Figtree", "fig tree", now).expect("seed");
    record_correction(db, "Figtree", "fig tree", now).expect("seed");
    record_correction(db, "Garamond", "", now).expect("seed");
    record_correction(db, "Hidden", "hiden", now).expect("seed");
    dismiss_suggestion(db, "Hidden", "hiden", now).expect("seed");
    db.conn.execute("INSERT OR IGNORE INTO dictionary_usage_state (id, revision) VALUES (1, 1)", []).expect("seed");
}

#[cfg(test)]
mod tests {
    // parity: DICT-036
    /// Every branch of `DictationErrorMessage.describe`, through the same call the page's load error makes.
    #[test]
    fn describe_has_a_copy_for_each_kind_of_failure() {
        let edit = |code| VocabError::Edit(super::edit(Field::Entry, code));
        assert_eq!(describe(&edit(Code::Damaged)), "Preferred spellings could not be loaded. Repair or delete entries in Settings.");
        assert_eq!(describe(&edit(Code::StaleRevision)), Code::StaleRevision.message());
        assert!(!Code::StaleRevision.message().starts_with("Preferred spelling rejected"));
        assert_eq!(describe(&edit(Code::Empty)), format!("Preferred spelling rejected: {}", Code::Empty.message()));
        let sql = rusqlite::Connection::open_in_memory().unwrap().execute("nonsense", []).unwrap_err();
        assert_eq!(describe(&VocabError::Sql(sql)), "Error type DatabaseError, code 1.");
    }

    use super::*;

    fn entry(c: &str, a: &[&str]) -> Entry {
        Entry { id: format!("id-{c}"), canonical: c.into(), aliases: a.iter().map(|s| s.to_string()).collect(), enabled: true, learned_at: None }
    }
    fn empty() -> Db {
        Db::memory()
    }

    // parity: DICT-039 DICT-149
    #[test]
    fn hash_serialization_matches_swift_bytes() {
        // Seeded row in the Swift migration: the hash of the empty set.
        let db = empty();
        let c = load(&db).unwrap();
        assert_eq!(c.state.revision, 0);
        assert_eq!(c.state.payload_bytes, 0);
        assert_eq!(c.state.content_hash, sha256_hex(b"localflow-vocabulary-v1:[]"));
        let e = Entry { id: "b".into(), canonical: "Q\"u\\o\u{1}".into(), aliases: vec!["x".into()], enabled: false, learned_at: Some(5) };
        let f = Entry { id: "a".into(), canonical: "A".into(), aliases: vec![], enabled: true, learned_at: None };
        let s = String::from_utf8(serialize(&[e, f])).unwrap();
        assert_eq!(s, "localflow-vocabulary-v1:[{\"aliases\":[],\"canonical\":\"A\",\"enabled\":true,\"id\":\"a\"},{\"aliases\":[\"x\"],\"canonical\":\"Q\\\"u\\\\o\\u0001\",\"enabled\":false,\"id\":\"b\",\"learned_at\":5}]");
    }

    // parity: DICT-025 DICT-067 DICT-129..DICT-136
    #[test]
    fn folding_key_ids_and_term_validation() {
        assert_eq!(fold("ZÜRICH"), "zürich");
        assert_eq!(fold("Zu\u{308}rich"), "zürich");
        assert_ne!(fold("Maß"), fold("MASS"));
        assert_eq!(key_id("Zürich").len(), 32);
        assert_eq!(key_id("zÜrich"), key_id("Zürich"));
        // sha256("abc") prefix.
        assert_eq!(key_id("abc"), "ba7816bf8f01cfea414140de5dae2223");
        assert_eq!(term_code(""), Some(Code::Empty));
        assert_eq!(term_code("a\nb"), Some(Code::Multiline));
        assert_eq!(term_code("a\u{200B}b"), Some(Code::Control));
        assert_eq!(term_code(" a"), Some(Code::EdgeWhitespace));
        assert_eq!(term_code("a  b"), Some(Code::Spacing));
        assert_eq!(term_code("a\u{A0}b"), Some(Code::Spacing));
        assert_eq!(term_code(&"é".repeat(129)), Some(Code::TooManyBytes));
        assert_eq!(term_code(&"a".repeat(65)), Some(Code::TooManyScalars));
        assert_eq!(term_code("Zu\u{308}rich"), Some(Code::NotCanonicalForm));
        assert_eq!(term_code("Zürich"), None);
        for (code, msg) in [
            (Code::Empty, "Enter a term."),
            (Code::Multiline, "Use one line."),
            (Code::Control, "Remove control characters."),
            (Code::EdgeWhitespace, "Remove leading or trailing spaces."),
            (Code::Spacing, "Separate words with single spaces."),
            (Code::TooManyBytes, "At most 256 bytes."),
            (Code::TooManyScalars, "At most 64 characters."),
            (Code::NotCanonicalForm, "Use composed Unicode characters."),
        ] {
            assert_eq!(code.message(), msg);
        }
    }

    // parity: DICT-137 DICT-138 DICT-139 DICT-140 DICT-141 DICT-142 DICT-143 DICT-144 DICT-145 DICT-146 DICT-147
    #[test]
    fn entry_validation_rejects_with_swift_field_and_copy() {
        let db = empty();
        save(&db, &entry("Alpha", &["alfa"]), None, "established").unwrap();
        let code = |e: &Entry| match save(&db, e, None, "established") {
            Err(VocabError::Edit(x)) => (x.field, x.code),
            o => panic!("{:?}", o.map(|s| s.revision)),
        };
        assert_eq!(code(&entry("Foo , bar", &[])), (Field::Canonical, Code::UnstableFormatting));
        assert_eq!(Code::UnstableFormatting.message(), "Canonical spelling must already be formatted.");
        let many: Vec<&str> = vec!["a", "b", "c", "d", "e", "f", "g", "h", "i"];
        assert_eq!(code(&entry("Beta", &many)), (Field::Aliases, Code::TooManyAliases));
        assert_eq!(code(&entry("Beta", &["BETA"])), (Field::Alias(0), Code::DuplicateAlias));
        assert_eq!(code(&entry("Beta", &["alfa"])), (Field::Alias(0), Code::ConflictingSource));
        assert_eq!(code(&entry("Beta", &["alpha"])), (Field::Alias(0), Code::TargetChain));
        assert_eq!(code(&entry("ALFA", &[])), (Field::Canonical, Code::ConflictingSource));
        let mut bad = entry("Beta", &[]);
        bad.id = String::new();
        assert_eq!(code(&bad), (Field::Entry, Code::InvalidId));
        assert_eq!(Code::InvalidId.message(), "Entry identity is invalid.");
        match set_enabled(&db, "nope", true, None) {
            Err(VocabError::Edit(x)) => assert_eq!((x.field, x.code.message()), (Field::Entry, "This entry no longer exists.")),
            _ => panic!(),
        }
        // Entry and key limits are checked against the table, not only the count.
        let mut t = KeyTable::default();
        for i in 0..MAX_KEYS {
            t.owners.insert(format!("k{i}"), ("x".into(), false));
        }
        assert_eq!(t.register(&entry("New", &[])).unwrap_err().code, Code::TooManyKeys);
        assert_eq!(Code::TooManyKeys.message(), "At most 4608 terms in total.");
        assert_eq!(Code::TooManyEntries.message(), "At most 512 entries.");
        assert_eq!(Code::PayloadCapacity.message(), "Vocabulary storage is full.");
        // A hand-edited row no longer matches the hash: damaged.
        db.conn.execute("UPDATE vocabulary_entries SET canonical_text='Omega'", []).unwrap();
        let err = load(&db).err().unwrap();
        assert_eq!(describe(&err), "Preferred spellings could not be loaded. Repair or delete entries in Settings.");
        assert_eq!(Code::Damaged.message(), "Stored vocabulary is invalid and cannot be used.");
    }

    // parity: DICT-037 DICT-038 DICT-123 DICT-124 DICT-125 DICT-126 DICT-148 DICT-151 DICT-152 DICT-154
    #[test]
    fn write_transaction_revisions_usage_and_staleness() {
        let db = empty();
        let e = entry("Alpha", &["alfa"]);
        let s1 = save(&db, &e, Some(0), "established").unwrap();
        assert_eq!(s1.revision, 1);
        let keys: i64 = db.conn.query_row("SELECT count(*) FROM dictionary_key_usage WHERE entry_id=? AND state='established'", [&e.id], |r| r.get(0)).unwrap();
        assert_eq!(keys, 3); // canonical, alias and boost.
        // Identical content: same state, no write, so a retired key stays retired (DICT-154).
        db.conn.execute("UPDATE dictionary_key_usage SET state='retired', retired_at=1, reverted=2 WHERE key_id='boost'", []).unwrap();
        assert_eq!(save(&db, &e, Some(1), "established").unwrap().revision, 1);
        let st: String = db.conn.query_row("SELECT state FROM dictionary_key_usage WHERE key_id='boost'", [], |r| r.get(0)).unwrap();
        assert_eq!(st, "retired");
        // Changed content re-trusts, resets reverted and drops removed keys.
        let e2 = entry("Alpha", &["alpha one"]);
        assert_eq!(save(&db, &e2, Some(1), "established").unwrap().revision, 2);
        let (st, rev): (String, i64) = db.conn.query_row("SELECT state, reverted FROM dictionary_key_usage WHERE key_id='boost'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!((st.as_str(), rev), ("established", 0));
        let old: i64 = db.conn.query_row("SELECT count(*) FROM dictionary_key_usage WHERE key_id=?", [key_id("alfa")], |r| r.get(0)).unwrap();
        assert_eq!(old, 0);
        // Stale revision is refused.
        let stale = save(&db, &entry("Beta", &[]), Some(0), "established").err().unwrap();
        assert!(matches!(stale, VocabError::Edit(EditError { code: Code::StaleRevision, field: Field::Store, .. })));
        assert_eq!(load(&db).unwrap().state.revision, 2);
        // Delete cascades usage and removes events.
        db.conn.execute("INSERT INTO dictionary_usage_events (dictation_id, entry_id, key_id, outcome, at) VALUES ('d', ?, 'boost', 'kept', 1)", [&e.id]).unwrap();
        delete(&db, &e.id, Some(2)).unwrap();
        for table in ["dictionary_key_usage", "dictionary_usage_events", "vocabulary_entries"] {
            let n: i64 = db.conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0)).unwrap();
            assert_eq!(n, 0, "{table}");
        }
    }

    // parity: DICT-050 DICT-051 DICT-052 DICT-053 DICT-054 DICT-055 DICT-056 DICT-150
    #[test]
    fn suggestions_are_mined_like_swift() {
        assert!(is_term_shaped("LocalFlow"));
        assert!(is_term_shaped("gpt4o"));
        assert!(!is_term_shaped("word"));
        assert!(!is_term_shaped("Foo.bar"));
        assert!(!is_term_shaped("a1b2c3"));
        assert!(!is_term_shaped("123e4567-e89b-12d3-a456-426614174000"));
        let db = empty();
        save(&db, &entry("Alpha", &["alfa"]), None, "established").unwrap();
        let contents = SuggestionContents {
            corrections: vec![("Beta".into(), "".into(), 1), ("Gamma".into(), "gama".into(), 5), ("Alpha".into(), "".into(), 9), ("Zed".into(), "ALFA".into(), 9), ("Off".into(), "".into(), 9), ("Aaa".into(), "".into(), 1)],
            dismissed: HashSet::from([("Off".to_string(), "".to_string())]),
            context_terms: vec![vec!["LocalFlow".into(), "Two".into(), "English Word".into()]; 3].into_iter().chain([vec!["Twice".into()], vec!["Twice".into()]]).collect(),
        };
        let entries = load(&db).unwrap().entries;
        let got = mine_suggestions(&contents, &entries, |w| ["Two", "English", "Word"].contains(&w));
        let names: Vec<&str> = got.iter().map(|s| s.canonical.as_str()).collect();
        assert_eq!(names, ["Gamma", "Aaa", "Beta", "LocalFlow"]);
        assert_eq!(got[3].sightings, 3);
        assert_eq!(got[3].source, Source::Context);
        let many = SuggestionContents { corrections: (0..20).map(|i| (format!("Term{i:02}"), String::new(), 1)).collect(), ..Default::default() };
        assert_eq!(mine_suggestions(&many, &[], |_| false).len(), 12);
        // Store: upsert counts; dismiss wins; prune keeps 500 newest.
        record_correction(&db, "Gamma", "gama", 1).unwrap();
        record_correction(&db, "Gamma", "gama", 2).unwrap();
        record_correction(&db, "bad  term", "", 2).unwrap();
        let c = suggestion_contents(&db).unwrap();
        assert_eq!(c.corrections, vec![("Gamma".to_string(), "gama".to_string(), 2)]);
        dismiss_suggestion(&db, "Gamma", "gama", 3).unwrap();
        assert!(suggestion_contents(&db).unwrap().dismissed.contains(&("Gamma".to_string(), "gama".to_string())));
        for i in 0..510 {
            record_correction(&db, &format!("T{i}"), "", 100 + i).unwrap();
        }
        let n: i64 = db.conn.query_row("SELECT count(*) FROM term_suggestions", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 500);
    }

    // parity: DICT-073 DICT-075 DICT-076
    #[test]
    fn usage_formula_and_trust_policy() {
        let db = empty();
        assert_eq!(usage_text(&db, 0, 3, 3, Some(1)), "Unused");
        assert_eq!(usage_text(&db, 2, 0, 0, None), "Used 2 · not checked yet");
        assert_eq!(usage_text(&db, 5, 3, 0, None), "Used 5 · kept 3");
        assert_eq!(usage_text(&db, 5, 3, 2, None), "Used 5 · kept 3 · undone 2");
        assert_eq!(next_key_state("retired", 9, 0), "retired");
        assert_eq!(next_key_state("provisional", 0, 1), "retired");
        assert_eq!(next_key_state("provisional", 3, 0), "established");
        assert_eq!(next_key_state("provisional", 2, 0), "provisional");
        assert_eq!(next_key_state("established", 1, 1), "established");
        assert_eq!(next_key_state("established", 4, 2), "retired");
        assert_eq!(next_key_state("established", 5, 2), "established");
        assert!(usage(&db).unwrap().is_empty());
    }

    // parity: DICT-038
    /// One damaged store per condition the Swift check names; each loads as `Damaged`.
    #[test]
    fn each_kind_of_damage_is_refused_on_load() {
        let damaged = |hurt: &dyn Fn(&Db)| {
            let db = empty();
            save(&db, &entry("Alpha", &["alfa"]), None, "established").unwrap();
            save(&db, &entry("Beta", &[]), None, "established").unwrap();
            assert!(load(&db).is_ok());
            hurt(&db);
            matches!(load(&db), Err(VocabError::Edit(x)) if x.code == Code::Damaged)
        };
        let run = |sql: &str| {
            let sql = sql.to_string();
            move |db: &Db| {
                db.conn.execute_batch(&sql).unwrap();
            }
        };
        assert!(damaged(&run("PRAGMA ignore_check_constraints=ON; UPDATE vocabulary_state SET schema_version=2; PRAGMA ignore_check_constraints=OFF")), "schema version");
        assert!(damaged(&|db: &Db| {
            for n in 0..512 {
                db.conn.execute("INSERT INTO vocabulary_entries (id, canonical_text, aliases_json, enabled) VALUES (?, ?, '[]', 1)", params![format!("x{n}"), format!("Term{n}")]).unwrap();
            }
        }), "over 512 rows");
        assert!(damaged(&run("UPDATE vocabulary_entries SET aliases_json='not json' WHERE canonical_text='Alpha'")), "aliases JSON");
        assert!(damaged(&run("PRAGMA ignore_check_constraints=ON; UPDATE vocabulary_entries SET learned_at=-1 WHERE canonical_text='Alpha'; PRAGMA ignore_check_constraints=OFF")), "negative learned_at");
        assert!(damaged(&run("UPDATE vocabulary_state SET payload_bytes=payload_bytes+1")), "payload bytes");
        assert!(damaged(&run("UPDATE vocabulary_state SET content_hash=printf('%064d', 0)")), "hash");
        // Bytes and hash agree, but two entries claim one key: the cross-entry check.
        assert!(damaged(&|db: &Db| {
            db.conn.execute_batch("UPDATE vocabulary_entries SET canonical_text='Alpha' WHERE canonical_text='Beta'").unwrap();
            let mut rows: Vec<Entry> = vec![entry("Alpha", &["alfa"]), entry("Alpha", &[])];
            rows[1].id = "id-Beta".into();
            let bytes = serialize(&rows);
            db.conn.execute("UPDATE vocabulary_state SET content_hash=?, payload_bytes=?", params![sha256_hex(&bytes), payload_bytes(&bytes)]).unwrap();
        }), "cross-entry key");
    }

    // parity: DICT-142
    #[test]
    fn the_513th_entry_is_refused_on_the_entry_field() {
        let db = empty();
        for n in 0..MAX_ENTRIES {
            save(&db, &entry(&format!("Term{n}"), &[]), None, "established").unwrap();
        }
        match save(&db, &entry("Oneover", &[]), None, "established") {
            Err(VocabError::Edit(x)) => {
                assert_eq!((x.field, x.code), (Field::Entry, Code::TooManyEntries));
                assert_eq!(x.code.message(), "At most 512 entries.");
            }
            o => panic!("{:?}", o.map(|s| s.revision)),
        }
    }

    // parity: DICT-144
    /// Reached the only way a user could: 64 four-byte characters per term fills 1 MiB before 512 entries.
    #[test]
    fn a_full_store_is_refused_on_the_entry_field() {
        let db = empty();
        let term = |n: u32| -> String { (0..64).map(|i| char::from_u32(0x20000 + n * 64 + i).unwrap()).collect() };
        // Written directly up to near the cap: one save per entry takes half a minute.
        let mut rows: Vec<Entry> = (0..400u32).map(|i| Entry { id: format!("id-{i:03}"), canonical: term(i * 9), aliases: (1..=8).map(|a| term(i * 9 + a)).collect(), enabled: true, learned_at: None }).collect();
        rows.sort_by(|a, b| a.id.cmp(&b.id));
        for e in &rows {
            db.conn.execute("INSERT INTO vocabulary_entries (id, canonical_text, aliases_json, enabled) VALUES (?, ?, ?, 1)", params![e.id, e.canonical, encode_aliases(&e.aliases)]).unwrap();
        }
        let bytes = serialize(&rows);
        db.conn.execute("UPDATE vocabulary_state SET content_hash=?, payload_bytes=?", params![sha256_hex(&bytes), payload_bytes(&bytes)]).unwrap();
        let mut n = 400 * 9;
        let refused = loop {
            let mut e = entry("x", &[]);
            e.id = format!("id-z{n}");
            e.canonical = term(n);
            e.aliases = (1..=8).map(|a| term(n + a)).collect();
            n += 9;
            match save(&db, &e, None, "established") {
                Ok(_) => assert!(n < 9 * 512, "the store never filled"),
                Err(VocabError::Edit(x)) => break x,
                Err(o) => panic!("{}", describe(&o)),
            }
        };
        assert_eq!((refused.field, refused.code), (Field::Entry, Code::PayloadCapacity));
        assert_eq!(refused.code.message(), "Vocabulary storage is full.");
        assert!(load(&db).unwrap().state.payload_bytes as usize <= MAX_PAYLOAD);
    }

    // parity: DICT-128
    #[test]
    fn restore_is_ignored_while_a_write_runs() {
        let db = empty();
        seed(&db);
        let mut m = Model::default();
        m.refresh(&db, |_| false);
        let z = m.entries.iter().find(|e| e.canonical == "Z\u{fc}rich").unwrap().clone();
        let term = m.retired_terms(&z)[0].clone();
        let retired = |db: &Db| db.conn.query_row("SELECT count(*) FROM dictionary_key_usage WHERE state='retired'", [], |r| r.get::<_, i64>(0)).unwrap();
        let before = retired(&db);
        m.saving = true;
        m.restore(&db, &z, &term, |_| false);
        assert_eq!(retired(&db), before);
        m.saving = false;
        m.restore(&db, &z, &term, |_| false);
        assert_eq!(retired(&db), before - 1);
    }

    // parity: DICT-076
    #[test]
    fn a_failed_usage_read_reads_unused_without_an_error() {
        let db = empty();
        let e = entry("Alpha", &["alfa"]);
        save(&db, &e, None, "established").unwrap();
        db.conn.execute_batch("UPDATE dictionary_key_usage SET applied=4; DROP TABLE dictionary_key_usage;").unwrap();
        let mut m = Model::default();
        m.refresh(&db, |_| false);
        assert_eq!(m.usage_summary(&db, &e), "Unused");
        assert_eq!(m.load_error, None);
    }

    // parity: DICT-079 DICT-078 DICT-069
    #[test]
    fn seed_loads_and_restore_retrusts() {
        let db = empty();
        seed(&db);
        let mut m = Model::default();
        m.refresh(&db, |_| false);
        assert!(m.entries.len() >= 7);
        let z = m.entries.iter().find(|e| e.canonical == "Zürich").unwrap().clone();
        let terms = m.retired_terms(&z);
        assert_eq!(terms[0].term, "Zürich");
        let rev = |db: &Db| db.conn.query_row("SELECT revision FROM dictionary_usage_state", [], |r| r.get::<_, i64>(0)).unwrap();
        let before = rev(&db);
        m.restore(&db, &z, &terms[0], |_| false);
        assert_eq!(m.status.as_deref(), Some("Restored Zürich."));
        assert_eq!(rev(&db), before + 1);
        assert!(m.retired_terms(&z).is_empty());
        let k = m.entries.iter().find(|e| e.canonical == "Kubernetes").unwrap();
        assert!(m.is_provisional(k));
        let t = m.entries.iter().find(|e| e.canonical == "Tallinn").unwrap();
        assert!(m.retired_terms(t)[0].is_boost());
        assert!(!m.is_provisional(t));
    }
}
