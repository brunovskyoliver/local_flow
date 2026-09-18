#!/usr/bin/env python3
"""Summarize private chunk-strategy evidence without printing transcript text."""
import argparse
import json
import os
from pathlib import Path

STRATEGIES = ('contiguous-fixed', 'vad-min', 'vad-preferred')
CORPORA = ('short', 'long')


def read(path):
    with Path(path).open('rb') as source:
        return json.load(source)


def stable(path):
    body = read(path)
    for key in ('recognition_seconds', 'wall_seconds', 'rss'):
        body.get('measurements', {}).pop(key, None)
    for key in ('recognition_seconds', 'wall_seconds', 'peak_rss_bytes'):
        body.pop(key, None)
    return body


def summarize(root, strategy, corpus):
    name = f'{strategy}-{corpus}'
    run = root / f'{name}-a'
    repeat = root / f'{name}-b'
    score = read(root / 'scores' / f'{name}-a.json')
    fixtures = {fixture['id']: fixture for fixture in score['fixtures']}
    diagnostics = []
    nondeterministic = []
    for path in sorted((run / 'chunks').glob('*.json')):
        item = read(path)
        diagnostics.append(item)
        if stable(path) != stable(repeat / 'chunks' / path.name):
            nondeterministic.append(item['id'])
    result_differences = [path.stem for path in sorted((run / 'results').glob('*.json'))
                          if stable(path) != stable(repeat / 'results' / path.name)]
    details = []
    for item in diagnostics:
        stage = fixtures[item['id']]['stages']['assembled']
        details.append({
            'id': item['id'], 'wer': stage['wer'], 'cer': stage['cer'],
            'chunk_count': len(item['chunks']),
            'boundaries': [{'start': chunk['sample_start'],
                            'end': chunk['sample_start'] + chunk['sample_count'],
                            'cause': chunk['boundary']} for chunk in item['chunks']],
            'vad_selected': item['silence_boundaries'],
            'nominal_fallback': item['fallback_boundaries'],
            'incomplete': item['incomplete'], 'ambiguous_seams': item['uncertain_seams'],
            'conflicting_edges': item['conflicting_edge_tokens'],
            'lexical_discards': item['discarded_lexical_words'],
            'recognition_seconds': item['recognition_seconds'],
            'wall_seconds': item['wall_seconds'], 'peak_rss_bytes': item['peak_rss_bytes'],
            'maximum_audio_buffer_samples': item['maximum_audio_buffer_samples'],
            'maximum_planner_buffer_samples': item['maximum_planner_buffer_samples'],
        })
    return {
        'strategy': strategy, 'corpus': corpus,
        'manifest_sha256': score['manifest_sha256'], 'run_sha256': score['run_sha256'],
        'categories': {category: values['assembled']
                       for category, values in score['categories'].items()},
        'fixtures': details,
        'totals': {
            'fixtures': len(details), 'chunks': sum(row['chunk_count'] for row in details),
            'maximum_chunks': max(row['chunk_count'] for row in details),
            'vad_selected': sum(row['vad_selected'] for row in details),
            'nominal_fallback': sum(row['nominal_fallback'] for row in details),
            'incomplete': sum(row['incomplete'] for row in details),
            'ambiguous_seams': sum(row['ambiguous_seams'] for row in details),
            'conflicting_edges': sum(row['conflicting_edges'] for row in details),
            'lexical_discards': sum(row['lexical_discards'] for row in details),
            'recognition_seconds': sum(row['recognition_seconds'] for row in details),
            'wall_seconds': sum(row['wall_seconds'] for row in details),
            'peak_rss_bytes': max(row['peak_rss_bytes'] or 0 for row in details),
            'maximum_audio_buffer_samples': max(row['maximum_audio_buffer_samples'] for row in details),
            'maximum_planner_buffer_samples': max(row['maximum_planner_buffer_samples'] for row in details),
            'nondeterministic_results': result_differences,
            'nondeterministic_chunk_plans': nondeterministic,
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    reports = [summarize(args.root, strategy, corpus)
               for strategy in STRATEGIES for corpus in CORPORA]
    fixed = {(report['corpus'], row['id']): row for report in reports
             if report['strategy'] == 'contiguous-fixed' for row in report['fixtures']}
    for report in reports:
        for row in report['fixtures']:
            baseline = fixed[(report['corpus'], row['id'])]
            row['wer_delta_vs_contiguous_fixed'] = f"{float(row['wer']) - float(baseline['wer']):.6f}"
            row['cer_delta_vs_contiguous_fixed'] = f"{float(row['cer']) - float(baseline['cer']):.6f}"
    body = {'schema_version': 1, 'reports': reports}
    data = json.dumps(body, sort_keys=True, separators=(',', ':')).encode() + b'\n'
    if args.output.exists():
        raise ValueError('output_exists')
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(data)


if __name__ == '__main__':
    main()
