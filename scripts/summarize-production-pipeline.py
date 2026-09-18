#!/usr/bin/env python3
"""Summarize private production-pipeline corpus runs without printing transcript text.

Reads the score reports written by scripts/evaluate-production-pipeline.sh, the earlier
contiguous-fixed chunk-planner scores and the T014 historical baseline score, and prints one
JSON object with category WER/CER per stage, per-fixture deltas, completeness counts,
normalization effects and determinism. Only IDs, hashes, counts and rates are emitted.
"""
import argparse
import hashlib
import json
from fractions import Fraction
from pathlib import Path


def read(path):
    with Path(path).open('rb') as source:
        return json.load(source)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def rate(rows, stage, key):
    errors = sum(r['stages'][stage]['substitutions'] + r['stages'][stage]['deletions']
                 + r['stages'][stage]['insertions'] for r in rows)
    if key == 'wer':
        denominator = sum(r['stages'][stage]['reference_words'] for r in rows)
    else:
        errors = sum(r['stages'][stage]['character_errors'] for r in rows)
        denominator = sum(r['stages'][stage]['reference_characters'] for r in rows)
    return None if denominator == 0 else Fraction(errors, denominator)


def fmt(value):
    return None if value is None else f'{float(value):.6f}'


def categories(manifest):
    names = sorted({c for f in manifest['fixtures'] for c in f['categories']})
    return {name: [f['id'] for f in manifest['fixtures'] if name in f['categories']] for name in names}


def summarize(manifest, score, stage):
    by_id = {f['id']: f for f in score['fixtures']}
    out = {}
    for name, ids in categories(manifest).items():
        rows = [by_id[i] for i in ids if by_id[i]['stages'][stage]['available']]
        out[name] = {
            'fixtures': len(ids), 'scored': len(rows),
            'wer': fmt(rate(rows, stage, 'wer')), 'cer': fmt(rate(rows, stage, 'cer')),
            'incomplete': sum(by_id[i]['incomplete'] or by_id[i]['status'] != 'completed' for i in ids),
        }
    return out


def per_fixture_delta(score_a, score_b, stage_a, stage_b):
    """Absolute WER delta b - a per fixture; positive means the candidate is worse."""
    a = {f['id']: f for f in score_a['fixtures']}
    improved = regressed = unchanged = 0
    largest_regression = largest_improvement = Fraction(0)
    for f in score_b['fixtures']:
        base = a[f['id']]['stages'][stage_a]
        cand = f['stages'][stage_b]
        if not (base['available'] and cand['available']) or base['reference_words'] == 0:
            continue
        delta = (Fraction(cand['substitutions'] + cand['deletions'] + cand['insertions'], cand['reference_words'])
                 - Fraction(base['substitutions'] + base['deletions'] + base['insertions'], base['reference_words']))
        if delta > 0:
            regressed += 1
            largest_regression = max(largest_regression, delta)
        elif delta < 0:
            improved += 1
            largest_improvement = min(largest_improvement, delta)
        else:
            unchanged += 1
    return {'improved': improved, 'regressed': regressed, 'unchanged': unchanged,
            'largest_regression': fmt(largest_regression), 'largest_improvement': fmt(largest_improvement)}


def normalization_effects(run_root, score):
    changed = 0
    reasons = {}
    technical_total = technical_correct = unexpected = 0
    for f in score['fixtures']:
        stages = f['stages']
        if stages['assembled']['output_sha256'] != stages['normalized']['output_sha256']:
            changed += 1
        technical_total += stages['normalized']['technical_total']
        technical_correct += stages['normalized']['technical_correct']
        unexpected += stages['normalized']['unexpected_replacements']
        result = read(Path(run_root) / 'results' / f"{f['id']}.json")
        for reason in result['reasons']:
            reasons[reason] = reasons.get(reason, 0) + 1
    seconds = []
    for path in sorted((Path(run_root) / 'results').glob('*.json')):
        value = read(path)['measurements'].get('normalization_seconds', {}).get('value')
        if value is not None:
            seconds.append(value)
    seconds.sort()
    return {'normalized_text_differs_from_assembled': changed, 'completion_reasons': reasons,
            'technical_total': technical_total, 'technical_correct': technical_correct,
            'unexpected_replacements': unexpected,
            'normalization_seconds_max': max(seconds) if seconds else None,
            'normalization_seconds_median': seconds[len(seconds) // 2] if seconds else None}


def seams(run_root):
    discards = uncertain = conflicting = incomplete = chunks = 0
    max_chunks = 0
    for path in sorted((Path(run_root) / 'chunks').glob('*.json')):
        item = read(path)
        discards += item['discarded_lexical_words']
        uncertain += item['uncertain_seams']
        conflicting += item['conflicting_edge_tokens']
        incomplete += item['incomplete']
        chunks += len(item['chunks'])
        max_chunks = max(max_chunks, len(item['chunks']))
    return {'assembler_lexical_discards': discards, 'uncertain_seams': uncertain,
            'conflicting_edge_tokens': conflicting, 'incomplete_results': incomplete,
            'chunks_total': chunks, 'max_chunks_per_fixture': max_chunks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--production-a', required=True, help='production run directory, pass a')
    parser.add_argument('--production-b', required=True, help='production run directory, pass b')
    parser.add_argument('--production-score', required=True, help='score report of pass a')
    parser.add_argument('--production-score-b', required=True, help='score report of pass b')
    parser.add_argument('--contiguous-score', help='earlier contiguous-fixed chunk-planner score')
    parser.add_argument('--historical-score', help='T014 historical baseline score')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    manifest = read(args.manifest)
    production = read(args.production_score)
    production_b = read(args.production_score_b)
    out = {
        'manifest_sha256': production['manifest_sha256'],
        'production_run_sha256': {'a': production['run_sha256'], 'b': production_b['run_sha256']},
        'production_score_sha256': {'a': sha(args.production_score), 'b': sha(args.production_score_b)},
        'scoring_version': production['scoring_version'],
        'fixtures': len(production['fixtures']),
        'stage_identities': {s: production['fixtures'][0]['stages'][s]['identity'] for s in ('raw', 'assembled', 'normalized')},
        'categories': {stage: summarize(manifest, production, stage) for stage in ('raw', 'assembled', 'normalized')},
        'repeat_recognition': {
            'stage_hash_differences': sum(
                any(a['stages'][s]['output_sha256'] != b['stages'][s]['output_sha256'] for s in ('raw', 'assembled', 'normalized'))
                for a, b in zip(production['fixtures'], production_b['fixtures'])),
            'status_differences': sum(a['status'] != b['status'] or a['incomplete'] != b['incomplete']
                                      for a, b in zip(production['fixtures'], production_b['fixtures'])),
        },
        'normalization': normalization_effects(args.production_a, production),
        'seams': seams(args.production_a),
    }
    if args.contiguous_score:
        contiguous = read(args.contiguous_score)
        out['contiguous_fixed_run_sha256'] = contiguous['run_sha256']
        out['vs_contiguous_fixed_assembled'] = per_fixture_delta(contiguous, production, 'assembled', 'assembled')
        out['vs_contiguous_fixed_normalized'] = per_fixture_delta(contiguous, production, 'assembled', 'normalized')
    if args.historical_score:
        historical = read(args.historical_score)
        out['historical_run_sha256'] = historical['run_sha256']
        out['historical_categories'] = summarize(manifest, historical, 'assembled')
        out['vs_historical_normalized'] = per_fixture_delta(historical, production, 'assembled', 'normalized')
        deltas = {}
        for name, row in out['categories']['normalized'].items():
            base = out['historical_categories'][name]['wer']
            if base is not None and row['wer'] is not None:
                deltas[name] = fmt(Fraction(row['wer']) - Fraction(base))
        out['category_wer_delta_vs_historical_points'] = {k: f'{float(Fraction(v)) * 100:+.3f}' for k, v in deltas.items()}
    Path(args.output).write_text(json.dumps(out, indent=1, sort_keys=True) + '\n')
    print(json.dumps({'output': args.output, 'fixtures': out['fixtures'],
                      'repeat_recognition': out['repeat_recognition'], 'seams': out['seams']}, sort_keys=True))


if __name__ == '__main__':
    main()
