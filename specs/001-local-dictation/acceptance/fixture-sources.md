# Speech fixture sources

Research checked 2026-09-16. This document records source suitability; it does not claim audio was downloaded or accuracy was measured.

Google FLEURS provides Slovak (`sk_sk`) and American English (`en_us`) recordings with both raw and normalized reference transcripts. Its official dataset card identifies the release as CC BY 4.0. Preserve both transcript forms, source filename, sentence ID, split, repository revision, downloaded-file SHA-256, and any conversion steps in the fixture manifest. [Google dataset card](https://huggingface.co/datasets/google/fleurs/blob/main/README.md)

The source paper describes read speech at 16 kHz, with recordings shorter than 30 seconds, and separate speakers for training/development versus test. These clips can exercise real speech decoding, but they do not reproduce live microphone dictation or prove performance for the user's accent and environment. I did not find individual consent records or an explicit consent statement in the card or paper. Record the rights basis as the publisher's CC BY 4.0 release, with individual consent documentation unavailable. [FLEURS paper](https://arxiv.org/pdf/2205.12446)

## Bounded acquisition

The repository API reported revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd` during this check. Resolve files against that revision for reproducibility; this is a fixture source revision, not a dependency or model pin change.

- Transcript URLs follow `https://huggingface.co/datasets/google/fleurs/resolve/70bb2e84b976b7e960aa89f1c648e09c59f894dd/data/{locale}/test.tsv`.
- Audio archives follow the same prefix plus `data/{locale}/audio/test.tar.gz`. Slovak test is about 450 MB. A streaming tar reader can stop after extracting ten valid complete recordings whose filenames match the TSV, without downloading the entire archive. Select before running recognition to avoid cherry-picking.
- The alternative [Hugging Face rows API](https://huggingface.co/docs/dataset-viewer/en/rows) accepts `dataset=google/fleurs`, `config=sk_sk` or `en_us`, `split=test`, `offset=0`, and `length=10`. The Slovak request returned HTTP 500 during this check. Do not depend on this route without checking the response.
- Avoid loading every locale. The Slovak test Parquet alone is about 585 MB.

## Mixed-language limitation

CC BY 4.0 permits adaptations with attribution, a license link, and a notice describing changes. Concatenating licensed Slovak and English utterances is therefore a practical source of explicitly artificial mixed-language stress fixtures. Keep the component filenames and transcripts and record the join, inserted silence, and format conversion. [CC BY 4.0 terms](https://creativecommons.org/licenses/by/4.0/)

Such concatenations cannot establish authentic within-speaker code-switching accuracy. Keep them separate from the ten required natural mixed-language acceptance recordings.

A TUKE paper describes a Slovak-English bilingual corpus, but I found no downloadable corpus release with an explicit audio license in that paper. The paper's CC BY license applies to the publication; it must not be assumed to license its source recordings. Authentic mixed-language acceptance remains open until suitable licensed recordings or consented local recordings are available. [TUKE bilingual speech paper](https://ceur-ws.org/Vol-2473/paper28.pdf)
