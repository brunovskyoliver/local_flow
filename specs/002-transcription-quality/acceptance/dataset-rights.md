# Public corpus rights review

Reviewed 2026-09-16, before acquisition-code changes.

## Common Voice

Pin: Mozilla Common Voice Scripted Speech `cv-corpus-26.0-2026-06-12`, locales `sk` and `en`. Mozilla lists both as CC0-1.0. Prefer `validated.tsv`; do not infer validation from filenames. [Slovak release](https://mozilladatacollective.com/datasets/cmqinsswu00xanq07gb1dex5z), [Mozilla release catalog](https://mozilladatacollective.com/datasets?q=Common+Voice+Corpus).

The [consumer terms](https://mozilladatacollective.com/terms/consumers), updated May 6, 2026, also govern access. They require dataset-license acceptance, prohibit speaker identification and bypassing access controls, and restrict redistribution. CC0 alone does not establish permission to republish a downloaded subset under these platform terms. Keep audio and reference-bearing manifests local; publish selection rules, dataset identifiers and hashes only until permission for reference redistribution is established. No speaker identities will be inferred.

The [official API](https://mozilladatacollective.com/api-reference/docs) requires an API key and previously satisfied access requirements for downloads. Account terms acceptance occurs on the website. An unauthenticated dataset-detail request from this environment returned HTTP 403. No access controls were bypassed. English release ID is `cmqim2hn800ssnr07gvmpcnwu`. Archive checksums still need retrieval through authorized access before a Common Voice corpus freeze. The owner confirms no local downloads or credentials are configured; Common Voice is optional and cannot block the public baseline.

## VoxPopuli

Pin: upstream repository revision `f7a3bb98d664e1d031763ec4f7639c4a530c64e9`;
publisher data revision `42f01879c780b4a2e90ec0b4f616c2ece526e4f1`.
The [pinned upstream license table](https://github.com/facebookresearch/voxpopuli/tree/f7a3bb98d664e1d031763ec4f7639c4a530c64e9#license)
explicitly distinguishes **VoxPopuli Data: CC0** from code and pretrained models:
CC-BY-NC-4.0. The repository's LICENSE file covers the latter; it does not establish a
conflicting noncommercial data license. This corrects the earlier review's conflation.
The [publisher dataset card](https://huggingface.co/datasets/facebook/voxpopuli/blob/42f01879c780b4a2e90ec0b4f616c2ece526e4f1/README.md)
also declares CC0 for data. No VoxPopuli model or code is used in LocalFlow.

Credit Wang et al., VoxPopuli (ACL 2021), Facebook Research and the European Parliament.
Retain the [European Parliament legal notice](https://www.europarl.europa.eu/legal-notice/en/)
and source attribution. The corpus is used for local ASR evaluation, without speaker
identification, endorsement claims or redistribution of audio. Exact source segments are
converted without content editing. Transcript/alignment accuracy is not guaranteed by licensing.

The publisher supplies Slovak transcripts and a Slovak-accented-English `en_sk` label.
Accent labels are retained, never inferred from speaker identities. They do not demonstrate
within-speaker code-switching. Pin shard LFS SHA-256 values, source clip hashes and converted
hashes in addition to the dataset revision. Files are publisher-hosted and downloadable
without an account; no access-control workaround is needed.

The long-form acceptance corpus uses the same pinned data and rights basis, but obtains exact
continuous intervals from the publisher's original year recordings and official ASR
annotations. It preserves the original recording hash, interval timestamps, transcript span
IDs and converted hash. It does not combine unrelated source material, redistribute audio, or
change the license conclusion above.

## Acceptance implications

No manual private recording is required. Authentic within-speaker Slovak/English switching remains a separate coverage gap. Synthetic concatenation cannot close it. Existing FLEURS fixtures retain their existing rights and derivations in a separate legacy subset. This review does not certify dataset transcript accuracy, speaker consent beyond published provenance, or transcript accuracy for VoxPopuli.

## Downloadable fallback approved by the owner

The owner confirmed noncommercial research/evaluation and requested a source without account-specific access. Use new FLEURS test clips for general, technology and entity/numeric coverage; preserve the original 30 separately. Google publishes FLEURS under CC-BY-4.0. Pin `google/fleurs` revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`, matching the legacy source revision, with new clip IDs excluding every legacy component. Credit Conneau et al., FLEURS (2022), Google. [Publisher dataset card](https://huggingface.co/datasets/google/fleurs/tree/70bb2e84b976b7e960aa89f1c648e09c59f894dd). License permits evaluation and reference metadata redistribution with attribution and conversion notices.

Use publisher-hosted `facebook/voxpopuli` at the data revision above, Slovak test and
`en_accented` test filtered by source accent `en_sk`. The license distinction is documented
above. Acquisition v2 corrects the old overly restrictive rights string and adds explicit
source durations, reference-field provenance and corpus-subset identifiers. It preserves
all selected audio and references from the initial acquisition.
