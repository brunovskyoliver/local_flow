#!/usr/bin/env python3
"""Explicitly retrieve a small pinned FLEURS subset; no package dependencies.

Streams archive prefixes, stops after ten eligible files per language, and
records transformations/provenance. Never called by make check.
"""
import argparse
import array
import csv
import hashlib
import io
import json
import math
from pathlib import Path
import struct
import sys
import tarfile
import urllib.request
import wave

REVISION = '70bb2e84b976b7e960aa89f1c648e09c59f894dd'
BASE = f'https://huggingface.co/datasets/google/fleurs/resolve/{REVISION}'
SOURCE = 'https://huggingface.co/datasets/google/fleurs'
LICENSE = 'https://creativecommons.org/licenses/by/4.0/'
MAX_NETWORK_BYTES = 64 << 20
MAX_MEMBER_BYTES = 16 << 20


def fetch(url, limit):
    with urllib.request.urlopen(url, timeout=45) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError('metadata exceeds bound')
    return data


class BoundedResponse:
    def __init__(self, response):
        self.response = response
        self.count = 0

    def read(self, size):
        if size < 0 or size > 1 << 20:
            raise ValueError('unbounded archive read')
        data = self.response.read(min(size, MAX_NETWORK_BYTES - self.count + 1))
        self.count += len(data)
        if self.count > MAX_NETWORK_BYTES:
            raise ValueError('archive prefix exceeds 64 MiB budget')
        return data


def pcm16(raw):
    """Read only bounded mono/16k PCM or IEEE float WAV, normalize to PCM16."""
    if raw[:4] != b'RIFF' or raw[8:12] != b'WAVE':
        raise ValueError('not RIFF WAV')
    offset, fmt, payload = 12, None, None
    while offset + 8 <= len(raw):
        kind, size = struct.unpack_from('<4sI', raw, offset)
        offset += 8
        if offset + size > len(raw):
            raise ValueError('truncated WAV chunk')
        if kind == b'fmt ':
            fmt = raw[offset:offset + size]
        elif kind == b'data':
            payload = raw[offset:offset + size]
        offset += size + (size % 2)
    if fmt is None or payload is None or len(fmt) < 16:
        raise ValueError('missing WAV format/data')
    encoding, channels, rate, _, alignment, bits = struct.unpack_from('<HHIIHH', fmt)
    if channels != 1 or rate != 16000 or len(payload) % alignment:
        raise ValueError('expected mono 16k audio')
    if encoding == 1 and bits == 16 and alignment == 2:
        return payload
    if encoding != 3 or bits != 32 or alignment != 4:
        raise ValueError(f'unsupported WAV encoding {encoding}/{bits}')
    values = array.array('f')
    values.frombytes(payload)
    if sys.byteorder != 'little':
        values.byteswap()
    result = array.array('h')
    for value in values:
        if not math.isfinite(value):
            raise ValueError('nonfinite sample')
        result.append(max(-32768, min(32767, round(value * 32768))))
    if sys.byteorder != 'little':
        result.byteswap()
    return result.tobytes()


def write_wav(path, frames):
    with wave.open(str(path), 'wb') as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(frames)
    path.chmod(0o600)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(root, manifest_path):
    expected = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
    if expected and all((root / f['path']).is_file() and
                        hashlib.sha256((root / f['path']).read_bytes()).hexdigest() == f['sha256']
                        for f in expected['fixtures']):
        print('Existing fixture hashes verified; no download needed.')
        return
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    (root / 'source').mkdir(exist_ok=True, mode=0o700)
    (root / 'source-card.md').write_bytes(fetch(BASE + '/README.md', 1 << 20))
    fixtures, audio, transfers = [], {}, {}
    for group, locale in [('sk', 'sk_sk'), ('en', 'en_us')]:
        tsv_url = f'{BASE}/data/{locale}/test.tsv'
        tsv = fetch(tsv_url, 2 << 20)
        (root / f'{locale}-test.tsv').write_bytes(tsv)
        rows = {row[1]: row for row in csv.reader(io.StringIO(tsv.decode()), delimiter='\t')}
        archive_url = f'{BASE}/data/{locale}/audio/test.tar.gz'
        count = 0
        with urllib.request.urlopen(archive_url, timeout=45) as response:
            stream = BoundedResponse(response)
            with tarfile.open(fileobj=stream, mode='r|gz') as archive:
                for member in archive:
                    name = Path(member.name).name
                    if not member.isfile() or name not in rows:
                        continue
                    row = rows[name]
                    if len(row) != 7 or not 32000 <= int(row[5]) <= 480000:
                        continue
                    if not 0 < member.size <= MAX_MEMBER_BYTES:
                        raise ValueError('oversized archive member')
                    handle = archive.extractfile(member)
                    if handle is None:
                        raise ValueError('unreadable archive member')
                    raw = handle.read(MAX_MEMBER_BYTES + 1)
                    if len(raw) != member.size:
                        raise ValueError('short archive member')
                    frames = pcm16(raw)
                    if len(frames) // 2 != int(row[5]):
                        raise ValueError('TSV sample count mismatch')
                    count += 1
                    fixture_id = f'{group}-{count:02d}'
                    original = root / 'source' / f'{fixture_id}.wav'
                    original.write_bytes(raw)
                    original.chmod(0o600)
                    path = fixture_id + '.wav'
                    sha = write_wav(root / path, frames)
                    audio[fixture_id] = frames
                    fixtures.append({
                        'id': fixture_id, 'group': group, 'path': path,
                        'reference': row[2], 'source_normalized_reference': row[3],
                        'sha256': sha, 'sample_rate': 16000, 'num_samples': len(frames) // 2,
                        'duration_seconds': len(frames) / 32000,
                        'synthetic': False, 'acceptance_eligible': True,
                        'meaning_reviewed': False,
                        'source': {'dataset': 'google/fleurs', 'revision': REVISION,
                            'locale': locale, 'split': 'test', 'sentence_id': row[0],
                            'archive_url': archive_url, 'archive_member': member.name,
                            'original_sha256': hashlib.sha256(raw).hexdigest(),
                            'tsv_url': tsv_url, 'tsv_sha256': hashlib.sha256(tsv).hexdigest()},
                        'license': 'CC-BY-4.0', 'license_url': LICENSE,
                        'speaker_consent': 'Publisher-licensed release; individual consent records not supplied.',
                        'changes': 'Converted mono 16 kHz WAV to signed PCM16; no resampling, trimming or gain adjustment.',
                    })
                    if count == 10:
                        break
            transfers[group] = stream.count
        if count != 10:
            raise ValueError('fewer than ten eligible recordings')
        print(f'{group}: 10 recordings; {transfers[group]} archive-prefix bytes retrieved', flush=True)
    by_id = {f['id']: f for f in fixtures}
    for index in range(1, 11):
        components = [f'sk-{index:02d}', f'en-{index:02d}']
        if index % 2 == 0:
            components.reverse()
        frames = audio[components[0]] + bytes(4000 * 2) + audio[components[1]]
        fixture_id = f'mixed-{index:02d}'
        path = fixture_id + '.wav'
        fixtures.append({
            'id': fixture_id, 'group': 'mixed', 'path': path,
            'reference': ' '.join(by_id[c]['reference'] for c in components),
            'sha256': write_wav(root / path, frames), 'sample_rate': 16000,
            'num_samples': len(frames) // 2, 'duration_seconds': len(frames) / 32000,
            'synthetic': True, 'acceptance_eligible': False, 'meaning_reviewed': False,
            'components': components, 'switch_seconds': len(audio[components[0]]) / 32000 + 0.25,
            'license': 'CC-BY-4.0', 'license_url': LICENSE,
            'speaker_consent': 'Derived from publisher-licensed FLEURS clips; individual consent records not supplied.',
            'changes': 'Artificial concatenation of two different monolingual clips with 250 ms silence. Not authentic code-switching.',
        })
    manifest = {'schema_version': 1, 'fixture_root': str(root),
        'dataset': {'name': 'Google FLEURS', 'source_url': SOURCE, 'revision': REVISION,
            'attribution': 'Alexis Conneau et al., FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech (2022), Google.',
            'license': 'CC-BY-4.0', 'license_url': LICENSE},
        'selection': 'First ten archive-order test WAVs per language with matching TSV and duration 2–30 seconds; selected before decoding, no accuracy-based filtering.',
        'archive_prefix_bytes': transfers,
        'integrity_note': 'Per-file hashes computed from retrieved HTTPS bytes. Archives were intentionally not fully downloaded or whole-archive-hash verified.',
        'acceptance_note': 'Natural monolingual speech plus artificial mixed stress fixtures. Human meaning review and authentic mixed-language acceptance are pending.',
        'fixtures': fixtures}
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    if expected:
        expected_identity = [(f['id'], f['sha256'], f['reference']) for f in expected['fixtures']]
        actual_identity = [(f['id'], f['sha256'], f['reference']) for f in fixtures]
        if expected_identity != actual_identity:
            raise ValueError('retrieved corpus differs from existing manifest; manifest preserved')
        print('Retrieved files match the existing pinned fixture manifest.')
        return
    temporary = manifest_path.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(manifest_path)
    print(f'Prepared {len(fixtures)} fixtures and provenance manifest at {manifest_path}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--download', action='store_true', required=True)
    parser.add_argument('--root', type=Path, default=Path('build/speech-fixtures'))
    parser.add_argument('--manifest', type=Path, default=Path('fixtures/audio/manifest.json'))
    args = parser.parse_args()
    download(args.root, args.manifest)
