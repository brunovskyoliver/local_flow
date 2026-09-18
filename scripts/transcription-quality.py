#!/usr/bin/env python3
"""Bounded offline scoring. Speech content is never printed by this CLI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import unicodedata
import importlib.util

_gate_spec = importlib.util.spec_from_file_location("quality_gates", Path(__file__).with_name("quality-gates.py"))
gate_module = importlib.util.module_from_spec(_gate_spec)
_gate_spec.loader.exec_module(gate_module)

VERSION = 'quality-score-v2'
SMALL = 4_194_304
ARTIFACT = 16_777_216
STAGES = ('raw', 'assembled', 'normalized')

class Invalid(Exception):
    pass

def require(ok):
    if not ok: raise Invalid('invalid_artifact')

def sha(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()

def canonical(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()

def safe_id(value):
    require(isinstance(value,str) and 0 < len(value) <= 128 and re.fullmatch(r'[A-Za-z0-9_-]+',value))
    return value

def digest(value):
    require(isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value))

def bounded_text(value, limit=65536):
    require(isinstance(value,str) and len(value.encode()) <= limit)

def read(path, limit=SMALL):
    path=Path(path)
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as f:
        require(os.fstat(f.fileno()).st_size <= limit)
        data=f.read(limit+1)
    require(len(data)<=limit)
    def pairs(items):
        result={}
        for key,value in items:
            require(key not in result); result[key]=value
        return result
    return json.loads(data,object_pairs_hook=pairs,parse_constant=lambda _: (_ for _ in ()).throw(Invalid())),hashlib.sha256(data).hexdigest()

def write_new(path, obj):
    data=canonical(obj)+b'\n'
    require(len(data)<=SMALL)
    path=Path(path)
    require(path.parent.is_dir() and not path.parent.is_symlink())
    # Caller chooses a private parent; never change permissions of unrelated directories.
    require(path.parent.stat().st_mode & 0o077 == 0)
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as f:
        f.write(data); f.flush(); os.fsync(f.fileno())
    fd=os.open(path.parent,os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)

def tokens(text):
    bounded_text(text,262144)
    require(len(text)<=65536)
    words=[]
    for word in unicodedata.normalize('NFC',text).lower().split():
        if not any(c.isdigit() or c in '/@_`\\' for c in word):
            stripped=word.strip('.,!?;:"()[]{}')
            if stripped: word=stripped
        words.append(word)
        require(len(words)<=16384)
    require(sum(map(len,words))<=65536)
    return words

def distance(reference,hypothesis):
    """Two rows of (cost,S,D,I); stable match/substitution/deletion/insertion ties."""
    if reference == hypothesis: return (0,0,0)
    if not hypothesis: return (0,len(reference),0)
    if not reference: return (0,0,len(hypothesis))
    previous=[(j,0,0,j) for j in range(len(hypothesis)+1)]
    for i,a in enumerate(reference,1):
        current=[(i,0,i,0)]
        for j,b in enumerate(hypothesis,1):
            diag=previous[j-1]
            if a==b: candidates=[diag]
            else: candidates=[(diag[0]+1,diag[1]+1,diag[2],diag[3])]
            up=previous[j]; left=current[j-1]
            candidates.extend([(up[0]+1,up[1],up[2]+1,up[3]),(left[0]+1,left[1],left[2],left[3]+1)])
            current.append(min(candidates,key=lambda x:x[0]))
        previous=current
    return previous[-1][1:]

def technical_accuracy(reference, hypothesis, terms):
    """Follow the same tie-broken alignment and count exact annotated target spans."""
    if not terms: return {'technical_total':0,'technical_correct':0,'unexpected_replacements':0}
    raw_h=hypothesis.split(); r=tokens(reference); h=tokens(hypothesis)
    endings={}
    selected=[t for t in terms if t['held_out']]
    for bit,t in enumerate(selected):
        width=t.get('reference_token_count',len(t['canonical'].split()))
        endings.setdefault(t['reference_token']+width,[]).append((bit,t,width))
    # cost, completed occurrence bitset, consecutive diagonal steps
    previous=[(j,0,0) for j in range(len(h)+1)]
    for i,a in enumerate(r,1):
        current=[(i,0,0)]
        for j,b in enumerate(h,1):
            diag=previous[j-1]; mask=diag[1]; streak=diag[2]+1
            for bit,t,width in endings.get(i,[]):
                if streak>=width and j>=width and raw_h[j-width:j]==t['canonical'].split(): mask |= 1<<bit
            choices=[(diag[0]+(a!=b),mask,streak),(previous[j][0]+1,previous[j][1],0),(current[j-1][0]+1,current[j-1][1],0)]
            current.append(min(choices,key=lambda x:x[0]))
        previous=current
    mask=previous[-1][1]
    positive=[i for i,t in enumerate(selected) if t.get('expected',True)]
    negative=[i for i,t in enumerate(selected) if not t.get('expected',True)]
    return {'technical_total':len(positive),'technical_correct':sum(bool(mask & (1<<i)) for i in positive),'unexpected_replacements':sum(bool(mask & (1<<i)) for i in negative)}

def rate(n,d): return f'{n/d:.6f}' if d else None

def metrics(reference,hypothesis):
    r=tokens(reference); h=tokens(hypothesis)
    s,d,i=distance(r,h); cs,cd,ci=distance(''.join(r),''.join(h))
    return dict(substitutions=s,deletions=d,insertions=i,reference_words=len(r),character_errors=cs+cd+ci,reference_characters=len(''.join(r)),wer=rate(s+d+i,len(r)),cer=rate(cs+cd+ci,len(''.join(r))),hallucination=not r and bool(h))

def aggregate(rows):
    fields=('substitutions','deletions','insertions','reference_words','character_errors','reference_characters')
    out={k:sum(r[k] for r in rows) for k in fields}
    out['wer']=rate(sum(out[k] for k in fields[:3]),out['reference_words'])
    out['cer']=rate(out['character_errors'],out['reference_characters'])
    return out

def manifest(path):
    m,h=read(path)
    require(m['schema_version']==2); safe_id(m['set_version'])
    fixtures=m['fixtures']; require(isinstance(fixtures,list) and 1<=len(fixtures)<=256)
    seen=set(); categories=set()
    for f in fixtures:
        safe_id(f['id']); require(f['id'] not in seen); seen.add(f['id'])
        p=Path(f['path']); require(not p.is_absolute() and '..' not in p.parts and str(p)!='.')
        digest(f['sha256']); digest(f['reference_sha256']); bounded_text(f['reference'])
        require(sha(f['reference'])==f['reference_sha256']); tokens(f['reference'])
        require(f['sample_rate']==16000 and type(f['num_samples']) is int and 1<=f['num_samples']<=2880000)
        require(abs(f['duration_seconds']-f['num_samples']/16000)<0.0001)
        require(f['partition'] in ('tuning','acceptance','regression'))
        require(f['classification'] in ('authentic','synthetic'))
        if 'provenance' in f:
            provenance=f['provenance']; require(isinstance(provenance,dict))
            require(len(canonical(provenance))<=16384)
            for key in ('dataset','version','source_clip_id'):
                bounded_text(provenance[key],4096); require(bool(provenance[key]))
        if 'authentic_mixed' in f['categories']:
            require(f['classification']=='authentic' and set(f['languages'])=={'sk','en'} and bool(f['switches']))
        require(0<len(f['categories'])<=32 and len(set(f['categories']))==len(f['categories']))
        for c in f['categories']: safe_id(c); categories.add(c)
        require(0<len(f['languages'])<=8)
        for lang in f['languages']: safe_id(lang)
        for key in ('source','rights','consent_basis'): bounded_text(f[key],4096); require(bool(f[key]))
        require(len(f['derivations'])<=32)
        for item in f['derivations']: bounded_text(item,4096)
        require(len(f['switches'])<=256 and len(f['technical_terms'])<=256)
        for switch in f['switches']:
            require(0<=switch['start_sample']<=switch['end_sample']<=f['num_samples'])
            safe_id(switch['from']); safe_id(switch['to'])
        for term in f['technical_terms']:
            bounded_text(term['canonical'],256)
            require(type(term['reference_token']) is int and 0<=term['reference_token']<len(f['reference'].split()))
            require(type(term['held_out']) is bool)
    require(len(categories)<=32)
    return m,h

def review_valid(r,fixture,stage,reference,output):
    return (r.get('fixture_id')==fixture and r.get('stage')==stage and r.get('reference_sha256')==reference and r.get('output_sha256')==output and bool(r.get('reviewer')) and bool(re.fullmatch(r'\d{4}-\d{2}-\d{2}',r.get('date',''))) and r.get('verdict') in ('preserved','changed','uncertain'))

def reviews(path):
    if path is None: return []
    obj,_=read(path); require(obj['schema_version']==2 and len(obj['reviews'])<=768)
    seen=set()
    for r in obj['reviews']:
        safe_id(r['fixture_id']); require(r['stage'] in STAGES)
        bounded_text(r['reviewer'],128); bounded_text(r['explanation'],4096)
        bounded_text(r['date'],32); digest(r['reference_sha256']); digest(r['output_sha256'])
        require(r['verdict'] in (None,'preserved','changed','uncertain'))
        key=(r['fixture_id'],r['stage']); require(key not in seen); seen.add(key)
    return obj['reviews']

def load_run(root,m,mh):
    root=Path(root); require(not root.is_symlink())
    run,rh=read(root/'run.json')
    require(run['schema_version']==2 and run['manifest_sha256']==mh and run['scoring_version']==VERSION)
    require(run['status'] in ('prepared','running','complete','aborted','interrupted'))
    require(len(run['ledger'])==len(m['fixtures']))
    require([r['id'] for r in run['ledger']]==[f['id'] for f in m['fixtures']])
    require(hashlib.sha256(canonical(run['config'])).hexdigest()==run['config_sha256'])
    for row in run['ledger']:
        require(row['status'] in ('pending','running','completed','failed','cancelled','not_run','interrupted'))
        if row['result_sha256'] is not None: digest(row['result_sha256'])
    return run,rh

def result(root,row):
    p=Path(root)/'results'/f"{row['id']}.json"
    require(not p.parent.is_symlink())
    obj,h=read(p,ARTIFACT)
    require(row['result_sha256']==h and obj['schema_version']==2 and obj['id']==row['id'])
    require(obj['status']==row['status'] and type(obj['incomplete']) is bool)
    require(len(obj['windows'])<=32 and len(obj['reasons'])<=64)
    for reason in obj['reasons']: safe_id(reason)
    for w in obj['windows']:
        bounded_text(w['text']); require(sha(w['text'])==w['sha256'])
        require(len(w['tokens'])<=16384 and sum(len(t['text'].encode()) for t in w['tokens'])<=65536)
    for stage in STAGES:
        v=obj['stages'][stage]
        safe_id(v['identity'])
        if v['text'] is None:
            require(v['sha256'] is None and bool(v['unavailable_reason'])); bounded_text(v['unavailable_reason'],4096)
        else:
            bounded_text(v['text'],262144); require(sha(v['text'])==v['sha256'])
    if obj['stages']['raw']['text'] is not None:
        require(obj['stages']['raw']['text']=='\n'.join(w['text'] for w in obj['windows']))
    for name,value in obj['measurements'].items():
        safe_id(name); bounded_text(value['unit'],128)
        require(value['value'] is not None or bool(value['reason']))
    return obj

def score(m,mh,root,review_rows):
    run,rh=load_run(root,m,mh); summaries=[]; groups={}; templates=[]
    for f,row in zip(m['fixtures'],run['ledger']):
        failure=None
        try: obj=result(root,row)
        except (OSError,ValueError,KeyError,TypeError,Invalid,RecursionError): obj=None; failure='missing_or_invalid_result'
        summary={'id':f['id'],'status':row['status'],'incomplete':obj['incomplete'] if obj else True,'score_failure':failure,'stages':{}}
        if 'provenance' in f:
            summary['provenance']=f['provenance']
        for stage in STAGES:
            v=obj['stages'][stage] if obj else None
            text=v['text'] if v else None
            try: counts=metrics(f['reference'],text or '')
            except Invalid: counts=metrics(f['reference'],''); summary['score_failure']='scoring_capacity'; text=None
            reviewed=next((r for r in review_rows if review_valid(r,f['id'],stage,f['reference_sha256'],v['sha256'] if v else None)),None)
            counts.update(output_sha256=v['sha256'] if v else None,identity=v['identity'] if v else None,available=text is not None,meaning=reviewed['verdict'] if reviewed else 'unreviewed')
            # Exact case-sensitive sequence occurrences are reported independently of WER.
            counts.update(technical_accuracy(f['reference'],text or '',f['technical_terms']))
            summary['stages'][stage]=counts
            if text is not None:
                templates.append(dict(fixture_id=f['id'],stage=stage,reference_sha256=f['reference_sha256'],output_sha256=v['sha256'],reviewer='',date='',verdict=None,explanation=''))
            for category in f['categories']:
                groups.setdefault(category,{}).setdefault(stage,[]).append(counts)
        summaries.append(summary)
    report={'schema_version':2,'scoring_version':VERSION,'python_version':sys.version.split()[0],'unicode_version':unicodedata.unidata_version,'manifest_sha256':mh,'run_sha256':rh,'raw_label':'received_window_LF_concatenation_includes_overlap','fixtures':summaries,'categories':{c:{s:aggregate(rows) for s,rows in stages.items()} for c,stages in groups.items()},'acceptance':{}}
    report["acceptance"]=gate_module.evaluate(m,report,run)
    require(len(canonical(report))<=SMALL)
    return report,templates,run

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    for name in ('score','compare','review-template'):
        p=sub.add_parser(name); p.add_argument('manifest'); p.add_argument('run')
        if name=='compare': p.add_argument('candidate')
        p.add_argument('output')
        if name=='score':
            p.add_argument('--reviews'); p.add_argument('--require-acceptance',action='store_true')
            p.add_argument('--evidence'); p.add_argument('--baseline'); p.add_argument('--baseline-reviews')
            p.add_argument('--repeat')
    args=parser.parse_args()
    try:
        m,mh=manifest(args.manifest)
        report,template,run=score(m,mh,args.run,reviews(getattr(args,'reviews',None)))
        if args.command=='review-template': out={'schema_version':2,'reviews':template}
        elif args.command=='compare':
            other,_,candidate=score(m,mh,args.candidate,[])
            changes=[k for k in sorted(set(run['config'])|set(candidate['config'])) if run['config'].get(k)!=candidate['config'].get(k)]
            out={'schema_version':2,'manifest_sha256':mh,'scoring_version':VERSION,'changed_factors':changes,'declared_factors_match':set(changes)==set(candidate.get('changed_factors',[])),'fixtures':[{'id':a['id'],'baseline':a,'candidate':b,'changed':a!=b} for a,b in zip(report['fixtures'],other['fixtures'])],'baseline_categories':report['categories'],'candidate_categories':other['categories']}
        else:
            baseline=None; repeat=None
            if args.baseline:
                b,_,br=score(m,mh,args.baseline,reviews(args.baseline_reviews))
                baseline=(b,br)
            if args.repeat:
                r,_,rr=score(m,mh,args.repeat,[])
                require(r['run_sha256'] != report['run_sha256'])
                repeat=(r,rr)
            again,_,_=score(m,mh,args.run,reviews(args.reviews))
            evidence,evidence_hash=read(args.evidence) if args.evidence else (None,None)
            report['acceptance']=gate_module.evaluate(m,report,run,evidence,baseline,repeat,
                rescored=canonical(again)==canonical(report))
            report['acceptance']['evidence_sha256']=evidence_hash
            report['acceptance']['baseline_run_sha256']=baseline[0]['run_sha256'] if baseline else None
            report['acceptance']['repeat_run_sha256']=repeat[0]['run_sha256'] if repeat else None
            if repeat:
                report['recognition_repeat_differences']=[{'id':a['id'],'status_changed':a['status']!=b['status'],
                    'incomplete_changed':a['incomplete']!=b['incomplete'],
                    'changed_stage_hashes':[s for s in STAGES if a['stages'][s]['output_sha256']!=b['stages'][s]['output_sha256']]}
                    for a,b in zip(report['fixtures'],repeat[0]['fixtures'])]
            out=report
        write_new(args.output,out)
        return 2 if getattr(args,'require_acceptance',False) and not report['acceptance']['passed'] else 0
    except (Invalid,OSError,ValueError,KeyError,TypeError,RecursionError):
        print('quality_evaluation_invalid_input_or_output',file=sys.stderr); return 1

if __name__=='__main__': sys.exit(main())
