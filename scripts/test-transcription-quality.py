#!/usr/bin/env python3
"""Authored deterministic inputs only; no speech fixtures or review verdicts."""
import importlib.util
import pathlib
import tempfile
import unittest
import json

spec = importlib.util.spec_from_file_location('quality', pathlib.Path(__file__).with_name('transcription-quality.py'))
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)

class ScoringTests(unittest.TestCase):
    def test_tokenizer(self):
        self.assertEqual(q.tokens('Hello, ČÍSLO 1.5 1,5 v1.2 don\'t foo_bar https://a.b !'), ['hello','číslo','1.5','1,5','v1.2',"don't",'foo_bar','https://a.b','!'])
        self.assertEqual(q.tokens('c\u030c'), ['č'])
    def test_tie_and_empty(self):
        self.assertEqual(q.distance(['a','b'], ['b','a']), (2,0,0))
        self.assertEqual(q.distance(['a'], []), (0,1,0))
        self.assertEqual(q.distance([], ['a']), (0,0,1))
        self.assertIsNone(q.metrics('', 'a')['wer'])
        self.assertEqual(q.metrics('č', 'c')['cer'], '1.000000')
    def test_bounds(self):
        with self.assertRaises(q.Invalid): q.tokens('a ' * 16385)
        with self.assertRaises(q.Invalid): q.tokens('a' * 65537)
        with self.assertRaises(q.Invalid): q.safe_id('../speech')
    def test_private_creation(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'review.json'
            q.write_new(p, {'verdict':None})
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError): q.write_new(p,{})
    def test_weighted(self):
        a=q.metrics('a b c', '')
        b=q.metrics('a', 'a')
        total=q.aggregate([a,b])
        self.assertEqual(total['wer'], '0.750000')
    def test_hash_review(self):
        r={'fixture_id':'one','stage':'assembled','reference_sha256':q.sha('a'),'output_sha256':q.sha('b'),'reviewer':'test-only','date':'2026-09-16','verdict':'preserved','explanation':''}
        self.assertTrue(q.review_valid(r,'one','assembled',q.sha('a'),q.sha('b')))
        self.assertFalse(q.review_valid(r,'one','assembled',q.sha('a'),q.sha('c')))

class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=pathlib.Path(self.temp.name); self.run=self.root/'run'; self.run.mkdir(mode=0o700); (self.run/'results').mkdir(mode=0o700)
        f=dict(id='one',path='one.wav',sha256='a'*64,reference='a b',reference_sha256=q.sha('a b'),sample_rate=16000,num_samples=1600,duration_seconds=.1,categories=['english','technical'],languages=['en'],classification='synthetic',partition='tuning',source='authored unit test',rights='authored',consent_basis='no recording',derivations=[],switches=[],technical_terms=[])
        self.m={'schema_version':2,'set_version':'test','fixtures':[f]}
        self.manifest=self.root/'manifest.json'; q.write_new(self.manifest,self.m)
        self.mh=q.read(self.manifest)[1]
        self.result={'schema_version':2,'id':'one','status':'completed','incomplete':False,'reasons':[],'windows':[], 'measurements':{},'stages':{stage:dict(text='' if stage=='raw' else 'a b',sha256=q.sha('' if stage=='raw' else 'a b'),identity='test',unavailable_reason=None) for stage in q.STAGES}}
        self.save_result()
    def save_result(self):
        p=self.run/'results/one.json';p.unlink(missing_ok=True);q.write_new(p,self.result)
        self.ledger={'schema_version':2,'run_id':'test','manifest_sha256':self.mh,'scoring_version':q.VERSION,'status':'complete','config':{},'config_sha256':q.hashlib.sha256(q.canonical({})).hexdigest(),'ledger':[{'id':'one','status':'completed','result_sha256':q.read(p)[1]}]}
        self.save_ledger()
    def save_ledger(self):
        p=self.run/'run.json';p.unlink(missing_ok=True);q.write_new(p,self.ledger)
    def test_manifest_and_determinism(self):
        q.manifest(self.manifest)
        a=q.score(self.m,self.mh,self.run,[])[0];b=q.score(self.m,self.mh,self.run,[])[0]
        self.assertEqual(q.canonical(a),q.canonical(b))
        self.assertEqual(a['categories']['english'],a['categories']['technical'])
    def test_failed_missing_and_oversized(self):
        p=self.run/'results/one.json';p.unlink()
        a=q.score(self.m,self.mh,self.run,[])[0]
        self.assertEqual(a['fixtures'][0]['stages']['assembled']['deletions'],2)
        self.assertEqual(len(a['fixtures']),1)
        with p.open('wb') as file: file.truncate(q.ARTIFACT+1)
        a=q.score(self.m,self.mh,self.run,[])[0]
        self.assertIsNotNone(a['fixtures'][0]['score_failure'])
    def test_failed_recovered_text(self):
        self.result['status']='failed';self.result['incomplete']=True;self.save_result()
        self.ledger['ledger'][0]['status']='failed';self.save_ledger()
        a=q.score(self.m,self.mh,self.run,[])[0]
        self.assertEqual(a['fixtures'][0]['status'],'failed')
        self.assertEqual(a['fixtures'][0]['stages']['assembled']['reference_words'],2)
    def test_mismatch_and_review(self):
        with self.assertRaises(q.Invalid):q.score(self.m,'0'*64,self.run,[])
        _,template,_=q.score(self.m,self.mh,self.run,[])
        template[1].update(reviewer='test-only',date='2026-09-16',verdict='preserved')
        a=q.score(self.m,self.mh,self.run,template)[0]
        self.assertEqual(a['fixtures'][0]['stages']['assembled']['meaning'],'preserved')
        template[1]['output_sha256']='0'*64
        a=q.score(self.m,self.mh,self.run,template)[0]
        self.assertEqual(a['fixtures'][0]['stages']['assembled']['meaning'],'unreviewed')
    def test_cli_exit_and_privacy(self):
        import subprocess,sys
        script=pathlib.Path(__file__).with_name('transcription-quality.py')
        report=self.root/'report.json'
        p=subprocess.run([sys.executable,str(script),'score',str(self.manifest),str(self.run),str(report),'--require-acceptance'],capture_output=True)
        self.assertEqual(p.returncode,2)
        self.assertEqual(p.stdout,b'');self.assertEqual(p.stderr,b'')
        self.assertEqual(report.stat().st_mode & 0o777,0o600)
        review=self.root/'review.json'
        command=[sys.executable,str(script),'review-template',str(self.manifest),str(self.run),str(review)]
        self.assertEqual(subprocess.run(command,capture_output=True).returncode,0)
        before=review.read_bytes()
        self.assertEqual(subprocess.run(command,capture_output=True).returncode,1)
        self.assertEqual(review.read_bytes(),before)
    def test_cli_evidence_repeat_and_actual_rescore(self):
        import subprocess,sys,shutil
        config={k:'authored-test' for k in ('hardware','os','power','engine','sdk','model_revision',
            'model_descriptor_sha256','build','dirty','language','window_samples','overlap_samples','padding_minimum')}
        self.ledger.update(config=config,config_sha256=q.hashlib.sha256(q.canonical(config)).hexdigest())
        self.save_ledger()
        repeated=self.root/'repeat';shutil.copytree(self.run,repeated)
        obj=q.read(repeated/'run.json')[0];obj['run_id']='distinct-repeat'
        (repeated/'run.json').unlink();q.write_new(repeated/'run.json',obj)
        evidence=self.root/'evidence.json'
        q.write_new(evidence,dict(schema_version=1,manifest_sha256=self.mh,run_sha256=q.read(self.run/'run.json')[1],
            reproduction=dict(reviewer='test-only',date='2026-09-16',artifact_sha256='a'*64,conditions_complete=True)))
        report=self.root/'scored.json'
        command=[sys.executable,str(pathlib.Path(__file__).with_name('transcription-quality.py')),
            'score',str(self.manifest),str(self.run),str(report),'--repeat',str(repeated),'--evidence',str(evidence)]
        process=subprocess.run(command,capture_output=True)
        self.assertEqual(process.returncode,0)
        self.assertEqual(process.stdout+process.stderr,b'')
        scored=q.read(report)[0]
        self.assertEqual(scored['acceptance']['gates']['SC-002'],'pass')
        self.assertEqual(scored['recognition_repeat_differences'][0]['changed_stage_hashes'],[])
        report.unlink()
        command[command.index(str(repeated))]=str(self.run)
        self.assertEqual(subprocess.run(command,capture_output=True).returncode,1)

    def test_exact_technical_alignment(self):
        terms=[dict(canonical='LocalFlow',reference_token=1,held_out=True)]
        self.assertEqual(q.technical_accuracy('use localflow','use LocalFlow',terms)['technical_correct'],1)
        self.assertEqual(q.technical_accuracy('use localflow','use localflow',terms)['technical_correct'],0)

class GateTests(unittest.TestCase):
    """Synthetic evidence exercises gates; it is never acceptance evidence."""
    def setUp(self):
        import copy
        self.copy=copy.deepcopy
        self.g=q.gate_module
        original=json.loads((self.g.ROOT/'fixtures/audio/manifest.json').read_text())['fixtures']
        fixtures=[]
        for f in original:
            row=self.copy(f)
            row.update(partition='regression',classification='synthetic' if f['synthetic'] else 'authentic',
                       languages=['en','sk'] if f['group']=='mixed' else [f['group']], switches=[],technical_terms=[],
                       categories=[{'en':'original_english','sk':'original_slovak','mixed':'synthetic_mixed'}[f['group']]])
            fixtures.append(row)
        for i in range(10):
            fixtures.append(dict(id=f'authored-{i}',partition='acceptance',classification='authentic',
                languages=['sk','en'],categories=['authentic_mixed','technical','long_form'],
                duration_seconds=175,reference='authored',sha256='a'*64,num_samples=2800000,
                switches=[{'from':'sk','to':'en'},{'from':'en','to':'sk'}]))
        self.m={'fixtures':fixtures}
        rows=[]
        for f in fixtures:
            counts=q.metrics('a '*100,'a '*100)
            counts.update(available=True,meaning='preserved',technical_total=1,technical_correct=1,unexpected_replacements=0)
            rows.append(dict(id=f['id'],status='completed',incomplete=False,score_failure=None,
                stages={s:self.copy(counts) for s in q.STAGES}))
        self.report=dict(manifest_sha256='a'*64,run_sha256='b'*64,fixtures=rows)
        self.run=dict(status='complete',config={k:'authored-test' for k in (
            'hardware','os','power','engine','sdk','model_revision','model_descriptor_sha256',
            'build','dirty','language','window_samples','overlap_samples','padding_minimum')})
        self.base=self.copy(self.report);self.base['run_sha256']='c'*64
        self.repeat=self.copy(self.report);self.repeat['run_sha256']='d'*64
        def att(**kw):
            return dict(reviewer='authored-unit-test',date='2026-09-16',artifact_sha256='e'*64,**kw)
        self.e=dict(schema_version=1,manifest_sha256='a'*64,run_sha256='b'*64,
            corpus=att(boundary_switch_fixture_ids=['authored-0'],provenance_and_references_verified=True,within_speaker_verified=True),
            reproduction=att(conditions_complete=True),
            decision=att(disposition='retain',baseline_run_sha256='c'*64,failures_localized=True,
                         controlled_comparisons=True,rationale_reviewed=True,limitations_recorded=True),
            storage=att(**{k:True for k in self.g.SCENARIOS}),
            resources=att(**{k:True for k in self.g.RESOURCE_CHECKS},hardware='Apple M5',idle_mb=100,
                          capture_overhead_mb=50,settled_unloaded_mb=[100]*20,
                          **{k:1 for k in self.g.MEASUREMENTS}))
        for name,filename in [('assembly','assembly-cases.json'),('normalization','normalization-cases.json')]:
            path=self.g.ROOT/'fixtures/quality'/filename
            cases=json.loads(path.read_text())['cases']
            self.e[name]=att(cases_sha256=self.g.file_hash(path),cases=[dict(id=c['id'],**c['expected']) for c in cases])
        self.e['assembly'].update(zero_induced_duplications=True,zero_induced_omissions=True,all_mixed_long_joins_classified=True)
        self.e['normalization'].update(all_cases_meaning_preserved=True,zero_unapproved_lexical_number_changes=True,held_out_are_alias_case_corrections=True)
    def evaluate(self):
        return self.g.evaluate(self.m,self.report,self.run,self.e,(self.base,self.run),(self.repeat,self.run),True)
    def test_complete_evidence_can_pass(self):
        a=self.evaluate()
        self.assertTrue(a['passed'],a)
        self.assertEqual(a['gates']['SC-007'],'not_applicable')
    def test_every_gate_evaluates_failure(self):
        mutations={
            'SC-001':lambda:self.m['fixtures'].pop(),
            'SC-002':lambda:self.report['fixtures'][0]['stages']['raw'].update(available=False),
            'SC-003':lambda:self.report['fixtures'][10]['stages']['assembled'].update(substitutions=100),
            'SC-004':lambda:self.e['assembly']['cases'][0].update(assembled_text='wrong'),
            'SC-005':lambda:self.report['fixtures'][0]['stages']['normalized'].update(unexpected_replacements=1),
            'SC-006':lambda:self.e['storage'].update(restart_exact_stages=False),
            'SC-008':lambda:self.e['resources'].update(idle_mb=151)}
        for gate,mutate in mutations.items():
            with self.subTest(gate=gate):
                self.setUp();mutate()
                result=self.evaluate()
                self.assertEqual(result['gates'][gate],'fail')
                self.assertFalse(result['passed'])
    def test_stale_missing_and_false_attestations(self):
        self.e['run_sha256']='f'*64
        a=self.evaluate()
        self.assertEqual(a['evidence_binding'],'stale')
        self.assertEqual(a['gates']['SC-006'],'unverified')
        self.assertFalse(a['passed'])
        self.setUp();del self.e['storage']['reviewer']
        self.assertEqual(self.evaluate()['gates']['SC-006'],'unverified')
        self.setUp();self.e['storage']['offline']='true'
        self.assertEqual(self.evaluate()['gates']['SC-006'],'unverified')
    def test_contract_hash_mismatch_and_missing_cases(self):
        self.e['assembly']['cases_sha256']='f'*64
        self.assertEqual(self.evaluate()['gates']['SC-004'],'unverified')
        self.setUp();self.e['normalization']['cases'].pop()
        self.assertEqual(self.evaluate()['gates']['SC-005'],'fail')
    def test_historical_baseline_uses_explicit_matching_stage(self):
        for row in self.base['fixtures']:
            row['stages']['normalized'].update(available=False,meaning='unreviewed')
        self.assertEqual(self.evaluate()['gates']['SC-003'],'pass')
        self.e['quality_stage']='normalized'
        self.assertEqual(self.evaluate()['gates']['SC-003'],'unverified')

    def test_retention_never_passes_mixed_accuracy(self):
        for row in self.report['fixtures'][-10:]: row['stages']['assembled']['substitutions']=25
        a=self.evaluate()
        self.assertEqual(a['gates']['SC-003'],'pass')
        self.assertFalse(a['inherited_authentic_mixed_15_percent'])
    def test_resource_thresholds_and_growth(self):
        self.e['resources'].update(idle_mb=150,capture_overhead_mb=100,settled_unloaded_mb=[170]*20)
        self.assertEqual(self.evaluate()['gates']['SC-008'],'pass')
        self.e['resources']['settled_unloaded_mb'][-1]=170.01
        self.assertEqual(self.evaluate()['gates']['SC-008'],'fail')
        self.e['resources'].update(idle_mb=100,settled_unloaded_mb=list(range(100,120)))
        self.assertFalse(self.evaluate()['checks']['SC-008']['growth_investigated'])
        self.e['resources']['growth_explained']=True
        self.assertEqual(self.evaluate()['gates']['SC-008'],'pass')
    def test_adoption_thresholds_and_repetitions(self):
        self.e['decision']['disposition']='replace'
        self.e['adoption']=dict(reviewer='test',date='2026-09-16',artifact_sha256='e'*64,
            same_workload_conditions=True,target_category='authentic_mixed',
            baseline_peak_transcription_mb=[100]*3,candidate_peak_transcription_mb=[80]*3,
            baseline_transcription_seconds=[10]*3,candidate_transcription_seconds=[10]*3)
        self.assertEqual(self.evaluate()['gates']['SC-007'],'pass')
        self.e['adoption']['candidate_peak_transcription_mb']=[80.01]*3
        self.assertEqual(self.evaluate()['gates']['SC-007'],'fail')
        self.e['adoption']['candidate_peak_transcription_mb']=[80]*2
        self.assertEqual(self.evaluate()['gates']['SC-007'],'fail')
        self.e['adoption']['candidate_peak_transcription_mb']=[80]*3
        self.e['decision']['disposition']='fallback'
        self.assertEqual(self.evaluate()['gates']['SC-007'],'unverified')
        self.e['adoption']['full_fallback_path']=False
        self.assertEqual(self.evaluate()['gates']['SC-007'],'fail')
    def test_tuning_cannot_supply_acceptance(self):
        for f in self.m['fixtures'][-10:]: f['partition']='tuning'
        self.assertEqual(self.evaluate()['gates']['SC-001'],'fail')
    def test_quality_relative_and_absolute_thresholds(self):
        del self.e['decision']
        for b,c in zip(self.base['fixtures'][-10:],self.report['fixtures'][-10:]):
            b['stages']['assembled']['substitutions']=25
            c['stages']['assembled']['substitutions']=20
        self.assertTrue(self.evaluate()['checks']['SC-003']['mixed_closure'])
        self.report['fixtures'][-1]['stages']['assembled']['substitutions']=21
        self.assertIsNone(self.evaluate()['checks']['SC-003']['mixed_closure'])
        self.report['fixtures'][0]['stages']['assembled']['substitutions']=1
        self.assertTrue(self.evaluate()['checks']['SC-003']['original_slovak_regression'])
        self.report['fixtures'][0]['stages']['assembled']['substitutions']=11
        self.assertFalse(self.evaluate()['checks']['SC-003']['original_slovak_regression'])

class AuthoredCorpusTests(unittest.TestCase):
    def test_exact_bytes_unique_ids_and_no_human_verdicts(self):
        for name in ('assembly','normalization'):
            cases=json.loads((q.gate_module.ROOT/f'fixtures/quality/{name}-cases.json').read_text())['cases']
            self.assertEqual(len(cases),len({c['id'] for c in cases}))
            for c in cases:
                if name=='assembly':
                    self.assertEqual(c['expected']['raw_utf8_hex'],[w['text'].encode().hex() for w in c['windows']])
                    self.assertEqual(c['expected']['assembled_words'],c['expected']['assembled_text'].split())
                    if c['expected']['incomplete']:
                        self.assertFalse(c['expected']['automatic_insertion_allowed'])
                        self.assertEqual(c['expected']['assembled_text'],' '.join(w['text'] for w in c['windows']))
                else:self.assertIsNone(c['human_meaning_verdict'])
    def test_private_corpus_ignored(self):
        import subprocess
        for path in ('fixtures/quality/manifest.json','fixtures/quality/private/manifest.json','fixtures/quality/private/recording.wav',
                     'fixtures/quality/private/recording.json','fixtures/quality/private/reviews.json'):
            self.assertEqual(subprocess.run(['git','check-ignore','-q',path]).returncode,0)

if __name__ == '__main__': unittest.main()
