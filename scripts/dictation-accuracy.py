#!/usr/bin/env python3
"""Score explicit local speech results; never print reference or recognized text."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import unicodedata


def words(text):
    normalized = unicodedata.normalize("NFC", text).lower()
    return "".join(c for c in normalized if not unicodedata.category(c).startswith("P")).split()


def distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, word in enumerate(reference, 1):
        current = [i]
        for j, other in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (word != other)))
        previous = current
    return previous[-1]


def score(manifest, results):
    fixtures = manifest["fixtures"]
    if manifest.get("schema_version") != 1 or not 1 <= len(fixtures) <= 30:
        raise ValueError("unsupported manifest or fixture count")
    indexed = {result["id"]: result for result in results}
    if len(indexed) != len(results) or len({f["id"] for f in fixtures}) != len(fixtures):
        raise ValueError("duplicate fixture/result IDs")
    if set(indexed) != {f["id"] for f in fixtures}:
        raise ValueError("missing or unexpected results")
    rows = []
    for fixture in fixtures:
        result = indexed[fixture["id"]]
        if fixture["group"] not in ("sk", "en", "mixed"):
            raise ValueError("unknown fixture group")
        reference, hypothesis = words(fixture["reference"]), words(result["text"])
        if not reference or len(reference) > 16384 or len(hypothesis) > 16384:
            raise ValueError("empty reference or text exceeds bounded scoring capacity")
        if result["samples"] != fixture["num_samples"]:
            raise ValueError("sample count mismatch")
        review = result.get("meaning_review", {})
        reviewed = (bool(review.get("reviewer")) and
                    review.get("text_sha256") == hashlib.sha256(result["text"].encode()).hexdigest() and
                    review.get("reference_sha256") == hashlib.sha256(fixture["reference"].encode()).hexdigest())
        preserved = reviewed and review.get("preserved") is True
        errors = distance(reference, hypothesis)
        rows.append({"id": fixture["id"], "group": fixture["group"],
                     "reference_words": len(reference), "errors": errors, "wer": errors / len(reference),
                     "nonempty": bool(hypothesis), "incomplete": result["incomplete"],
                     "synthetic": fixture["synthetic"], "acceptance_eligible": fixture["acceptance_eligible"],
                     "meaning_reviewed": reviewed, "meaning_preserved": preserved})
    groups = {}
    for group in ("sk", "en", "mixed"):
        subset = [row for row in rows if row["group"] == group]
        count = sum(row["reference_words"] for row in subset)
        errors = sum(row["errors"] for row in subset)
        wer = errors / count if count else None
        eligible = len(subset) == 10 and all(row["acceptance_eligible"] and not row["synthetic"] for row in subset)
        complete = all(row["nonempty"] and not row["incomplete"] for row in subset)
        reviewed = bool(subset) and all(row["meaning_reviewed"] for row in subset)
        preserved = bool(subset) and all(row["meaning_preserved"] for row in subset)
        groups[group] = {"count": len(subset), "reference_words": count, "errors": errors,
                         "wer": wer, "eligible": eligible, "complete": complete, "meaning_reviewed": reviewed, "meaning_preserved": preserved,
                         "passes_numeric_threshold": wer is not None and wer <= .15,
                         "acceptance_pass": eligible and complete and preserved and wer is not None and wer <= .15}
    return {"schema_version": 1, "normalization": "NFC, lowercase, remove Unicode punctuation, collapse whitespace; retain diacritics",
            "fixtures": rows, "groups": groups,
            "limitations": ["WER does not establish meaning preservation; human review remains required.",
                            "Concatenated language-switch stress fixtures do not establish genuine mixed-speaker acceptance.",
                            "Eligibility depends on the manifest's source, license and consent evidence."]}


def read_bounded(path):
    if path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("JSON exceeds 4 MiB")
    return json.loads(path.read_text())


def meaning_worksheet(manifest, results):
    """Prepare exact-output human review without inventing any verdicts."""
    score(manifest, results)  # Reject mismatched IDs/sample counts before exporting text.
    indexed = {result["id"]: result for result in results}
    return [{"id": fixture["id"], "reference": fixture["reference"],
             **indexed[fixture["id"]],
             "meaning_review": {
                 "reviewer": "", "preserved": None, "notes": "",
                 "text_sha256": hashlib.sha256(indexed[fixture["id"]]["text"].encode()).hexdigest(),
                 "reference_sha256": hashlib.sha256(fixture["reference"].encode()).hexdigest()
             }} for fixture in manifest["fixtures"]]


def write_private(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("results", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--require-acceptance", action="store_true",
                        help="Exit 1 unless all three groups pass every acceptance gate.")
    parser.add_argument("--review-output", type=Path,
                        help="Create a private, unreviewed worksheet; never overwrite an existing review.")
    args = parser.parse_args()
    if args.output.resolve() in (args.manifest.resolve(), args.results.resolve()):
        parser.error("report output must not overwrite the manifest or results")
    if args.review_output and (args.review_output.exists() or args.review_output.is_symlink()
                              or args.review_output.resolve() == args.output.resolve()):
        parser.error("review output must be a new, separate file")
    manifest, results = read_bounded(args.manifest), read_bounded(args.results)
    report = score(manifest, results)
    write_private(args.output, report)
    if args.review_output:
        # O_EXCL also prevents overwriting a review created after the preflight.
        fd = os.open(args.review_output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(meaning_worksheet(manifest, results), stream, indent=2, ensure_ascii=False)
            stream.write("\n")
    for group, result in report["groups"].items():
        print(f"{group}: count={result['count']} WER={result['wer']} acceptance_pass={result['acceptance_pass']}")
    if args.require_acceptance and not all(group["acceptance_pass"] for group in report["groups"].values()):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
