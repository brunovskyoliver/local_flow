"""Acceptance evidence evaluation; no recognition or scoring transformations."""
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parents[1]
SCENARIOS = ('restart_exact_stages', 'restart_provenance', 'legacy_read', 'confirmed_delete',
             'offline', 'cancellation', 'incomplete_result', 'storage_failure', 'retry_identity',
             'duration_cap', 'permission_failure', 'model_failure', 'audio_cleanup')
RESOURCE_CHECKS = ('network_disabled', 'no_outbound_requests', 'no_server', 'models_provisioned',
                   'default_cooldown', 'rapid_reuse', 'keep_loaded', 'manual_release',
                   'maximum_duration', 'maximum_vocabulary', 'matching_pipeline_conditions',
                   'single_model_residency', 'eventual_release', 'no_retained_engine_or_audio')
MEASUREMENTS = ('model_working_set_mb', 'added_text_metadata_mb', 'assembly_seconds',
                'normalization_seconds', 'load_seconds', 'release_seconds', 'queue_peak',
                'transcription_seconds')

def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def wer(counts):
    n = counts['reference_words']
    return Fraction(sum(counts[k] for k in ('substitutions', 'deletions', 'insertions')), n) if n else None

def finite(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0

def attested(e):
    import re
    return (isinstance(e, dict) and isinstance(e.get('reviewer'), str) and 0 < len(e['reviewer']) <= 128
            and isinstance(e.get('date'), str) and bool(re.fullmatch(r'\d{4}-\d{2}-\d{2}', e['date']))
            and isinstance(e.get('artifact_sha256'), str)
            and bool(re.fullmatch('[0-9a-f]{64}', e['artifact_sha256'])))

def evaluate(manifest, report, run, evidence=None, baseline=None, repeat=None, rescored=None):
    gates = {}; details = {}
    def gate(id, checks):
        # None denotes absent evidence, False a measured/observed failure.
        details[id] = checks
        gates[id] = 'fail' if any(v is False for v in checks.values()) else ('unverified' if any(v is None for v in checks.values()) else 'pass')
    if evidence is not None and not isinstance(evidence, dict):
        raise ValueError('invalid_acceptance_evidence')
    evidence = evidence or {}
    binding = (evidence.get('schema_version') == 1 and evidence.get('manifest_sha256') == report['manifest_sha256']
               and evidence.get('run_sha256') == report['run_sha256'])
    def section(name):
        value = evidence.get(name)
        return value if binding and attested(value) else None
    def assertion(e, key):
        value = e.get(key) if e else None
        return value if type(value) is bool else None
    fixtures = manifest['fixtures']; selected = [f for f in fixtures if f['partition'] != 'tuning']
    original = json.loads((ROOT / 'fixtures/audio/manifest.json').read_text())['fixtures']
    by_id = {f['id']: f for f in selected}
    originals = all(f['id'] in by_id and all(by_id[f['id']][k] == f[k] for k in ('sha256','reference','num_samples')) for f in original)
    mixed = [f for f in selected if f['classification'] == 'authentic' and 'authentic_mixed' in f['categories'] and {'sk','en'} <= set(f['languages']) and f['switches']]
    switches = [s for f in mixed for s in f['switches']]
    corpus = section('corpus')
    gate('SC-001', dict(original_30=originals, authentic_mixed=len(mixed)>=10,
        technical=sum('technical' in f['categories'] for f in selected)>=10,
        long_form=sum(60<=f['duration_seconds']<=180 for f in selected)>=6,
        near_limit=sum(170<=f['duration_seconds']<=180 for f in selected)>=2,
        both_switch_directions={('sk','en'),('en','sk')} <= {(s['from'],s['to']) for s in switches},
        # Boundary-nearness has no normative numeric radius; require reviewed fixture IDs.
        boundary_switch_review=(bool(corpus.get('boundary_switch_fixture_ids')) and set(corpus['boundary_switch_fixture_ids']) <= {f['id'] for f in mixed}) if corpus else None,
        provenance_and_references_verified=assertion(corpus,'provenance_and_references_verified'),
        within_speaker_verified=assertion(corpus,'within_speaker_verified')))
    def usable(r):
        return all(f['score_failure'] is None and all(s['available'] for s in f['stages'].values()) for f in r['fixtures'])
    conditions = ('hardware','os','power','engine','sdk','model_revision','model_descriptor_sha256',
                  'build','dirty','language','window_samples','overlap_samples','padding_minimum')
    # A full config equality is stricter than comparing only selected keys; missing identities remain open.
    reproduction = section('reproduction')
    same_repeat = None if repeat is None else (repeat[1]['config'] == run['config'] and repeat[0]['run_sha256'] != report['run_sha256'])
    identities = all(isinstance(run['config'].get(k), str) and run['config'][k]
                     and not run['config'][k].startswith('unknown') for k in conditions)
    gate('SC-002', dict(all_ids_accounted=len(report['fixtures'])==len(fixtures), stages_exposed=usable(report),
        finalized=run['status']=='complete', rescore_identical=rescored,
        same_conditions=same_repeat,
        recorded_conditions=identities if identities else None,
        conditions_reviewed=assertion(reproduction,'conditions_complete'),
        repeated_run_accounted=usable(repeat[0]) if repeat else None,
        repeated_run_finalized=repeat[1]['status']=='complete' if repeat else None))
    quality_stage = evidence.get('quality_stage', 'assembled') if binding else 'assembled'
    if quality_stage not in ('assembled', 'normalized'):
        raise ValueError('invalid_quality_stage')
    # Only acceptance/regression fixtures enter acceptance arithmetic. Display scoring remains unchanged.
    def group(r, category):
        rows=[s for f,s in zip(fixtures,r['fixtures']) if f['partition']!='tuning' and category in f['categories']]
        if not rows: return None
        counts={k:sum(s['stages'][quality_stage][k] for s in rows) for k in ('substitutions','deletions','insertions','reference_words')}
        return dict(wer=wer(counts), incomplete=sum(s['incomplete'] or s['status']!='completed' for s in rows),
                    changed=sum(s['stages'][quality_stage]['meaning']=='changed' for s in rows),
                    reviewed=all(s['stages'][quality_stage]['meaning'] in ('preserved','changed') for s in rows),
                    available=all(s['stages'][quality_stage]['available'] and s['score_failure'] is None for s in rows))
    base=baseline[0] if baseline and baseline[0]['manifest_sha256']==report['manifest_sha256'] else None
    def pair(category): return group(base,category) if base else None, group(report,category)
    checks={}
    for category in ('original_english','original_slovak'):
        b,c=pair(category)
        checks[category+'_15_percent']= c['wer']<=Fraction(15,100) if c and c['available'] and c['wer'] is not None else None
        checks[category+'_regression']=c['wer']-b['wer']<=Fraction(1,100) if b and c and b['available'] and c['available'] and b['wer'] is not None and c['wer'] is not None else None
    b,c=pair('authentic_mixed')
    improvement=None
    if b and c and b['available'] and c['available'] and b['reviewed'] and c['reviewed'] and b['wer'] is not None and c['wer'] is not None:
        improvement=b['wer']>0 and c['wer']<=b['wer']*Fraction(4,5) and c['incomplete']<=b['incomplete'] and c['changed']<=b['changed']
    decision=section('decision')
    decision_ok=None
    if decision:
        decision_ok=(decision.get('disposition') in ('retain','replace','fallback') and base is not None
                     and decision.get('baseline_run_sha256')==base['run_sha256']
                     and all(decision.get(k) is True for k in ('failures_localized','controlled_comparisons','rationale_reviewed','limitations_recorded')))
    checks['mixed_closure']=True if improvement is True or decision_ok is True else (False if improvement is False and decision_ok is False else None)
    checks['separate_mixed_groups']=all(group(report,g) is not None for g in ('authentic_mixed','synthetic_mixed'))
    gate('SC-003',checks)
    mixed_target=c['wer']<=Fraction(15,100) if c and c['available'] and c['wer'] is not None else None
    def contract(name, filename, fields):
        e=section(name)
        if not e: return None
        path=ROOT/'fixtures/quality'/filename
        if e.get('cases_sha256')!=file_hash(path): return None
        cases=json.loads(path.read_text())['cases']; rows=e.get('cases',[])
        if not isinstance(rows,list) or len(rows)!=len(cases) or not all(isinstance(r,dict) and isinstance(r.get('id'),str) for r in rows): return False
        if {r['id'] for r in rows}!={c['id'] for c in cases}: return False
        actual={r['id']:r for r in rows}
        return all(all(actual[c['id']].get(k)==c['expected'].get(k) for k in fields) for c in cases)
    assembly=section('assembly')
    gate('SC-004',dict(contract_cases=contract('assembly','assembly-cases.json',('assembled_text','assembled_words','incomplete','reasons','automatic_insertion_allowed','raw_utf8_hex')),
                       zero_induced_duplications=assertion(assembly,'zero_induced_duplications'),
                       zero_induced_omissions=assertion(assembly,'zero_induced_omissions'),
                       all_mixed_long_joins_classified=assertion(assembly,'all_mixed_long_joins_classified')))
    normalization=section('normalization')
    accepted=[s for f,s in zip(fixtures,report['fixtures']) if f['partition']!='tuning']
    terms=[s['stages']['normalized'] for s in accepted]
    total=sum(s['technical_total'] for s in terms); correct=sum(s['technical_correct'] for s in terms)
    gate('SC-005',dict(contract_cases=contract('normalization','normalization-cases.json',('text','applied_rule_ids','applied_entry_ids','reason','snapshot_validation','idempotent')),
        authored_cases_meaning_reviewed=assertion(normalization,'all_cases_meaning_preserved'),
        zero_unapproved_lexical_number_changes=assertion(normalization,'zero_unapproved_lexical_number_changes'),
        held_out_corrections=total>=10 and correct==total,
        explicit_alias_case_occurrences=assertion(normalization,'held_out_are_alias_case_corrections'),
        negative_replacements=sum(s['unexpected_replacements'] for s in terms)==0,
        acceptance_meaning_reviewed=all(s['meaning']=='preserved' for s in terms) if terms else None))
    storage=section('storage')
    gate('SC-006',{k:assertion(storage,k) for k in SCENARIOS})
    resource=section('resources')
    rc={k:assertion(resource,k) for k in RESOURCE_CHECKS}
    if resource:
        idle=resource.get('idle_mb'); capture=resource.get('capture_overhead_mb'); cycles=resource.get('settled_unloaded_mb')
        rc['idle_limit']=idle<=150 if finite(idle) else None
        rc['capture_limit']=capture<=100 if finite(capture) else None
        if isinstance(cycles,list) and len(cycles)==20 and all(finite(x) for x in cycles) and finite(idle):
            rc['release_tolerance']=all(abs(x-idle)<=max(20,idle*.1) for x in cycles)
            slope=sum((i-9.5)*x for i,x in enumerate(cycles))/sum((i-9.5)**2 for i in range(20))
            growth=statistics.median(cycles[-5:])-statistics.median(cycles[:5])
            rc['growth_investigated']=(slope<=.5 and growth<=10) or assertion(resource,'growth_explained') is True
        else: rc['release_tolerance']=None; rc['growth_investigated']=None
        rc['m5_measurements']=resource.get('hardware')=='Apple M5' and all(finite(resource.get(k)) for k in MEASUREMENTS)
    else: rc.update(idle_limit=None,capture_limit=None,release_tolerance=None,growth_investigated=None,m5_measurements=None)
    gate('SC-008',rc)
    adoption=section('adoption')
    if decision and decision.get('disposition')=='retain' and decision_ok:
        gates['SC-007']='not_applicable'; details['SC-007']={'reviewed_retention_decision':True}
    else:
        ac={}
        ac['decision']=decision_ok if decision and decision.get('disposition') in ('replace','fallback') else None
        ac['same_workload_conditions']=assertion(adoption,'same_workload_conditions')
        ac['recorded_hardware_conditions']=(all(run['config'].get(k) and run['config'].get(k)==baseline[1]['config'].get(k) for k in ('hardware','os','power','language')) if baseline else None)
        ac['resource_gates']=True if gates['SC-008']=='pass' else (False if gates['SC-008']=='fail' else None)
        for category in sorted({c for f in selected for c in f['categories'] if c in ('original_english','original_slovak','authentic_mixed','synthetic_mixed')}):
            b,c=pair(category)
            ac[category]= (c['wer']-b['wer']<=Fraction(1,100) and c['incomplete']<=b['incomplete'] and c['changed']<=b['changed']) if b and c and b['reviewed'] and c['reviewed'] and b['available'] and c['available'] and b['wer'] is not None and c['wer'] is not None else None
        if adoption:
            b,c=pair(adoption.get('target_category'))
            quality= b['wer']>0 and c['wer']<=b['wer']*Fraction(4,5) if b and c and b['available'] and c['available'] and b['wer'] is not None and c['wer'] is not None else False
            resource_gain=False; repetitions=True
            for metric in ('peak_transcription_mb','transcription_seconds'):
                a=adoption.get('baseline_'+metric); z=adoption.get('candidate_'+metric)
                valid=isinstance(a,list) and isinstance(z,list) and len(a)==len(z) and 3<=len(a)<=256 and all(finite(x) for x in a+z)
                repetitions &= valid
                if valid:
                    ba=max(a) if metric=='peak_transcription_mb' else statistics.median(a)
                    ca=max(z) if metric=='peak_transcription_mb' else statistics.median(z)
                    resource_gain |= ba>0 and ca<=ba*.8
            ac['three_repetitions']=repetitions
            ac['twenty_percent_gain']=quality or resource_gain
            ac['full_fallback_path']=assertion(adoption,'full_fallback_path') if decision and decision.get('disposition')=='fallback' else True
        else: ac.update(three_repetitions=None,twenty_percent_gain=None)
        gate('SC-007',ac)
    ready=run['status']=='complete' and usable(report) and all(s['status']=='completed' and not s['incomplete'] for s in report['fixtures'])
    return dict(passed=ready and all(v in ('pass','not_applicable') for v in gates.values()),gates=dict(sorted(gates.items())),checks=dict(sorted(details.items())),
                quality_stage=quality_stage, evidence_binding='matched' if binding else ('missing' if not evidence else 'stale'),
                inherited_authentic_mixed_15_percent=mixed_target)
