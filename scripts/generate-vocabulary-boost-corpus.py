#!/usr/bin/env python3
"""Speak an authored Feature 013 corpus with macOS voices into a private directory.

Usage: generate-vocabulary-boost-corpus.py fixtures/vocabulary-boost/tuning.json build/boost-tuning

Writes 16 kHz mono float WAVs, manifest.json ([{id, wav, reference, set}]) and
vocabulary.json. Synthetic speech: a proxy for accents and term pronunciation,
not for the owner's voice. Never called by make check.
"""
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def main(corpus_path, out):
    corpus = json.loads(Path(corpus_path).read_text())
    out = Path(out)
    (out / 'wav').mkdir(parents=True, exist_ok=True, mode=0o700)
    manifest, jobs = [], []
    for subset, sentences in corpus['sentences'].items():
        language = subset[:2]
        for index, text in enumerate(sentences):
            for voice in corpus['voices'][language]:
                for rate in corpus['rates'][language]:
                    clip = f"{subset}-{index:02d}-{voice.split()[0].lower()}" + (f"-r{rate}" if rate else '')
                    wav = out / 'wav' / f'{clip}.wav'
                    command = ['say', '-v', voice, '-o', str(wav), '--file-format=WAVE',
                               '--data-format=LEF32@16000'] + (['-r', str(rate)] if rate else []) + [text]
                    jobs.append((wav, command))
                    manifest.append(dict(id=clip, wav=str(wav.resolve()), reference=text, set=subset))

    def speak(job):
        wav, command = job
        if not wav.exists() or wav.stat().st_size < 8_000:
            subprocess.run(command, check=True)

    with ThreadPoolExecutor(os.cpu_count() or 4) as pool:
        list(pool.map(speak, jobs))
    (out / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False))
    (out / 'vocabulary.json').write_text(json.dumps(corpus['vocabulary'], ensure_ascii=False))
    print(f'{len(manifest)} clips')


if __name__ == '__main__':
    main(*sys.argv[1:3])
