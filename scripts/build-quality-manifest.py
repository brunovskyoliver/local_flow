#!/usr/bin/env python3
"""Assemble a v2 quality manifest from recorded fixtures and hand-written sidecars.

Reads <id>.wav plus <id>.json from a fixture root, computes every hash, sample count
and duration, then validates the result with the real scorer validator before writing.
Speech text is never printed.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import wave

HERE = Path(__file__).resolve().parent
WINDOW, STRIDE = 239_360, 207_360


def scorer():
    spec = importlib.util.spec_from_file_location('q', HERE / 'transcription-quality.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def audio_facts(path, q):
    with wave.open(str(path), 'rb') as handle:
        if handle.getnchannels() != 1 or handle.getframerate() != 16000 or handle.getsampwidth() != 2:
            raise ValueError('expected mono 16 kHz PCM16')
        frames = handle.getnframes()
    import hashlib
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        while chunk := handle.read(1_048_576):
            digest.update(chunk)
    return frames, digest.hexdigest()


def fixture(sidecar, q):
    body = json.loads(sidecar.read_text(encoding='utf-8'))
    fixture_id = sidecar.stem
    wav = sidecar.with_suffix('.wav')
    if not wav.is_file():
        raise ValueError(f'{fixture_id}: missing recording')
    samples, digest = audio_facts(wav, q)
    reference = body['reference']
    provenance = body.get('provenance', {})
    subset = body.get('corpus_subset', provenance.get('subset',
        'synthetic_stress' if body.get('classification') == 'synthetic' else 'private_recording'))
    if subset not in ('legacy_fleurs', 'public_evaluation', 'synthetic_stress', 'private_recording'):
        raise ValueError('invalid_corpus_subset')
    if (subset == 'synthetic_stress') != (body.get('classification', 'authentic') == 'synthetic'):
        raise ValueError('subset_classification_mismatch')
    if provenance.get('subset', subset) != subset:
        raise ValueError('provenance_subset_mismatch')
    return {
        'id': fixture_id,
        'corpus_subset': subset,
        'provenance': provenance,
        'path': wav.name,
        'sha256': digest,
        'reference': reference,
        'reference_sha256': q.sha(reference),
        'sample_rate': 16000,
        'num_samples': samples,
        'duration_seconds': round(samples / 16000, 4),
        'categories': body['categories'],
        'languages': body['languages'],
        'classification': body.get('classification', 'authentic'),
        'partition': body.get('partition', 'acceptance'),
        'source': body['source'],
        'rights': body['rights'],
        'consent_basis': body['consent_basis'],
        'derivations': body.get('derivations', []),
        'switches': body.get('switches', []),
        'technical_terms': body.get('technical_terms', []),
    }


def summarize(fixtures):
    categories = {}
    for f in fixtures:
        for c in f['categories']:
            categories.setdefault(c, []).append(f['duration_seconds'])
    print(f'fixtures: {len(fixtures)}')
    for name in sorted(categories):
        spans = categories[name]
        print(f'  {name}: {len(spans)} fixtures, {min(spans):.1f}-{max(spans):.1f} s')
    multi = [f for f in fixtures if f['num_samples'] > WINDOW]
    long_form = [f for f in fixtures if 60 <= f['duration_seconds'] <= 180]
    longest = [f for f in fixtures if 170 <= f['duration_seconds'] <= 180]
    mixed = [f for f in fixtures if 'authentic_mixed' in f['categories']]
    technical = [f for f in fixtures if 'technical' in f['categories']]
    switches = sum(len(f['switches']) for f in fixtures)
    seam = [f for f in mixed
            if any(any(abs(s['start_sample'] - (WINDOW + STRIDE * n)) <= 16000 for n in range(14))
                   for s in f['switches'])]
    print(f'multi-window recordings (> {WINDOW} samples): {len(multi)}')
    print(f'annotated code switches: {switches}; switches near a window seam: {len(seam)}')
    print('Coverage only; public T013 uses acquire-quality-corpus.py and its frozen selection lock.')
    print(f'authentic mixed: {len(mixed)}; technical: {len(technical)}; 60-180 s: {len(long_form)}; 170-180 s: {len(longest)}')



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root')
    parser.add_argument('output')
    parser.add_argument('--set-version', required=True)
    args = parser.parse_args()
    q = scorer()
    root = Path(args.root)
    sidecars = sorted(p for p in root.glob('*.json'))
    if not sidecars:
        print('no fixture sidecars found', file=sys.stderr)
        return 1
    try:
        fixtures = [fixture(p, q) for p in sidecars]
    except (ValueError, KeyError, TypeError, OSError, wave.Error, json.JSONDecodeError) as error:
        print(f'fixture_invalid: {error}', file=sys.stderr)
        return 1
    manifest = {'schema_version': 2, 'set_version': args.set_version, 'fixtures': fixtures}
    try:
        q.write_new(args.output, manifest)
    except (q.Invalid, OSError) as error:
        print(f'manifest_not_written: {error}', file=sys.stderr)
        return 1
    try:
        _, digest = q.manifest(args.output)
    except (q.Invalid, OSError, ValueError, KeyError, TypeError) as error:
        Path(args.output).unlink(missing_ok=True)
        print(f'manifest_rejected_by_validator: {type(error).__name__}', file=sys.stderr)
        return 1
    print(f'manifest_sha256: {digest}')
    summarize(fixtures)
    return 0


if __name__ == '__main__':
    sys.exit(main())
