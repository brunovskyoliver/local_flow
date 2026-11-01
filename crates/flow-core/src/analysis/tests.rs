use super::queue::{Coordinator, QUEUE_FULL, Status, waiting_delay};
use super::run::{self, Deps, Endpoint, Route, fragments, rfc3339};
use super::validate::*;
use super::wire::*;
use super::*;
use crate::meetings::{OverlayTarget, SEED_FULL, SourceRef, new_id, set_overlay};
use crate::settings::RewriteSettings;
use serde_json::json;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const SEG_A: &str = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
const SEG_B: &str = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB";
const SEG_C: &str = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC";
const KNOWN: &str = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD";
const MEETING: &str = "11111111-1111-4111-8111-111111111111";

// MARK: evidence version

/// From Swift's `EvidenceVersion.compute`, run once on these exact inputs (`swift test` in LocalFlowCore).
#[test]
fn evidence_version_matches_swift() {
    let snapshot = Snapshot {
        segments: vec![
            Segment { id: SEG_B.into(), ordinal: 1, start_ms: 1500, end_ms: 2500, speaker: Speaker::Unknown, text: "Ďalší bod: rozpočet".into() },
            Segment { id: SEG_A.to_lowercase(), ordinal: 0, start_ms: 0, end_ms: 1400, speaker: Speaker::Root(SEG_C.to_lowercase()), text: "Hello there".into() },
            Segment { id: SEG_C.into(), ordinal: 2, start_ms: 2500, end_ms: 3000, speaker: Speaker::Ambiguous, text: "x".into() },
        ],
        participants: vec![
            Participant { speaker_id: SEG_C.into(), certainty: "confirmed", origin: "manual".into(), known_id: Some(KNOWN.into()), name: Some("Not hashed".into()), label: None },
            Participant { speaker_id: SEG_A.into(), certainty: "local_user", origin: "none".into(), known_id: Some(KNOWN.into()), name: Some("Me".into()), label: None },
            Participant { speaker_id: SEG_B.into(), certainty: "unknown", origin: "none".into(), known_id: None, name: None, label: None },
        ],
        candidates: Default::default(),
        notes: vec![Note { ordinal: 1, text: "Note žltý".into(), hash: crate::history::sha256_hex("Note žltý".as_bytes()) }],
    };
    assert_eq!(snapshot.notes[0].hash, "5b4fcb23544ab2e1a654daa349f1b1297c9b505af511ea440b28c9e1023d1f72");
    assert_eq!(evidence_version(&MEETING.to_lowercase(), "22222222-2222-4222-8222-222222222222", &snapshot, "sk"), "dd7df7c240471aa4b2cb7bc4a5698b10473e50875d80fe1182a17815a8df7fa6");
}
#[test]
fn renaming_a_speaker_keeps_the_version_and_a_new_identity_changes_it() {
    let mut s = Snapshot { participants: vec![Participant { speaker_id: SEG_A.into(), certainty: "confirmed", origin: "x".into(), known_id: Some(KNOWN.into()), name: Some("Kat".into()), label: None }], ..Default::default() };
    let v = evidence_version(MEETING, MEETING, &s, "en");
    s.participants[0].name = Some("Katarína".into());
    assert_eq!(evidence_version(MEETING, MEETING, &s, "en"), v);
    s.participants[0].certainty = "recognized";
    assert_ne!(evidence_version(MEETING, MEETING, &s, "en"), v);
}

// MARK: planner

fn segments(sizes: &[usize]) -> Vec<Segment> {
    sizes.iter().enumerate().map(|(i, n)| Segment { id: new_id(), ordinal: i as i64, start_ms: 0, end_ms: 0, speaker: Speaker::Unknown, text: "a".repeat(*n) }).collect()
}
#[test]
fn a_meeting_under_the_budget_is_one_request() {
    let plan = plan(&segments(&[100, 100]), &[], &Policy::default()).unwrap();
    assert!(plan.chunks.is_empty());
    assert_eq!(plan.request_count(), 1);
}
#[test]
fn chunks_cover_every_segment_and_stay_under_the_budget() {
    let segs = segments(&vec![1000; 40]);
    let plan = plan(&segs, &[], &Policy::default()).unwrap();
    assert!(plan.chunks.len() >= 3);
    assert_eq!(plan.chunks[0].first, 0);
    assert_eq!(plan.chunks.last().unwrap().last, 40);
    for pair in plan.chunks.windows(2) {
        assert_eq!(pair[0].last, pair[1].first);
    }
    assert!(plan.chunks.iter().all(|c| c.bytes <= 16_384));
    assert_eq!(plan.synthesis, vec![1]);
    assert_eq!(plan.request_count(), plan.chunks.len() + 1);
}
#[test]
fn a_segment_over_the_budget_gets_its_own_chunk() {
    let plan = plan(&segments(&[100, 20_000, 100]), &[], &Policy::default()).unwrap();
    let huge = plan.chunks.iter().find(|c| c.oversized).unwrap();
    assert_eq!((huge.first, huge.last, huge.bytes), (1, 2, 20_000));
}
#[test]
fn plans_past_the_limits_refuse() {
    let small = Policy { full_budget: 10, chunk_budget: 10, ..Default::default() };
    assert_eq!(plan(&segments(&vec![10; 65]), &[], &small).unwrap_err(), Failure::with("too_long", "too_many_chunks"));
    let notes = vec![Note { ordinal: 1, text: "a".repeat(MAX_NOTE_PARAGRAPH_BYTES + 1), hash: String::new() }];
    assert_eq!(plan(&[], &notes, &Policy::default()).unwrap_err(), Failure::with("too_long", "notes_too_large"));
}
#[test]
fn many_chunks_reduce_in_two_levels() {
    let small = Policy { full_budget: 10, chunk_budget: 10, ..Default::default() };
    assert_eq!(plan(&segments(&vec![10; 40]), &[], &small).unwrap().synthesis, vec![3, 1]);
}
#[test]
fn health_only_lowers_the_policy() {
    let health = Health { limits: Some(Limits { input_bytes: 100, context_tokens: 999_999 }), caps: Some(Caps { sources_per_item: 99, topics: 2, decisions: 99, action_items: 99, next_steps: 99, open_questions: 99, risks: 99 }), ..Default::default() };
    let lowered = Policy::default().lowered(&health);
    assert_eq!((lowered.full_budget, lowered.chunk_budget, lowered.context_tokens, lowered.topic_cap, lowered.sources_per_item), (100, 100, 32_768, 2, 10));
    assert_eq!(Policy::deadline_seconds(1), 360);
    assert_eq!(Policy::deadline_seconds(100), 1800);
    assert!(serde_json::from_str::<Value>(&Policy::default().config_json()).is_ok());
}

// MARK: language

#[test]
fn language_comes_from_the_pass_then_the_text() {
    assert_eq!(recorded_language(Some("a+lang_sk_prompt_v2+b")), Some("sk"));
    assert_eq!(recorded_language(Some("lang_en_prompt_v1+lang_sk_prompt_v1")), None);
    assert_eq!(recorded_language(Some("lang_de_prompt_v1")), None);
    let say = |texts: &[&str]| detect_language(&texts.iter().enumerate().map(|(i, t)| Segment { id: new_id(), ordinal: i as i64, start_ms: 0, end_ms: 0, speaker: Speaker::Unknown, text: t.to_string() }).collect::<Vec<_>>());
    assert_eq!(say(&["We should ship this before the release and it will be fine."]), "en");
    assert_eq!(say(&["Treba to dokončiť ešte dnes, lebo potom bude neskoro."]), "sk");
    assert_eq!(say(&["We should ship this today.", "Treba to dokončiť ešte dnes."]), "mixed");
    assert_eq!(say(&["OK."]), "mixed");
    assert_eq!(say(&[]), "mixed");
}
#[test]
fn only_substantial_plain_prose_counts_as_the_other_language() {
    let english = "We have reviewed the plan and we think that the team should finish this before the release because it would be late if the people were not ready for what the customer wants from the product and all of the work that they have done with the others in the room.";
    assert_eq!(confident(english, 200, 30), Some(Dominant::English));
    assert_eq!(confident("Too short for the check.", 200, 30), None);
}

// MARK: wire

fn analysis() -> Value {
    json!({"schema_version": 1, "meeting_id": MEETING, "partial": false, "language": "en",
        "summary": {"text": "The team met.", "sources": [], "whole_meeting": true},
        "topics": [], "decisions": [], "action_items": [], "next_steps": [], "open_questions": [], "risks": []})
}
#[test]
fn results_decode_strictly() {
    assert!(decode_result(Some(&analysis()), false).is_ok());
    let changed = |f: &dyn Fn(&mut Value)| {
        let mut v = analysis();
        f(&mut v);
        decode_result(Some(&v), false).unwrap_err().category
    };
    assert_eq!(changed(&|v| v["extra"] = json!(1)), "malformed_response");
    assert_eq!(changed(&|v| v["schema_version"] = json!(2)), "unsupported_version");
    assert_eq!(changed(&|v| v["language"] = json!("de")), "malformed_response");
    assert_eq!(changed(&|v| v["meeting_id"] = json!("nope")), "malformed_response");
    assert_eq!(changed(&|v| v["summary"]["text"] = json!("")), "malformed_response");
    assert_eq!(changed(&|v| { v["topics"] = json!(vec![json!({"title":"t","summary":"","bullets":[],"sources":[]}); 21]); }), "over_cap");
    let source = json!({"kind": "segment", "id": SEG_A});
    assert_eq!(changed(&|v| v["decisions"] = json!([{"text": "x", "sources": []}])), "malformed_response");
    assert_eq!(changed(&|v| v["decisions"] = json!([{"text": "x", "sources": [source, source]}])), "malformed_response");
    assert_eq!(changed(&|v| v["next_steps"] = json!([{"text": "x", "sources": [source], "evidence_class": "explicit"}])), "malformed_response");
    assert_eq!(changed(&|v| v["decisions"] = json!([{"text": "x", "sources": [{"kind": "note", "id": "seven"}]}])), "malformed_response");
}
#[test]
fn a_partial_has_half_the_caps() {
    let mut v = analysis();
    v["topics"] = json!(vec![json!({"title":"t","summary":"","bullets":[],"sources":[]}); 11]);
    assert_eq!(decode_result(Some(&v), true).unwrap_err().category, "over_cap");
    assert!(decode_result(Some(&v), false).is_ok());
}
fn action(owner: Value, due: Value, ownership: &str) -> Value {
    json!({"text": "Ship the lamp", "owner": owner, "ownership_state": ownership, "due": due, "sources": [{"kind": "segment", "id": SEG_A}]})
}
#[test]
fn owners_and_dues_must_be_shaped_by_their_kind() {
    let absent = json!({"state": "absent"});
    let source = json!({"kind": "segment", "id": SEG_A});
    let try_one = |a: Value| {
        let mut v = analysis();
        v["action_items"] = json!([a]);
        decode_result(Some(&v), false).map(|_| ()).map_err(|e| e.category)
    };
    assert!(try_one(action(json!({"kind": "none"}), absent.clone(), "unresolved")).is_ok());
    assert!(try_one(action(json!({"kind": "participant", "name": "x"}), absent.clone(), "explicit")).is_err());
    assert!(try_one(action(json!({"kind": "mentioned", "name": ""}), absent.clone(), "supported")).is_err());
    assert!(try_one(action(json!({"kind": "none"}), json!({"state": "explicit_absolute", "date": "2026-13", "original": "x", "source": source}), "unresolved")).is_err());
    assert!(try_one(action(json!({"kind": "none"}), json!({"state": "unresolved", "date": "2026-01-01", "original": "x", "source": source}), "unresolved")).is_err());
    assert!(try_one(action(json!({"kind": "none"}), json!({"state": "unresolved", "original": "soon", "source": source}), "unresolved")).is_ok());
}
#[test]
fn events_decode() {
    assert_eq!(decode_event(br#"{"schema_version":1,"type":"accepted"}"#).unwrap(), Event::Accepted);
    assert_eq!(decode_event(br#"{"schema_version":1,"type":"progress"}"#).unwrap(), Event::Progress { chars: 0 });
    assert_eq!(decode_event(br#"{"schema_version":1,"type":"error","code":"preempted"}"#).unwrap(), Event::Error("preempted".into()));
    assert_eq!(decode_event(br#"{"schema_version":2,"type":"accepted"}"#).unwrap_err().category, "unsupported_version");
    assert_eq!(decode_event(b"not json").unwrap_err().category, "malformed_response");
    assert_eq!(decode_event(br#"{"schema_version":1,"type":"mystery"}"#).unwrap_err().category, "malformed_response");
    assert_eq!(decode_event(&vec![b' '; MAX_LINE_BYTES + 1]).unwrap_err().category, "oversized_response");
    let line = json!({"schema_version": 1, "type": "result", "stage": "other", "analysis": analysis()}).to_string();
    assert_eq!(decode_event(line.as_bytes()).unwrap_err().category, "malformed_response");
    let line = json!({"schema_version": 1, "type": "result", "stage": "full", "run_id": "r", "backend": {"kind": "k", "model": "m"}, "server": {"name": "x".repeat(129), "version": "1"}, "analysis": analysis()}).to_string();
    let Event::Result(payload) = decode_event(line.as_bytes()).unwrap() else { panic!() };
    assert_eq!((payload.run_id.as_deref(), payload.backend_kind.as_deref(), payload.server_version.as_deref()), (Some("r"), Some("k"), None));
}
#[test]
fn health_needs_all_of_limits_and_caps() {
    let h = decode_health(br#"{"service":"localflow-analysis","limits":{"input_bytes":1,"output_bytes":1,"context_tokens":1},"caps":{"topics":1},"prompt_versions":{"full":3},"result_schema_version":1,"backend":{"state":"ready","kind":"k","model":"m"}}"#).unwrap();
    assert_eq!((h.limits, h.caps, h.prompt_versions["full"], h.backend_model.as_deref()), (None, None, 3, Some("m")));
    assert_eq!(decode_health(b"[]"), None);
}
#[test]
fn fragments_fit_a_control_message_and_join_back() {
    let awkward = "\"\\/\u{1}".repeat(30_000) + &"ž".repeat(40_000);
    let parts = fragments(&awkward);
    assert_eq!(parts.concat(), awkward);
    assert!(parts.len() > 1);
    assert!(parts.iter().all(|p| p.len() <= 49_152 && json!({"data": p}).to_string().len() < crate::remote::channel::MAX_CONTROL));
}

// MARK: validator

fn evidence() -> Evidence {
    let text = |id: &str, t: &str| (upper(id), (id.to_string(), t.to_string()));
    Evidence {
        meeting: MEETING.into(),
        segments: [text(SEG_A, "We will ship the lamp on 12.3.2026 for 500 EUR."), text(SEG_B, "Marta owns the budget review.")].into(),
        notes: vec![Note { ordinal: 1, text: "Budget notes".into(), hash: "h".repeat(64) }],
        participants: vec![
            Participant { speaker_id: SEG_C.into(), certainty: "confirmed", origin: "x".into(), known_id: Some(KNOWN.into()), name: Some("Marta".into()), label: None },
            Participant { speaker_id: KNOWN.into(), certainty: "possible", origin: "x".into(), known_id: None, name: None, label: Some("Speaker 2".into()) },
        ],
        candidates: ["Peťo Novák".to_string()].into(),
        started_ms: Some(1_767_225_600_000), // 2026-01-01, a Thursday
        offset: 0,
    }
}
fn decoded(v: Value) -> AnalysisResult {
    decode_result(Some(&v), false).unwrap()
}
fn check(f: impl Fn(&mut Value)) -> Result<(Validated, Counts), Failure> {
    let mut v = analysis();
    f(&mut v);
    validate(&decoded(v), &evidence(), &Policy::default())
}
fn seg(id: &str) -> Value {
    json!({"kind": "segment", "id": id})
}
#[test]
fn the_meeting_and_sources_must_be_this_meetings() {
    assert_eq!(check(|v| v["meeting_id"] = json!(SEG_A)).unwrap_err().category, "meeting_mismatch");
    assert_eq!(check(|v| v["summary"]["sources"] = json!([seg(KNOWN)])).unwrap_err(), Failure::with("source_validation", "unknown_segment"));
    assert_eq!(check(|v| v["summary"]["sources"] = json!([{"kind": "note", "id": "note:9"}])).unwrap_err(), Failure::with("source_validation", "unknown_note"));
    let few = Policy { sources_per_item: 1, ..Default::default() };
    let mut v = analysis();
    v["summary"]["sources"] = json!([seg(SEG_A), seg(SEG_B)]);
    assert_eq!(validate(&decoded(v), &evidence(), &few).unwrap_err(), Failure::with("source_validation", "too_many_sources"));
    let (ok, _) = check(|v| v["summary"]["sources"] = json!([seg(&SEG_A.to_lowercase()), {"kind": "note", "id": "note:1"}])).unwrap();
    assert_eq!(ok.summary_sources, vec![SourceRef::Segment(SEG_A.into()), SourceRef::Note(1, "h".repeat(64))]);
}
#[test]
fn a_named_owner_needs_a_certain_identity() {
    let absent = json!({"state": "absent"});
    let (ok, counts) = check(|v| v["action_items"] = json!([action(json!({"kind": "participant", "speaker_id": SEG_C}), absent.clone(), "explicit")])).unwrap();
    assert!(matches!(&ok.action_items[0].owner, Owner::Participant { certainty: "confirmed", known: Some(_), .. }));
    assert_eq!((counts.identity_downgrades, counts.unresolved_owners), (0, 0));
    let (ok, counts) = check(|v| v["action_items"] = json!([action(json!({"kind": "participant", "speaker_id": KNOWN}), absent.clone(), "explicit")])).unwrap();
    assert_eq!((&ok.action_items[0].owner, ok.action_items[0].ownership_state.as_str()), (&Owner::None, "unresolved"));
    assert_eq!((counts.identity_downgrades, counts.unresolved_owners), (1, 1));
    // A Possible match's name, with case and marks changed, is that same identity.
    let (ok, counts) = check(|v| v["action_items"] = json!([action(json!({"kind": "mentioned", "name": "PETO NOVAK"}), absent.clone(), "supported")])).unwrap();
    assert_eq!((&ok.action_items[0].owner, counts.identity_downgrades), (&Owner::None, 1));
    let (ok, _) = check(|v| v["action_items"] = json!([action(json!({"kind": "mentioned", "name": "Zuzana"}), absent.clone(), "explicit")])).unwrap();
    assert_eq!(ok.action_items[0].ownership_state, "supported");
    let (ok, counts) = check(|v| v["action_items"] = json!([action(json!({"kind": "participant", "speaker_id": SEG_B}), absent.clone(), "explicit")])).unwrap();
    assert_eq!((&ok.action_items[0].owner, counts.identity_downgrades, counts.unresolved_owners), (&Owner::None, 0, 1));
}
#[test]
fn a_due_date_must_match_its_phrase() {
    let due = |d: Value| check(|v| v["action_items"] = json!([action(json!({"kind": "none"}), d.clone(), "unresolved")])).unwrap().0.action_items[0].due.clone();
    let source = seg(SEG_A);
    let right = due(json!({"state": "explicit_relative_resolved", "date": "2026-01-02", "original": "tomorrow", "source": source}));
    assert_eq!((right.state.as_str(), right.date.as_deref()), ("explicit_relative_resolved", Some("2026-01-02")));
    let wrong = due(json!({"state": "explicit_relative_resolved", "date": "2026-02-02", "original": "tomorrow", "source": source}));
    assert_eq!((wrong.state.as_str(), wrong.date), ("unresolved", None));
    let vague = due(json!({"state": "explicit_absolute", "date": "2026-02-02", "original": "soon", "source": source}));
    assert_eq!((vague.state.as_str(), vague.date), ("unresolved", None));
    let fabricated = due(json!({"state": "explicit_absolute", "date": "2026-02-02", "original": "the budget review", "source": seg(KNOWN)}));
    assert_eq!((fabricated.state.as_str(), fabricated.date, fabricated.source), ("unresolved", None, None));
    let month = due(json!({"state": "explicit_absolute", "date": "2026-13-02", "original": "x y z w v", "source": source}));
    assert_eq!(month.state, "unresolved");
}
#[test]
fn invented_literals_drop_what_carries_them() {
    let (ok, counts) = check(|v| {
        v["summary"]["text"] = json!("The team met. They spent 900 EUR today.");
        v["decisions"] = json!([{"text": "Spend 500 EUR on the lamp", "sources": [seg(SEG_A)]}, {"text": "Spend 900 EUR on the lamp", "sources": [seg(SEG_A)]}]);
    })
    .unwrap();
    assert_eq!(ok.summary, "The team met.");
    assert_eq!(ok.decisions.len(), 1);
    assert_eq!(counts.dropped_literal, 1);
    assert_eq!(check(|v| v["summary"]["text"] = json!("They spent 900 EUR today.")).unwrap_err().category, "protected_literal");
    let (ok, counts) = check(|v| v["topics"] = json!([{"title": "Budget", "summary": "It costs 900 EUR", "bullets": [], "sources": []}, {"title": "Lamp", "summary": "", "bullets": ["fine"], "sources": []}])).unwrap();
    assert_eq!((ok.topics.len(), ok.topics[0].title.as_str(), counts.dropped_literal), (1, "Lamp", 1));
}
#[test]
fn an_item_must_share_a_word_with_what_it_cites() {
    let (ok, counts) = check(|v| v["risks"] = json!([{"text": "Reviewing budgets", "sources": [seg(SEG_B)]}, {"text": "Vendor insolvency threatens delivery", "sources": [seg(SEG_B)]}, {"text": "It is what it is", "sources": [seg(SEG_B)]}])).unwrap();
    assert_eq!(ok.risks.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(), ["Reviewing budgets", "It is what it is"]);
    assert_eq!(counts.dropped_unsupported, 1);
}
#[test]
fn duplicates_merge_and_a_next_step_repeating_an_action_goes() {
    let (ok, counts) = check(|v| {
        v["action_items"] = json!([action(json!({"kind": "none"}), json!({"state": "absent"}), "unresolved")]);
        v["next_steps"] = json!([{"text": "ship the lamp!", "sources": [seg(SEG_A)]}, {"text": "The budget review", "sources": [seg(SEG_B)]}, {"text": "the budget  review", "sources": [seg(SEG_B)]}]);
    })
    .unwrap();
    assert_eq!(ok.next_steps.len(), 1);
    assert_eq!(counts.items, 2);
    assert_eq!((counts.dropped_literal, counts.dropped_unsupported), (0, 0));
}
#[test]
fn protected_literals_are_found() {
    let found = |text: &str| violations(text, "");
    for (text, literal) in [
        ("cost $1,200 total", "$1,200"),
        ("about 500 EUR and more", "500 EUR"),
        ("a 1 000 000 EUR deal", "1 000 000 EUR"),
        ("on 2026-03-12 we", "2026-03-12"),
        ("on 12.3.2026 we", "12.3.2026"),
        ("on 12/3/26 we", "12/3/26"),
        ("on 15. marca we", "15. marca"),
        ("by March 15 we", "March 15"),
        ("see https://x.example/a, then", "https://x.example/a"),
        ("mail a@b.example now", "a@b.example"),
        ("host api.example.com now", "api.example.com"),
        ("at 10:30 sharp", "10:30"),
        ("use v2.1 now", "v2.1"),
        ("use 1.2.3 now", "1.2.3"),
        ("ip 10.0.0.1 now", "10.0.0.1"),
        ("the A320 flight", "A320"),
    ] {
        assert!(found(text).iter().any(|l| l == literal), "{text}: {:?}", found(text));
    }
    assert!(found("plain words and 42 alone").is_empty());
    assert!(violations("spent 500  EUR", "He spent 500 EUR there").is_empty(), "whitespace collapses on the evidence side only for the haystack");
    assert!(violations("on 12.3.2026", "on 12.3.2026\nnext").is_empty());
}
#[test]
fn due_phrases_resolve_against_the_meeting_start() {
    let start = 1_767_225_600_000; // Thursday 2026-01-01 00:00 UTC
    let date = |p: &str| match resolve_phrase(p, start, 0) {
        Some(Resolution::Date(_, d)) => d,
        other => panic!("{p}: {other:?}"),
    };
    assert_eq!(date("tomorrow"), "2026-01-02");
    assert_eq!(date("Pozajtra."), "2026-01-03");
    assert_eq!(date("next week"), "2026-01-05");
    assert_eq!(date("budúci týždeň"), "2026-01-05");
    assert_eq!(date("friday"), "2026-01-02");
    assert_eq!(date("thursday"), "2026-01-08", "today's weekday means the next one");
    assert_eq!(date("next friday"), "2026-01-09");
    assert_eq!(date("v piatok"), "2026-01-02");
    assert_eq!(date("2026-02-31"), "2026-03-03", "an invalid date normalizes as Calendar does");
    assert_eq!(date("15.3."), "2026-03-15");
    assert_eq!(date("15.3.2027"), "2027-03-15");
    assert_eq!(date("March 15th"), "2026-03-15");
    assert_eq!(date("15. marca"), "2026-03-15");
    assert_eq!(date("the 3rd of february"), "2026-02-03");
    assert_eq!(resolve_phrase("časom", start, 0), Some(Resolution::Vague));
    assert_eq!(resolve_phrase("next time", start, 0), Some(Resolution::Vague));
    assert_eq!(resolve_phrase("when it's ready", start, 0), None);
    assert_eq!(resolve_phrase("32.1.", start, 0), None);
    // Late on New Year's Eve in the meeting's zone: its day, not UTC's.
    assert_eq!(resolve_phrase("tomorrow", start - 3_600_000, -7200), Some(Resolution::Date("explicit_relative_resolved", "2026-01-01".into())));
    // A date already past this year rolls to the next.
    let june = 1_780_272_000_000; // 2026-06-01
    assert_eq!(resolve_phrase("15.3.", june, 0), Some(Resolution::Date("explicit_absolute", "2027-03-15".into())));
}
#[test]
fn sentences_split_where_a_new_one_starts() {
    assert_eq!(sentences("One. Two! Three? four"), ["One.", " Two!", " Three? four"]);
    assert_eq!(sentences("Costs 1.5 units.\nNext"), ["Costs 1.5 units.", "\n", "Next"]);
}
fn overlay(id: &str, kind: &str, text: &str, key: &str) -> OverlayRow {
    OverlayRow { id: id.into(), item_kind: Some(kind.into()), field: "status".into(), is_summary: false, orphaned: false, item_text: Some(text.into()), source_key: Some(key.into()) }
}
fn item(id: &str, kind: &str, text: &str, keys: &[&str]) -> NewItem {
    NewItem { id: id.into(), kind: kind.into(), text: text.into(), source_keys: keys.iter().map(|k| k.to_string()).collect() }
}
#[test]
fn overlays_follow_their_item() {
    let items = [item("by-source", "decision", "Other words", &["s:A", "s:B"]), item("by-text", "decision", "Ship the lamp soon", &["s:Z"]), item("task", "action_item", "Ship the lamp soon", &["s:A", "s:B"])];
    let (matched, orphaned) = match_overlays(&[overlay("1", "decision", "Something", "s:A,s:B"), overlay("2", "decision", "ship the lamp, soon!", "s:Q"), overlay("3", "risk", "Ship", "s:A,s:B"), overlay("4", "decision", "Unrelated", "s:Q")], &items);
    assert_eq!(matched, [("1".to_string(), "by-source".to_string()), ("2".to_string(), "by-text".to_string())]);
    assert_eq!(orphaned, ["3", "4"]);
    // One field of one item holds one overlay; the older keeps it.
    let (matched, orphaned) = match_overlays(&[overlay("old", "decision", "x", "s:A,s:B"), overlay("new", "decision", "y", "s:A,s:B")], &items);
    assert_eq!((matched.len(), orphaned), (1, vec!["new".to_string()]));
    let mut gone = overlay("gone", "decision", "x", "s:A,s:B");
    gone.orphaned = true;
    assert_eq!(match_overlays(&[gone], &items), (vec![], vec![]));
}

// MARK: store

fn seeded() -> Db {
    let db = Db::memory();
    crate::meetings::seed(&db);
    db
}
const HEX: &str = "abababababababababababababababababababababababababababababababab";
fn admitted(db: &Db) -> String {
    store::admit(db, SEED_FULL, "manual", HEX, "pass", &Policy::default(), 1000).unwrap()
}
fn run_state(db: &Db, id: &str) -> String {
    store::run(db, id).unwrap().unwrap().state
}
fn validated(db: &Db) -> Validated {
    let segment: String = db.conn.query_row("SELECT id FROM transcript_segments WHERE meeting_id=?1 ORDER BY ordinal LIMIT 1", [SEED_FULL], |r| r.get(0)).unwrap();
    let source = SourceRef::Segment(segment);
    Validated {
        language: "en".into(),
        summary: "New summary.".into(),
        whole_meeting: true,
        summary_sources: vec![source.clone(), SourceRef::Note(1, HEX.into())],
        topics: vec![Topic { title: "Lamp".into(), summary: "".into(), bullets: vec!["a".into()], sources: vec![source.clone()] }],
        decisions: vec![Item { text: "Ship the lamp".into(), evidence_class: Some("explicit".into()), sources: vec![source.clone()] }],
        action_items: vec![Action { text: "Order parts".into(), owner: Owner::Mentioned("Zuzana".into()), ownership_state: "supported".into(), due: Due { state: "absent".into(), date: None, original: None, source: None }, sources: vec![source.clone()] }],
        next_steps: vec![],
        open_questions: vec![],
        risks: vec![Item { text: "Late parts".into(), evidence_class: None, sources: vec![source] }],
    }
}
fn count(db: &Db, sql: &str) -> i64 {
    db.conn.query_row(sql, [], |r| r.get(0)).unwrap()
}
#[test]
fn one_active_run_per_meeting() {
    let db = seeded();
    let run = admitted(&db);
    assert!(matches!(store::admit(&db, SEED_FULL, "manual", HEX, "pass", &Policy::default(), 2), Err(store::StoreError::ActiveRun)));
    store::cancel(&db, &run, 2000).unwrap();
    assert_eq!(run_state(&db, &run), "cancelled");
    assert!(matches!(store::cancel(&db, &run, 3000), Err(store::StoreError::InvalidTransition)), "a finished run stays finished");
    admitted(&db);
}
#[test]
fn the_state_machine_holds() {
    let db = seeded();
    let run = admitted(&db);
    assert!(matches!(store::record_plan(&db, &run, 1), Err(store::StoreError::Late)), "only a running run takes counters");
    assert!(matches!(store::fail(&db, &run, "timeout", None, 1), Err(store::StoreError::InvalidTransition)));
    store::start(&db, &run, 1500).unwrap();
    store::record_plan(&db, &run, 3).unwrap();
    store::record_request(&db, &run, 10, 20, true, false).unwrap();
    store::record_request(&db, &run, 1, 2, false, true).unwrap();
    let totals: (i64, i64, i64, i64, i64, i64) = db.conn.query_row("SELECT chunk_count, request_count, input_bytes, output_bytes, retry_count, preemption_count FROM analysis_runs WHERE id=?1", [&run], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?))).unwrap();
    assert_eq!(totals, (3, 2, 11, 22, 1, 1));
    store::fail(&db, &run, "server_unavailable", Some(&"é".repeat(400)), 2500).unwrap();
    let row = store::run(&db, &run).unwrap().unwrap();
    assert_eq!((row.state.as_str(), row.failure_category.as_deref()), ("failed", Some("server_unavailable")));
    assert_eq!(row.failure_detail.unwrap().len(), 512);
    let duration: i64 = db.conn.query_row("SELECT duration_ms FROM analysis_runs WHERE id=?1", [&run], |r| r.get(0)).unwrap();
    assert_eq!(duration, 1000);
    let run = admitted(&db);
    store::start(&db, &run, 1).unwrap();
    store::time_out(&db, &run, 2).unwrap();
    assert_eq!(store::run(&db, &run).unwrap().unwrap().failure_category.as_deref(), Some("timeout"));
    let run = admitted(&db);
    store::interrupt(&db, &run, 2).unwrap();
    assert_eq!(run_state(&db, &run), "interrupted");
}
#[test]
fn adoption_swaps_the_content_and_rematches_overlays() {
    let db = seeded();
    let previous: String = db.conn.query_row("SELECT accepted_run_id FROM meeting_analysis WHERE meeting_id=?1", [SEED_FULL], |r| r.get(0)).unwrap();
    db.conn.execute("DELETE FROM analysis_overlays WHERE meeting_id=?1", [SEED_FULL]).unwrap();
    let old_item: (String, String) = db.conn.query_row("SELECT id, kind FROM analysis_items WHERE run_id=?1 ORDER BY kind LIMIT 1", [&previous], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    let segment: String = db.conn.query_row("SELECT id FROM transcript_segments WHERE meeting_id=?1 ORDER BY ordinal LIMIT 1", [SEED_FULL], |r| r.get(0)).unwrap();
    let key = format!("s:{segment}");
    db.conn.execute("INSERT INTO analysis_overlays (id, meeting_id, item_id, target_kind, item_kind, field, user_value, item_text_snapshot, source_key, created_at, updated_at) VALUES ('keep',?1,?2,'item','decision','status','done','Ship the lamp',?3,1,1)", params![SEED_FULL, old_item.0, key]).unwrap();
    db.conn.execute("INSERT INTO analysis_overlays (id, meeting_id, target_kind, item_kind, field, user_value, item_text_snapshot, source_key, created_at, updated_at) VALUES ('lost',?1,'item','next_step','status','done','Gone',?2,2,2)", params![SEED_FULL, key]).unwrap();
    set_overlay(&db, SEED_FULL, OverlayTarget::Summary, "summary_text", "Mine", None, None, "", 3).unwrap();
    let run = admitted(&db);
    store::start(&db, &run, 1500).unwrap();
    let identity = store::Identity { server_version: "v".repeat(100), backend_kind: "k".into(), backend_model: "m".into(), prompt_versions: "full=1".into(), pipeline_version: PIPELINE_VERSION.into() };
    let counts = Counts { items: 3, dropped_literal: 1, dropped_unsupported: 2, identity_downgrades: 3, unresolved_owners: 4 };
    store::adopt(&db, &run, &validated(&db), &counts, &identity, 2000).unwrap();

    assert_eq!(run_state(&db, &run), "succeeded");
    assert_eq!(run_state(&db, &previous), "superseded");
    assert_eq!(count(&db, &format!("SELECT count(*) FROM analysis_items WHERE run_id='{previous}'")), 0);
    let totals: (i64, String, String, i64, i64) = db.conn.query_row("SELECT item_count, server_version, language_policy, dropped_unsupported_count, duration_ms FROM analysis_runs WHERE id=?1", [&run], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))).unwrap();
    assert_eq!(totals, (3, "v".repeat(64), "en".to_string(), 2, 500));
    let pointer: (String, String) = db.conn.query_row("SELECT accepted_run_id, accepted_evidence_version FROM meeting_analysis WHERE meeting_id=?1", [SEED_FULL], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    assert_eq!(pointer, (run.clone(), HEX.to_string()));
    assert_eq!(count(&db, &format!("SELECT count(*) FROM analysis_sources WHERE run_id='{run}' AND target_kind='summary'")), 2);

    let kept: (Option<String>, Option<i64>) = db.conn.query_row("SELECT item_id, orphaned_at FROM analysis_overlays WHERE id='keep'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    let decision: String = db.conn.query_row("SELECT id FROM analysis_items WHERE run_id=?1 AND kind='decision'", [&run], |r| r.get(0)).unwrap();
    assert_eq!(kept, (Some(decision), None));
    let lost: (Option<String>, Option<i64>) = db.conn.query_row("SELECT item_id, orphaned_at FROM analysis_overlays WHERE id='lost'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    assert_eq!(lost, (None, Some(2000)));
    assert_eq!(count(&db, "SELECT count(*) FROM analysis_overlays WHERE id<>'keep' AND id<>'lost' AND orphaned_at IS NULL AND target_kind='summary'"), 1, "a summary overlay stays");
    assert!(crate::meetings::read_model(&db, SEED_FULL).unwrap().is_some());
}
#[test]
fn a_late_write_changes_nothing_and_supersedes() {
    let db = seeded();
    let accepted: String = db.conn.query_row("SELECT accepted_run_id FROM meeting_analysis WHERE meeting_id=?1", [SEED_FULL], |r| r.get(0)).unwrap();
    let run = admitted(&db);
    store::start(&db, &run, 1).unwrap();
    db.conn.execute("UPDATE meeting_analysis SET current_run_id=?1 WHERE meeting_id=?2", params![accepted, SEED_FULL]).unwrap();
    let result = store::adopt(&db, &run, &validated(&db), &Counts::default(), &Default::default(), 2);
    assert!(matches!(result, Err(store::StoreError::Late)));
    assert_eq!(count(&db, &format!("SELECT count(*) FROM analysis_summaries WHERE run_id='{run}'")), 0);
    store::supersede(&db, &run, 3).unwrap();
    store::supersede(&db, &run, 4).unwrap();
    assert_eq!(run_state(&db, &run), "superseded");
    assert_eq!(run_state(&db, &accepted), "succeeded", "the accepted run keeps its content");
    let cancelled = admitted(&db);
    store::cancel(&db, &cancelled, 5).unwrap();
    assert!(matches!(store::adopt(&db, &cancelled, &validated(&db), &Counts::default(), &Default::default(), 6), Err(store::StoreError::Late)));
}
#[test]
fn adoption_prunes_old_unfinished_rows() {
    let db = seeded();
    for i in 0..25 {
        let run = store::admit(&db, SEED_FULL, "manual", HEX, "pass", &Policy::default(), 100 + i).unwrap();
        store::cancel(&db, &run, 200 + i).unwrap();
    }
    let run = admitted(&db);
    store::start(&db, &run, 1).unwrap();
    store::adopt(&db, &run, &validated(&db), &Counts::default(), &Default::default(), 2).unwrap();
    assert_eq!(count(&db, &format!("SELECT count(*) FROM analysis_runs WHERE meeting_id='{SEED_FULL}'")), RUN_ROWS_PER_MEETING);
    assert_eq!(run_state(&db, &run), "succeeded");
}
#[test]
fn launch_interrupts_runs_and_restarts_only_automatic_ones_without_a_summary() {
    let db = seeded();
    let root = std::env::temp_dir().join(format!("flow-analysis-reconcile-{}", std::process::id()));
    let run = store::admit(&db, SEED_FULL, "automatic", HEX, "pass", &Policy::default(), 1).unwrap();
    let recovery = crate::meetings::reconcile_launch(&db, &root, 2).unwrap();
    assert_eq!(run_state(&db, &run), "interrupted");
    assert!(recovery.analysis_restarts.is_empty(), "this meeting already has an accepted summary");
    db.conn.execute("UPDATE meeting_analysis SET accepted_run_id=NULL WHERE meeting_id=?1", [SEED_FULL]).unwrap();
    let manual = store::admit(&db, SEED_FULL, "manual", HEX, "pass", &Policy::default(), 3).unwrap();
    assert!(crate::meetings::reconcile_launch(&db, &root, 4).unwrap().analysis_restarts.is_empty(), "a manual run waits for the user");
    assert_eq!(run_state(&db, &manual), "interrupted");
    store::admit(&db, SEED_FULL, "automatic", HEX, "pass", &Policy::default(), 5).unwrap();
    assert_eq!(crate::meetings::reconcile_launch(&db, &root, 6).unwrap().analysis_restarts, [SEED_FULL]);
    assert_eq!(count(&db, &format!("SELECT auto_restarted_at FROM meeting_analysis WHERE meeting_id='{SEED_FULL}'")), 6);
}
#[test]
fn timestamps_format_as_swift_does() {
    assert_eq!(rfc3339(1_767_225_600_000, 0), "2026-01-01T00:00:00Z");
    assert_eq!(rfc3339(1_767_225_600_000, 3600), "2026-01-01T01:00:00+01:00");
    assert_eq!(rfc3339(1_767_225_600_000, -19_800), "2025-12-31T18:30:00-05:30");
    assert_eq!(run::current_zone(0).is_empty(), false);
}

// MARK: runs against a fake server

enum Answer {
    Lines(u16, Vec<String>),
    /// Holds the connection open, silent.
    Hang,
}
struct Fake {
    origin: String,
    posts: Arc<Mutex<Vec<Value>>>,
    headers: Arc<Mutex<Vec<String>>>,
}
fn serve(health: Value, answer: impl Fn(usize, &Value) -> Answer + Send + Sync + 'static) -> Fake {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let (posts, headers) = (Arc::new(Mutex::new(vec![])), Arc::new(Mutex::new(vec![])));
    let (seen, heads, answer) = (posts.clone(), headers.clone(), Arc::new(answer));
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let (seen, heads, answer, health): (Arc<Mutex<Vec<Value>>>, Arc<Mutex<Vec<String>>>, _, _) = (seen.clone(), heads.clone(), answer.clone(), health.clone());
            std::thread::spawn(move || {
                let mut raw = vec![];
                let mut byte = [0; 1024];
                let split = loop {
                    let n = stream.read(&mut byte).unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    raw.extend_from_slice(&byte[..n]);
                    if let Some(at) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                        break at + 4;
                    }
                };
                let head = String::from_utf8_lossy(&raw[..split]).to_string();
                let length = head.lines().find_map(|l| l.to_lowercase().strip_prefix("content-length: ").and_then(|v| v.parse::<usize>().ok())).unwrap_or(0);
                while raw.len() < split + length {
                    let n = stream.read(&mut byte).unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    raw.extend_from_slice(&byte[..n]);
                }
                let (status, body) = if head.starts_with("GET") {
                    (200, health.to_string())
                } else {
                    heads.lock().unwrap().push(head);
                    let request: Value = serde_json::from_slice(&raw[split..]).unwrap();
                    let index = {
                        let mut seen = seen.lock().unwrap();
                        seen.push(request.clone());
                        seen.len() - 1
                    };
                    match answer(index, &request) {
                        Answer::Hang => {
                            std::thread::sleep(Duration::from_secs(20));
                            return;
                        }
                        Answer::Lines(status, lines) => (status, lines.join("\n") + "\n"),
                    }
                };
                let _ = write!(stream, "HTTP/1.1 {status} X\r\nConnection: close\r\nContent-Type: application/x-ndjson\r\n\r\n{body}");
            });
        }
    });
    Fake { origin, posts, headers }
}
fn ready() -> Value {
    json!({"service": "localflow-analysis", "server": {"name": "flowd", "version": "9"}, "backend": {"state": "ready", "kind": "fake", "model": "qwen"}, "prompt_versions": {"full": 1, "chunk": 2}, "result_schema_version": 1})
}
fn limited(input_bytes: usize) -> Value {
    let mut h = ready();
    h["limits"] = json!({"input_bytes": input_bytes, "output_bytes": 100_000, "context_tokens": 32_768, "concurrency": 1});
    h
}
fn result_line(request: &Value, first_segment: &str) -> String {
    let source = json!({"kind": "segment", "id": first_segment});
    json!({"schema_version": 1, "type": "result", "stage": request["stage"], "run_id": request["run_id"], "backend": {"kind": "fake", "model": "qwen"}, "analysis": {
        "schema_version": 1, "meeting_id": request["meeting"]["id"], "partial": request["stage"] == "chunk", "language": request["meeting"]["language_policy"]["output"],
        "summary": {"text": "The team reviewed the prototype.", "sources": [source], "whole_meeting": true},
        "topics": [{"title": "Prototype", "summary": "They reviewed it.", "bullets": [], "sources": [source]}],
        "decisions": [], "action_items": [{"text": "Follow up", "owner": {"kind": "none"}, "ownership_state": "unresolved", "due": {"state": "absent"}, "sources": [source]}],
        "next_steps": [], "open_questions": [], "risks": [],
    }})
    .to_string()
}
const ACCEPTED: &str = r#"{"schema_version":1,"type":"accepted"}"#;
struct World {
    path: PathBuf,
    db: Db,
    first_segment: String,
    total_bytes: usize,
}
impl Drop for World {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(self.path.parent().unwrap());
    }
}
/// A real file, because each run thread opens its own connection, with SEED_FULL as evidence.
fn world() -> World {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let dir = std::env::temp_dir().join(format!("flow-analysis-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::SeqCst)));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("history.sqlite");
    let db = Db::open_or_create(&path).unwrap();
    crate::meetings::seed(&db);
    db.conn.execute("DELETE FROM meeting_analysis WHERE meeting_id=?1", [SEED_FULL]).unwrap();
    db.conn.execute("DELETE FROM analysis_runs WHERE meeting_id=?1", [SEED_FULL]).unwrap();
    let first_segment: String = db.conn.query_row("SELECT upper(id) FROM transcript_segments WHERE meeting_id=?1 ORDER BY ordinal LIMIT 1", [SEED_FULL], |r| r.get(0)).unwrap();
    let total_bytes: i64 = db.conn.query_row("SELECT sum(length(CAST(normalized_text AS BLOB))) FROM transcript_segments WHERE meeting_id=?1", [SEED_FULL], |r| r.get(0)).unwrap();
    World { path, db, first_segment, total_bytes: total_bytes as usize }
}
fn deps(world: &World, deadline_unit: Duration) -> Deps {
    Deps { database: world.path.clone(), secret: Arc::new(|_| None), pool: None, wait_unit: Duration::from_millis(1), deadline_unit, partials: Default::default() }
}
fn http_route(origin: &str) -> Route {
    Route { settings: RewriteSettings { origin: origin.into(), ..Default::default() }, endpoint: Some(Endpoint { origin: origin.into(), headers: vec![], via_channel: false, channel_fallback: false }), local: None }
}
fn run_once(deps: &Deps, world: &World, route: &Route) -> Option<store::RunRow> {
    let admission = run::admit(deps, &world.db, route, SEED_FULL, "manual").unwrap_or_else(|e| panic!("{e:?}"));
    run::execute(deps, &admission, &Arc::new(AtomicBool::new(false)), &|_| {})
}
fn failed_with(row: &Option<store::RunRow>) -> (String, Option<String>, Option<String>) {
    let row = row.as_ref().unwrap();
    (row.state.clone(), row.failure_category.clone(), row.failure_detail.clone())
}
#[test]
fn a_short_meeting_is_one_full_request_and_lands_in_the_read_model() {
    let w = world();
    let segment = w.first_segment.clone();
    let fake = serve(ready(), move |_, r| Answer::Lines(200, vec![ACCEPTED.into(), r#"{"schema_version":1,"type":"progress","chars":5}"#.into(), result_line(r, &segment)]));
    let d = deps(&w, Duration::from_secs(1));
    let progress = Mutex::new(vec![]);
    let admission = run::admit(&d, &w.db, &http_route(&fake.origin), SEED_FULL, "manual").unwrap();
    let row = run::execute(&d, &admission, &Arc::new(AtomicBool::new(false)), &|p| progress.lock().unwrap().push(p)).unwrap();
    assert_eq!(row.state, "succeeded");
    let posts = fake.posts.lock().unwrap();
    assert_eq!(posts.len(), 1);
    assert_eq!(posts[0]["stage"], "full");
    assert_eq!(posts[0]["priority"], "background");
    assert_eq!(posts[0]["run_id"], upper(&row.id));
    assert_eq!(posts[0]["meeting"]["id"], upper(SEED_FULL));
    assert_eq!(posts[0]["meeting"]["language_policy"]["output"], "en");
    assert_eq!(posts[0]["meeting"]["title"], "Lamp prototype review");
    assert!(posts[0]["segments"][0]["id"].as_str().unwrap().chars().all(|c| !c.is_ascii_lowercase()));
    assert!(posts[0]["notes"].as_array().is_some());
    let model = crate::meetings::read_model(&w.db, SEED_FULL).unwrap().unwrap();
    assert_eq!(model.summary, "The team reviewed the prototype.");
    let (kind, model_name, prompts, version, path, requests): (String, String, String, String, String, i64) = w.db.conn.query_row("SELECT backend_kind, backend_model, prompt_versions, server_version, inference_path, request_count FROM analysis_runs WHERE id=?1", [&row.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?))).unwrap();
    assert_eq!((kind.as_str(), model_name.as_str(), prompts.as_str(), version.as_str(), path.as_str(), requests), ("fake", "qwen", "chunk=2,full=1", "9", "local", 1));
    let seen = progress.lock().unwrap();
    assert_eq!(seen.first().unwrap().as_ref().unwrap().0, "Analyzing");
    assert_eq!(seen.last().unwrap(), &None);
    assert!(seen.iter().flatten().any(|p| p.1 > 0.1));
    // The version the run stored is the one the page compares against, so the summary isn't stale.
    assert_eq!(current_version(&w.db, SEED_FULL).unwrap().unwrap(), row.evidence_version);
    assert!(!model.stale);
}
#[test]
fn a_long_meeting_chunks_then_combines_and_a_retry_reuses_the_chunks() {
    let w = world();
    let segment = w.first_segment.clone();
    let fail_next = Arc::new(AtomicBool::new(true));
    let flag = fail_next.clone();
    let fake = serve(limited(w.total_bytes / 2 + 1), move |_, r| {
        if r["stage"] == "synthesis" && flag.swap(false, Ordering::SeqCst) {
            return Answer::Lines(200, vec![r#"{"schema_version":1,"type":"error","code":"backend_error"}"#.into()]);
        }
        Answer::Lines(200, vec![result_line(r, &segment)])
    });
    let d = deps(&w, Duration::from_secs(1));
    let route = http_route(&fake.origin);
    let first = run_once(&d, &w, &route);
    assert_eq!(failed_with(&first), ("failed".into(), Some("backend_unavailable".into()), Some("backend_error".into())));
    let chunks = {
        let posts = fake.posts.lock().unwrap();
        let chunks = posts.iter().filter(|p| p["stage"] == "chunk").count();
        assert!(chunks >= 2);
        assert_eq!(posts[0]["chunk"], json!({"index": 0, "count": chunks}));
        assert!(posts[0].get("notes").is_none(), "notes ride the final synthesis only");
        let synthesis = posts.last().unwrap();
        assert_eq!(synthesis["partials"].as_array().unwrap().len(), chunks);
        assert_eq!(synthesis["partials"][0]["partial"], true, "forwarded unchanged");
        assert!(synthesis["notes"].as_array().is_some());
        assert!(synthesis.get("segments").is_none());
        chunks
    };
    assert_eq!(run_once(&d, &w, &route).unwrap().state, "succeeded");
    let posts = fake.posts.lock().unwrap();
    assert_eq!(posts.iter().filter(|p| p["stage"] == "chunk").count(), chunks, "no chunk asked twice");
    assert_eq!(posts.len(), chunks + 2);
    assert_eq!(d.partials.lock().unwrap().forget("not-it"), ());
}
#[test]
fn preemption_retries_the_same_request_three_times_then_fails_busy() {
    let w = world();
    let segment = w.first_segment.clone();
    let fake = serve(ready(), move |i, r| if i < 2 { Answer::Lines(200, vec![r#"{"schema_version":1,"type":"error","code":"preempted"}"#.into()]) } else { Answer::Lines(200, vec![result_line(r, &segment)]) });
    let d = deps(&w, Duration::from_secs(1));
    let row = run_once(&d, &w, &http_route(&fake.origin)).unwrap();
    assert_eq!(row.state, "succeeded");
    {
        let posts = fake.posts.lock().unwrap();
        assert_eq!(posts[0]["request_id"], posts[2]["request_id"]);
    }
    let totals: (i64, i64, i64) = w.db.conn.query_row("SELECT request_count, preemption_count, retry_count FROM analysis_runs WHERE id=?1", [&row.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
    assert_eq!(totals, (3, 2, 2));
    let fake = serve(ready(), |_, _| Answer::Lines(200, vec![r#"{"schema_version":1,"type":"error","code":"preempted"}"#.into()]));
    let row = run_once(&d, &w, &http_route(&fake.origin));
    assert_eq!(failed_with(&row), ("failed".into(), Some("backend_busy".into()), Some("preempted".into())));
    assert_eq!(fake.posts.lock().unwrap().len(), 4);
}
#[test]
fn bad_answers_fail_the_run_and_keep_the_old_summary_out() {
    let w = world();
    let d = deps(&w, Duration::from_secs(1));
    let cases: Vec<(Box<dyn Fn(&Value, &str) -> Vec<String> + Send + Sync>, &str, Option<&str>)> = vec![
        (Box::new(|_, _| vec![ACCEPTED.into()]), "malformed_response", Some("no_result")),
        (Box::new(|r, s| vec![result_line(r, s).replace(r["run_id"].as_str().unwrap(), "11111111-0000-4000-8000-000000000000")]), "malformed_response", Some("run_id")),
        (Box::new(|r, s| vec![result_line(r, s).replace("\"language\":\"en\"", "\"language\":\"sk\"")]), "malformed_response", Some("language_policy")),
        (Box::new(|r, _| vec![result_line(r, SEG_A)]), "source_validation", Some("unknown_segment")),
        (Box::new(|_, _| vec!["{not json".into()]), "malformed_response", None),
        (Box::new(|r, s| vec![result_line(r, s).replace("The team reviewed the prototype.", "It cost 4242 EUR today.")]), "protected_literal", None),
    ];
    for (answer, category, detail) in cases {
        let segment = w.first_segment.clone();
        let fake = serve(ready(), move |_, r| Answer::Lines(200, answer(r, &segment)));
        let row = run_once(&d, &w, &http_route(&fake.origin));
        assert_eq!(failed_with(&row), ("failed".into(), Some(category.to_string()), detail.map(String::from)));
    }
    assert!(crate::meetings::read_model(&w.db, SEED_FULL).unwrap().is_none());
}
#[test]
fn http_statuses_map_to_categories() {
    let w = world();
    let d = deps(&w, Duration::from_secs(1));
    for (status, body, category, detail) in [
        (429, "", "server_unavailable", Some("server_busy")),
        (401, "", "authentication_failed", None),
        (413, "", "too_long", None),
        (503, r#"{"error":{"code":"backend_unavailable"}}"#, "backend_unavailable", Some("backend_unavailable")),
        (500, "", "server_unreachable", None),
    ] {
        let fake = serve(ready(), move |_, _| Answer::Lines(status, vec![body.to_string()]));
        let row = run_once(&d, &w, &http_route(&fake.origin));
        assert_eq!(failed_with(&row), ("failed".into(), Some(category.to_string()), detail.map(String::from)), "{status}");
    }
}
#[test]
fn health_refuses_before_any_request() {
    let w = world();
    let d = deps(&w, Duration::from_secs(1));
    let mut stopped = ready();
    stopped["backend"]["state"] = json!("loading");
    let fake = serve(stopped, |_, _| Answer::Hang);
    let refused = run::admit(&d, &w.db, &http_route(&fake.origin), SEED_FULL, "manual").err().unwrap();
    assert!(matches!(refused, run::Stop::Failure(Failure { category: "backend_unavailable", detail: Some(ref s) }) if s == "loading"));
    assert!(store::latest_run(&w.db, SEED_FULL).unwrap().is_none(), "a refusal leaves no row");
    let mut future = ready();
    future["result_schema_version"] = json!(2);
    let fake = serve(future, |_, _| Answer::Hang);
    let admission = run::admit(&d, &w.db, &http_route(&fake.origin), SEED_FULL, "automatic").unwrap();
    let row = run::execute(&d, &admission, &Arc::new(AtomicBool::new(false)), &|_| {});
    assert_eq!(failed_with(&row).1.as_deref(), Some("unsupported_version"));
    assert!(fake.posts.lock().unwrap().is_empty());
}
#[test]
fn only_a_final_transcript_is_eligible_and_one_automatic_run_per_pass() {
    let w = world();
    let d = deps(&w, Duration::from_secs(1));
    let segment = w.first_segment.clone();
    let fake = serve(ready(), move |_, r| Answer::Lines(200, vec![result_line(r, &segment)]));
    let route = http_route(&fake.origin);
    assert_eq!(run_once(&d, &w, &route).unwrap().state, "succeeded");
    let again = run::admit(&d, &w.db, &route, SEED_FULL, "automatic").err().unwrap();
    assert!(matches!(again, run::Stop::Failure(Failure { category: "not_eligible", detail: Some(ref s) }) if s == "automatic_already_accepted"));
    w.db.conn.execute("UPDATE meeting_transcriptions SET state='finalizing' WHERE meeting_id=?1", [SEED_FULL]).unwrap();
    assert!(matches!(run::admit(&d, &w.db, &route, SEED_FULL, "manual").err().unwrap(), run::Stop::Failure(Failure { category: "not_eligible", detail: None })));
    let mut blocked = http_route("http://203.0.113.1:1");
    blocked.settings.credential_present = false;
    w.db.conn.execute("UPDATE meeting_transcriptions SET state='final' WHERE meeting_id=?1", [SEED_FULL]).unwrap();
    assert!(matches!(run::admit(&d, &w.db, &blocked, SEED_FULL, "manual").err().unwrap(), run::Stop::Failure(Failure { category: "server_unavailable", .. })), "plain http to another host stops in preflight");
    blocked.endpoint = None;
    blocked.settings = RewriteSettings { origin: fake.origin.clone(), ..Default::default() };
    assert!(matches!(run::admit(&d, &w.db, &blocked, SEED_FULL, "manual").err().unwrap(), run::Stop::Failure(Failure { category: "server_unavailable", detail: Some(_) })));
}
#[test]
fn evidence_that_changes_during_the_run_stops_it() {
    let w = world();
    let d = deps(&w, Duration::from_secs(1));
    let segment = w.first_segment.clone();
    let path = w.path.clone();
    let fake = serve(ready(), move |_, r| {
        Db::open(&path).unwrap().conn.execute("UPDATE meeting_notes SET text='Changed meanwhile' WHERE meeting_id=?1", [SEED_FULL]).unwrap();
        Answer::Lines(200, vec![result_line(r, &segment)])
    });
    let row = run_once(&d, &w, &http_route(&fake.origin));
    assert_eq!(failed_with(&row), ("failed".into(), Some("source_validation".into()), Some("evidence_changed".into())));
    assert!(crate::meetings::read_model(&w.db, SEED_FULL).unwrap().is_none());
}
#[test]
fn cancel_stops_a_request_in_flight() {
    let w = world();
    let d = deps(&w, Duration::from_secs(1));
    let fake = serve(ready(), |_, _| Answer::Hang);
    let admission = run::admit(&d, &w.db, &http_route(&fake.origin), SEED_FULL, "manual").unwrap();
    let cancel = Arc::new(AtomicBool::new(false));
    let flag = cancel.clone();
    let posts = fake.posts.clone();
    let setter = std::thread::spawn(move || {
        while posts.lock().unwrap().is_empty() {
            std::thread::sleep(Duration::from_millis(5));
        }
        flag.store(true, Ordering::SeqCst);
    });
    let started = Instant::now();
    assert_eq!(run::execute(&d, &admission, &cancel, &|_| {}), None);
    setter.join().unwrap();
    assert!(started.elapsed() < Duration::from_secs(5));
    assert_eq!(store::latest_run(&w.db, SEED_FULL).unwrap().unwrap().state, "cancelled");
}
#[test]
fn the_deadline_times_the_run_out() {
    let w = world();
    let d = deps(&w, Duration::from_millis(1)); // 300 ms a request, 360 ms a run
    let fake = serve(ready(), |_, _| Answer::Hang);
    let started = Instant::now();
    let row = run_once(&d, &w, &http_route(&fake.origin));
    assert_eq!(failed_with(&row), ("timed_out".into(), Some("timeout".into()), None));
    assert!(started.elapsed() < Duration::from_secs(5));
}
#[test]
fn an_unreachable_server_fails_the_row() {
    let w = world();
    let d = deps(&w, Duration::from_secs(1));
    let closed = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let route = http_route(&format!("http://{closed}"));
    let row = run_once(&d, &w, &route);
    assert_eq!(failed_with(&row).1.as_deref(), Some("server_unreachable"));
    assert!(!run::server_reachable(&d, &route));
}

// MARK: channel

use crate::remote::channel::{Channel, ChannelError, Purpose, Transports};
use crate::remote::pool::{Opener, Pool};
use crate::remote::scripted::{Counters, Reply, Script};

fn channel_pool(replies: Vec<Reply>) -> (Arc<Pool>, Counters) {
    let mut all = vec![Reply::ready()];
    all.extend(replies);
    let script = Script::new(all);
    let counters = script.counters();
    let open: Opener = Box::new(move || {
        let mut channel = Channel::new(script.open("ws://x").map_err(|_| ChannelError::Unreachable)?, &script.public_key())?;
        channel.open(Purpose::Session, Some("token"))?;
        Ok(channel)
    });
    (Arc::new(Pool::new(open, Box::new(|| Duration::ZERO))), counters)
}
fn channel_route() -> Route {
    Route { settings: RewriteSettings::routed_to_remote("https://mini.example.com".into()), endpoint: Some(Endpoint { origin: "https://mini.example.com".into(), headers: vec![], via_channel: true, channel_fallback: false }), local: None }
}
fn event(op: i64, e: Value) -> Reply {
    Reply::Json(json!({"schema_version": 1, "type": "analysis_event", "op": op, "event": e}))
}
#[test]
fn the_channel_carries_the_request_and_a_fragmented_result() {
    let w = world();
    let mut d = deps(&w, Duration::from_secs(1));
    // The result needs the run id, which isn't known yet, so it leaves it out.
    let source = json!({"kind": "segment", "id": w.first_segment});
    let line = json!({"schema_version": 1, "type": "result", "stage": "full", "analysis": {
        "schema_version": 1, "meeting_id": upper(SEED_FULL), "partial": false, "language": "en",
        "summary": {"text": "The team reviewed it.", "sources": [source], "whole_meeting": true},
        "topics": [], "decisions": [], "action_items": [], "next_steps": [], "open_questions": [], "risks": [],
    }})
    .to_string();
    let (head, tail) = line.split_at(40);
    let part = |index: i64, data: &str| Reply::Json(json!({"schema_version": 1, "type": "analysis_event_part", "op": 1, "index": index, "data": data}));
    let (pool, counters) = channel_pool(vec![
        Reply::After("analysis"),
        event(1, json!({"schema_version": 1, "type": "accepted"})),
        part(0, head),
        part(1, tail),
        Reply::Json(json!({"schema_version": 1, "type": "analysis_event", "op": 1, "parts": 2, "sha256": crate::history::sha256_hex(line.as_bytes())})),
    ]);
    d.pool = Some(pool);
    let row = run_once(&d, &w, &channel_route()).unwrap();
    assert_eq!(row.state, "succeeded", "{row:?}");
    let path: String = w.db.conn.query_row("SELECT inference_path FROM analysis_runs WHERE id=?1", [&row.id], |r| r.get(0)).unwrap();
    assert_eq!(path, "server");
    let messages = counters.messages();
    let parts: Vec<&Value> = messages.iter().filter(|m| m["type"] == "analysis_part").collect();
    let closing = messages.iter().find(|m| m["type"] == "analysis").unwrap();
    let body: String = parts.iter().map(|p| p["data"].as_str().unwrap()).collect();
    assert_eq!(closing["sha256"], crate::history::sha256_hex(body.as_bytes()));
    assert_eq!(closing["parts"], parts.len());
    let request: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(request["run_id"], upper(&row.id));
    assert_eq!(counters.closed(), 0, "a clean op keeps the channel");
}
#[test]
fn channel_errors_wait_for_the_server_or_refuse() {
    let w = world();
    let mut d = deps(&w, Duration::from_secs(1));
    for (code, category, detail) in [("busy", "server_unreachable", Some(run::WAITING_DETAIL)), ("worker_unavailable", "server_unreachable", Some(run::WAITING_DETAIL)), ("not_offered", "server_unavailable", Some("not_offered")), ("revoked", "authentication_failed", None), ("limit_exceeded", "too_long", None)] {
        let (pool, _) = channel_pool(vec![Reply::After("analysis"), Reply::error(code)]);
        d.pool = Some(pool);
        let row = run_once(&d, &w, &channel_route());
        assert_eq!(failed_with(&row), ("failed".into(), Some(category.to_string()), detail.map(String::from)), "{code}");
    }
    let (pool, _) = channel_pool(vec![Reply::After("analysis"), Reply::Json(json!({"schema_version": 1, "type": "analysis_event", "op": 1, "parts": 1, "sha256": "0".repeat(64)}))]);
    d.pool = Some(pool);
    assert_eq!(failed_with(&run_once(&d, &w, &channel_route())).1.as_deref(), Some("malformed_response"));
    let unreachable: Opener = Box::new(|| Err(ChannelError::Unreachable));
    d.pool = Some(Arc::new(Pool::new(unreachable, Box::new(|| Duration::ZERO))));
    assert_eq!(failed_with(&run_once(&d, &w, &channel_route())).2.as_deref(), Some(run::WAITING_DETAIL));
}
#[test]
fn a_custom_server_falls_back_to_the_channel_before_anything_commits() {
    let w = world();
    let mut d = deps(&w, Duration::from_secs(1));
    let source = json!({"kind": "segment", "id": w.first_segment});
    let result = json!({"schema_version": 1, "type": "result", "stage": "full", "analysis": {
        "schema_version": 1, "meeting_id": upper(SEED_FULL), "partial": false, "language": "en",
        "summary": {"text": "The team reviewed it.", "sources": [source], "whole_meeting": true},
        "topics": [], "decisions": [], "action_items": [], "next_steps": [], "open_questions": [], "risks": [],
    }});
    let (pool, counters) = channel_pool(vec![Reply::After("analysis"), event(1, result)]);
    d.pool = Some(pool);
    let fake = serve(ready(), |_, _| Answer::Lines(200, vec![ACCEPTED.into(), r#"{"schema_version":1,"type":"error","code":"backend_unavailable"}"#.into()]));
    let mut route = http_route(&fake.origin);
    {
        let endpoint = route.endpoint.as_mut().unwrap();
        endpoint.headers = vec![("X-LocalFlow-Primary-URL", "http://ai-vm:8000/v1".into()), ("X-LocalFlow-Primary-Model", "qwen".into()), ("X-LocalFlow-Primary-Only", "1".into())];
        endpoint.channel_fallback = true;
    }
    let row = run_once(&d, &w, &route).unwrap();
    assert_eq!(row.state, "succeeded", "{row:?}");
    let path: String = w.db.conn.query_row("SELECT inference_path FROM analysis_runs WHERE id=?1", [&row.id], |r| r.get(0)).unwrap();
    assert_eq!(path, "server");
    assert!(fake.headers.lock().unwrap()[0].to_lowercase().contains("x-localflow-primary-only: 1"));
    assert!(counters.messages().iter().any(|m| m["type"] == "analysis"));
    // Past a progress event a failure stands.
    let (pool, counters) = channel_pool(vec![]);
    d.pool = Some(pool);
    let fake = serve(ready(), |_, _| Answer::Lines(200, vec![r#"{"schema_version":1,"type":"progress","chars":1}"#.into(), r#"{"schema_version":1,"type":"error","code":"backend_error"}"#.into()]));
    let endpoint = route.endpoint.as_mut().unwrap();
    endpoint.origin = fake.origin.clone();
    route.settings.origin = fake.origin.clone();
    assert_eq!(failed_with(&run_once(&d, &w, &route)).1.as_deref(), Some("backend_unavailable"));
    assert_eq!(counters.opened(), 0);
}
#[test]
fn routes_follow_the_settings() {
    let mut p = crate::prefs::Prefs::memory();
    p.set("rewriteEndpoint", "http://127.0.0.1:8091".to_string());
    let plain = run::route(&p, |_| false, None);
    let endpoint = plain.endpoint.unwrap();
    assert!((endpoint.headers.is_empty(), endpoint.via_channel, plain.local.is_none()) == (true, false, true));
    p.set("summaryServer", "remote".to_string());
    p.set("summaryServerURL", "http://ai-vm:8000/v1".to_string());
    p.set("summaryServerModel", "qwen".to_string());
    let pinned = run::route(&p, |_| false, Some("k")).endpoint.unwrap();
    assert_eq!(pinned.headers.iter().map(|h| h.0).collect::<Vec<_>>(), ["X-LocalFlow-Primary-URL", "X-LocalFlow-Primary-Model", "X-LocalFlow-Primary-Key"]);
    p.set("rewriteEndpoint", "not a url".to_string());
    assert!(run::route(&p, |_| false, None).endpoint.is_none());
}

// MARK: queue

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let end = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < end, "never: {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}
#[test]
fn the_backoff_doubles_to_ten_minutes() {
    assert_eq!((0..7).map(waiting_delay).collect::<Vec<_>>(), [30, 60, 120, 240, 480, 600, 600]);
}
#[test]
fn a_request_runs_and_a_refusal_is_a_notice() {
    let w = world();
    let segment = w.first_segment.clone();
    let fake = serve(ready(), move |_, r| Answer::Lines(200, vec![result_line(r, &segment)]));
    let c = Coordinator::new(deps(&w, Duration::from_secs(1)));
    let route = http_route(&fake.origin);
    c.request(SEED_FULL, "manual", &route);
    wait_for("the run", || store::latest_run(&w.db, SEED_FULL).unwrap().is_some_and(|r| r.state == "succeeded") && !c.busy());
    assert!(c.drain_notices().is_empty());
    assert_eq!(c.status(SEED_FULL), None);
    let not_final = "22222222-2222-4222-8222-222222222222";
    c.request(not_final, "manual", &route);
    wait_for("the notice", || c.in_flight() == 0);
    assert_eq!(c.drain_notices(), [crate::meetings::analysis_failure_text("not_eligible")]);
    c.settled(not_final, &route);
    wait_for("quiet refusal", || c.in_flight() == 0);
    assert!(c.drain_notices().is_empty(), "an automatic refusal stays quiet");
}
#[test]
fn the_queue_runs_one_at_a_time_and_refuses_past_capacity() {
    let w = world();
    let c = Coordinator::new(deps(&w, Duration::from_secs(1)));
    let fake = serve(ready(), |_, _| Answer::Hang);
    let route = http_route(&fake.origin);
    c.request(SEED_FULL, "manual", &route);
    wait_for("running", || matches!(c.status(SEED_FULL), Some(Status::Running(_))));
    assert!(c.busy());
    c.request(SEED_FULL, "retry", &route);
    assert_eq!(c.in_flight(), 1, "deduplicated");
    for i in 0..99 {
        c.request(&format!("missing-{i}"), "automatic", &route);
    }
    c.request("one-too-many", "manual", &route);
    assert!(c.drain_notices().contains(&QUEUE_FULL.to_string()));
    wait_for("refusals to clear", || c.in_flight() == 1);
    c.cancel(&w.db, SEED_FULL);
    wait_for("the cancel", || !c.busy());
    assert_eq!(store::latest_run(&w.db, SEED_FULL).unwrap().unwrap().state, "cancelled");
}
#[test]
fn a_busy_server_gets_one_requeue_after_thirty_units() {
    let w = world();
    let c = Coordinator::new(deps(&w, Duration::from_secs(1)));
    let fake = serve(ready(), |_, _| Answer::Lines(429, vec![String::new()]));
    let route = http_route(&fake.origin);
    c.request(SEED_FULL, "manual", &route);
    wait_for("the failure", || !c.busy() && c.in_flight() == 0 && store::latest_run(&w.db, SEED_FULL).unwrap().is_some());
    assert!(!c.due(), "it waits first");
    assert_eq!(store::latest_run(&w.db, SEED_FULL).unwrap().unwrap().failure_detail.as_deref(), Some("server_busy"));
    let c = Coordinator::new(deps(&w, Duration::from_millis(1)));
    c.request(SEED_FULL, "manual", &route);
    wait_for("the due re-queue", || c.due());
    c.tick(&route);
    wait_for("the second failure", || fake.posts.lock().unwrap().len() == 3 && !c.busy() && c.in_flight() == 0);
    let last = store::latest_run(&w.db, SEED_FULL).unwrap().unwrap();
    assert_eq!((last.trigger.as_str(), last.state.as_str()), ("retry", "failed"));
    std::thread::sleep(Duration::from_millis(50));
    assert!(!c.due(), "a second busy answer stays failed");
}
#[test]
fn a_waiting_run_retries_with_backoff_and_when_the_server_returns() {
    let w = world();
    let mut d = deps(&w, Duration::from_secs(1));
    d.pool = Some(Arc::new(Pool::new(Box::new(|| Err(ChannelError::Unreachable)), Box::new(|| Duration::ZERO))));
    let c = Coordinator::new(d);
    let route = channel_route();
    c.request(SEED_FULL, "manual", &route);
    wait_for("waiting", || c.waiting().contains(SEED_FULL) && !c.busy());
    let first = store::latest_run(&w.db, SEED_FULL).unwrap().unwrap();
    assert_eq!(first.failure_detail.as_deref(), Some(run::WAITING_DETAIL));
    assert!(!c.due(), "30 s away");
    c.server_may_be_reachable(&route);
    wait_for("the second try", || store::latest_run(&w.db, SEED_FULL).unwrap().unwrap().id != first.id && !c.busy() && c.in_flight() == 0);
    assert_eq!(store::latest_run(&w.db, SEED_FULL).unwrap().unwrap().trigger, "retry");
    // Run on this Mac ends the wait and goes again; a request replaces it too.
    let second = store::latest_run(&w.db, SEED_FULL).unwrap().unwrap().id;
    c.run_locally(SEED_FULL, &route);
    wait_for("the local try", || store::latest_run(&w.db, SEED_FULL).unwrap().unwrap().id != second && !c.busy() && c.in_flight() == 0);
    c.run_locally("not-waiting", &route);
    assert_eq!(c.in_flight(), 0);
    c.cancel(&w.db, SEED_FULL);
    assert!(c.waiting().is_empty(), "cancel ends the wait");
}
#[test]
fn an_automatic_run_probes_then_requeues_once() {
    let w = world();
    let c = Coordinator::new(deps(&w, Duration::from_millis(1)));
    let segment = w.first_segment.clone();
    let closed = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    c.settled(SEED_FULL, &http_route(&format!("http://{closed}")));
    wait_for("the automatic failure", || c.due());
    assert_eq!(store::latest_run(&w.db, SEED_FULL).unwrap().unwrap().failure_category.as_deref(), Some("server_unreachable"));
    let fake = serve(ready(), move |_, r| Answer::Lines(200, vec![result_line(r, &segment)]));
    c.tick(&http_route(&fake.origin));
    wait_for("the run after the probe", || store::latest_run(&w.db, SEED_FULL).unwrap().unwrap().state == "succeeded" && !c.busy());
    assert_eq!(store::latest_run(&w.db, SEED_FULL).unwrap().unwrap().trigger, "automatic");
}
#[test]
fn not_offered_is_reported_once() {
    let w = world();
    let mut d = deps(&w, Duration::from_secs(1));
    let (pool, _) = channel_pool(vec![Reply::After("analysis"), Reply::error("not_offered")]);
    d.pool = Some(pool);
    let c = Coordinator::new(d);
    c.request(SEED_FULL, "manual", &channel_route());
    wait_for("the failure", || !c.busy() && c.in_flight() == 0 && store::latest_run(&w.db, SEED_FULL).unwrap().is_some());
    assert!(c.take_not_offered());
    assert!(!c.take_not_offered());
}
#[test]
fn deleting_a_meeting_stops_its_run() {
    let w = world();
    let c = Coordinator::new(deps(&w, Duration::from_secs(1)));
    let fake = serve(ready(), |_, _| Answer::Hang);
    c.request(SEED_FULL, "manual", &http_route(&fake.origin));
    wait_for("running", || matches!(c.status(SEED_FULL), Some(Status::Running(_))));
    c.will_delete(&w.db, SEED_FULL);
    wait_for("the stop", || !c.busy());
}

/// Against a real flowd, on a copy of a history database. Never point it at the live file.
/// `LOCALFLOW_E2E_DB=/tmp/copy/history.sqlite LOCALFLOW_E2E_MEETING=<id> LOCALFLOW_E2E_ORIGIN=http://127.0.0.1:8091
/// cargo test -p flow-core real_flowd -- --ignored --nocapture`. `LOCALFLOW_E2E_SECRET_ENV` names an
/// environment variable holding the bearer token, if the server wants one.
#[test]
#[ignore = "needs a running flowd and a copied database"]
fn real_flowd() {
    let var = |name: &str| std::env::var(name).unwrap_or_else(|_| panic!("set {name}"));
    let (path, meeting, origin) = (PathBuf::from(var("LOCALFLOW_E2E_DB")), var("LOCALFLOW_E2E_MEETING"), var("LOCALFLOW_E2E_ORIGIN"));
    assert!(!path.to_string_lossy().contains("Application Support"), "use a copy of the database");
    let secret = std::env::var("LOCALFLOW_E2E_SECRET_ENV").ok().and_then(|name| std::env::var(name).ok());
    let d = Deps { database: path.clone(), secret: Arc::new(move |_| secret.clone()), pool: None, wait_unit: Duration::from_secs(1), deadline_unit: Duration::from_secs(1), partials: Default::default() };
    let db = Db::open(&path).unwrap();
    let credential_present = std::env::var("LOCALFLOW_E2E_SECRET_ENV").is_ok();
    let mut route = http_route(&origin);
    route.settings.credential_present = credential_present;
    let admission = run::admit(&d, &db, &route, &meeting, "manual").unwrap_or_else(|e| panic!("refused: {e:?}"));
    let row = run::execute(&d, &admission, &Arc::new(AtomicBool::new(false)), &|p| eprintln!("{p:?}")).unwrap();
    eprintln!("{row:?}");
    assert_eq!(row.state, "succeeded");
    let model = crate::meetings::read_model(&db, &meeting).unwrap().unwrap();
    eprintln!("{}", model.summary);
}
