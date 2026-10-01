---
language:
- en
library_name: nemo
datasets:
- librispeech_asr
- fisher_corpus
- mozilla-foundation/common_voice_8_0
- National-Singapore-Corpus-Part-1
- vctk
- voxpopuli
- europarl
- multilingual_librispeech
thumbnail: null
tags:
- automatic-speech-recognition
- speech
- audio
- Transducer
- TDT
- FastConformer
- Conformer
- pytorch
- NeMo
- hf-asr-leaderboard
license: cc-by-4.0
widget:
- example_title: Librispeech sample 1
  src: https://cdn-media.huggingface.co/speech_samples/sample1.flac
- example_title: Librispeech sample 2
  src: https://cdn-media.huggingface.co/speech_samples/sample2.flac
model-index:
- name: parakeet-tdt_ctc-110m
  results:
  - task:
      name: Automatic Speech Recognition
      type: automatic-speech-recognition
    dataset:
      name: AMI (Meetings test)
      type: edinburghcstr/ami
      config: ihm
      split: test
      args:
        language: en
    metrics:
    - name: Test WER
      type: wer
      value: 15.88
  - task:
      name: Automatic Speech Recognition
      type: automatic-speech-recognition
    dataset:
      name: Earnings-22
      type: revdotcom/earnings22
      split: test
      args:
        language: en
    metrics:
    - name: Test WER
      type: wer
      value: 12.42
  - task:
      name: Automatic Speech Recognition
      type: automatic-speech-recognition
    dataset:
      name: GigaSpeech
      type: speechcolab/gigaspeech
      split: test
      args:
        language: en
    metrics:
    - name: Test WER
      type: wer
      value: 10.52
  - task:
      name: Automatic Speech Recognition
      type: automatic-speech-recognition
    dataset:
      name: LibriSpeech (clean)
      type: librispeech_asr
      config: other
      split: test
      args:
        language: en
    metrics:
    - name: Test WER
      type: wer
      value: 2.4
  - task:
      name: Automatic Speech Recognition
      type: automatic-speech-recognition
    dataset:
      name: LibriSpeech (other)
      type: librispeech_asr
      config: other
      split: test
      args:
        language: en
    metrics:
    - name: Test WER
      type: wer
      value: 5.2
  - task:
      type: Automatic Speech Recognition
      name: automatic-speech-recognition
    dataset:
      name: SPGI Speech
      type: kensho/spgispeech
      config: test
      split: test
      args:
        language: en
    metrics:
    - name: Test WER
      type: wer
      value: 2.54
  - task:
      type: Automatic Speech Recognition
      name: automatic-speech-recognition
    dataset:
      name: tedlium-v3
      type: LIUM/tedlium
      config: release1
      split: test
      args:
        language: en
    metrics:
    - name: Test WER
      type: wer
      value: 4.16
  - task:
      name: Automatic Speech Recognition
      type: automatic-speech-recognition
    dataset:
      name: Vox Populi
      type: facebook/voxpopuli
      config: en
      split: test
      args:
        language: en
    metrics:
    - name: Test WER
      type: wer
      value: 6.91
metrics:
- wer
pipeline_tag: automatic-speech-recognition
base_model:
- nvidia/parakeet-tdt_ctc-110m
---

# Parakeet-TDT-CTC-110M CoreML

NVIDIA's Parakeet-TDT-CTC-110M model converted to CoreML format for efficient inference on Apple Silicon.

## Model Description

This is a hybrid ASR model with a shared Conformer encoder and two decoder heads:
- **CTC Head**: Fast greedy decoding, ideal for keyword spotting
- **TDT Head**: Token-Duration Transducer for high-quality transcription

### Architecture

| Component | Description | Size |
|-----------|-------------|------|
| Preprocessor | Mel spectrogram extraction | ~1 MB |
| Encoder | Conformer encoder (shared) | ~400 MB |
| CTCHead | CTC output projection | ~4 MB |
| Decoder | TDT prediction network (LSTM) | ~25 MB |
| JointDecision | TDT joint network | ~6 MB |

**Total size**: ~436 MB

### Performance

Benchmarked on Earnings22 dataset (772 audio files):

| Metric | Value |
|--------|-------|
| Keyword Recall | 100% (1309/1309) |
| WER | 17.97% |
| RTFx (M4 Pro) | 358x real-time |

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4)
- Python 3.10+

## Installation

```bash
# Using uv (recommended)
uv sync

# Or using pip
pip install -e .

# For audio file support (WAV, MP3, etc.)
pip install -e ".[audio]"
```

## Usage

### Python Inference

```python
from scripts.inference import ParakeetCoreML

# Load model (from current directory with .mlpackage files)
model = ParakeetCoreML(".")

# Transcribe with TDT (higher quality)
text = model.transcribe("audio.wav", mode="tdt")
print(text)

# Or use CTC for faster keyword spotting
text = model.transcribe("audio.wav", mode="ctc")
print(text)
```

### Command Line

```bash
# TDT decoding (default, higher quality)
uv run scripts/inference.py --audio audio.wav

# CTC decoding (faster, good for keyword spotting)
uv run scripts/inference.py --audio audio.wav --mode ctc
```

## Model Conversion

To convert from the original NeMo model:

```bash
# Install conversion dependencies
uv sync --extra convert

# Run conversion
uv run scripts/convert_nemo_to_coreml.py --output-dir ./model
```

This will:
1. Download the original model from NVIDIA (`nvidia/parakeet-tdt_ctc-110m`)
2. Convert each component to CoreML format
3. Extract vocabulary and create metadata

## File Structure

```
./
├── Preprocessor.mlpackage    # Audio → Mel spectrogram
├── Encoder.mlpackage         # Mel → Encoder features
├── CTCHead.mlpackage         # Encoder → CTC log probs
├── Decoder.mlpackage         # TDT prediction network
├── JointDecision.mlpackage   # TDT joint network
├── vocab.json                # Token vocabulary (1024 tokens)
├── metadata.json             # Model configuration
├── pyproject.toml            # Python dependencies
├── uv.lock                   # Locked dependencies
└── scripts/                  # Inference & conversion scripts
```

## Decoding Modes

### TDT Mode (Recommended for Transcription)
- Uses Token-Duration Transducer decoding
- Higher accuracy (17.97% WER)
- Predicts both tokens and durations
- Best for full transcription tasks

### CTC Mode (Recommended for Keyword Spotting)
- Greedy CTC decoding
- Faster inference
- 100% keyword recall on Earnings22
- Best for detecting specific words/phrases

## Custom Vocabulary / Keyword Spotting

For keyword spotting, CTC mode with custom vocabulary boosting achieves 100% recall:

```python
# Load custom vocabulary with token IDs
with open("custom_vocab.json") as f:
    keywords = json.load(f)  # {"keyword": [token_ids], ...}

# Run CTC decoding
tokens = model.decode_ctc(encoder_output)

# Check for keyword matches
for keyword, expected_ids in keywords.items():
    if is_subsequence(expected_ids, tokens):
        print(f"Found keyword: {keyword}")
```

## License

This model conversion is released under the Apache 2.0 License, same as the original NVIDIA model.

## Citation

If you use this model, please cite the original NVIDIA work:

```bibtex
@misc{nvidia_parakeet_tdt_ctc,
  title={Parakeet-TDT-CTC-110M},
  author={NVIDIA},
  year={2024},
  publisher={Hugging Face},
  url={https://huggingface.co/nvidia/parakeet-tdt_ctc-110m}
}
```

## Acknowledgments

- Original model by [NVIDIA NeMo](https://github.com/NVIDIA/NeMo)
- CoreML conversion by [FluidInference](https://github.com/FluidInference)