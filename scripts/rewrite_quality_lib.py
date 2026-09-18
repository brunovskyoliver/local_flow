"""Deterministic checks shared by the offline tests and opt-in rewrite runner."""
import math
import re
import statistics
import unicodedata
from collections import Counter

MODES = ('clean', 'polished', 'concise')
CLASSES = {'ip', 'url', 'email', 'path', 'version', 'number', 'currency', 'date', 'time', 'identifier'}
FACTS = {'negation', 'ownership', 'deadline', 'quantity', 'commitment', 'language_mix'}
SPANS = ('first_byte_ms', 'network_ms', 'total_ms', 'queue_ms', 'backend_first_token_ms', 'backend_ms')
REVIEW_PROPERTIES = ('names', 'negation', 'ownership', 'commitments', 'language_mix', 'not_summarized', 'no_invented_content')


def nfc(text):
    return unicodedata.normalize('NFC', text)


def bucket(text):
    count = len(text.split())
    return 'short' if count <= 25 else 'ordinary' if count <= 90 else 'long'


def occurrences(text, value):
    return nfc(text).count(nfc(value))


def check_protected(item, output):
    checks = []
    for entity in item.get('protected', []):
        before = occurrences(item['text'], entity['value'])
        after = occurrences(output, entity['value'])
        checks.append({'class': entity['class'], 'value': entity['value'],
                       'expected_count': before, 'actual_count': after, 'pass': before > 0 and before == after})
    return {'pass': all(c['pass'] for c in checks), 'checks': checks}


def words(text):
    return re.findall(r"[^\W\d_]+(?:['’][^\W\d_]+)?|\d+(?:[.,]\d+)?", nfc(text).lower())


def sentences(text):
    return [s for s in re.split(r'[!?]+|\.(?=\s|$)|\n+', nfc(text)) if s.strip()]


CALENDAR_GROUPS = (
    ('monday', 'pondelok', 'pondelka', 'pondelku'), ('tuesday', 'utorok', 'utorka', 'utorku'),
    ('wednesday', 'streda', 'stredu', 'stredy', 'strede'), ('thursday', 'štvrtok', 'štvrtka', 'štvrtku'),
    ('friday', 'piatok', 'piatka', 'piatku'), ('saturday', 'sobota', 'sobotu', 'soboty', 'sobote'),
    ('sunday', 'nedeľa', 'nedeľu', 'nedele', 'nedeli'),
    ('january', 'január', 'januára', 'januári'), ('february', 'február', 'februára', 'februári'),
    ('march', 'marec', 'marca', 'marci'), ('april', 'apríl', 'apríla', 'apríli'),
    ('may', 'máj', 'mája', 'máji'), ('june', 'jún', 'júna', 'júni'),
    ('july', 'júl', 'júla', 'júli'), ('august', 'augusta', 'auguste'),
    ('september', 'septembra', 'septembri'), ('october', 'október', 'októbra', 'októbri'),
    ('november', 'novembra', 'novembri'), ('december', 'decembra', 'decembri'))
CALENDAR = {name: group[0] for group in CALENDAR_GROUPS for name in group}
NUMERALS = dict(zip(
    'zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty'.split(),
    map(str, range(21))))
NUMERALS.update(dict(zip(
    'nula jeden dva tri štyri päť šesť sedem osem deväť desať jedenásť dvanásť trinásť štrnásť pätnásť šestnásť sedemnásť osemnásť devätnásť dvadsať'.split(),
    map(str, range(21)))))
SK_WORDS = set('a na ten potom prosím môžeš pošli pošlem potrebujeme správu to v do je nie sa som sme pre ale ak už ešte dnes zajtra nemôžem bez'.split())
EN_WORDS = set('the a an and is are will please can you to on in for not then with this that deployment update check configuration'.split())
DIACRITICS = set('áäčďéíĺľňóôŕšťúýž')
COMMITMENT = re.compile(r"\b(?:will|i['’]ll|can you|please|urobím|pošlem|môžeš|prosím)\b", re.I)


def negations(text, fact):
    tokens = words(text)
    extra = {w for w in words(fact.get('span', '')) if w.startswith('ne')}
    extra.update(w.lower() for w in fact.get('markers', []))
    return sum(w in {'not', 'no', 'never', 'nie', 'nikdy', 'žiadny', 'žiadna', 'žiadne'} | extra
               or w.endswith("n't") or w.endswith('n’t') for w in tokens)


def check_facts(item, output):
    source = nfc(item['text'])
    output = nfc(output)
    checks = []
    for fact in item.get('facts', []):
        kind = fact['type']
        passed = True
        if kind == 'negation':
            # Keep unrelated sentences from concealing a dropped or added negation.
            before, after = sentences(source), sentences(output)
            anchors = set(words(fact.get('span', ''))) | set(fact.get('markers', []))
            selected = [s for s in before if anchors.intersection(words(s))] or before
            content = set(words(' '.join(selected))) - anchors - EN_WORDS - SK_WORDS
            matched = [s for s in after if content.intersection(words(s))] or after
            passed = negations(' '.join(selected), fact) == negations(' '.join(matched), fact)
        elif kind == 'ownership':
            owners = {fact['owner'].lower(), *[x.lower() for x in fact.get('inflections', [])]}
            actions = {x.lower() for x in fact['action_keywords']}
            relevant = [set(words(s)) for s in sentences(output) if actions.intersection(words(s))]
            other_owners = {f['owner'].lower() for f in item.get('facts', [])
                            if f['type'] == 'ownership' and f['owner'].lower() not in owners}
            passed = any(owners.intersection(s) for s in relevant) and not any(
                other_owners.intersection(s) and not owners.intersection(s) for s in relevant)
        elif kind == 'deadline':
            calendar = lambda text: {CALENDAR[w] for w in words(text) if w in CALENDAR}
            passed = calendar(source) == calendar(output)
        elif kind == 'quantity':
            normalized = lambda text: Counter(NUMERALS.get(w, w) for w in words(text))
            value = NUMERALS.get(fact['value'].lower(), fact['value'])
            passed = normalized(source)[value] > 0 and normalized(source)[value] == normalized(output)[value]
        elif kind == 'commitment':
            passed = sum(bool(COMMITMENT.search(s)) for s in sentences(output)) >= fact['count']
        elif kind == 'language_mix':
            tokens = set(words(output))
            expected = fact['expected']
            if 'sk' in expected:
                before = sum(c.lower() in DIACRITICS for c in source)
                after = sum(c.lower() in DIACRITICS for c in output)
                passed = bool(tokens & SK_WORDS) and (not before or abs(after - before) <= before * .2)
            if 'en' in expected:
                passed = passed and bool(tokens & EN_WORDS)
            passed = passed and not any('CYRILLIC' in unicodedata.name(c, '') for c in output)
        else:
            checks.append({'type': kind, 'status': 'not_applicable', 'hard': False})
            continue
        checks.append({'type': kind, 'status': 'pass' if passed else 'flag',
                       'hard': kind in {'deadline', 'quantity'}})
    return checks


def validate_identity(identity):
    try:
        for block, keys in [('server', ('name', 'version')), ('backend', ('kind', 'model'))]:
            for key in keys:
                value = identity[block][key]
                if not isinstance(value, str) or not value.strip() or len(value.encode()) > 128:
                    raise ValueError('invalid identity')
        for mode in MODES:
            if type(identity['prompt_versions'][mode]) is not int or identity['prompt_versions'][mode] < 1:
                raise ValueError('invalid prompt identity')
        if type(identity['shield_version']) is not int or identity['shield_version'] < 0:
            raise ValueError('invalid shield identity')
        if type(identity['protocol_version']) is not int or identity['protocol_version'] != 1:
            raise ValueError('invalid protocol identity')
    except (KeyError, TypeError) as error:
        raise ValueError('missing identity') from error
    return identity


def distribution(samples):
    samples = sorted(x for x in samples if isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) and x >= 0)
    if len(samples) < 5:
        return {'status': 'unmeasured', 'samples': len(samples), 'median_ms': None, 'p95_ms': None}
    return {'status': 'measured', 'samples': len(samples), 'median_ms': statistics.median(samples),
            'p95_ms': samples[math.ceil(len(samples) * .95) - 1]}


def summarize(rows, identity):
    validate_identity(identity)
    result = {'identity': identity, 'modes': {}}
    for mode in MODES:
        selected = [row for row in rows if row['mode'] == mode]
        latency = {b: {span: distribution([r.get('timing', {}).get(span) for r in selected
                                          if r['bucket'] == b and not r.get('failure_code')])
                       for span in SPANS} for b in ('short', 'ordinary', 'long')}
        short = latency['short']['total_ms']['median_ms']
        ordinary = latency['ordinary']['total_ms']['p95_ms']
        flags = Counter(d['type'] for r in selected for d in r.get('detectors', []) if d['status'] == 'flag')
        result['modes'][mode] = {
            'items': len(selected), 'protected_pass_count': sum(r.get('protected', {}).get('pass', False) for r in selected),
            'hard_failures': sum(bool(r.get('failure_code')) or not r.get('protected', {}).get('pass', False)
                                 or any(d['hard'] and d['status'] == 'flag' for d in r.get('detectors', [])) for r in selected),
            'detector_flags': dict(flags), 'shield_failures': sum(r.get('failure_code') == 'server_validation_failed' for r in selected),
            'shield_detector_misses': sum(len(r.get('shield_detector_misses', [])) for r in selected),
            'unmeasured_count': sum(latency[b]['total_ms']['status'] == 'unmeasured' for b in latency),
            'latency': latency, 'short_gate_pass': None if short is None else short <= 1500,
            'short_target_achieved': None if short is None else short <= 1000,
            'ordinary_gate_pass': None if ordinary is None else ordinary <= 3000}
    return result


def validate_corpus(corpus):
    items = corpus['items']
    if corpus.get('corpus_version') != 1 or not 40 <= len(items) <= 256:
        raise ValueError('invalid corpus version or size')
    languages = Counter(i['language'] for i in items)
    buckets = Counter(bucket(i['text']) for i in items)
    if any(languages[l] < 8 for l in ('en', 'sk', 'mixed')) or buckets['short'] < 5 or buckets['ordinary'] < 5 or buckets['long'] < 1:
        raise ValueError('insufficient corpus coverage')
    if {p['class'] for i in items for p in i['protected']} != CLASSES or {f['type'] for i in items for f in i['facts']} != FACTS:
        raise ValueError('missing protected class or fact type')
    if len({i['id'] for i in items}) != len(items):
        raise ValueError('duplicate item id')
    for item in items:
        if not 0 < len(item['text']) <= 20000 or len(item['text'].encode()) > 65536:
            raise ValueError('invalid corpus text size')
        if not all(mode in item['review'] for mode in MODES):
            raise ValueError('missing per-mode review expectations')
        if not check_protected(item, item['text'])['pass']:
            raise ValueError('annotation absent from input')

# Version 1 detector definitions used to audit shielding coverage. The server
# implementation must match these fixtures when its shielding phase is built.
SHIELD_PATTERNS = {
    'url': r'https?://[^\s<>"⟦⟧]+',
    'email': r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}',
    'path': r'(?<!\w)/(?:[\w.-]+/)*[\w.-]+',
    'ip': r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?!\w|\.\d)',
    'version': r'\bv?\d+\.\d+\.\d+(?:[-+][\w.-]+)?\b',
    'currency': r'(?:[$€£]\s?\d+(?:[.,]\d+)*|(?:USD|EUR|GBP)\s+\d+(?:[.,]\d+)*|\d+(?:[.,]\d+)*\s+(?:USD|EUR|GBP))',
    'date': r'\b(?:\d{4}-\d{2}-\d{2}|\d{1,2}[./]\d{1,2}[./]\d{4}|' + '|'.join(re.escape(n) for n in CALENDAR) + r')\b',
    'time': r'\b\d{1,2}:\d{2}(?::\d{2})?\b',
    'number': r'(?<!\w)\d+(?:[.,]\d+)*(?!\w)',
}


def shield_detector_misses(item):
    misses = []
    for entity in item['protected']:
        kind, value = entity['class'], nfc(entity['value'])
        if kind == 'identifier':
            continue
        spans = [m.span() for m in re.finditer(SHIELD_PATTERNS[kind], nfc(item['text']), re.I if kind == 'date' else 0)]
        occurrences_ = [m.span() for m in re.finditer(re.escape(value), nfc(item['text']))]
        if any(not any(start <= a and end >= b for start, end in spans) for a, b in occurrences_):
            misses.append({'class': kind, 'value': value})
    return misses
