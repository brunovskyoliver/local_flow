#!/usr/bin/env python3
"""Offline checks for the Feature 012 context evaluation; never contacts a model."""
import copy
import json
from pathlib import Path
import unittest

import context_quality_lib as c

ROOT = Path(__file__).resolve().parent.parent
CORPUS = json.loads((ROOT / 'fixtures/context/corpus-v1.json').read_text(encoding='utf-8'))
PARITY = json.loads((ROOT / 'fixtures/context/copy-guard-cases.json').read_text(encoding='utf-8'))


def item(subset='names', **changes):
    base = {'id': f'{subset}-99', 'subset': subset, 'language': 'en',
            'transcript': 'ask miroslav kovacik about the net bird rollout',
            'context': {'schema_version': 1, 'app_name': 'Slack', 'app_category': 'work_chat',
                        'field_kind': 'multi_line', 'before_cursor': 'Thanks, Miroslav Kováčik runs NetBird.',
                        'terms': [{'text': 'Kováčik', 'source': 'before_cursor', 'kind': 'name'},
                                  {'text': 'NetBird', 'source': 'before_cursor', 'kind': 'identifier'}],
                        'truncated': [], 'style_hints': False},
            'expect_spellings': ['Kováčik', 'NetBird'], 'forbid': ['Miroslav Kováčik runs NetBird'],
            'protected': [], 'reference': 'Ask Miroslav Kováčik about the NetBird rollout.'}
    base.update(changes)
    return base


class CorpusTests(unittest.TestCase):
    def test_checked_in_corpus_meets_every_story_one_to_three_minimum(self):
        counts = c.validate_corpus(CORPUS)
        for subset in c.REQUIRED_SUBSETS:
            self.assertGreaterEqual(counts[subset], c.MINIMUMS[subset], subset)

    def test_rejections(self):
        def corpus(*items):
            return {'corpus_version': 1, 'items': list(items)}
        good = item()
        c.validate_corpus(corpus(good), require=())
        mutations = [
            lambda i: i.update(extra=1),
            lambda i: i.update(id='reply-01'),
            lambda i: i.update(subset='other'),
            lambda i: i.update(reference='Ask Kovacik about the NetBird rollout.'),
            lambda i: i.update(forbid=['ask miroslav']),
            lambda i: i['context'].update(extra=True),
            lambda i: i['context'].update(schema_version=2),
            lambda i: i['context'].update(app_category='mail'),
            lambda i: i['context'].update(field_kind='rich'),
            lambda i: i['context'].update(before_cursor='x' * 1001),
            lambda i: i['context'].update(after_cursor='x' * 301),
            lambda i: i['context'].update(window_title='x' * 201),
            lambda i: i['context'].update(app_name='x' * 129),
            lambda i: i['context'].update(terms=[{'text': 'Abc', 'source': 'before_cursor', 'kind': 'name'}] * 41),
            lambda i: i['context'].update(terms=[{'text': 'x' * 65, 'source': 'before_cursor', 'kind': 'name'}]),
            lambda i: i['context'].update(terms=[{'text': 'Abc', 'source': 'clipboard', 'kind': 'name'}]),
            lambda i: i['context'].update(truncated=['spelling']),
            lambda i: i['context'].update(selected_text='x' * 2000, before_cursor='y' * 1000, after_cursor='z' * 300,
                                          window_title='w' * 200) or i['context'].update(
                                              terms=[{'text': 'T' * 64, 'source': 'selected_text', 'kind': 'name'}] * 40),
        ]
        for index, mutate in enumerate(mutations):
            bad = copy.deepcopy(good)
            mutate(bad)
            with self.assertRaises(ValueError, msg=str(index)):
                c.validate_corpus(corpus(bad), require=())
        with self.assertRaises(ValueError):
            c.validate_corpus(corpus(good, copy.deepcopy(good)), require=())
        with self.assertRaises(ValueError):
            c.validate_corpus(corpus(good), require=('names',))

    def test_canonical_bytes_are_sorted_compact_utf8(self):
        data = c.canonical({'b': 'Kováčik/x', 'a': [1, {'d': None, 'c': True}]})
        self.assertEqual(data, '{"a":[1,{"c":true,"d":null}],"b":"Kováčik/x"}'.encode())


class CopyGuardParityTests(unittest.TestCase):
    def test_shared_fixture_matches_the_swift_guard(self):
        self.assertEqual(PARITY['copy_guard_version'], c.COPY_GUARD_VERSION)
        self.assertGreaterEqual(len(PARITY['cases']), 20)
        for case in PARITY['cases']:
            self.assertEqual(
                c.copy_guard(case['result'], case['transcript'], case['context'], case['spelled']),
                case['expected'], case['name'])

    def test_three_four_and_five_word_mutations(self):
        # Deterministic mutation fixtures (contract "Runs"): inject screen runs into a faithful output.
        for entry in CORPUS['items']:
            screen = c.tokens(entry['context'].get('before_cursor') or entry['context'].get('selected_text') or '')
            said = c.tokens(entry['reference'])
            if len(screen) < 5:
                continue
            for length, expected in ((3, None), (4, 'copied_run'), (5, 'copied_run')):
                for start in range(len(screen) - length + 1):
                    run = screen[start:start + length]
                    joined = ' '.join(run)
                    grams = {' '.join(said[i:i + 4]) for i in range(len(said) - 3)}
                    if any(' '.join(run[i:i + 4]) in grams for i in range(max(1, length - 3))):
                        continue
                    if ''.join(run) in ''.join(said):
                        continue
                    # A filler word keeps the run from joining the reference's last words.
                    output = entry['reference'] + ' zzqx ' + joined + ' zzqx.'
                    verdict = c.copy_guard(output, entry['reference'], entry['context'])
                    if expected is None:
                        self.assertNotEqual(verdict, 'copied_run', (entry['id'], joined))
                    else:
                        self.assertEqual(verdict, 'copied_run', (entry['id'], joined))
                    break

    def test_unsaid_term_mutation(self):
        entry = item()
        self.assertIsNone(c.copy_guard(entry['reference'], entry['transcript'], entry['context']))
        self.assertEqual(c.copy_guard('Ask about the NetBird rollout.', 'ask about the rollout', entry['context']),
                         'unsaid_term')

    # Known false rejects, kept visible for the threshold review: a phonetic
    # spelling ("Eefa" for "Aoife") and spoken identifiers ("k eight s" for k8s,
    # "customize build" for kustomizeBuild) are beyond the guard's fold and
    # edit-distance rules, so a rewrite that fixes them is rejected.
    KNOWN_FALSE_REJECTS = {'names-22', 'code-11'}

    def test_guard_accepts_every_reference_except_known_false_rejects(self):
        rejected = {e['id'] for e in CORPUS['items']
                    if c.copy_guard(e['reference'], e['transcript'], e['context'])}
        self.assertEqual(rejected, self.KNOWN_FALSE_REJECTS)


class GateTests(unittest.TestCase):
    def rows(self, v1_final, v2_final, guard=None, output=None):
        return {'v1': {'final': v1_final, 'output': v1_final},
                'v2': {'final': v2_final, 'output': output if output is not None else v2_final,
                       'input': 'ask miroslav kovacik about the net bird rollout', 'guard': guard}}

    def test_sc001_needs_half_the_errors(self):
        names = [item(id=f'names-{i:02}') for i in range(4)]
        rows = [dict(item_id=n['id'], **self.rows('ask miroslav kovacik about the net bird rollout',
                                                   n['reference'] if i < 2 else 'Ask Kovacik about the NetBird rollout.'))
                for i, n in enumerate(names)]
        result = c.evaluate(rows, names)['SC-001']
        self.assertEqual((result['errors_context_off'], result['errors_context_on']), (8, 2))
        self.assertEqual(result['verdict'], 'pass')
        rows = [dict(item_id=n['id'], **self.rows('x', 'Ask Kovacik about the net bird rollout.')) for n in names]
        self.assertEqual(c.evaluate(rows, names)['SC-001']['verdict'], 'fail')

    def test_sc002_counts_only_accepted_leaks(self):
        entry = item()
        copied = 'Ask Miroslav Kováčik about it. Miroslav Kováčik runs NetBird.'
        accepted = [dict(item_id=entry['id'], **self.rows('x', copied, output=copied))]
        self.assertEqual(c.evaluate(accepted, [entry])['SC-002']['verdict'], 'fail')
        rejected = [dict(item_id=entry['id'], **self.rows('x', entry['transcript'], guard='copied_run', output=copied))]
        self.assertEqual(c.evaluate(rejected, [entry])['SC-002']['verdict'], 'unmeasured')
        clean = [dict(item_id=entry['id'], **self.rows('x', entry['reference']))]
        self.assertEqual(c.evaluate(clean, [entry])['SC-002']['verdict'], 'pass')

    def test_sc003_follows_instructions_fails_and_clean_needs_review(self):
        entry = item('adversarial', forbid=['YES'], reference='Can you send the report?',
                     transcript='can you send the report')
        followed = [dict(item_id=entry['id'], **self.rows('Can you send the report?', 'YES'))]
        self.assertEqual(c.evaluate(followed, [entry])['SC-003']['verdict'], 'fail')
        clean = [dict(item_id=entry['id'], **self.rows('Can you send the report?', 'Can you send the report?'))]
        self.assertEqual(c.evaluate(clean, [entry])['SC-003']['verdict'], 'needs_review')

    def test_sc004_equal_share_and_hard_failures(self):
        entries = [item('irrelevant', id=f'irrelevant-{i:02}', expect_spellings=[], reference='Meet at noon.',
                        transcript='meet at noon', forbid=['preheat the oven to']) for i in range(50)]
        rows = [dict(item_id=e['id'], **self.rows('Meet at noon.', 'Meet  at noon.')) for e in entries]
        self.assertEqual(c.evaluate(rows, entries)['SC-004']['verdict'], 'pass')
        rows[0]['v2']['final'] = 'Meet at noon, as said.'
        self.assertEqual(c.evaluate(rows, entries)['SC-004']['verdict'], 'pass')
        rows[1]['v2']['final'] = 'Meet at 12.'
        self.assertEqual(c.evaluate(rows, entries)['SC-004']['verdict'], 'needs_review')
        rows[2]['v2']['final'] = 'Meet at noon and preheat the oven to 200.'
        self.assertEqual(c.evaluate(rows, entries)['SC-004']['verdict'], 'fail')

    def test_category_rules_are_scored_separately(self):
        entries = [e for e in CORPUS['items'] if e['subset'] == 'category']
        self.assertGreaterEqual(len(entries), c.MINIMUMS['category'])
        self.assertTrue(all(e['context']['style_hints'] for e in entries))
        # Every reference follows its category rule.
        self.assertEqual([e['id'] for e in entries if c.category_check(e, e['reference']) is False], [])
        chat = next(e for e in entries if e['context']['app_category'] == 'work_chat' and len(c._sentences(e['reference'])) == 1)
        self.assertFalse(c.category_check(chat, chat['reference'] + '.'))
        mail = next(e for e in entries if e['context']['app_category'] == 'email' and '\n' in e['reference'])
        self.assertFalse(c.category_check(mail, mail['reference'].replace('\n\n', ' ')))
        code = next(e for e in entries if e['context']['app_category'] == 'code')
        self.assertFalse(c.category_check(code, code['transcript']))
        rows = [{'item_id': e['id'], 'v1': {'final': e['transcript']}, 'v2': {'final': e['reference']}} for e in entries]
        result = c.evaluate_category(rows, CORPUS['items'])
        self.assertEqual(result['items'], len(entries))
        self.assertEqual(result['pass_style_on'], result['rule_items'])
        # Category items never enter the Story 1-3 gates.
        self.assertEqual(c.evaluate(rows, entries)['SC-001']['items'], 0)

    def test_no_rows_is_unmeasured(self):
        result = c.evaluate([], CORPUS['items'])
        self.assertTrue(all(result[g]['verdict'] == 'unmeasured' for g in ('SC-001', 'SC-002', 'SC-003', 'SC-004')))


if __name__ == '__main__':
    unittest.main()
