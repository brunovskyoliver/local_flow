#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("accuracy", Path(__file__).with_name("dictation-accuracy.py"))
accuracy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(accuracy)


class AccuracyTests(unittest.TestCase):
    def test_acceptance_command_fails_and_review_requires_a_human(self):
        fixture = {"id": "a", "group": "mixed", "reference": "one two", "num_samples": 2,
                   "synthetic": True, "acceptance_eligible": False}
        result = {"id": "a", "text": "one two", "samples": 2, "incomplete": True}
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            manifest, results, report, review = [root / name for name in ("manifest.json", "results.json", "report.json", "review.json")]
            manifest.write_text(json.dumps({"schema_version": 1, "fixtures": [fixture]}))
            results.write_text(json.dumps([result]))
            command = [sys.executable, str(Path(__file__).with_name("dictation-accuracy.py")),
                       str(manifest), str(results), str(report), "--require-acceptance", "--review-output", str(review)]
            run = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(run.returncode, 1, run.stderr)
            worksheet = json.loads(review.read_text())
            self.assertEqual(worksheet[0]["meaning_review"]["reviewer"], "")
            self.assertIsNone(worksheet[0]["meaning_review"]["preserved"])
            self.assertEqual(review.stat().st_mode & 0o777, 0o600)
            self.assertFalse(accuracy.score(json.loads(manifest.read_text()), worksheet)["fixtures"][0]["meaning_reviewed"])
            review.write_text("human work in progress")
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 2)
            self.assertEqual(review.read_text(), "human work in progress")
            fixtures, accepted = [], []
            digest = hashlib.sha256(b"one two").hexdigest()
            for group in ("sk", "en", "mixed"):
                for index in range(10):
                    identifier = f"{group}-{index}"
                    fixtures.append({**fixture, "id": identifier, "group": group,
                                     "synthetic": False, "acceptance_eligible": True})
                    accepted.append({**result, "id": identifier, "incomplete": False,
                                     "meaning_review": {"reviewer": "test reviewer", "preserved": True,
                                                        "text_sha256": digest, "reference_sha256": digest}})
            manifest.write_text(json.dumps({"schema_version": 1, "fixtures": fixtures}))
            results.write_text(json.dumps(accepted))
            self.assertEqual(subprocess.run(command[:-2], capture_output=True).returncode, 0)

    def test_normalization_preserves_diacritics(self):
        self.assertEqual(accuracy.words("  ŽLTÝ,  ko\u0302ň! "), ["žltý", "kôň"])
        self.assertNotEqual(accuracy.words("kôň"), accuracy.words("kon"))

    def test_edits_include_insert_delete_substitute(self):
        self.assertEqual(accuracy.distance(["a", "b", "c"], ["a", "x", "c", "d"]), 2)
        self.assertEqual(accuracy.distance(["a", "b"], []), 2)

    def test_aggregate_and_synthetic_gate(self):
        fixtures = [{"id": str(i), "group": "mixed", "reference": "one two", "num_samples": 2,
                     "synthetic": True, "acceptance_eligible": False} for i in range(10)]
        results = [{"id": str(i), "text": "one two", "samples": 2, "incomplete": False} for i in range(10)]
        fixtures[0]["reference"] = "one two three four"
        report = accuracy.score({"schema_version": 1, "fixtures": fixtures}, results)
        self.assertEqual(report["groups"]["mixed"]["wer"], 2 / 22)
        self.assertFalse(report["groups"]["mixed"]["acceptance_pass"])
        self.assertFalse(report["groups"]["en"]["acceptance_pass"])

    def test_numeric_success_does_not_replace_meaning_review(self):
        fixtures = [{"id": str(i), "group": "en", "reference": "one two", "num_samples": 2,
                     "synthetic": False, "acceptance_eligible": True} for i in range(10)]
        results = [{"id": str(i), "text": "one two", "samples": 2, "incomplete": False} for i in range(10)]
        report = accuracy.score({"schema_version": 1, "fixtures": fixtures}, results)
        self.assertTrue(report["groups"]["en"]["passes_numeric_threshold"])
        self.assertFalse(report["groups"]["en"]["acceptance_pass"])

    def test_meaning_verdict_is_bound_to_output_and_reference(self):
        fixtures = [{"id": str(i), "group": "en", "reference": "one two", "num_samples": 2,
                     "synthetic": False, "acceptance_eligible": True} for i in range(10)]
        digest = hashlib.sha256(b"one two").hexdigest()
        results = [{"id": str(i), "text": "one two", "samples": 2, "incomplete": False,
                    "meaning_review": {"reviewer": "test", "preserved": True,
                                       "text_sha256": digest, "reference_sha256": digest}} for i in range(10)]
        manifest = {"schema_version": 1, "fixtures": fixtures}
        self.assertTrue(accuracy.score(manifest, results)["groups"]["en"]["acceptance_pass"])
        results[0]["text"] = "one two!"
        self.assertFalse(accuracy.score(manifest, results)["groups"]["en"]["acceptance_pass"])
        results[0]["text"] = "one two"
        fixtures[0]["reference"] = "one two!"
        self.assertFalse(accuracy.score(manifest, results)["groups"]["en"]["acceptance_pass"])

    def test_missing_and_duplicate_results_rejected(self):
        fixture = {"id": "a"}
        manifest = {"schema_version": 1, "fixtures": [fixture]}
        with self.assertRaises(ValueError):
            accuracy.score(manifest, [])
        with self.assertRaises(ValueError):
            accuracy.score(manifest, [{"id": "a"}, {"id": "a"}])


if __name__ == "__main__":
    unittest.main()
