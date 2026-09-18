#!/usr/bin/env python3
"""Offline acquisition regression checks; generated tones are test-only inputs."""
import importlib.util
import io
from pathlib import Path
import struct
import tempfile
import unittest
import wave

spec = importlib.util.spec_from_file_location('acquire', Path(__file__).with_name('acquire-quality-corpus.py'))
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


class AcquisitionTests(unittest.TestCase):
    def test_long_candidates_are_one_continuous_source_interval(self):
        rows=[]
        for index,(start,end) in enumerate(((10,35),(35.2,60),(60.4,75))):
            rows.append({'session_id':'recording','id_':f'span-{index}','start':start,'end':end})
        candidates=a.long_candidates(rows,60,90,1)
        self.assertEqual(len(candidates),1)
        candidate=candidates[0]
        self.assertEqual((candidate['start'],candidate['end']), (10,75))
        self.assertEqual([row['id_'] for row in candidate['rows']],
                         ['span-0','span-1','span-2'])
        self.assertAlmostEqual(candidate['maximum_gap'],.4)

    def test_long_candidate_rejects_unbounded_transcript_gap(self):
        rows=[{'session_id':'recording','id_':'a','start':0,'end':40},
              {'session_id':'recording','id_':'b','start':50,'end':90}]
        self.assertEqual(a.long_candidates(rows,60,90,3),[])

    def test_selection_excludes_legacy_and_quota_overlap(self):
        rows = [dict(clip=f'{i:03}.wav', reference='computer version 123' if i < 10 else 'number 42') for i in range(50)]
        selected = a.select_rows(reversed(rows), {'000.wav'})
        self.assertEqual(len(selected), 30)
        self.assertEqual(len({r['clip'] for r, _ in selected}), 30)
        self.assertNotIn('000.wav', [r['clip'] for r, _ in selected])
        self.assertEqual(selected, a.select_rows(rows, {'000.wav'}))

    def test_shortage_fails_instead_of_relabeling(self):
        with self.assertRaisesRegex(ValueError, 'shortage'):
            a.select_rows([dict(clip='a.wav', reference='ordinary words')], set())

    def test_float_wav_duration_and_truncation(self):
        fmt = struct.pack('<HHIIHH', 3, 1, 16000, 64000, 4, 32)
        payload = b'\0' * 64000
        body = b'WAVEfmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(payload)) + payload
        raw = b'RIFF' + struct.pack('<I', len(body)) + body
        self.assertEqual(a.wav_duration(raw), 1)
        with self.assertRaisesRegex(ValueError, 'truncated'):
            a.wav_duration(raw[:-1])

    def test_conversion_is_identical_pcm16_mono_16k(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source.wav'
            with wave.open(str(source), 'wb') as out:
                out.setparams((2, 2, 48000, 0, 'NONE', 'not compressed'))
                out.writeframes(struct.pack('<hh', 100, -50) * 4800)
            first, second = root / 'a.wav', root / 'b.wav'
            self.assertEqual(a.convert(source, first), 1600)
            a.convert(source, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with wave.open(str(first)) as result:
                self.assertEqual((result.getnchannels(), result.getframerate(), result.getsampwidth()), (1, 16000, 2))

    def test_changed_cached_source_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'source'
            path.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'hash_mismatch'):
                a.download('https://invalid.example/never-requested', path, '0' * 64)


class ProvenanceTests(unittest.TestCase):
    def test_record_pins_source_and_converted_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); data=io.BytesIO()
            with wave.open(data,'wb') as out:
                out.setparams((1,2,16000,0,'NONE','not compressed'))
                out.writeframes(b'\x00\x01'*1600)
            raw=data.getvalue()
            source=dict(dataset='google/fleurs',source_clip_id='authored.wav',source_url='https://example.invalid',
                        version='test',split='test',reference_field='authored',reference_source_url='authored')
            fixture=a.record(root,raw,source,'authored test',['public_sk_general'],'sk',{'rule':'test'})
            self.assertEqual(fixture['provenance']['original_duration_seconds'],.1)
            self.assertEqual(fixture['provenance']['converted_duration_seconds'],.1)
            self.assertEqual(fixture['provenance']['source_audio_sha256'],a.sha(raw))
            self.assertEqual(fixture['provenance']['subset'],'public_evaluation')
            self.assertEqual(fixture['provenance']['source_language'],'sk')
            self.assertEqual(fixture['sha256'],a.digest(root/fixture['path']))
            self.assertEqual(fixture['reference_sha256'],a.sha(b'authored test'))
    def test_manifest_builder_preserves_source_subset(self):
        import json
        builder=a.module('build-quality-manifest')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);wav=root/'test.wav'
            with wave.open(str(wav),'wb') as out:
                out.setparams((1,2,16000,0,'NONE','not compressed'));out.writeframes(b'\0\0'*1600)
            sidecar=root/'test.json'
            body=dict(reference='authored',categories=['test'],languages=['en'],source='test',rights='authored',
                      consent_basis='no speech',provenance={'subset':'public_evaluation','dataset':'test'})
            sidecar.write_text(json.dumps(body))
            fixture=builder.fixture(sidecar,builder.scorer())
            self.assertEqual(fixture['corpus_subset'],'public_evaluation')
            self.assertEqual(fixture['provenance'],body['provenance'])
            body['classification']='synthetic';sidecar.write_text(json.dumps(body))
            with self.assertRaisesRegex(ValueError,'subset_classification'):
                builder.fixture(sidecar,builder.scorer())
    def test_optional_common_voice_local_archives_need_no_credentials(self):
        import tarfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); cache=root/'cache';cache.mkdir()
            archives=[]
            for language in ('sk','en'):
                path=root/(language+'.tar.gz');archives.append(path)
                prefix=a.CV+'/'+language+'/'
                rows=[(f'{language}-{i:03}.mp3','computer version 123' if i<10 else 'number 42') for i in range(40)]
                with tarfile.open(path,'w:gz') as archive:
                    metadata=('path\tsentence\n'+''.join(f'{name}\t{text}\n' for name,text in rows)).encode()
                    item=tarfile.TarInfo(prefix+'validated.tsv');item.size=len(metadata);archive.addfile(item,io.BytesIO(metadata))
                    for name,_ in rows:
                        item=tarfile.TarInfo(prefix+'clips/'+name);item.size=1;archive.addfile(item,io.BytesIO(b'x'))
            def capture(root,raw,source,reference,categories,language,conversion):
                return dict(source=source,categories=categories,language=language)
            with mock.patch.object(a,'fetch',side_effect=AssertionError('must not request credentials')), mock.patch.object(a,'record',side_effect=capture):
                result=a.common_voice(root,cache,{},archives)
            self.assertEqual(len(result),60)
            self.assertEqual(len({f['source']['source_clip_id'] for f in result}),60)
            self.assertTrue(all(f['source']['split']=='validated' for f in result))
            self.assertTrue(all(f['source']['version']==a.CV for f in result))
            self.assertTrue(all(f['source']['reference_field']=='validated.tsv sentence' for f in result))

    def test_corpus_validation_detects_changed_audio_before_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'one.wav').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'converted_hash'):
                a.validate_corpus({'fixtures':[dict(path='one.wav',sha256='0'*64)]},root)
    def test_licensing_data_is_distinct_from_code(self):
        # Pin the selected data's rights declaration through the real record path.
        with tempfile.TemporaryDirectory() as directory:
            data=io.BytesIO()
            with wave.open(data,'wb') as out:
                out.setparams((1,2,16000,0,'NONE','not compressed'));out.writeframes(b'\0\0'*1600)
            source=dict(dataset='facebook/voxpopuli',source_clip_id='test',source_url='authored')
            f=a.record(Path(directory),data.getvalue(),source,'test',['test'],'en',{})
            self.assertIn('CC0-1.0',f['rights'])
            self.assertNotIn('NC',f['rights'])

if __name__ == '__main__':
    unittest.main()
