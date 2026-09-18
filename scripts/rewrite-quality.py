#!/usr/bin/env python3
"""Opt-in sequential evaluator. Text is written only inside a private output directory."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import sys
import time
from datetime import datetime, timezone
from urllib.parse import urlsplit
import uuid

import rewrite_quality_lib as q


class Failure(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def decode(data):
    try:
        return json.loads(data, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, UnicodeError):
        raise Failure('malformed_response') from None


def integer(value):
    return type(value) is int and 0 <= value <= 2147483647


def validate_event(event, request):
    if not isinstance(event, dict) or not isinstance(event.get('event'), str):
        raise Failure('malformed_response')
    if event['event'] == 'result' and (type(event.get('schema_version')) is not int or event['schema_version'] != 1):
        raise Failure('unsupported_schema_version')
    if not isinstance(event.get('request_id'), str):
        raise Failure('malformed_response')
    if event['request_id'].lower() != request['request_id'].lower():
        raise Failure('request_mismatch')
    if event['event'] == 'error':
        code = event.get('code')
        mapping = {'shield_restore_failed':'server_validation_failed', 'backend_error':'server_validation_failed',
                   'invalid_request':'server_validation_failed', 'too_large':'server_validation_failed',
                   'output_too_large':'oversized_response', 'unauthorized':'authentication_failed',
                   'unsupported_version':'unsupported_schema_version', 'backend_timeout':'backend_unavailable',
                   'backend_first_token_timeout':'backend_unavailable', 'backend_unavailable':'backend_unavailable',
                   'server_busy':'backend_unavailable'}
        raise Failure(mapping.get(code, 'malformed_response'))
    if event['event'] != 'result':
        return None
    if event.get('mode') != request['mode'] or not isinstance(event.get('text'), str):
        raise Failure('malformed_response')
    text = event['text']
    if not text.strip():
        raise Failure('empty_response')
    if len(text.encode()) > min(4 * len(request['text'].encode()), 65536):
        raise Failure('oversized_response')
    try:
        for block, keys in [('server', ('name', 'version')), ('backend', ('kind', 'model'))]:
            for key in keys:
                value = event[block][key]
                if not isinstance(value, str) or not value or len(value.encode()) > 128:
                    raise ValueError()
        if not integer(event['prompt_version']): raise ValueError()
        for key in ('version', 'placeholders', 'restored'):
            if not integer(event['shield'][key]): raise ValueError()
        if not isinstance(event['timing'], dict): raise ValueError()
        if any(not integer(event['timing'][k]) for k in ('queue_ms', 'backend_first_token_ms', 'backend_ms') if k in event['timing']):
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise Failure('malformed_response') from None
    if '⟦' in text or '⟧' in text:
        raise Failure('server_validation_failed')
    event['unchanged'] = text.encode() == request['text'].encode()
    return event


def read_result(response, request, started):
    cap = min(4 * len(request['text'].encode()) + 8192, 73728)
    received, terminal, first_byte = 0, None, None
    while True:
        # read1 avoids waiting for the entire response before recording first byte.
        chunk = response.read1(min(4096, cap + 1 - received))
        if not chunk:
            break
        if first_byte is None: first_byte = (time.monotonic() - started) * 1000
        received += len(chunk)
        if received > cap: raise Failure('oversized_response')
        if received == len(chunk): buffer = bytearray()
        buffer.extend(chunk)
        while b'\n' in buffer:
            line, _, rest = buffer.partition(b'\n')
            buffer = bytearray(rest)
            event = decode(line)
            if not isinstance(event, dict) or not isinstance(event.get('event'), str): raise Failure('malformed_response')
            if len(line) > 8192 and event['event'] != 'result': raise Failure('malformed_response')
            if terminal is None:
                terminal = validate_event(event, request)
        if time.monotonic() - started > 60: raise Failure('timeout')
    if received and buffer: raise Failure('malformed_response')
    if terminal is None: raise Failure('malformed_response')
    elapsed = (time.monotonic() - started) * 1000
    return terminal, {'first_byte_ms': first_byte, 'network_ms': elapsed, 'total_ms': elapsed, **terminal['timing']}


def private_file(directory, name):
    fd = os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    return os.fdopen(fd, 'w', encoding='utf-8')


def run(args):
    with args.corpus.open('rb') as source:
        corpus_bytes = source.read(8 * 1024 * 1024 + 1)
    if len(corpus_bytes) > 8 * 1024 * 1024: raise ValueError('corpus too large')
    corpus = json.loads(corpus_bytes)
    q.validate_corpus(corpus)
    modes = args.modes.split(',')
    if not modes or len(set(modes)) != len(modes) or any(m not in q.MODES for m in modes):
        raise ValueError('invalid modes')
    endpoint = urlsplit(args.endpoint)
    if endpoint.scheme not in ('http', 'https') or not endpoint.hostname or endpoint.username or endpoint.password or endpoint.query or endpoint.fragment or endpoint.path not in ('', '/'):
        raise ValueError('endpoint must be an HTTP(S) origin without credentials')
    host = endpoint.hostname.lower()
    port = endpoint.port or (443 if endpoint.scheme == 'https' else 80)
    origin = f'{endpoint.scheme}://{("[" + host + "]") if ":" in host else host}:{port}'
    if len(origin.encode()) > 255: raise ValueError('endpoint too long')
    headers = {'Accept': 'application/x-ndjson', 'Content-Type': 'application/json'}
    if args.credential_env:
        secret = os.environ.get(args.credential_env)
        if not secret or len(secret.encode()) > 4096 or '\r' in secret or '\n' in secret:
            raise ValueError('invalid credential environment variable')
        headers['Authorization'] = 'Bearer ' + secret
    connection_type = http.client.HTTPSConnection if endpoint.scheme == 'https' else http.client.HTTPConnection
    connection = connection_type(host, port, timeout=10)
    try:
        connection.request('GET', '/v1/rewrite/health', headers=headers)
        response = connection.getresponse()
        if response.status != 200: raise Failure('health_unavailable')
        health_bytes = response.read(8193)
        if len(health_bytes) > 8192: raise Failure('oversized_response')
        health = decode(health_bytes)
        if not isinstance(health, dict) or health.get('service') != 'localflow-rewrite' or health.get('schema_version') != 1 or 1 not in health.get('protocol_versions', []):
            raise Failure('unsupported_schema_version')
        identity = q.validate_identity({k: health[k] for k in ('server', 'backend', 'prompt_versions', 'shield_version')} | {'protocol_version': 1})
        if health['backend'].get('state') != 'ready': raise Failure('backend_unavailable')
    finally:
        connection.close()
    # No artifacts exist until the full health identity has been validated.
    args.output_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.output_dir.is_symlink() or args.output_dir.stat().st_mode & 0o077:
        raise ValueError('output directory must be private (0700)')
    run_id = str(uuid.uuid4())
    metadata = {'run_id': run_id, 'started': datetime.now(timezone.utc).isoformat(),
                'endpoint_origin': origin, 'identity': identity, 'corpus_version': corpus['corpus_version'],
                'corpus_hash': hashlib.sha256(corpus_bytes).hexdigest()}
    compact_rows = []
    stopped = False
    with private_file(args.output_dir, 'results.json') as results:
        results.write(json.dumps(metadata, ensure_ascii=False)[:-1] + ', "results": [\n')
        first = True
        for item in corpus['items']:
            for mode in modes:
                request = {'schema_version': 1, 'request_id': str(uuid.uuid4()), 'mode': mode,
                           'text': item['text'], 'language_hints': [], 'stream_deltas': False}
                row = {'item_id': item['id'], 'mode': mode, 'request_id': request['request_id'],
                       'bucket': q.bucket(item['text']), 'input_hash': digest(item['text']), 'output_hash': None,
                       'output_text': None, 'protected': {'pass': False}, 'detectors': [], 'timing': {},
                       'shield': None, 'shield_active': identity['shield_version'] > 0,
                       'shield_detector_misses': q.shield_detector_misses(item), 'failure_code': None}
                connection = connection_type(host, port, timeout=60)
                transport_failure = False
                try:
                    started = time.monotonic()
                    connection.request('POST', '/v1/rewrite', body=json.dumps(request).encode(), headers=headers)
                    response = connection.getresponse()
                    if response.status != 200:
                        transport_failure = True
                        body = decode(response.read(8192))
                        code = body.get('error', {}).get('code') if isinstance(body, dict) else None
                        category = {400: 'unsupported_schema_version' if code == 'unsupported_version' else 'server_validation_failed',
                                    401:'authentication_failed',403:'authentication_failed',413:'server_validation_failed',
                                    429:'backend_unavailable',503:'backend_unavailable'}.get(response.status,'transport_error')
                        raise Failure(category)
                    if response.getheader('Content-Type', '').split(';')[0].strip() != 'application/x-ndjson':
                        raise Failure('malformed_response')
                    result, timing = read_result(response, request, started)
                    if (any(result['server'].get(k) != identity['server'][k] for k in ('name','version')) or any(result['backend'].get(k) != identity['backend'][k] for k in ('kind','model'))
                            or result['prompt_version'] != identity['prompt_versions'][mode] or result['shield']['version'] != identity['shield_version']):
                        raise Failure('identity_changed')
                    row.update(output_text=result['text'], output_hash=digest(result['text']),
                               protected=q.check_protected(item, result['text']), detectors=q.check_facts(item, result['text']),
                               shield=result['shield'], timing=timing)
                except Failure as error:
                    row['failure_code'] = error.code
                except (OSError, http.client.HTTPException) as error:
                    row['failure_code'] = 'timeout' if isinstance(error, (TimeoutError, socket.timeout)) else 'transport_error'
                    transport_failure = True
                finally:
                    connection.close()
                if not first: results.write(',\n')
                results.write(json.dumps(row, ensure_ascii=False))
                results.flush()
                first = False
                # Retain only bounded counters, hashes and spans; no response text.
                compact = {k: v for k, v in row.items() if k not in ('output_text', 'protected', 'shield_detector_misses')}
                compact['protected'] = {'pass': row['protected']['pass']}
                compact['shield_detector_misses'] = [e['class'] for e in row['shield_detector_misses']]
                compact_rows.append(compact)
                if transport_failure and not args.continue_on_error:
                    stopped = True
                    break
            if stopped: break
        results.write('], "finished": ' + json.dumps(datetime.now(timezone.utc).isoformat()) + '}\n')
    with private_file(args.output_dir, 'summary.json') as output:
        json.dump(q.summarize(compact_rows, identity) | {'run_id': run_id, 'stopped_early': stopped}, output, indent=2)
    with private_file(args.output_dir, 'review-template.md') as output:
        output.write('# Rewrite review\n\nReviewer: \nDate: \n\n```json\n' + json.dumps(metadata, indent=2) + '\n```\n\n')
        output.write('Add hardware, macOS, app build/commit, flowd commit/flags, inference program/version, loaded model file/tag, warm-up and network/timeout conditions before using this as acceptance evidence.\n\n')
        for mode in modes:
            output.write(f'## {mode.capitalize()}\n\n| Item | Input hash | Output hash | Detector flags | ' + ' | '.join(q.REVIEW_PROPERTIES) + ' |\n')
            output.write('| ' + ' | '.join(['---'] * (4 + len(q.REVIEW_PROPERTIES))) + ' |\n')
            for row in compact_rows:
                if row['mode'] != mode: continue
                flags = ', '.join(d['type'] for d in row['detectors'] if d['status'] == 'flag')
                output.write('| ' + ' | '.join([row['item_id'], row['input_hash'], row['output_hash'] or '', row['failure_code'] or flags] + [''] * len(q.REVIEW_PROPERTIES)) + ' |\n')
    print(f'Evaluated {len(compact_rows)} item/mode pairs. Review files written to the private output directory.')
    return 1 if stopped or any(r['failure_code'] or not r['protected']['pass'] or any(d['hard'] and d['status'] == 'flag' for d in r['detectors']) for r in compact_rows) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus', type=Path)
    parser.add_argument('output_dir', type=Path)
    parser.add_argument('--endpoint', required=True)
    parser.add_argument('--modes', default=','.join(q.MODES))
    parser.add_argument('--credential-env')
    parser.add_argument('--continue', dest='continue_on_error', action='store_true')
    try:
        return run(parser.parse_args())
    except (ValueError, KeyError, TypeError, OSError, Failure, http.client.HTTPException):
        # Raw errors can contain transcript fragments, paths or credentials.
        print('Evaluation stopped: invalid configuration, identity, response, or unavailable server.', file=sys.stderr)
        return 1

if __name__ == '__main__': sys.exit(main())
