# Quickstart: Dictionary term boosting and suggestions

1. Settings › Term booster › Download (103 MB).
2. Add a term to the Dictionary, for example "Zabbix", with no alias.
3. Dictate "Zabbix sends the alert to the on-call channel." The inserted text spells "Zabbix"; History detail lists rule `V002`.
4. Correct a dictated term in place with learning on. If the learner only suggests it, it appears under Dictionary › Suggested.

## Benchmark

```sh
python3 scripts/generate-vocabulary-boost-corpus.py fixtures/vocabulary-boost/heldout.json build/boost-heldout
scripts/vocabulary-boost-benchmark.sh build/boost-heldout/manifest.json build/boost-heldout/vocabulary.json build/boost-heldout/results.jsonl
python3 scripts/vocabulary-boost-quality.py build/boost-heldout/manifest.json build/boost-heldout/vocabulary.json build/boost-heldout/results.jsonl
```

The scorer exits 1 when any clip is worse or a term is falsely inserted.
