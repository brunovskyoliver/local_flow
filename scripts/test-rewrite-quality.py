#!/usr/bin/env python3
"""Offline regression tests for rewrite evaluation; never contacts a model."""
import copy
import json
from pathlib import Path
import unicodedata
import unittest
import sys

import rewrite_quality_lib as q

IDENTITY = {"server": {"name": "flowd", "version": "test"},
            "backend": {"kind": "openai-compatible", "model": "test"},
            "prompt_versions": dict.fromkeys(q.MODES, 1), "shield_version": 1,
            "protocol_version": 1}

class QualityTests(unittest.TestCase):
    def test_protected_counts_case_and_nfc(self):
        item = {"text": "NetBird 15 15 päť", "protected": [
            {"class": "identifier", "value": "NetBird"},
            {"class": "number", "value": "15"},
            {"class": "identifier", "value": "päť"}]}
        self.assertTrue(q.check_protected(item, unicodedata.normalize('NFD', item['text']))['pass'])
        for text in ['NetBird 15 päť', 'netbird 15 15 päť', 'NetBird 16 15 päť', 'NetBird 15 15 15 päť']:
            self.assertFalse(q.check_protected(item, text)['pass'])

    def test_detectors(self):
        cases = [
            ('I will not deploy.', {'type': 'negation', 'markers': ['not']}, 'I will not deploy.', 'I will deploy.'),
            ('I will deploy.', {'type': 'negation', 'markers': ['not']}, 'I will deploy.', 'I will not deploy.'),
            ('Nemôžem nasadiť zmenu.', {'type': 'negation', 'span': 'nemôžem'}, 'Zmenu nemôžem nasadiť.', 'Môžem nasadiť zmenu.'),
            ('Peter will deploy. Anna will review.', {'type': 'ownership', 'owner': 'Peter', 'action_keywords': ['deploy']}, 'Peter will deploy. Anna will review.', 'Anna will deploy. Peter will review.'),
            ('Ship on Monday in January.', {'type': 'deadline', 'when': 'Monday'}, 'In January, ship on Monday.', 'Ship on Tuesday in January.'),
            ('Pošli to v pondelok v januári.', {'type': 'deadline', 'when': 'pondelok'}, 'V januári to pošli v pondelok.', 'Pošli to v utorok v januári.'),
            ('Send 15 units.', {'type': 'quantity', 'value': '15'}, 'Please send 15 units.', 'Send 16 units.'),
            ('I will deploy. I will check.', {'type': 'commitment', 'count': 2}, "I'll deploy. I will check.", 'I will deploy.'),
            ('Môžeš prosím check the deployment a potom pošli správu.', {'type': 'language_mix', 'expected': ['sk', 'en']}, 'Prosím check the deployment a potom môžeš poslať správu.', 'Please check the deployment and send the report.'),
            ('Môžeš poslať správu prosím.', {'type': 'language_mix', 'expected': ['sk']}, 'Prosím môžeš poslať správu.', 'Mozes poslat spravu prosim.'),
        ]
        for source, fact, clean, mutation in cases:
            item = {'text': source, 'facts': [fact], 'protected': []}
            with self.subTest(fact=fact):
                self.assertEqual(q.check_facts(item, clean)[0]['status'], 'pass')
                self.assertEqual(q.check_facts(item, mutation)[0]['status'], 'flag')
        item = {'text': 'Send 15 units.', 'facts': [{'type': 'quantity', 'value': '15'}],
                'protected': [{'class': 'number', 'value': '15'}]}
        self.assertEqual(q.check_facts(item, 'Send fifteen units.')[0]['status'], 'pass')
        self.assertFalse(q.check_protected(item, 'Send fifteen units.')['pass'])
        self.assertEqual(q.check_facts(item, 'Pošli pätnásť units.')[0]['status'], 'pass')

    def test_buckets_identity_and_verdicts(self):
        for count, bucket in [(25, 'short'), (26, 'ordinary'), (90, 'ordinary'), (91, 'long')]:
            self.assertEqual(q.bucket('word ' * count), bucket)
        for key in IDENTITY:
            identity = copy.deepcopy(IDENTITY)
            del identity[key]
            with self.assertRaises(ValueError): q.summarize([], identity)
        rows = [{'mode': 'clean', 'bucket': 'short', 'timing': {'total_ms': 1180},
                 'protected': {'pass': True}, 'detectors': [], 'failure_code': None} for _ in range(5)]
        summary = q.summarize(rows, IDENTITY)['modes']['clean']
        self.assertTrue(summary['short_gate_pass'])
        self.assertFalse(summary['short_target_achieved'])
        self.assertIsNone(summary['ordinary_gate_pass'])
        summary = q.summarize(rows[:4], IDENTITY)['modes']['clean']
        self.assertIsNone(summary['short_gate_pass'])
        self.assertEqual(summary['latency']['short']['total_ms']['status'], 'unmeasured')
        for row in rows: row.update(bucket='ordinary', timing={'total_ms': 3001})
        self.assertFalse(q.summarize(rows, IDENTITY)['modes']['clean']['ordinary_gate_pass'])

    def test_corpus_coverage_and_self_consistency(self):
        corpus = json.loads((Path(__file__).resolve().parents[1] / 'fixtures/rewrite/corpus-v1.json').read_text())
        q.validate_corpus(corpus)
        for item in corpus['items']:
            self.assertTrue(q.check_protected(item, item['text'])['pass'], item['id'])
            self.assertTrue(all(f['status'] == 'pass' for f in q.check_facts(item, item['text'])), item['id'])

    def test_runner_validation_and_bounded_streaming(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('rewrite-quality.py'))
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        request = {'request_id': '6f9619ff-8b86-d011-b42d-00c04fc964ff', 'mode': 'clean', 'text': 'Hello world'}
        event = {'event': 'result', 'schema_version': 1, 'request_id': request['request_id'], 'mode': 'clean',
                 'text': 'Hello world.', 'unchanged': True, 'server': IDENTITY['server'], 'backend': IDENTITY['backend'],
                 'prompt_version': 1, 'shield': {'version': 1, 'placeholders': 0, 'restored': 0}, 'timing': {'backend_ms': 12}}
        self.assertFalse(runner.validate_event(copy.deepcopy(event), request)['unchanged'])
        cases = [('schema_version', 2, 'unsupported_schema_version'), ('request_id', 'wrong', 'request_mismatch'),
                 ('mode', 'concise', 'malformed_response'), ('text', ' ', 'empty_response'),
                 ('text', 'x' * 45, 'oversized_response'), ('text', '⟦1⟧', 'server_validation_failed'),
                 ('timing', None, 'malformed_response'), ('prompt_version', True, 'malformed_response')]
        for key, value, expected in cases:
            mutated = copy.deepcopy(event)
            mutated[key] = value
            with self.assertRaises(runner.Failure) as caught: runner.validate_event(mutated, request)
            self.assertEqual(caught.exception.code, expected)
        for key in ('server', 'backend', 'prompt_version', 'shield', 'timing'):
            mutated = copy.deepcopy(event)
            del mutated[key]
            with self.assertRaises(runner.Failure): runner.validate_event(mutated, request)
        class Response:
            def __init__(self, data): self.data = data
            def read1(self, size):
                data, self.data = self.data[:size], self.data[size:]
                return data
        import time
        line = json.dumps(event).encode() + b'\n'
        result, spans = runner.read_result(Response(line + line), request, time.monotonic())
        self.assertEqual(result['text'], event['text'])
        self.assertGreaterEqual(spans['total_ms'], spans['first_byte_ms'])
        for data, expected in [(b'{}\n', 'malformed_response'), (b'[]\n', 'malformed_response'),
                               (b'x' * 8300, 'oversized_response'), (b'', 'malformed_response')]:
            with self.assertRaises(runner.Failure) as caught: runner.read_result(Response(data), request, time.monotonic())
            self.assertEqual(caught.exception.code, expected)

    def test_runner_end_to_end_with_local_double_and_private_artifacts(self):
        import http.server
        import subprocess
        import tempfile
        import threading
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                health = copy.deepcopy(IDENTITY)
                health.update(schema_version=1, service='localflow-rewrite', protocol_versions=[1])
                health['backend']['state'] = 'ready'
                body = json.dumps(health).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                assert request['language_hints'] == []
                event = {**request, 'event':'result', 'server':IDENTITY['server'], 'backend':IDENTITY['backend'],
                         'prompt_version':1, 'shield':{'version':1,'placeholders':0,'restored':0}, 'timing':{'backend_ms':1}}
                body = json.dumps(event).encode() + b'\n'
                self.send_response(200)
                self.send_header('Content-Type','application/x-ndjson')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(__file__).resolve().parents[1]
                output = Path(directory) / 'results'
                command = [sys.executable, str(root/'scripts/rewrite-quality.py'), str(root/'fixtures/rewrite/corpus-v1.json'),
                           str(output), '--endpoint', f'http://127.0.0.1:{server.server_port}']
                result = subprocess.run(command, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.stat().st_mode & 0o777, 0o700)
                rows = json.loads((output/'results.json').read_text())['results']
                self.assertEqual(len(rows), 120)
                self.assertEqual(len({r['request_id'] for r in rows}), 120)
                self.assertTrue(all(r['input_hash'] == r['output_hash'] for r in rows))
                self.assertFalse(any(r['shield_detector_misses'] for r in rows))
                self.assertNotIn('Peter', result.stdout + result.stderr)
                before = (output/'results.json').read_bytes()
                repeated = subprocess.run(command, capture_output=True, text=True, timeout=15)
                self.assertNotEqual(repeated.returncode, 0)
                self.assertEqual((output/'results.json').read_bytes(), before)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

if __name__ == '__main__': unittest.main()

