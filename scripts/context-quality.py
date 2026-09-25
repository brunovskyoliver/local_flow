#!/usr/bin/env python3
"""Opt-in live A/B evaluation for Feature 012: each corpus item is rewritten once
as protocol v1 without context and once as v2 with its snapshot. Model text is
written only inside a private output directory; summary.json holds hashes,
verdicts and the identity block."""
import argparse
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import time
from datetime import datetime, timezone
from urllib.parse import urlsplit
import uuid

import context_quality_lib as c
import rewrite_quality_lib as q

_spec = importlib.util.spec_from_file_location('rewrite_quality', Path(__file__).with_name('rewrite-quality.py'))
rq = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rq)
Failure = rq.Failure


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def body(request, context):
    """v2 splices the canonical snapshot bytes, exactly as the client does."""
    data = json.dumps(request).encode()
    return data if context is None else data[:-1] + b',"context":' + context + b'}'


def send(connection_type, host, port, headers, request, context):
    connection = connection_type(host, port, timeout=60)
    try:
        started = time.monotonic()
        connection.request('POST', '/v1/rewrite', body=body(request, context), headers=headers)
        response = connection.getresponse()
        if response.status != 200:
            error = rq.decode(response.read(8192))
            code = error.get('error', {}).get('code') if isinstance(error, dict) else None
            raise Failure({400: 'unsupported_schema_version' if code == 'unsupported_version' else 'server_validation_failed',
                           401: 'authentication_failed', 403: 'authentication_failed', 413: 'server_validation_failed',
                           429: 'backend_unavailable', 503: 'backend_unavailable'}.get(response.status, 'transport_error'))
        if response.getheader('Content-Type', '').split(';')[0].strip() != 'application/x-ndjson':
            raise Failure('malformed_response')
        result, timing = rq.read_result(response, request, started)
        if context is not None:
            version = result.get('context_prompt_version')
            if type(version) is not int or version < 1:
                raise Failure('malformed_response')
        return result, timing
    except (OSError, http.client.HTTPException) as error:
        raise Failure('timeout' if isinstance(error, (TimeoutError, socket.timeout)) else 'transport_error') from None
    finally:
        connection.close()


def run(args):
    corpus_bytes = args.corpus.read_bytes()
    corpus = json.loads(corpus_bytes)
    c.validate_corpus(corpus)
    subsets = set(args.subsets.split(','))
    if not subsets <= set(c.MINIMUMS):
        raise ValueError('unknown subset')
    items = [i for i in corpus['items'] if i['subset'] in subsets][:args.limit or None]
    spelled, speller_version = {}, None
    if args.spelled:
        export = json.loads(args.spelled.read_text(encoding='utf-8'))
        speller_version, spelled = export['speller_version'], export['items']
    endpoint = urlsplit(args.endpoint)
    if endpoint.scheme not in ('http', 'https') or not endpoint.hostname or endpoint.username or endpoint.password or endpoint.path not in ('', '/'):
        raise ValueError('endpoint must be an HTTP(S) origin without credentials')
    host = endpoint.hostname.lower()
    port = endpoint.port or (443 if endpoint.scheme == 'https' else 80)
    headers = {'Accept': 'application/x-ndjson', 'Content-Type': 'application/json'}
    if args.credential_env:
        secret = os.environ.get(args.credential_env)
        if not secret or '\r' in secret or '\n' in secret:
            raise ValueError('invalid credential environment variable')
        headers['Authorization'] = 'Bearer ' + secret
    connection_type = http.client.HTTPSConnection if endpoint.scheme == 'https' else http.client.HTTPConnection
    connection = connection_type(host, port, timeout=10)
    try:
        connection.request('GET', '/v1/rewrite/health', headers=headers)
        response = connection.getresponse()
        if response.status != 200:
            raise Failure('health_unavailable')
        health = rq.decode(response.read(8193))
        if not isinstance(health, dict) or health.get('service') != 'localflow-rewrite' or not {1, 2} <= set(health.get('protocol_versions', [])):
            raise Failure('protocol_v2_unsupported')
        identity = q.validate_identity({k: health[k] for k in ('server', 'backend', 'prompt_versions', 'shield_version')} | {'protocol_version': 1})
        if health['backend'].get('state') != 'ready':
            raise Failure('backend_unavailable')
    finally:
        connection.close()
    args.out.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.out.is_symlink() or args.out.stat().st_mode & 0o077:
        raise ValueError('output directory must be private (0700)')
    rows, compact, context_prompt_versions = [], [], set()
    for item in items:
        context = c.canonical(item['context'])
        v2_text = spelled.get(item['id'], {}).get('text', item['transcript'])
        replacements = spelled.get(item['id'], {}).get('replacements', [])
        row = {'item_id': item['id'], 'subset': item['subset']}
        halves = (('v1', item['transcript'], None), ('v2', v2_text, context))
        if item['subset'] == 'category':
            # Story 4: the baseline is the same v2 request with the style toggle off.
            halves = (('v1', v2_text, c.canonical(item['context'] | {'style_hints': False})), ('v2', v2_text, context))
        for half, text, payload in halves:
            request = {'schema_version': 1 if payload is None else 2, 'request_id': str(uuid.uuid4()),
                       'mode': args.mode, 'text': text, 'language_hints': [], 'stream_deltas': False}
            entry = {'input': text, 'output': None, 'failure': None, 'guard': None, 'timing': {}, 'spelled': replacements}
            try:
                result, timing = send(connection_type, host, port, headers, request, payload)
                if (any(result['server'].get(k) != identity['server'][k] for k in ('name', 'version'))
                        or any(result['backend'].get(k) != identity['backend'][k] for k in ('kind', 'model'))
                        or result['prompt_version'] != identity['prompt_versions'][args.mode]):
                    raise Failure('identity_changed')
                entry.update(output=result['text'], timing=timing)
                if payload is not None:
                    context_prompt_versions.add(result['context_prompt_version'])
                    entry['guard'] = c.copy_guard(result['text'], text, item['context'], replacements)
            except Failure as error:
                entry['failure'] = error.code
            # What the app inserts: the output, or the faithful text on failure or rejection.
            entry['final'] = entry['output'] if entry['output'] is not None and entry['guard'] is None else text
            row[half] = entry
        rows.append(row)
        compact.append({'item_id': item['id'], 'subset': item['subset'],
                        **{half: {'output_hash': digest(row[half]['output']) if row[half]['output'] is not None else None,
                                  'final_hash': digest(row[half]['final']), 'failure': row[half]['failure'],
                                  'guard': row[half]['guard'],
                                  'missing_spellings': len(c.missing_spellings(item, row[half]['final'])),
                                  'forbidden_hits': len(c.forbidden_hits(item, row[half]['final'])),
                                  'protected_ok': c.protected_ok(item, row[half]['final']),
                                  'total_ms': row[half]['timing'].get('total_ms')}
                           for half in ('v1', 'v2')}})
        print(f"{item['id']}: v1 {row['v1']['failure'] or 'ok'} v2 {row['v2']['failure'] or row['v2']['guard'] or 'ok'}", file=sys.stderr)
    rewrite_off = None
    if spelled:
        names = [i for i in items if i['subset'] == 'names']
        off = sum(len(c.missing_spellings(i, i['transcript'])) for i in names)
        on = sum(len(c.missing_spellings(i, spelled[i['id']]['text'])) for i in names if i['id'] in spelled)
        rewrite_off = {'errors_context_off': off, 'errors_context_on': on, 'reduction': c.reduction(off, on),
                       'verdict': 'pass' if off and c.reduction(off, on) >= 0.5 else 'fail'}
    fd = os.open(args.out / 'results.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as output:
        json.dump({'rows': rows}, output, ensure_ascii=False, indent=1)
    summary = {
        'run_id': str(uuid.uuid4()), 'finished': datetime.now(timezone.utc).isoformat(),
        'identity': identity | {'protocol_versions': health['protocol_versions']},
        'context_prompt_version': sorted(context_prompt_versions),
        'speller_version': speller_version, 'copy_guard_version': c.COPY_GUARD_VERSION,
        'corpus_version': corpus['corpus_version'], 'corpus_hash': hashlib.sha256(corpus_bytes).hexdigest(),
        'mode': args.mode, 'items': len(items), 'spelling_applied': bool(spelled),
        'gates': c.evaluate(rows, items) | {'SC-001 rewrite off': rewrite_off,
                                            'category (style off vs on)': c.evaluate_category(rows, items)},
        'rows': compact,
    }
    fd = os.open(args.out / 'summary.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as output:
        json.dump(summary, output, indent=2)
    print(json.dumps(summary['gates'], indent=2))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--endpoint', required=True)
    parser.add_argument('--corpus', type=Path, default=Path(__file__).resolve().parent.parent / 'fixtures/context/corpus-v1.json')
    parser.add_argument('--out', type=Path, default=Path('build/context-eval') / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    parser.add_argument('--spelled', type=Path, help='export from ContextSpellerTests.testOptInExportSpelledCorpus')
    parser.add_argument('--mode', default='clean', choices=q.MODES)
    parser.add_argument('--subsets', default=','.join(c.REQUIRED_SUBSETS))
    parser.add_argument('--limit', type=int, default=0)
    parser.add_argument('--credential-env')
    try:
        return run(parser.parse_args())
    except (ValueError, KeyError, TypeError, OSError, Failure, http.client.HTTPException) as error:
        # Raw errors can contain transcript fragments, paths or credentials.
        print(f'Evaluation stopped: {type(error).__name__} {getattr(error, "code", "")}'.strip(), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
