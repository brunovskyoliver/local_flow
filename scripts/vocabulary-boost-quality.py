#!/usr/bin/env python3
"""Score a Feature 013 before/after run: WER, Dictionary-term recall, false term
insertions, clips made better or worse, and latency.

Usage: vocabulary-boost-quality.py MANIFEST.json VOCABULARY.json RESULTS.jsonl [--show]

The gate: no set may have a clip made worse or a new false term insertion.
Exit status 1 when the gate fails. --show prints every changed clip (private text).
"""
import json
import re
import statistics
import sys
import unicodedata
from collections import Counter, defaultdict


def words(text):
    text = unicodedata.normalize('NFC', text).lower()
    text = re.sub(r'(?<=\w)-(?=\w)', '', text)
    return re.sub(r"[^\w\s']", ' ', text).split()


def edits(ref, hyp):
    row = list(range(len(hyp) + 1))
    for i in range(1, len(ref) + 1):
        previous, row[0] = row[0], i
        for j in range(1, len(hyp) + 1):
            previous, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1,
                                           previous + (ref[i - 1] != hyp[j - 1]))
    return row[len(hyp)]


def main(manifest_path, vocabulary_path, results_path, show=False):
    refs = {c['id']: c for c in json.load(open(manifest_path))}
    keys = {''.join(words(t['canonical'])) for t in json.load(open(vocabulary_path))}

    def terms(ws):
        found, i = Counter(), 0
        while i < len(ws):
            for n in (3, 2, 1):
                if i + n <= len(ws) and ''.join(ws[i:i + n]) in keys:
                    found[''.join(ws[i:i + n])] += 1
                    i += n
                    break
            else:
                i += 1
        return found

    sets = defaultdict(lambda: defaultdict(float))
    latency = defaultdict(list)
    changed = []
    for line in open(results_path):
        row = json.loads(line)
        clip = refs[row['id']]
        s = sets[clip['set']]
        ref = words(clip['reference'])
        ref_terms = terms(ref)
        s['clips'] += 1
        s['words'] += len(ref)
        s['terms'] += sum(ref_terms.values())
        errors = {}
        for variant in ('baseline', 'boosted'):
            hyp = words(row[variant])
            found = terms(hyp)
            errors[variant] = edits(ref, hyp)
            s[variant + '_edits'] += errors[variant]
            s[variant + '_hits'] += sum(min(n, found[k]) for k, n in ref_terms.items())
            s[variant + '_false'] += sum(max(0, n - ref_terms[k]) for k, n in found.items())
        if row['baseline'] != row['boosted']:
            s['changed'] += 1
            s['better'] += errors['boosted'] < errors['baseline']
            s['worse'] += errors['boosted'] > errors['baseline']
            changed.append((errors['boosted'] - errors['baseline'], row, clip))
        latency['baseline'].append(row['asr_s'] * 1000)
        latency['boosted'].append(row['boost_s'] * 1000)

    print(f"{'set':22} {'clips':>5} {'WER before':>10} {'WER after':>9} {'terms':>5} "
          f"{'recall before':>13} {'recall after':>12} {'false b/a':>9} {'better':>6} {'worse':>5}")
    failed = False
    for name in sorted(sets):
        s = sets[name]
        recall = lambda v: f"{s[v + '_hits'] / s['terms'] * 100:12.1f}%" if s['terms'] else f"{'-':>13}"
        print(f"{name:22} {int(s['clips']):5d} {s['baseline_edits'] / s['words'] * 100:9.2f}% "
              f"{s['boosted_edits'] / s['words'] * 100:8.2f}% {int(s['terms']):5d} {recall('baseline')} "
              f"{recall('boosted')[1:]} {int(s['baseline_false']):4d}/{int(s['boosted_false']):<4d} "
              f"{int(s['better']):6d} {int(s['worse']):5d}")
        failed |= s['worse'] > 0 or s['boosted_false'] > s['baseline_false']

    def q(values, p):
        return sorted(values)[min(len(values) - 1, int(p * len(values)))]
    b, a = latency['baseline'], latency['boosted']
    print(f"latency per window: before mean {statistics.mean(b):.0f} ms p95 {q(b, .95):.0f} ms; "
          f"after mean {statistics.mean(a):.0f} ms p95 {q(a, .95):.0f} ms; "
          f"added mean {statistics.mean(a) - statistics.mean(b):.0f} ms")
    if show:
        for delta, row, clip in sorted(changed, key=lambda x: -x[0]):
            tag = 'WORSE' if delta > 0 else 'BETTER' if delta < 0 else 'SAME'
            print(f"[{tag}] {row['id']}\n  ref:    {clip['reference']}\n  before: {row['baseline']}\n"
                  f"  after:  {row['boosted']}")
    print('gate: ' + ('FAIL' if failed else 'pass'))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:4], show='--show' in sys.argv))
