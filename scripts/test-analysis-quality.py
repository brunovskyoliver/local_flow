#!/usr/bin/env python3
"""Offline regression tests for analysis-quality.py; never contacts a model."""
import http.server
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location(
    "analysis_quality", Path(__file__).with_name("analysis-quality.py"))
aq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aq)


def case(**overrides):
    verdict = {
        "fixture": "deployment", "response": "deployment-valid",
        "expect": "succeeded", "state": "succeeded", "failure": None,
        "language": "en", "itemCount": 4, "droppedLiteralCount": 0,
        "droppedUnsupportedCount": 0, "identityDowngradeCount": 0,
        "unresolvedOwnerCount": 0, "detectedLanguage": "en",
        "expectedLanguage": "en", "expectedTerms": [],
        "candidateNames": [], "candidateInRequest": False,
        "namedOwnerViolation": False,
        "summaryText": "The team settled the deployment.",
        "items": [{"kind": "action", "text": "Prepare the backup",
                   "sources": 1}],
        "copyText": "Deployment sync\n\nSummary\nThe team settled the deployment.",
    }
    verdict.update(overrides)
    return verdict


class LoadTests(unittest.TestCase):
    def write(self, payload):
        handle = tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False)
        json.dump(payload, handle)
        handle.close()
        return Path(handle.name)

    def test_load_cases_bounds_input(self):
        self.assertEqual(aq.load_cases(self.write([case()]))[0]["response"],
                         "deployment-valid")
        for payload in ({"a": 1}, [1], [{"no_response": True}]):
            with self.assertRaises(aq.Failure):
                aq.load_cases(self.write(payload))

    def test_load_cases_rejects_malformed(self):
        handle = tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False)
        handle.write('{"x": NaN}')
        handle.close()
        with self.assertRaises(aq.Failure):
            aq.load_cases(Path(handle.name))


class EvaluateTests(unittest.TestCase):
    def violations(self, *cases):
        report = aq.evaluate(list(cases))
        return {sc: r["violations"] for sc, r in report.items()}

    def test_clean_run_has_no_violations(self):
        counts = self.violations(case())
        self.assertTrue(all(v == 0 for v in counts.values()))

    def test_sc001_outcome_mismatch(self):
        counts = self.violations(
            case(state="failed", failure="timeout"),
            case(expect="over_cap", state="failed", failure="timeout"))
        self.assertEqual(counts["SC-001"], 2)

    def test_sc002_candidate_and_named_owner(self):
        counts = self.violations(
            case(candidateInRequest=True),
            case(namedOwnerViolation=True))
        self.assertEqual(counts["SC-002"], 2)

    def test_sc003_sourceless_item_and_accepted_bad_source(self):
        counts = self.violations(
            case(items=[{"kind": "decision", "text": "x", "sources": 0}]),
            case(response="fabricated-segment", expect="succeeded"))
        self.assertEqual(counts["SC-003"], 2)

    def test_sc004_mutation_without_drop(self):
        counts = self.violations(
            case(response="mutated-ip-item", droppedLiteralCount=0),
            case(response="mutated-ip-item", droppedLiteralCount=1))
        self.assertEqual(counts["SC-004"], 1)

    def test_sc005_date_on_unresolved_due(self):
        counts = self.violations(
            case(items=[{"kind": "action", "text": "x", "sources": 1,
                         "dueState": "unresolved", "dueDate": "2026-09-21"}]))
        self.assertEqual(counts["SC-005"], 1)

    def test_sc005_wrong_relative_date(self):
        counts = self.violations(case(
            expectedRelativeDates={"tomorrow": "2026-09-21"},
            items=[{"kind": "action", "text": "Send it tomorrow", "sources": 1,
                    "dueState": "explicit_relative_resolved",
                    "dueOriginal": "tomorrow", "dueDate": "2030-01-01"}]))
        self.assertEqual(counts["SC-005"], 1)

    def test_sc005_missing_expected_date(self):
        counts = self.violations(case(
            expectedRelativeDates={"tomorrow": "2026-09-21"}, items=[]))
        self.assertEqual(counts["SC-005"], 1)

    def test_sc006_requires_human_review(self):
        report = aq.evaluate([case(items=[])])["SC-006"]
        self.assertEqual(report["status"], "unmeasured")
        self.assertEqual(report["cases"], 0)
        self.assertEqual(report["unmeasured"], 1)

    def test_live_language_metadata_is_not_a_prose_measurement(self):
        report = aq.evaluate([case(
            expectedLanguage="mixed", language="mixed", detectedLanguage=None,
            summaryText="Dohodli sme sa na nasadení.")])["SC-014"]
        self.assertEqual(report["violations"], 0)
        self.assertEqual(report["status"], "unmeasured")

    def test_sc013_banned_strings(self):
        counts = self.violations(
            case(copyText="run_id 9f0e certainty: possible"),
            case(copyText="Call the customer — (owner unresolved)"))
        self.assertEqual(counts["SC-013"], 1)

    def test_sc014_language_and_terms(self):
        counts = self.violations(
            case(expectedLanguage="sk", detectedLanguage="en"),
            case(expectedLanguage="mixed", detectedLanguage="sk",
                 expectedTerms=["deployment", "backup", "M6"],
                 summaryText="Deployment posunieme, backup hotový."),
            case(expectedLanguage="mixed", detectedLanguage="sk",
                 expectedTerms=["deployment"], summaryText="No terms here."))
        self.assertEqual(counts["SC-014"], 3)

    def test_mixed_expected_prose_is_slovak(self):
        counts = self.violations(
            case(expectedLanguage="mixed", detectedLanguage="en"))
        self.assertEqual(counts["SC-014"], 1)


FIXTURE = {
    "id": "66666666-6666-4666-8666-666666666666",
    "title": "Check", "started_at": "2026-09-20T09:00:00+02:00",
    "duration_ms": 120000, "time_zone": "Europe/Bratislava",
    "expected_language": "en", "expected_terms": [],
    "participants": [
        {"speaker_id": "aaaa0001-0000-4000-8000-000000000001",
         "certainty": "possible", "origin": "automatic_match",
         "candidate_name_kept_local": "Tomáš Juríček"},
        {"speaker_id": "aaaa0002-0000-4000-8000-000000000002",
         "certainty": "confirmed", "origin": "user_confirmation",
         "known_speaker_id": "bbbb0002-0000-4000-8000-000000000002",
         "name": "Oliver"}],
    "segments": [{"id": "aaaa0009-0000-4000-8000-000000000009",
                  "ordinal": 0, "start_ms": 0, "end_ms": 1000,
                  "speaker_id": "aaaa0002-0000-4000-8000-000000000002",
                  "normalized_text": "We deploy on Monday."}],
    "notes": "First paragraph.\n\nSecond paragraph.",
}


class LiveModeTests(unittest.TestCase):
    def test_build_request_strips_candidates_and_numbers_notes(self):
        fixture = dict(FIXTURE)
        request = aq.build_request(fixture, "RUN")
        self.assertNotIn("Tomáš Juríček", json.dumps(request))
        self.assertNotIn("candidate_name_kept_local",
                         json.dumps(request["participants"]))
        self.assertEqual([n["id"] for n in request["notes"]],
                         ["note:1", "note:2"])
        self.assertEqual(request["priority"], "background")
        self.assertEqual(request["stage"], "full")
        self.assertEqual(
            request["meeting"]["language_policy"],
            {"output": "en", "preserve_terms": True})
        self.assertEqual(request["segments"][0]["text"],
                         "We deploy on Monday.")

    def serve(self, lines):
        self.handler_cls = self.make_handler(lines)
        server = http.server.HTTPServer(("127.0.0.1", 0), self.handler_cls)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}"

    @staticmethod
    def make_handler(lines):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                Handler.request_body = self.rfile.read(length)
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ndjson")
                self.end_headers()
                for line in lines:
                    self.wfile.write(line.encode() + b"\n")

            def log_message(self, *args):
                pass

        Handler.request_body = None
        return Handler

    def result_line(self):
        return json.dumps({
            "schema_version": 1, "type": "result", "request_id": "x",
            "run_id": "x", "stage": "full",
            "server": {"name": "flowd", "version": "0"},
            "backend": {"kind": "test", "model": "test"},
            "prompt_version": 1, "pipeline_version": "a",
            "timing": {}, "preemptions": 0,
            "analysis": {
                "schema_version": 1, "meeting_id": FIXTURE["id"],
                "partial": False, "language": "en",
                "summary": {"text": "Deploys Monday.",
                            "sources": [], "whole_meeting": True},
                "topics": [], "decisions": [],
                "action_items": [{
                    "text": "Deploy on Monday",
                    "owner": {"kind": "participant",
                              "speaker_id": "aaaa0001-0000-4000-8000-000000000001"},
                    "ownership_state": "explicit",
                    "due": {"state": "unresolved", "date": "2026-09-21"},
                    "sources": [{"kind": "segment",
                                 "id": "aaaa0009-0000-4000-8000-000000000009"}]}],
                "next_steps": [], "open_questions": [], "risks": []}})

    def test_live_verdict_maps_result_and_owner(self):
        endpoint = self.serve([
            json.dumps({"type": "accepted", "request_id": "x"}),
            self.result_line()])
        fixture = dict(FIXTURE, _name="deployment.json")
        verdict = aq.live_verdict(fixture, endpoint, None)
        self.assertEqual(verdict["state"], "succeeded")
        self.assertEqual(verdict["language"], "en")
        # The Possible-match participant was named — a client-side violation.
        self.assertTrue(verdict["namedOwnerViolation"])
        self.assertEqual(verdict["items"][0]["dueState"], "unresolved")
        self.assertEqual(verdict["items"][0]["dueDate"], "2026-09-21")
        # The posted request never carried the candidate name.
        self.assertNotIn("Jur", self.handler_cls.request_body.decode())

    def test_live_verdict_maps_error_codes(self):
        for code, expected in (("server_busy", "server_unavailable"),
                               ("preempted", "backend_busy"),
                               ("unauthorized", "authentication_failed")):
            endpoint = self.serve([json.dumps(
                {"type": "error", "code": code})])
            verdict = aq.live_verdict(dict(FIXTURE), endpoint, None)
            self.assertEqual(verdict["failure"], expected)


if __name__ == "__main__":
    unittest.main()
