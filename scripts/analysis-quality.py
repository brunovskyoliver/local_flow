#!/usr/bin/env python3
"""Offline and live meeting-intelligence evaluator.

Offline mode reads `analysis-eval.json`, produced by
`AnalysisEvaluationExportTests` when `TEST_RUNNER_LOCALFLOW_ANALYSIS_EVAL_DIR`
is set, and reports the deterministic success criteria SC-001 through SC-006,
SC-013 and SC-014. Live mode (`--live`) posts each meeting fixture to a
running flowd's `POST /v1/analysis/meeting` and reports the same criteria on
the raw results. Semantic extraction quality requires human review; live prose
language and copy output remain explicitly unmeasured. The verdicts carry
adopted text; the report itself is content-free
— counts and case labels only. An optional `--output-dir` receives the report
JSON under 0700/0600 permissions, matching the export's private-directory
convention.
"""
import argparse
import http.client
import json
import os
import re
import sys
import uuid
from pathlib import Path
from urllib.parse import urlsplit

MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_CASES = 500
LIVE_TIMEOUT_SECONDS = 900
LIVE_MAX_LINE_BYTES = 4 * 1024 * 1024

BAD_SOURCE_RESPONSES = {"fabricated-segment", "cross-meeting-segment"}

# Expected prose language for each declared policy: `mixed` is Slovak prose
# with English technical terms kept (research R10).
EXPECTED_PROSE = {"sk": "sk", "en": "en", "mixed": "sk"}

# SC-013: identifiers, state words and confidence values never appear in
# copied output. "(owner unresolved)" is legitimate report prose, so only
# machine vocabulary is banned.
COPY_BANNED = re.compile(
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    r"|speaker_id|run_id|request_id|meeting_id"
    r"|\bconfidence\b|\bcertainty\b|\bdowngrade\b"
    r"|\bpossible match\b|\bstale\b|\bqueued\b"
    r"|\bsucceeded\b|\bsuperseded\b|\bcancelled\b|\btimed out\b)",
    re.IGNORECASE)


class Failure(Exception):
    pass


# Server `error` event codes → client failure categories (AnalysisRun.swift
# `forServerCode`), and pre-stream HTTP statuses (`forHTTPStatus`).
SERVER_CODES = {
    "unauthorized": "authentication_failed",
    "unsupported_version": "unsupported_version",
    "invalid_request": "malformed_response",
    "output_invalid": "malformed_response",
    "too_large": "too_long",
    "output_too_large": "oversized_response",
    "server_busy": "server_unavailable",
    "queue_timeout": "backend_busy",
    "preempted": "backend_busy",
    "backend_unavailable": "backend_unavailable",
    "backend_error": "backend_unavailable",
    "backend_timeout": "backend_timeout",
    "backend_first_token_timeout": "backend_timeout",
    "source_validation": "source_validation",
}
HTTP_CODES = {
    401: "authentication_failed", 403: "authentication_failed",
    404: "server_unavailable", 413: "too_long",
    429: "server_unavailable", 503: "backend_unavailable",
}


def build_request(fixture, run_id):
    """A `full`-stage wire request. `candidate_name_kept_local` is stripped —
    a Possible-match candidate's name never leaves the client."""
    notes = []
    for paragraph in (fixture.get("notes") or "").split("\n\n"):
        trimmed = paragraph.strip()
        if trimmed:
            notes.append({"id": f"note:{len(notes) + 1}", "text": trimmed})
    return {
        "schema_version": 1,
        "request_id": str(uuid.uuid4()).upper(),
        "run_id": run_id,
        "priority": "background",
        "stage": "full",
        "meeting": {
            "id": fixture["id"], "title": fixture["title"],
            "started_at": fixture["started_at"],
            "duration_ms": fixture["duration_ms"],
            "time_zone": fixture["time_zone"],
            "language_policy": {
                "output": fixture.get("expected_language") or "en",
                "preserve_terms": True,
            },
        },
        "participants": [
            {key: value for key, value in p.items()
             if key != "candidate_name_kept_local"}
            for p in fixture.get("participants") or []
        ],
        "segments": [
            {"id": s["id"], "start_ms": s["start_ms"], "end_ms": s["end_ms"],
             "speaker_id": s.get("speaker_id"), "text": s["normalized_text"]}
            for s in fixture.get("segments") or []
        ],
        "notes": notes,
    }


def live_verdict(fixture, endpoint, credential):
    """POST one fixture and fold the NDJSON stream into a verdict shaped like
    the XCTest export. The owner's certainty is checked against the fixture's
    participant list — a Possible/Unknown owner must be downgraded by the
    client, so the raw response can only reveal a violation, never hide one."""
    run_id = str(uuid.uuid4()).upper()
    request = build_request(fixture, run_id)
    body = json.dumps(request)
    candidates = [
        p["candidate_name_kept_local"]
        for p in fixture.get("participants") or []
        if p.get("candidate_name_kept_local")
    ]
    candidate_in_request = any(name in body for name in candidates)

    verdict = {
        "fixture": Path(fixture.get("_name", "fixture")).stem,
        "response": "live", "expect": "succeeded",
        "state": "failed", "failure": None, "language": None,
        "detectedLanguage": None,
        "expectedLanguage": fixture.get("expected_language"),
        "expectedTerms": fixture.get("expected_terms") or [],
        "expectedRelativeDates": fixture.get("expected_relative_dates") or {},
        "candidateNames": sorted(candidates),
        "candidateInRequest": candidate_in_request,
        "namedOwnerViolation": False,
        "summaryText": None, "items": [], "copyText": None,
    }

    url = urlsplit(endpoint)
    if url.scheme not in ("http", "https") or not url.hostname:
        raise Failure(f"bad endpoint {endpoint!r}")
    connection = (
        http.client.HTTPSConnection if url.scheme == "https"
        else http.client.HTTPConnection)(
            url.hostname, url.port, timeout=LIVE_TIMEOUT_SECONDS)
    headers = {"Content-Type": "application/json"}
    if credential:
        headers["Authorization"] = f"Bearer {credential}"
    base = url.path.rstrip("/")
    try:
        connection.request("POST", f"{base}/v1/analysis/meeting", body, headers)
        response = connection.getresponse()
        if response.status != 200:
            code = None
            try:
                error = json.loads(response.read(8192) or b"{}")
                code = (error.get("error") or {}).get("code")
            except ValueError:
                pass
            verdict["failure"] = (
                SERVER_CODES.get(code) if code
                else HTTP_CODES.get(response.status, "server_unreachable"))
            return verdict

        result = None
        while True:
            line = response.readline(LIVE_MAX_LINE_BYTES + 1)
            if not line:
                break
            if len(line) > LIVE_MAX_LINE_BYTES:
                verdict["failure"] = "oversized_response"
                return verdict
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                verdict["failure"] = "malformed_response"
                return verdict
            if event.get("type") == "error":
                verdict["failure"] = SERVER_CODES.get(
                    event.get("code"), "malformed_response")
                return verdict
            if event.get("type") == "result":
                result = event
    except OSError:
        verdict["failure"] = "server_unreachable"
        return verdict
    finally:
        connection.close()

    if result is None:
        verdict["failure"] = "malformed_response"
        return verdict
    analysis = result.get("analysis")
    if not isinstance(analysis, dict):
        verdict["failure"] = "malformed_response"
        return verdict
    if analysis.get("meeting_id", "").lower() != fixture["id"].lower():
        verdict["failure"] = "meeting_mismatch"
        return verdict

    verdict["state"] = "succeeded"
    verdict["language"] = analysis.get("language")
    summary = analysis.get("summary") or {}
    verdict["summaryText"] = summary.get("text")

    certainty = {
        p["speaker_id"]: p.get("certainty")
        for p in fixture.get("participants") or []
    }
    kinds = (("decisions", "decision"), ("action_items", "action"),
             ("next_steps", "next_step"), ("open_questions", "open_question"),
             ("risks", "risk"))
    for field, kind in kinds:
        for item in analysis.get(field) or []:
            row = {"kind": kind, "text": item.get("text"),
                   "sources": len(item.get("sources") or [])}
            if field == "action_items":
                owner = item.get("owner") or {}
                if owner.get("kind") == "participant":
                    owner_certainty = certainty.get(owner.get("speaker_id"))
                    row["ownerCertainty"] = owner_certainty
                    if owner_certainty in ("possible", "unknown"):
                        verdict["namedOwnerViolation"] = True
                elif owner.get("kind") == "mentioned":
                    row["ownerCertainty"] = "mentioned"
                due = item.get("due") or {}
                row["dueState"] = due.get("state")
                row["dueDate"] = due.get("date")
                row["dueOriginal"] = due.get("original")
            verdict["items"].append(row)
    return verdict


def load_cases(path):
    if path.stat().st_size > MAX_INPUT_BYTES:
        raise Failure("input too large")
    try:
        data = json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, UnicodeError) as exc:
        raise Failure(f"malformed input: {exc}") from None
    if not isinstance(data, list) or len(data) > MAX_CASES:
        raise Failure("expected a bounded list of verdicts")
    for case in data:
        if not isinstance(case, dict) or not isinstance(case.get("response"), str):
            raise Failure("malformed verdict")
    return data


def text_of(case):
    parts = [case.get("summaryText") or ""]
    parts += [i.get("text") or "" for i in case.get("items") or []]
    return " ".join(parts)


def evaluate(cases):
    report = {}
    violations = {}
    unmeasured = {}

    def unknown(sc, case, reason):
        unmeasured.setdefault(sc, []).append(
            f"{case.get('fixture', '?')}/{case['response']}: {reason}")

    def add(sc, case, note):
        violations.setdefault(sc, []).append(
            f"{case.get('fixture','?')}/{case['response']}: {note}")

    for case in cases:
        expect, state = case.get("expect"), case.get("state")
        failure = case.get("failure")
        succeeded = state == "succeeded"
        items = case.get("items") or []

        # SC-001: every case ends accepted or in its categorized failure.
        if expect == "succeeded":
            if not succeeded:
                add("SC-001", case, f"expected success, got {state}/{failure}")
        elif failure != expect:
            add("SC-001", case, f"expected {expect}, got {state}/{failure}")

        # SC-002: no Possible/Unknown name reaches owners or the wire.
        if case.get("candidateInRequest"):
            add("SC-002", case, "candidate name in request")
        if case.get("namedOwnerViolation"):
            add("SC-002", case, "Possible/Unknown participant named as owner")

        # SC-003: every accepted item carries a source; bad-source cases fail.
        if case.get("response") in BAD_SOURCE_RESPONSES and succeeded:
            add("SC-003", case, "fabricated/cross-meeting source accepted")
        if succeeded:
            for item in items:
                if (item.get("sources") or 0) < 1:
                    add("SC-003", case, f"item without source: kind={item.get('kind')}")
                    break

        # SC-004: a protected-literal mutation never passes validation.
        if case.get("response", "").startswith("mutated-") and succeeded:
            if (case.get("droppedLiteralCount") or 0) < 1:
                add("SC-004", case, "mutation adopted without a literal drop")

        # SC-005: an unresolved or absent due never carries a date.
        for item in items:
            if item.get("dueState") in ("unresolved", "absent") and item.get("dueDate"):
                add("SC-005", case, f"date on {item['dueState']} due")

        if succeeded:
            expected_dates = case.get("expectedRelativeDates") or {}
            for phrase, date in expected_dates.items():
                matching = [i for i in items if i.get("dueOriginal") == phrase]
                if not matching or any(
                        i.get("dueState") != "explicit_relative_resolved"
                        or i.get("dueDate") != date for i in matching):
                    add("SC-005", case, "missing or incorrect expected relative date")
            if any(i.get("dueState") == "explicit_relative_resolved"
                   and i.get("dueOriginal") not in expected_dates for i in items):
                unknown("SC-005", case, "relative date has no fixture expectation")

        # SC-006 requires semantic review of omissions, unsupported claims and
        # proposals. Drop counters do not measure any of those requirements.
        unknown("SC-006", case, "requires human review of extraction and support")

        # SC-013: copied output carries no identifiers or state words.
        copy_text = case.get("copyText")
        if copy_text is None:
            unknown("SC-013", case, "no client copy output")
        else:
            hits = sorted(set(m.group(0).lower() for m in COPY_BANNED.finditer(copy_text)))
            if hits:
                add("SC-013", case, f"banned strings in copy text: {','.join(hits)}")

        # SC-014: prose in the expected language, expected terms preserved.
        expected = case.get("expectedLanguage")
        if expected and succeeded:
            # A model's language label is not a measurement of its prose.
            detected = case.get("detectedLanguage")
            if not detected:
                unknown("SC-014", case, "prose language requires detection or review")
            elif detected != EXPECTED_PROSE.get(expected, expected):
                add("SC-014", case,
                    f"prose {detected} != expected {expected}")
            text = text_of(case).lower()
            for term in case.get("expectedTerms") or []:
                # Sentence-initial capitalization is not a mutation.
                if term.lower() not in text:
                    add("SC-014", case, f"missing term {term!r}")

    for sc in ("SC-001", "SC-002", "SC-003", "SC-004", "SC-005", "SC-006",
               "SC-013", "SC-014"):
        found = violations.get(sc, [])
        missing = unmeasured.get(sc, [])
        measured = len(cases) - len(missing)
        report[sc] = {"cases": measured, "violations": len(found),
                      "details": found, "unmeasured": len(missing),
                      "unmeasuredDetails": missing,
                      "status": ("unmeasured" if measured == 0 else
                                 "partial" if missing else "checked")}
    return report


def load_fixtures(fixture_dir):
    fixtures = []
    for path in sorted(Path(fixture_dir).glob("*.json")):
        fixture = json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if not isinstance(fixture.get("id"), str) or not isinstance(
                fixture.get("segments"), list):
            continue  # not a meeting fixture (e.g. the README's JSON snippets)
        fixture["_name"] = path.name
        fixtures.append(fixture)
    if len(fixtures) > MAX_CASES:
        raise Failure("too many fixtures")
    return fixtures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("eval_json", type=Path, nargs="?",
                        help="analysis-eval.json written by the export test")
    parser.add_argument("--live", action="store_true",
                        help="post meeting fixtures to a running flowd")
    parser.add_argument("--endpoint",
                        help="flowd base URL for --live, e.g. http://127.0.0.1:8080")
    parser.add_argument("--credential-env",
                        help="environment variable holding the flowd credential")
    parser.add_argument("--fixture-dir", type=Path,
                        default=Path(__file__).parent.parent / "fixtures" / "intelligence")
    parser.add_argument("--output-dir", type=Path,
                        help="private directory for analysis-quality-report.json")
    args = parser.parse_args()

    try:
        if args.live:
            if not args.endpoint:
                raise Failure("--live needs --endpoint")
            credential = os.environ.get(args.credential_env) if args.credential_env else None
            if args.credential_env and not credential:
                raise Failure(f"{args.credential_env} is not set")
            cases = []
            for fixture in load_fixtures(args.fixture_dir):
                verdict = live_verdict(fixture, args.endpoint, credential)
                cases.append(verdict)
                print(f"{verdict['fixture']}: {verdict['state']}"
                      + (f"/{verdict['failure']}" if verdict['failure'] else ""),
                      file=sys.stderr)
            if args.output_dir:
                args.output_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
                os.chmod(args.output_dir, 0o700)
                out = args.output_dir / "analysis-eval.json"
                out.write_text(json.dumps(cases, indent=2, sort_keys=True) + "\n",
                               encoding="utf-8")
                os.chmod(out, 0o600)
        else:
            if not args.eval_json:
                raise Failure("offline mode needs the eval JSON path")
            cases = load_cases(args.eval_json)
    except (OSError, ValueError, Failure) as exc:
        print(f"analysis-quality: {exc}", file=sys.stderr)
        return 2

    report = evaluate(cases)
    total = sum(r["violations"] for r in report.values())
    for sc, r in report.items():
        print(f"{sc}: {r['cases']} checked, {r['violations']} violations, "
              f"{r['unmeasured']} unmeasured ({r['status']})")
        for detail in r["details"]:
            print(f"  - {detail}")
    print(f"total: {len(cases)} cases, {total} violations; "
          "unmeasured criteria still require acceptance review")

    if args.output_dir:
        args.output_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(args.output_dir, 0o700)
        out = args.output_dir / "analysis-quality-report.json"
        out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n",
                       encoding="utf-8")
        os.chmod(out, 0o600)

    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
