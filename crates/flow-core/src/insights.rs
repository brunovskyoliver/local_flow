//! Aggregates behind the Insights page: port of `UsageInsights`. Rows come from the history store,
//! so there's nothing to seed here.
use crate::db::Db;
use crate::history::{civil_from_days, days_from_civil, region, region_date, region_number};
use std::collections::{BTreeMap, HashSet};

pub fn seed(_db: &Db) {}

pub const ERROR: &str = "Insights could not be loaded. Your transcriptions are unchanged.";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Category {
    Other,
    Ai,
    Personal,
    Emails,
    Work,
    Documents,
}

impl Category {
    pub const ALL: [Category; 6] = [
        Category::Other,
        Category::Ai,
        Category::Personal,
        Category::Emails,
        Category::Work,
        Category::Documents,
    ];
    pub fn label(self) -> &'static str {
        match self {
            Category::Other => "Other tasks",
            Category::Ai => "AI prompts",
            Category::Personal => "Personal messages",
            Category::Emails => "Emails",
            Category::Work => "Work messages",
            Category::Documents => "Documents",
        }
    }
    pub fn symbol(self) -> &'static str {
        match self {
            Category::Other => "infinity",
            Category::Ai => "cpu",
            Category::Personal => "bubble.left",
            Category::Emails => "envelope",
            Category::Work => "text.bubble",
            Category::Documents => "doc.text",
        }
    }
    /// Lowercased bundle lookup; nil or unknown is Other tasks.
    pub fn classify(bundle: Option<&str>) -> Category {
        let Some(b) = bundle else {
            return Category::Other;
        };
        const GROUPS: [(Category, &[&str]); 5] = [
            (
                Category::Ai,
                &[
                    "com.openai.chat",
                    "com.openai.codex",
                    "com.anthropic.claudefordesktop",
                    "com.t3tools.t3code",
                    "com.emanueledipietro.synara",
                    "ai.perplexity.mac",
                    "com.google.geminimacos",
                    "com.mistral.lechat",
                ],
            ),
            (
                Category::Personal,
                &[
                    "com.apple.mobilesms",
                    "net.whatsapp.whatsapp",
                    "desktop.whatsapp",
                    "ru.keepcoder.telegram",
                    "org.telegram.desktop",
                    "org.whispersystems.signal-desktop",
                    "com.facebook.archon",
                    "com.hnc.discord",
                ],
            ),
            (
                Category::Emails,
                &[
                    "com.apple.mail",
                    "com.microsoft.outlook",
                    "com.readdle.smartemail-mac",
                    "com.superhuman.electron",
                    "it.bloop.airmail2",
                    "com.mimestream.mimestream",
                    "com.freron.mailmate",
                ],
            ),
            (
                Category::Work,
                &[
                    "com.tinyspeck.slackmacgap",
                    "com.microsoft.teams",
                    "com.microsoft.teams2",
                    "us.zoom.xos",
                ],
            ),
            (
                Category::Documents,
                &[
                    "com.apple.iwork.pages",
                    "com.microsoft.word",
                    "com.apple.notes",
                    "com.apple.textedit",
                    "notion.id",
                    "md.obsidian",
                    "com.lukilabs.lukiapp",
                    "net.shinyfrog.bear",
                    "com.microsoft.onenote.mac",
                    "com.apple.iwork.keynote",
                ],
            ),
        ];
        let lower = b.to_lowercase();
        GROUPS
            .iter()
            .find(|(_, ids)| ids.contains(&lower.as_str()))
            .map_or(Category::Other, |(c, _)| *c)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Day {
    pub dictations: i64,
    pub words: i64,
    pub apps: BTreeMap<String, i64>,
}

/// Most words; a tie goes to the lexically smaller bundle ID.
pub fn top_of(apps: &BTreeMap<String, i64>) -> Option<&str> {
    apps.iter()
        .rev()
        .max_by_key(|(_, w)| **w)
        .map(|(k, _)| k.as_str())
}

impl Day {
    pub fn top_app(&self) -> Option<&str> {
        top_of(&self.apps)
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Insights {
    pub dictations: i64,
    pub total_words: i64,
    pub timed_words: i64,
    pub spoken_seconds: f64,
    pub words_corrected: i64,
    pub dictionary_fixes: i64,
    pub longest_words: i64,
    pub apps_used: i64,
    pub categories: [i64; 6],
    pub category_words: [i64; 6],
    pub app_words: BTreeMap<String, i64>,
    /// Keyed by days since 1970 in local time.
    pub days: BTreeMap<i64, Day>,
    pub hours: [i64; 24],
    pub hour_dictations: [i64; 24],
    pub hour_apps: [BTreeMap<String, i64>; 24],
}

pub fn word_count(text: &str) -> i64 {
    text.split_whitespace().count() as i64
}

/// Foundation's `.punctuationCharacters`: the Unicode P categories, no symbols.
/// ponytail: Latin, general and CJK punctuation blocks, enough for dictated text in every language
/// LocalFlow recognizes; other scripts' marks stay attached to their word.
fn is_punctuation(c: char) -> bool {
    match c {
        '$' | '+' | '<' | '=' | '>' | '^' | '`' | '|' | '~' => false,
        c if c.is_ascii_punctuation() => true,
        '¡' | '§' | '«' | '¶' | '·' | '»' | '¿' => true,
        '\u{2010}'..='\u{2027}'
        | '\u{2030}'..='\u{2043}'
        | '\u{2045}'..='\u{2051}'
        | '\u{2053}'..='\u{205E}' => true,
        '\u{3001}'..='\u{3003}' | '\u{3008}'..='\u{3011}' | '\u{FF01}'..='\u{FF0F}' => true,
        _ => false,
    }
}

fn tokens(text: &str) -> Vec<&str> {
    text.split_whitespace()
        .map(|t| t.trim_matches(is_punctuation))
        .filter(|t| !t.is_empty())
        .collect()
}

/// Words the rewrite replaced or dropped: Swift's `difference(from:).removals.count`, which for a
/// minimal diff is `before - LCS`.
pub fn corrected_words(input: &str, output: &str) -> i64 {
    let (a, b) = (tokens(input), tokens(output));
    if a == b {
        return 0;
    }
    let mut prev = vec![0usize; b.len() + 1];
    for x in &a {
        let mut cur = vec![0usize; b.len() + 1];
        for (j, y) in b.iter().enumerate() {
            cur[j + 1] = if x == y {
                prev[j] + 1
            } else {
                cur[j].max(prev[j + 1])
            };
        }
        prev = cur;
    }
    (a.len() - prev[b.len()]) as i64
}

pub struct Streaks {
    pub current: i64,
    pub longest: i64,
    pub current_days: HashSet<i64>,
}

/// A streak survives until the end of the day after its last dictation.
pub fn streaks(days: &BTreeMap<i64, Day>, today: i64) -> Streaks {
    let mut longest = 0;
    let mut run = 0;
    let mut prev = None;
    for d in days.keys() {
        run = if prev == Some(d - 1) { run + 1 } else { 1 };
        longest = longest.max(run);
        prev = Some(*d);
    }
    let Some(&last) = days
        .keys()
        .next_back()
        .filter(|l| **l == today || **l + 1 == today)
    else {
        return Streaks {
            current: 0,
            longest,
            current_days: HashSet::new(),
        };
    };
    let mut current_days = HashSet::from([last]);
    let mut c = last;
    while days.contains_key(&(c - 1)) {
        c -= 1;
        current_days.insert(c);
    }
    Streaks {
        current: current_days.len() as i64,
        longest,
        current_days,
    }
}

pub fn load(db: &Db) -> rusqlite::Result<Insights> {
    let mut i = Insights::default();
    let mut s = db.conn.prepare_cached(
        "SELECT t.target_bundle_id, t.text,
           json_extract(q.detail_json, '$.content.provenance.inputDurationSeconds') AS seconds,
           coalesce(json_array_length(q.detail_json, '$.content.appliedEntryIDs'), 0) AS fixes,
           strftime('%Y %m %d %H', t.created_at/1000, 'unixepoch', 'localtime')
         FROM transcriptions t LEFT JOIN transcription_quality q ON q.transcription_id = t.id",
    )?;
    let mut rows = s.query([])?;
    while let Some(r) = rows.next()? {
        let bundle: Option<String> = r.get(0)?;
        let words = word_count(&r.get::<_, String>(1)?);
        let seconds: Option<f64> = r.get(2)?;
        let when: String = r.get(4)?;
        let p: Vec<i64> = when.split(' ').map(|x| x.parse().unwrap_or(0)).collect();
        i.dictations += 1;
        i.total_words += words;
        i.longest_words = i.longest_words.max(words);
        i.dictionary_fixes += r.get::<_, i64>(3)?;
        if let Some(sec) = seconds.filter(|x| *x > 0.0) {
            i.timed_words += words;
            i.spoken_seconds += sec;
        }
        let c = Category::classify(bundle.as_deref()) as usize;
        i.categories[c] += 1;
        i.category_words[c] += words;
        let day = i.days.entry(days_from_civil(p[0], p[1], p[2])).or_default();
        day.dictations += 1;
        day.words += words;
        let hour = p[3] as usize;
        i.hours[hour] += words;
        i.hour_dictations[hour] += 1;
        if let Some(b) = bundle.filter(|b| !b.is_empty()) {
            *day.apps.entry(b.clone()).or_default() += words;
            *i.hour_apps[hour].entry(b.clone()).or_default() += words;
            *i.app_words.entry(b).or_default() += words;
        }
    }
    i.apps_used = i.app_words.len() as i64;
    let mut s = db.conn.prepare_cached("SELECT input_text, output_text FROM rewrite_attempts WHERE delivered = 1 AND state = 'succeeded' AND unchanged = 0")?;
    let mut rows = s.query([])?;
    while let Some(r) = rows.next()? {
        i.words_corrected += corrected_words(&r.get::<_, String>(0)?, &r.get::<_, String>(1)?);
    }
    Ok(i)
}

impl Insights {
    pub fn words_per_minute(&self) -> Option<i64> {
        (self.spoken_seconds >= 1.0 && self.timed_words > 0)
            .then(|| (self.timed_words as f64 / (self.spoken_seconds / 60.0)).round() as i64)
    }
    pub fn average_words(&self) -> i64 {
        if self.dictations == 0 {
            0
        } else {
            (self.total_words as f64 / self.dictations as f64).round() as i64
        }
    }
    /// All six, by dictation count descending; ties keep enum order.
    pub fn category_rows(&self) -> Vec<(Category, i64)> {
        let mut rows: Vec<(Category, i64)> = Category::ALL
            .iter()
            .map(|c| (*c, self.categories[*c as usize]))
            .collect();
        rows.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
        rows
    }
    pub fn top_app_in(&self, c: Category) -> Option<&str> {
        let in_category: BTreeMap<String, i64> = self
            .app_words
            .iter()
            .filter(|(k, _)| Category::classify(Some(k)) == c)
            .map(|(k, v)| (k.clone(), *v))
            .collect();
        top_of(&in_category)
            .and_then(|t| self.app_words.get_key_value(t))
            .map(|(k, _)| k.as_str())
    }
    /// Quartiles of all active days, so one heavy day doesn't wash out the rest.
    pub fn thresholds(&self) -> [i64; 3] {
        let mut counts: Vec<i64> = self
            .days
            .values()
            .map(|d| d.words)
            .filter(|w| *w > 0)
            .collect();
        counts.sort_unstable();
        if counts.is_empty() {
            return [1, 1, 1];
        }
        let n = counts.len();
        [0.25, 0.5, 0.75].map(|q: f64| counts[(n - 1).min((n as f64 * q) as usize)])
    }
}

pub fn level(count: i64, limits: &[i64; 3]) -> usize {
    if count > limits[2] {
        0
    } else if count > limits[1] {
        1
    } else if count > limits[0] {
        2
    } else {
        3
    }
}

pub fn talk_time(seconds: f64) -> String {
    let total = seconds.round() as i64;
    let (h, m) = (total / 3600, (total % 3600) / 60);
    if h > 0 {
        format!("{h}h {m}m")
    } else if m > 0 {
        format!("{m}m")
    } else {
        format!("{total}s")
    }
}

pub fn versus_typing(pace: Option<i64>) -> String {
    pace.map_or("–".into(), |p| {
        let ratio = p as f64 / 40.0;
        region_number(ratio, 1)
            .unwrap_or_else(|| crate::onboarding::localized(&format!("{ratio:.1}")))
            + "×"
    })
}

/// `formatted()`; the fallback groups with a no-break space.
pub fn grouped(n: i64) -> String {
    if let Some(s) = region_number(n as f64, 0) {
        return s;
    }
    let digits = n.abs().to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push('\u{A0}');
        }
        out.push(c);
    }
    if n < 0 { format!("-{out}") } else { out }
}

/// "1 word" / "2 000 words".
pub fn counted(n: i64, one: &str, many: &str) -> String {
    format!("{} {}", grouped(n), if n == 1 { one } else { many })
}

/// Last dot component with its first letter capitalized, else the bundle ID.
pub fn fallback_app_name(bundle: &str) -> String {
    let last = bundle.rsplit('.').next().unwrap_or(bundle);
    let mut c = last.chars();
    match c.next() {
        Some(f) => f.to_uppercase().chain(c).collect(),
        None => bundle.to_string(),
    }
}

const DAY_MS: i64 = 86_400_000;

/// `Calendar.firstWeekday`, Monday when no region is set.
fn first_weekday() -> i64 {
    region().map_or(2, |r| r.first_weekday)
}

/// The first day of the week containing `day`. Day 0 was a Thursday.
pub fn week_start(day: i64) -> i64 {
    // 1 is Sunday: Thursday's index is 5.
    day - (day + 5 - (first_weekday())).rem_euclid(7)
}

pub const WEEKS: i64 = 19;

/// `shortWeekdaySymbols` from the calendar's first weekday; `offset` counts rows down the grid.
pub fn weekday_label(offset: i64) -> String {
    // 2026-11-01 was a Sunday.
    let sunday = days_from_civil(2026, 11, 1);
    let day = sunday + (first_weekday() - 1 + offset).rem_euclid(7);
    region_date(day * DAY_MS, "EEE", true).unwrap_or_else(|| {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][(day - sunday) as usize].to_string()
    })
}

pub fn columns(today: i64, page: i64) -> Vec<i64> {
    (0..WEEKS)
        .map(|c| week_start(today) + 7 * (c - (WEEKS - 1) - page * WEEKS))
        .collect()
}

/// The abbreviated month when this week contains a 1st.
pub fn month_label(week: i64) -> Option<String> {
    let first = (0..7)
        .map(|o| week + o)
        .find(|day| civil_from_days(*day).2 == 1)?;
    Some(
        region_date(first * DAY_MS, "MMM", true)
            .unwrap_or_else(|| crate::history::month_short(civil_from_days(first).1).to_string()),
    )
}

/// `date(.long)`, "31 October 2026" in the fallback.
pub fn long_date(day: i64) -> String {
    region_date(day * DAY_MS, "yMMMMd", true).unwrap_or_else(|| {
        let (y, m, d) = civil_from_days(day);
        format!("{d} {} {y}", crate::history::MONTHS[(m - 1) as usize])
    })
}

/// `time: .shortened` for an hour of the day: "1:00", "13:00" in the fallback.
pub fn hour_time(h: i64) -> String {
    region_date(h * 3_600_000, "short-time", true).unwrap_or_else(|| format!("{h}:00"))
}

/// `.dateTime.hour()` for the axis: "00", "06" in the fallback.
pub fn hour_label(h: i64) -> String {
    region_date(h * 3_600_000, "j", true).unwrap_or_else(|| format!("{h:02}"))
}

/// The tip's plain sentence, which is also the element's accessibility value.
pub fn note_spoken(title: &str, detail: Option<&str>) -> String {
    match detail {
        Some(d) => format!("{title}, {}", d.replace('\n', ", ")),
        None => title.to_string(),
    }
}

pub fn day_spoken(day: i64, words: i64, apps: i64, top: Option<&str>) -> String {
    let mut parts = vec![
        long_date(day),
        counted(words, "word", "words"),
        format!("{} used", counted(apps, "app", "apps")),
    ];
    if let Some(t) = top {
        parts.push(format!("most in {t}"));
    }
    parts.join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::history::{local, now_ms, seed_id};

    // parity: INS-025 INS-026 INS-035 INS-036 INS-037 INS-040 INS-041 INS-042 INS-044 INS-057 INS-059 INS-062 INS-066 INS-085 INS-093 INS-095 INS-101 INS-106
    #[test]
    fn aggregates_over_the_seed() {
        let db = Db::memory();
        crate::history::seed(&db);
        let i = load(&db).unwrap();
        let n: i64 = db
            .conn
            .query_row("SELECT count(*) FROM transcriptions", [], |r| r.get(0))
            .unwrap();
        assert_eq!(i.dictations, n);
        assert_eq!(i.categories.iter().sum::<i64>(), n);
        assert_eq!(i.days.values().map(|d| d.dictations).sum::<i64>(), n);
        assert_eq!(i.hour_dictations.iter().sum::<i64>(), n);
        assert_eq!(i.hours.iter().sum::<i64>(), i.total_words);
        // Row 5 has no quality row, so it stays out of the timed totals; row 1 has one applied entry.
        assert!(i.timed_words < i.total_words);
        assert_eq!(i.dictionary_fixes, 1);
        assert!(i.words_per_minute().is_some());
        assert_eq!(
            i.average_words(),
            (i.total_words as f64 / n as f64).round() as i64
        );
        assert!(i.longest_words >= 20);
        assert_eq!(
            i.words_corrected,
            corrected_words(
                "Move the kickoff to Thursday and ask Northwind to send the updated floor plan before noon.",
                "Please move the kickoff to Thursday, and ask Northwind to send the updated floor plan before noon."
            )
        );
        let rows = i.category_rows();
        assert!(rows.windows(2).all(|w| w[0].1 >= w[1].1));
        assert_eq!(rows.len(), 6);
        assert!(i.apps_used >= 6);
        assert_eq!(i.top_app_in(Category::Emails), Some("com.apple.mail"));
        assert_eq!(
            i.top_app_in(Category::Personal),
            Some("com.apple.MobileSMS")
        );
        // The undelivered, unchanged and failed attempts don't count.
        db.conn
            .execute("UPDATE rewrite_attempts SET delivered=0", [])
            .unwrap();
        assert_eq!(load(&db).unwrap().words_corrected, 0);
        let _ = seed_id(1);
        // Empty: all zero and no pace.
        let e = load(&Db::memory()).unwrap();
        assert_eq!(
            (e.dictations, e.words_per_minute(), e.average_words()),
            (0, None, 0)
        );
        assert_eq!(e.thresholds(), [1, 1, 1]);
    }

    // parity: INS-030 INS-052 INS-053 INS-054 INS-055 INS-056 INS-063 INS-065 INS-070 INS-080 INS-081 INS-088 INS-091 INS-112
    #[test]
    fn formulas() {
        assert_eq!(corrected_words("Hello, world.", "hello world"), 1);
        assert_eq!(corrected_words("a b c", "a, b, c!"), 0);
        assert_eq!(corrected_words("a b c d", "a x d"), 2);
        assert_eq!(talk_time(59.4), "59s");
        assert_eq!(talk_time(3599.0), "59m");
        assert_eq!(talk_time(3660.0), "1h 1m");
        assert_eq!(versus_typing(Some(150)), "3.8×");
        assert_eq!(versus_typing(None), "–");
        assert_eq!(grouped(1234567), "1\u{A0}234\u{A0}567");
        assert_eq!(counted(1, "word", "words"), "1 word");
        assert_eq!(
            fallback_app_name("com.tinyspeck.slackmacgap"),
            "Slackmacgap"
        );
        assert_eq!(Category::classify(Some("COM.Apple.MAIL")), Category::Emails);
        assert_eq!(
            Category::classify(Some("com.google.GeminiMacOS")),
            Category::Ai
        );
        assert_eq!(
            Category::classify(Some("com.apple.iWork.Keynote")),
            Category::Documents
        );
        assert_eq!(Category::classify(Some("unknown")), Category::Other);
        assert_eq!(Category::classify(None), Category::Other);
        assert_eq!(
            top_of(&BTreeMap::from([
                ("b".to_string(), 3),
                ("a".to_string(), 3)
            ])),
            Some("a")
        );
        // Quartiles use every active day.
        let mut i = Insights::default();
        for (d, w) in [(1, 10), (2, 20), (3, 30), (4, 40)] {
            i.days.insert(
                d,
                Day {
                    words: w,
                    ..Default::default()
                },
            );
        }
        assert_eq!(i.thresholds(), [20, 30, 40]);
        assert_eq!(level(41, &[20, 30, 40]), 0);
        assert_eq!(level(40, &[20, 30, 40]), 1);
        assert_eq!(level(21, &[20, 30, 40]), 2);
        assert_eq!(level(20, &[20, 30, 40]), 3);
        // Streaks.
        let days: BTreeMap<i64, Day> = [10, 11, 12, 20, 21]
            .iter()
            .map(|d| (*d, Day::default()))
            .collect();
        let s = streaks(&days, 22);
        assert_eq!((s.current, s.longest), (2, 3));
        assert!(s.current_days.contains(&20) && !s.current_days.contains(&12));
        assert_eq!(streaks(&days, 23).current, 0);
        assert_eq!(streaks(&days, 21).current, 2);
        assert_eq!(streaks(&BTreeMap::new(), 21).longest, 0);
        // Columns and weeks: 2026-10-31 is a Saturday.
        let sat = days_from_civil(2026, 10, 31);
        assert_eq!(civil_from_days(week_start(sat)), (2026, 10, 26));
        let c = columns(sat, 0);
        assert_eq!(c.len(), 19);
        assert_eq!(c[18], week_start(sat));
        assert_eq!(columns(sat, 1)[18], c[0] - 7);
        assert_eq!(
            month_label(days_from_civil(2026, 9, 28)).as_deref(),
            Some("Oct")
        );
        assert_eq!(month_label(days_from_civil(2026, 10, 5)), None);
        assert_eq!(
            note_spoken("3 words", Some("a · b\nMost in Mail")),
            "3 words, a · b, Most in Mail"
        );
        assert!(day_spoken(sat, 1, 2, Some("Mail")).ends_with("1 word, 2 apps used, most in Mail"));
        let db = Db::memory();
        assert_eq!(local(&db, now_ms()).year >= 2026, true);
    }
}
