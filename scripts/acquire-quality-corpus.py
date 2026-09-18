#!/usr/bin/env python3
"""Explicit public-corpus acquisition. Audio stays in ignored build/ directories.

Requires development-only pyarrow==21.0.0 and ffmpeg. No model is downloaded.
Use --lock to reconstruct a frozen selection; changed source/output bytes fail.
"""
import argparse
import csv
import hashlib
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import struct
import sys
import tarfile
import urllib.error
import urllib.parse
import urllib.request
import wave

FLEURS = '70bb2e84b976b7e960aa89f1c648e09c59f894dd'
VOX = '42f01879c780b4a2e90ec0b4f616c2ece526e4f1'
VOX_CODE = 'f7a3bb98d664e1d031763ec4f7639c4a530c64e9'
VOX_AUDIO = 'https://dl.fbaipublicfiles.com/voxpopuli/audios'
VOX_ANNOTATIONS = 'https://dl.fbaipublicfiles.com/voxpopuli/annotations/asr'
CV = 'cv-corpus-26.0-2026-06-12'
CV_IDS = {'sk': 'cmqinsswu00xanq07gb1dex5z', 'en': 'cmqim2hn800ssnr07gvmpcnwu'}
SHARDS = {
    'sk/test-00000-of-00001.parquet': '024defcb7eb0b9c0a04fdb4a4cc86a91e69d8c17537823e8d96d9473d50ab96b',
    'en_accented/test-00000-of-00002.parquet': '202d71bde2680f30aa7ae1050a98cdf85972458f94e6493db2aa7b8dd8ff46ec',
    'en_accented/test-00001-of-00002.parquet': '7d61b4c7a2e5c565a382543236442a7a8dd081c985e52dd1084905e4becc3901',
}
TECH = re.compile(r'computer|software|internet|technolog|digital|comput|počíta|softvér|technológ|digitál|elektron|electronic|robot|program|satellit|satelit|telecom|telekom', re.I)
TARGETS = {'public_sk_general': 20, 'public_en_general': 20, 'public_technology': 10,
           'public_entity_numeric': 10, 'public_sk_longer': 10, 'public_sk_accented_en': 10}
LONG_TARGETS = {'public_sk_60_90': 10, 'public_sk_120_180': 10, 'public_en_60_180': 5}
LONG_ANNOTATION_HASHES = {
    'sk': '91817417f3ac6cb1f52ac7a430797d9e98483fa50a4698e147db2f7bb1e4a124',
    'en': '0f8b33b51066cfc1f869e3d6ecadd95c1530824ca2d106366c8e525ff05a15d9',
}
HERE = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), HERE / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fetch(url, limit=4 << 20, headers=None, method=None):
    request = urllib.request.Request(url, headers=headers or {}, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError('metadata_capacity')
    return data


def download(url, path, expected, limit=3 << 30):
    if path.exists():
        if digest(path) != expected:
            raise ValueError('cached_source_hash_mismatch')
        return
    temp = path.with_suffix(path.suffix + '.partial')
    try:
        with urllib.request.urlopen(url, timeout=90) as response, temp.open('wb') as out:
            total = 0
            while chunk := response.read(1 << 20):
                total += len(chunk)
                if total > limit:
                    raise ValueError('download_capacity')
                out.write(chunk)
        if digest(temp) != expected:
            raise ValueError('download_hash_mismatch')
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


def fetch_range(url, start, count):
    """Read one exact byte range. Used to index uncompressed official source tar files."""
    if count <= 0 or count > 256 << 20:
        raise ValueError('range_capacity')
    request = urllib.request.Request(url, headers={'Range': f'bytes={start}-{start + count - 1}'})
    with urllib.request.urlopen(request, timeout=90) as response:
        data = response.read(count + 1)
        if response.status != 206 or len(data) != count:
            raise ValueError('source_range_unavailable')
    return data


def remote_tar_members(url, outputs):
    """Extract named regular members in one remote tar index pass."""
    parsed = urllib.parse.urlsplit(url)
    connection = http.client.HTTPSConnection(parsed.hostname, timeout=90)

    def ranged(start, count):
        connection.request('GET', parsed.path, headers={
            'Range': f'bytes={start}-{start + count - 1}', 'Connection': 'keep-alive'})
        response = connection.getresponse()
        data = response.read(count + 1)
        if response.status != 206 or len(data) != count:
            raise ValueError('source_range_unavailable')
        return data

    def header_at(data, index):
        header = data[index:index + 512]
        if len(header) != 512 or header[257:262] != b'ustar':
            return None
        try:
            expected = int(header[148:156].rstrip(b'\0 ') or b'0', 8)
            actual = sum(header[:148]) + 8 * 32 + sum(header[156:])
            size = int(header[124:136].rstrip(b'\0 ') or b'0', 8)
            stored = header[:100].rstrip(b'\0').decode('utf-8')
            prefix = header[345:500].rstrip(b'\0').decode('utf-8')
        except (ValueError, UnicodeDecodeError):
            return None
        if actual != expected:
            return None
        return (prefix + '/' if prefix else '') + stored, size

    connection.request('HEAD', parsed.path)
    head = connection.getresponse()
    head.read()
    length = int(head.getheader('Content-Length') or 0)
    if head.status != 200 or length <= 0:
        raise ValueError('source_archive_length_unavailable')

    wanted = {Path(name).name: (name, Path(output)) for name, output in outputs.items()}
    found = {}
    try:
        offset = 0
        for _ in range(4096):
            header = ranged(offset, 512)
            if header == bytes(512):
                break
            parsed_header = header_at(header, 0)
            if not parsed_header:
                raise ValueError('invalid_remote_tar')
            name, size = parsed_header
            data_offset = offset + 512
            basename = Path(name).name
            if basename in wanted:
                if size <= 0 or size > 256 << 20:
                    raise ValueError('source_recording_capacity')
                data = ranged(data_offset, size)
                output = wanted[basename][1]
                output.write_bytes(data)
                info = dict(member=name, offset=data_offset, size=size, sha256=sha(data))
                output.with_suffix('.source.json').write_text(
                    json.dumps(info, sort_keys=True, separators=(',', ':')))
                found[basename] = info
                if len(found) == len(wanted):
                    return found
            offset = data_offset + ((size + 511) // 512) * 512
    finally:
        connection.close()
    raise ValueError('source_recording_not_found')


def remote_tar_member(url, member_name, output):
    return remote_tar_members(url, {member_name: output})[Path(member_name).name]


def convert(source, output):
    """Bounded PCM pipe and canonical WAV header, no ffmpeg metadata in output."""
    command = ['ffmpeg', '-nostdin', '-v', 'error', '-threads', '1', '-i', str(source),
               '-map', '0:a:0', '-vn', '-ac', '1', '-ar', '16000', '-acodec', 'pcm_s16le',
               '-fflags', '+bitexact', '-flags:a', '+bitexact', '-f', 's16le', '-']
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    count = 0
    try:
        with wave.open(str(output), 'wb') as out:
            out.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
            while chunk := process.stdout.read(65536):
                count += len(chunk)
                if count > 5_760_000:
                    raise ValueError('audio_duration_capacity')
                out.writeframesraw(chunk)
        if process.wait() != 0 or count == 0 or count % 2:
            raise ValueError('audio_conversion_failed')
    except BaseException:
        process.kill()
        process.wait()
        output.unlink(missing_ok=True)
        raise
    finally:
        process.stdout.close()
    return count // 2


def record(root, raw, source, reference, categories, language, conversion):
    if len(raw) > 16 << 20:
        raise ValueError('source_clip_capacity')
    identity = sha((source['dataset'] + ':' + source['source_clip_id']).encode())[:20]
    fixture_id = 'public-' + identity
    source['source_audio_sha256'] = sha(raw)
    source['conversion'] = conversion
    source['source_language'] = language
    source['analysis_tags'] = categories
    source['subset'] = 'public_evaluation'
    temp = root / (fixture_id + '.source')
    output = root / (fixture_id + '.wav')
    temp.write_bytes(raw)
    try:
        source['original_duration_seconds'] = (wav_duration(raw) if raw[:4] == b'RIFF' else
            float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                                          '-of', 'default=noprint_wrappers=1:nokey=1', str(temp)],
                                         stderr=subprocess.DEVNULL, timeout=30)))
        samples = convert(temp, output)
        source['converted_duration_seconds'] = samples / 16000
    finally:
        temp.unlink(missing_ok=True)
    if samples <= 0:
        raise ValueError('empty_audio')
    is_vox = source['dataset'] == 'facebook/voxpopuli'
    rights = 'CC0-1.0 (VoxPopuli data); European Parliament source attribution retained' if is_vox else ('CC0-1.0 plus MDC access terms; references local only' if source['dataset'] == 'mozilla/common_voice' else 'CC-BY-4.0')
    return dict(id=fixture_id, path=output.name, sha256=digest(output), reference=reference,
                reference_sha256=sha(reference.encode()), sample_rate=16000, num_samples=samples,
                duration_seconds=samples / 16000, categories=categories, languages=[language],
                classification='authentic', partition='acceptance', source=source['source_url'],
                rights=rights, consent_basis='Publisher-licensed public release; individual consent records not supplied.',
                derivations=['Decoded to mono 16000 Hz PCM16 with pinned FFmpeg; canonical WAV header; no trimming, padding, gain normalization or concatenation.'],
                switches=[], technical_terms=[], provenance=source)


def select_rows(rows, excluded):
    """Select before inference, with no overlap between quota groups."""
    rows = tuple(rows)
    selected = []
    used = set(excluded)
    for category, count, predicate in (
        ('public_technology', 5, lambda r: bool(TECH.search(r['reference']))),
        ('public_entity_numeric', 5, lambda r: bool(re.search(r'\d', r['reference']))),
        ('general', 20, lambda r: True),
    ):
        matches = sorted((r for r in rows if r['clip'] not in used and predicate(r)), key=lambda r: r['clip'])[:count]
        if len(matches) != count:
            raise ValueError('selection_category_shortage_' + category)
        for row in matches:
            selected.append((row, category))
            used.add(row['clip'])
    return selected


def fleurs(root, cache, conversion, legacy):
    fixtures = []
    for language, locale in [('sk', 'sk_sk'), ('en', 'en_us')]:
        base = f'https://huggingface.co/datasets/google/fleurs/resolve/{FLEURS}/data/{locale}'
        metadata = fetch(base + '/test.tsv')
        rows = [dict(clip=r[1], reference=r[2], sentence_id=r[0])
                for r in csv.reader(io.StringIO(metadata.decode()), delimiter='\t')
                if len(r) == 7 and 32000 <= int(r[5]) <= 480000]
        excluded = {Path(f['source']['archive_member']).name for f in legacy['fixtures']
                    if 'source' in f and f['source']['locale'] == locale}
        selected = {r['clip']: (r, category) for r, category in select_rows(rows, excluded)}
        url = base + '/audio/test.tar.gz'
        # The archive is streamed, never unpacked with extractall or held in RAM.
        with urllib.request.urlopen(url, timeout=90) as response:
            with tarfile.open(fileobj=response, mode='r|gz') as archive:
                for member in archive:
                    key = Path(member.name).name
                    if key not in selected or not member.isfile():
                        continue
                    if member.size > 16 << 20:
                        raise ValueError('archive_member_capacity')
                    row, category = selected.pop(key)
                    raw = archive.extractfile(member).read(16 << 20)
                    source = dict(dataset='google/fleurs', version=FLEURS, source_clip_id=key,
                                  split='test', locale=locale, source_url=url, archive_member=member.name,
                                  metadata_sha256=sha(metadata), sentence_id=row['sentence_id'],
                                  reference_field='test.tsv column 3 (raw transcription)',
                                  reference_source_url=base + '/test.tsv')
                    tags = ['public_' + language + '_general' if category == 'general' else category]
                    fixtures.append(record(root, raw, source, row['reference'], tags, language, conversion))
                    if not selected:
                        break
        if selected:
            raise ValueError('missing_fleurs_members')
        print(language + ': selected 30 FLEURS clips', flush=True)
    return fixtures


def wav_duration(raw):
    if raw[:4] != b'RIFF' or raw[8:12] != b'WAVE':
        raise ValueError('vox_source_not_wav')
    offset, byte_rate, data_size = 12, None, None
    while offset + 8 <= len(raw):
        kind, size = struct.unpack_from('<4sI', raw, offset)
        offset += 8
        if offset + size > len(raw):
            raise ValueError('truncated_wav')
        if kind == b'fmt ' and size >= 16:
            byte_rate = struct.unpack_from('<I', raw, offset + 8)[0]
        elif kind == b'data':
            data_size = size
        offset += size + size % 2
    if not byte_rate or data_size is None:
        raise ValueError('invalid_wav_header')
    return data_size / byte_rate


def voxpopuli(root, cache, conversion):
    import pyarrow
    import pyarrow.parquet as pq
    if pyarrow.__version__ != '21.0.0':
        raise ValueError('pyarrow_version_mismatch')
    fixtures = []
    counts = {'sk': 0, 'en_accented': 0}
    for shard, checksum in SHARDS.items():
        subset = shard.split('/')[0]
        if counts[subset] == 10:
            continue
        url = f'https://huggingface.co/datasets/facebook/voxpopuli/resolve/{VOX}/{shard}'
        path = cache / shard.replace('/', '-')
        print('Downloading/verifying VoxPopuli ' + shard, flush=True)
        download(url, path, checksum)
        parquet = pq.ParquetFile(path)
        # Pinned shards are <=3 GiB. Batch size bounds Python audio objects to 8 clips.
        for batch in parquet.iter_batches(batch_size=8, use_threads=False):
            for row in batch.to_pylist():
                if subset == 'en_accented' and row['accent'] != 'en_sk':
                    continue
                raw = row['audio']['bytes']
                if not raw or len(raw) > 16 << 20:
                    continue
                # WAV duration from source header, without loading decoded audio arrays.
                duration = wav_duration(raw)
                if not 2 <= duration <= 180 or (subset == 'sk' and duration <= 14.96):
                    continue
                reference = row['raw_text'] or row['normalized_text']
                if not reference.strip():
                    continue
                source = dict(dataset='facebook/voxpopuli', version=VOX, source_clip_id=row['audio_id'],
                              split='test', locale=subset, source_url=url, source_shard=shard,
                              source_shard_sha256=checksum, accent=row['accent'],
                              reference_field='raw_text' if row['raw_text'] else 'normalized_text',
                              is_gold_transcript=row['is_gold_transcript'], reference_source_url=url)
                tags = ['public_sk_longer' if subset == 'sk' else 'public_sk_accented_en']
                fixtures.append(record(root, raw, source, reference, tags, 'sk' if subset == 'sk' else 'en', conversion))
                counts[subset] += 1
                if counts[subset] == 10:
                    break
            if counts[subset] == 10:
                break
    if counts != {'sk': 10, 'en_accented': 10}:
        raise ValueError('vox_coverage_shortage')
    return fixtures


def read_long_annotations(cache, language):
    checksum = LONG_ANNOTATION_HASHES[language]
    path = cache / 'annotations' / f'asr_{language}.tsv.gz'
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    download(f'{VOX_ANNOTATIONS}/asr_{language}.tsv.gz', path, checksum, limit=128 << 20)
    import gzip
    from ast import literal_eval
    rows = []
    with gzip.open(path, 'rt') as source:
        for row in csv.DictReader(source, delimiter='|'):
            if row['split'] != 'test' or not row['original_text'].strip():
                continue
            row['start'] = float(row['start_time'])
            row['end'] = float(row['end_time'])
            row['vad_spans'] = [[float(a), float(b)] for a, b in literal_eval(row['vad'])]
            if not row['start'] < row['end'] or not row['vad_spans']:
                continue
            rows.append(row)
    return rows, dict(url=f'{VOX_ANNOTATIONS}/asr_{language}.tsv.gz', sha256=checksum)


def long_candidates(rows, minimum, maximum, maximum_gap):
    from collections import defaultdict
    sessions = defaultdict(list)
    for row in rows:
        sessions[row['session_id']].append(row)
    candidates = []
    for session, values in sessions.items():
        values.sort(key=lambda row: (row['start'], row['end'], row['id_']))
        for first in range(len(values)):
            for last in range(first, len(values)):
                if last > first and values[last]['start'] - values[last - 1]['end'] > maximum_gap:
                    break
                duration = values[last]['end'] - values[first]['start']
                if duration > maximum:
                    break
                if duration >= minimum:
                    span = values[first:last + 1]
                    candidates.append(dict(
                        session_id=session, start=span[0]['start'], end=span[-1]['end'],
                        duration=duration, rows=span,
                        maximum_gap=max([0.0] + [span[i]['start'] - span[i - 1]['end']
                                                for i in range(1, len(span))])))
    return candidates


def select_long_candidates(rows_by_language):
    """Frozen, transcript-only selection. No LocalFlow output or audio content is consulted."""
    selected = []

    def take(category, language, minimum, maximum, targets, unique_sessions, maximum_gap,
             per_session, years):
        candidates = long_candidates(rows_by_language[language], minimum, maximum, maximum_gap)
        candidates = [candidate for candidate in candidates if candidate['session_id'][:4] in years]
        used_intervals = set()
        counts = {}
        for target in targets:
            eligible = [candidate for candidate in candidates
                        if (candidate['session_id'], candidate['start'], candidate['end']) not in used_intervals
                        and counts.get(candidate['session_id'], 0) < per_session
                        and (not unique_sessions or candidate['session_id'] not in counts)]
            if not eligible:
                raise ValueError('long_form_selection_shortage_' + category)
            chosen = min(eligible, key=lambda candidate: (
                abs(candidate['duration'] - target), candidate['session_id'],
                candidate['start'], candidate['end']))
            chosen = dict(chosen, category=category, language=language)
            selected.append(chosen)
            used_intervals.add((chosen['session_id'], chosen['start'], chosen['end']))
            counts[chosen['session_id']] = counts.get(chosen['session_id'], 0) + 1

    take('public_sk_60_90', 'sk', 60, 90, [60, 64, 68, 72, 76, 80, 84, 88, 66, 74],
         True, 3, 1, {'2009', '2013'})
    # Test-split Slovak has only four recordings with continuous 120+ second aligned runs.
    take('public_sk_120_180', 'sk', 120, 180,
         [120, 126, 132, 138, 144, 150, 156, 164, 172, 179], False, 6, 3,
         {'2009', '2013'})
    take('public_en_60_180', 'en', 60, 180, [60, 68, 76, 88, 120], True, 3, 1,
         {'2013', '2018'})
    return selected


def convert_interval(source, output, start, end):
    if not 0 <= start < end <= 24 * 60 * 60 or end - start > 180:
        raise ValueError('invalid_source_interval')
    command = ['ffmpeg', '-nostdin', '-v', 'error', '-threads', '1', '-i', str(source),
               '-ss', f'{start:.9f}', '-t', f'{end - start:.9f}', '-map', '0:a:0', '-vn',
               '-ac', '1', '-ar', '16000', '-acodec', 'pcm_s16le', '-fflags', '+bitexact',
               '-flags:a', '+bitexact', '-f', 's16le', '-']
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    count = 0
    try:
        with wave.open(str(output), 'wb') as out:
            out.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
            while chunk := process.stdout.read(65536):
                count += len(chunk)
                if count > 5_760_000:
                    raise ValueError('audio_duration_capacity')
                out.writeframesraw(chunk)
        if process.wait() != 0 or count == 0 or count % 2:
            raise ValueError('audio_conversion_failed')
    except BaseException:
        process.kill()
        process.wait()
        output.unlink(missing_ok=True)
        raise
    finally:
        process.stdout.close()
    return count // 2


def acquire_long_form(root, cache, conversion, frozen_lock=None):
    rows_by_language, annotations = {}, {}
    for language in ('sk', 'en'):
        rows_by_language[language], annotations[language] = read_long_annotations(cache, language)
    selections = select_long_candidates(rows_by_language)
    recordings = {}
    frozen_sources = {}
    if frozen_lock:
        for fixture in frozen_lock['fixtures']:
            provenance = fixture['provenance']
            frozen_sources[provenance['source_recording_id']] = provenance
    needed = {}
    for selection in selections:
        session = selection['session_id']
        year = session[:4]
        member_name = session + '_original.ogg'
        source = cache / 'recordings' / year / member_name
        source.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        source_metadata = source.with_suffix('.source.json')
        if source.exists() and source_metadata.exists():
            source_info = json.loads(source_metadata.read_text())
            if source_info['size'] != source.stat().st_size or source_info['sha256'] != digest(source):
                raise ValueError('cached_source_hash_mismatch')
            recordings[session] = source_info
        elif session in frozen_sources:
            frozen = frozen_sources[session]
            size, offset = frozen['source_audio_bytes'], frozen['source_tar_member_offset']
            if not isinstance(size, int) or not isinstance(offset, int):
                raise ValueError('frozen_source_range_missing')
            data = fetch_range(f'{VOX_AUDIO}/original_{year}.tar', offset, size)
            if sha(data) != frozen['source_audio_sha256']:
                raise ValueError('frozen_source_hash_mismatch')
            source.write_bytes(data)
            recordings[session] = dict(
                member=frozen['source_tar_member'], size=size,
                sha256=frozen['source_audio_sha256'], offset=offset)
        else:
            needed.setdefault(year, {})[member_name] = source
    for year, outputs in sorted(needed.items()):
        url = f'{VOX_AUDIO}/original_{year}.tar'
        print(f'Indexing VoxPopuli source archive {year} for {len(outputs)} recordings', flush=True)
        for basename, source_info in remote_tar_members(url, outputs).items():
            recordings[basename.removesuffix('_original.ogg')] = source_info
    fixtures = []
    for selection in selections:
        session = selection['session_id']
        year = session[:4]
        source_url = f'{VOX_AUDIO}/original_{year}.tar'
        member_name = session + '_original.ogg'
        source = cache / 'recordings' / year / member_name
        source_info = recordings[session]
        start, end = selection['start'], selection['end']
        identity = sha(f"{selection['language']}:{session}:{start:.9f}:{end:.9f}".encode())[:20]
        fixture_id = 'long-' + identity
        output = root / (fixture_id + '.wav')
        samples = convert_interval(source, output, start, end)
        rows = selection['rows']
        reference = ' '.join(row['original_text'].strip() for row in rows)
        spans = [dict(id=row['id_'], paragraph_id=row['paragraph_id'],
                      start_seconds=row['start'], end_seconds=row['end'],
                      vad=row['vad_spans'], speaker_id=row['speaker_id']) for row in rows]
        provenance = dict(
            dataset='facebook/voxpopuli', version=VOX, acquisition_code_revision=VOX_CODE,
            source_recording_id=session, source_clip_id=fixture_id, split='test',
            source_language=[selection['language']], subset='public_long_form_evaluation',
            source_url=source_url, source_tar_member=source_info['member'],
            source_tar_member_offset=source_info['offset'], source_audio_sha256=source_info['sha256'],
            source_audio_bytes=source_info['size'], exact_start_seconds=start, exact_end_seconds=end,
            original_duration_seconds=end - start, converted_duration_seconds=samples / 16000,
            transcript_span_ids=[span['id'] for span in spans], transcript_spans=spans,
            annotation_url=annotations[selection['language']]['url'],
            annotation_sha256=annotations[selection['language']]['sha256'],
            reference_field='original_text joined in timestamp order',
            reference_source_url=annotations[selection['language']]['url'],
            maximum_inter_span_gap_seconds=selection['maximum_gap'],
            analysis_tags=[selection['category']], conversion=conversion)
        fixtures.append(dict(
            id=fixture_id, path=output.name, sha256=digest(output),
            reference=reference, reference_sha256=sha(reference.encode()), sample_rate=16000,
            num_samples=samples, duration_seconds=samples / 16000,
            categories=[selection['category'], 'public_long_form'],
            languages=[selection['language']], classification='authentic', partition='acceptance',
            source=source_url, rights='CC0-1.0 (VoxPopuli data); European Parliament source attribution retained',
            consent_basis='Publisher-licensed public release; individual consent records not supplied.',
            derivations=['One exact continuous interval cut from the original source recording; no clip concatenation, padding or gain normalization.'],
            switches=[], technical_terms=[], provenance=provenance))
    fixtures.sort(key=lambda fixture: fixture['id'])
    return fixtures


def validate_long_corpus(manifest, root):
    counts = {category: 0 for category in LONG_TARGETS}
    sources = set()
    near_limit = 0
    for fixture in manifest['fixtures']:
        path = root / fixture['path']
        if digest(path) != fixture['sha256']:
            raise ValueError('converted_hash_mismatch')
        with wave.open(str(path), 'rb') as audio:
            if (audio.getnchannels(), audio.getframerate(), audio.getsampwidth()) != (1, 16000, 2):
                raise ValueError('converted_format_mismatch')
            if audio.getnframes() != fixture['num_samples']:
                raise ValueError('converted_samples_mismatch')
        provenance = fixture['provenance']
        required = ('dataset', 'version', 'source_recording_id', 'exact_start_seconds',
                    'exact_end_seconds', 'transcript_span_ids', 'source_audio_sha256',
                    'annotation_sha256')
        if any(provenance.get(key) in (None, '', []) for key in required):
            raise ValueError('missing_long_form_provenance')
        if provenance['exact_end_seconds'] - provenance['exact_start_seconds'] > 180:
            raise ValueError('long_form_duration_capacity')
        sources.add(provenance['source_recording_id'])
        near_limit += fixture['duration_seconds'] >= 170
        for category in counts:
            counts[category] += category in fixture['categories']
    if counts != LONG_TARGETS or len(manifest['fixtures']) != sum(LONG_TARGETS.values()):
        raise ValueError('long_form_composition_mismatch')
    if near_limit < 1:
        raise ValueError('near_limit_fixture_missing')
    return dict(fixtures=len(manifest['fixtures']), source_recordings=len(sources),
                near_limit=near_limit, categories=counts)


def common_voice_archive(language, cache, local):
    """Optional authorized download; never accepts terms or logs signed URLs/tokens."""
    if local:
        return Path(local)
    key = os.environ.get('MDC_API_KEY')
    if not key:
        raise ValueError('common_voice_requires_local_archive_or_MDC_API_KEY')
    api = 'https://mozilladatacollective.com/api/datasets/' + CV_IDS[language] + '/download'
    response = json.loads(fetch(api, headers={'Authorization': 'Bearer ' + key}, method='POST'))
    expected_name = CV + '-' + language + '.tar.gz'
    if response['filename'] != expected_name:
        raise ValueError('common_voice_release_mismatch')
    path = cache / expected_name
    download(response['downloadUrl'], path, response['checksum'], limit=100 << 30)
    return path


def common_voice(root, cache, conversion, local_archives):
    fixtures = []
    for language, local in zip(('sk', 'en'), local_archives):
        path = common_voice_archive(language, cache, local)
        archive_hash = digest(path)
        prefix = CV + '/' + language + '/'
        with tarfile.open(path, 'r|gz') as archive:
            metadata = None
            for member in archive:
                if member.name.lstrip('./') == prefix + 'validated.tsv' and member.isfile():
                    if member.size > 1 << 30:
                        raise ValueError('common_voice_metadata_capacity')
                    # Copy to disk so CSV parsing remains incremental.
                    meta_path = cache / (language + '-validated.tsv')
                    with meta_path.open('wb') as out:
                        shutil.copyfileobj(archive.extractfile(member), out, 1 << 20)
                    metadata = digest(meta_path)
                    break
        if metadata is None:
            raise ValueError('common_voice_pinned_validated_metadata_missing')
        # Keep only the first 30 lexicographic candidates per quota, not the corpus.
        candidates = {k: [] for k in ('technology', 'numeric', 'general')}
        with meta_path.open(encoding='utf-8', newline='') as f:
            for row in csv.DictReader(f, delimiter='\t'):
                r = {'clip': row['path'], 'reference': row['sentence']}
                if not r['reference'].strip():
                    continue
                for name, eligible in [('technology', bool(TECH.search(r['reference']))),
                                       ('numeric', bool(re.search(r'\d', r['reference']))), ('general', True)]:
                    if eligible:
                        candidates[name].append(r)
                        candidates[name].sort(key=lambda x: x['clip'])
                        del candidates[name][30:]
        rows = {r['clip']: r for values in candidates.values() for r in values}
        selected = {r['clip']: (r, c) for r, c in select_rows(rows.values(), set())}
        with tarfile.open(path, 'r|gz') as archive:
            for member in archive:
                name = member.name.lstrip('./')
                clip = name.removeprefix(prefix + 'clips/')
                if not name.startswith(prefix + 'clips/') or clip not in selected or not member.isfile():
                    continue
                if member.size > 16 << 20:
                    raise ValueError('common_voice_clip_capacity')
                row, category = selected.pop(clip)
                source = dict(dataset='mozilla/common_voice', version=CV, source_clip_id=clip,
                              split='validated', locale=language, source_url='https://mozilladatacollective.com/datasets/' + CV_IDS[language],
                              dataset_id=CV_IDS[language], archive_sha256=archive_hash, metadata_sha256=metadata,
                              reference_field='validated.tsv sentence', reference_source_url='archive:validated.tsv')
                tags = ['public_' + language + '_general' if category == 'general' else category]
                fixtures.append(record(root, archive.extractfile(member).read(16 << 20), source, row['reference'], tags, language, conversion))
                if not selected:
                    break
        if selected:
            raise ValueError('common_voice_selected_audio_missing')
    return fixtures


def validate_corpus(manifest, root):
    """Check physical files, uniqueness and provenance independently of recognition."""
    seen = set()
    for fixture in manifest['fixtures']:
        path = root / fixture['path']
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('invalid_audio_path')
        if digest(path) != fixture['sha256']:
            raise ValueError('converted_hash_mismatch')
        with wave.open(str(path), 'rb') as audio:
            if (audio.getnchannels(), audio.getframerate(), audio.getsampwidth(), audio.getcomptype()) != (1, 16000, 2, 'NONE'):
                raise ValueError('converted_format_mismatch')
            if audio.getnframes() != fixture['num_samples']:
                raise ValueError('converted_samples_mismatch')
            size = 0
            while chunk := audio.readframes(8192):
                size += len(chunk)
            if size != fixture['num_samples'] * 2:
                raise ValueError('truncated_converted_audio')
        provenance = fixture['provenance']
        for key in ('dataset', 'version', 'source_clip_id', 'split', 'source_language',
                    'analysis_tags', 'reference_field', 'reference_source_url', 'subset'):
            if not provenance.get(key):
                raise ValueError('missing_fixture_provenance')
        if provenance['converted_duration_seconds'] != fixture['num_samples'] / 16000:
            raise ValueError('converted_duration_mismatch')
        if fixture['classification'] != 'synthetic':
            if fixture['sha256'] in seen:
                raise ValueError('duplicate_source_audio')
            seen.add(fixture['sha256'])
            if not 0 < provenance['original_duration_seconds'] <= 180:
                raise ValueError('invalid_source_duration')
        if provenance['subset'] == 'public_evaluation' and not provenance.get('source_audio_sha256'):
            raise ValueError('missing_source_hash')
    counts = {c: sum(c in f['categories'] for f in manifest['fixtures']) for c in TARGETS}
    if counts != TARGETS or len(seen) != 100 or len(manifest['fixtures']) != 110:
        raise ValueError('corpus_composition_mismatch')
    return {'source_recordings': len(seen), 'evaluation_fixtures': len(manifest['fixtures']),
            'synthetic_stress': 10, 'categories': counts}


def selection_lock(manifest, conversion):
    return dict(schema_version=1, set_version=manifest['set_version'], selection_rule=manifest['selection_rule'],
                conversion=conversion, targets=TARGETS,
                fixtures=[{k: f[k] for k in ('id', 'sha256', 'reference_sha256', 'num_samples', 'categories', 'provenance')} for f in manifest['fixtures']])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--download', action='store_true')
    mode.add_argument('--validate-only', action='store_true', help='verify an existing corpus without network')
    parser.add_argument('--root', type=Path, required=True, help='new output directory under build/')
    parser.add_argument('--cache', type=Path, default=Path('build/public-corpus-cache'))
    parser.add_argument('--lock', type=Path, help='existing selection lock to verify on reconstruction')
    parser.add_argument('--primary', choices=['fleurs', 'common-voice'], default='fleurs')
    parser.add_argument('--long-form', action='store_true',
                        help='build the separate continuous 60-180 second VoxPopuli corpus')
    parser.add_argument('--cv-sk-archive', type=Path)
    parser.add_argument('--cv-en-archive', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    for path in (args.root, args.cache):
        if not path.resolve().is_relative_to(Path('build').resolve()):
            raise ValueError('outputs_must_be_under_ignored_build')
    if args.validate_only:
        q = module('transcription-quality')
        manifest, manifest_hash = q.manifest(args.root / 'manifest.json')
        result = (validate_long_corpus(manifest, args.root) if args.long_form
                  else validate_corpus(manifest, args.root))
        stored, _ = q.read(args.root / 'selection-lock.json')
        actual = selection_lock(manifest, stored['conversion'])
        if actual != stored or (args.lock and q.read(args.lock)[0] != actual):
            raise ValueError('frozen_selection_mismatch')
        print(json.dumps(dict(result, manifest_sha256=manifest_hash)))
        return
    if not shutil.which('ffmpeg') or not shutil.which('ffprobe'):
        raise ValueError('ffmpeg_and_ffprobe_required')
    import pyarrow
    if pyarrow.__version__ != '21.0.0':
        raise ValueError('pyarrow_version_mismatch')
    args.root.mkdir(parents=True, exist_ok=False, mode=0o700)
    args.cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    conversion = dict(rule='ffmpeg-mono-16k-pcm16-canonical-wav-v1',
                      ffmpeg_version=subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0],
                      ffmpeg_binary_sha256=digest(shutil.which('ffmpeg')))
    if args.lock and json.loads(args.lock.read_text())['conversion'] != conversion:
        raise ValueError('conversion_toolchain_mismatch')
    if args.long_form:
        frozen = json.loads(args.lock.read_text()) if args.lock else None
        fixtures = acquire_long_form(args.root, args.cache, conversion, frozen)
        manifest = dict(
            schema_version=2, set_version='f2-public-voxpopuli-contiguous-long-v1',
            fixtures=fixtures, coverage_gaps=[],
            selection_rule='voxpopuli-test-contiguous-source-intervals-v1; transcript-only deterministic selection',
            attribution=['Wang et al., VoxPopuli (ACL 2021), Facebook Research; European Parliament recordings; CC0 data'])
        lock = selection_lock(manifest, conversion)
        if args.lock and json.loads(args.lock.read_text()) != lock:
            raise ValueError('frozen_selection_or_conversion_mismatch')
        q = module('transcription-quality')
        q.write_new(args.root / 'manifest.json', manifest)
        q.manifest(args.root / 'manifest.json')
        validate_long_corpus(manifest, args.root)
        q.write_new(args.root / 'selection-lock.json', lock)
        print(json.dumps({'fixtures': len(fixtures), 'categories': LONG_TARGETS,
                          'manifest_sha256': digest(args.root / 'manifest.json')}))
        return
    legacy = json.loads(Path('fixtures/audio/manifest.json').read_text())
    fixtures = (fleurs(args.root, args.cache, conversion, legacy) if args.primary == 'fleurs' else
                common_voice(args.root, args.cache, conversion, [args.cv_sk_archive, args.cv_en_archive]))
    fixtures += voxpopuli(args.root, args.cache, conversion)
    for f in legacy['fixtures']:
        source_path = Path('build/speech-fixtures') / f['path']
        if not source_path.exists() or digest(source_path) != f['sha256']:
            raise ValueError('legacy_audio_missing_or_changed_run_download_speech_fixtures')
        shutil.copyfile(source_path, args.root / f['path'])
        source = f.get('source', {})
        fixtures.append(dict(id=f['id'], path=f['path'], sha256=f['sha256'], reference=f['reference'],
            reference_sha256=sha(f['reference'].encode()), sample_rate=16000, num_samples=f['num_samples'],
            duration_seconds=f['duration_seconds'], categories=['legacy_synthetic_stress' if f['synthetic'] else 'legacy_' + f['group']],
            languages=['sk', 'en'] if f['synthetic'] else [f['group']], classification='synthetic' if f['synthetic'] else 'authentic',
            partition='regression', source='https://huggingface.co/datasets/google/fleurs', rights=f['license'],
            consent_basis=f['speaker_consent'], derivations=[f['changes']], switches=[], technical_terms=[],
            provenance=dict(dataset='google/fleurs', version=FLEURS, source_clip_id=source.get('archive_member', f['id']),
                            subset='synthetic_stress' if f['synthetic'] else 'legacy_fleurs',
                            split='derived_test' if f['synthetic'] else 'test',
                            source_language=['sk','en'] if f['synthetic'] else [f['group']],
                            original_duration_seconds=None if f['synthetic'] else f['duration_seconds'],
                            original_duration_reason='synthetic_composition_has_no_single_source' if f['synthetic'] else 'legacy_16000_hz_samples',
                            converted_duration_seconds=f['duration_seconds'],
                            analysis_tags=['legacy_synthetic_stress' if f['synthetic'] else 'legacy_' + f['group']],
                            reference_field='fixtures/audio/manifest.json reference (unchanged legacy)',
                            reference_source_url='fixtures/audio/manifest.json',
                            legacy_manifest_sha256=digest('fixtures/audio/manifest.json'), components=f.get('components', []), **({'legacy_source': source} if source else {}))))
    fixtures.sort(key=lambda f: f['id'])
    counts = {c: sum(c in f['categories'] for f in fixtures) for c in TARGETS}
    if counts != TARGETS:
        raise ValueError('public_coverage_shortage')
    manifest = dict(schema_version=2, set_version='f2-public-' + args.primary + '-v2', fixtures=fixtures,
                    coverage_gaps=['authentic_within_speaker_sk_en', 'natural_near_limit_170_180_seconds'],
                    selection_rule='public-corpus-v1-selection-v2-provenance; see acceptance/fixture-acquisition.md',
                    attribution=['Conneau et al., FLEURS (2022), Google, CC-BY-4.0',
                                 'Wang et al., VoxPopuli (ACL 2021), Facebook Research; European Parliament recordings; CC0 data'])
    # Public lock is text-free, including for optional Common Voice acquisition.
    lock = selection_lock(manifest, conversion)
    if args.lock and json.loads(args.lock.read_text()) != lock:
        raise ValueError('frozen_selection_or_conversion_mismatch')
    q = module('transcription-quality')
    q.write_new(args.root / 'manifest.json', manifest)
    q.manifest(args.root / 'manifest.json')
    validate_corpus(manifest, args.root)
    q.write_new(args.root / 'selection-lock.json', lock)
    print(json.dumps({'fixtures': len(fixtures), 'categories': counts, 'manifest_sha256': digest(args.root / 'manifest.json')}))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never print remote error bodies, credential-bearing URLs or corpus text.
        print('acquisition_failed: ' + type(error).__name__ + (': ' + str(error) if isinstance(error, ValueError) else ''), file=sys.stderr)
        sys.exit(1)
