# Quickstart: Adaptive Dictionary

## Automated

```sh
xcodebuild -project apps/macos/LocalFlow.xcodeproj -scheme LocalFlow -configuration Debug \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test \
  -only-testing:LocalFlowTests/DictionaryUsageTests \
  -only-testing:LocalFlowTests/UsageClassifierTests \
  -only-testing:LocalFlowTests/CorrectionLearnerTests \
  -only-testing:LocalFlowTests/VocabularyBoostTests \
  -only-testing:LocalFlowTests/VocabularyStoreTests
```

These cover the contract table in [contracts/usage-classification.md](contracts/usage-classification.md), the state transitions in [data-model.md](data-model.md), the persistence of sightings, and the boost ranking.

## By hand (learning on)

1. In the Dictionary, add "John" with alias "jon".
2. Dictate "ask jon about the boat" into TextEdit or Notes. The text reads "John". In the Dictionary, "John" shows 1 use, and 1 kept after 90 s with no edit.
3. Dictate it twice more. Each time, change "John" back to "jon" within 90 s. After the second revert (2 of 3 checked uses reverted), a notice says it stopped changing "jon" to "John". The next dictation keeps "jon".
4. Press Restore, in the notice or in the Dictionary. The next dictation writes "John" again.
5. Fix a new misrecognised term by hand once. It appears under Suggested, not as an entry. Quit and reopen LocalFlow, then make the same fix again: it is added with the "Added to dictionary" notice, marked provisional.
6. Check privacy: `sqlite3 -readonly ~/Library/Application\ Support/LocalFlow/history.sqlite "select * from dictionary_key_usage; select * from dictionary_usage_events limit 20; select hex(digest) from correction_sightings limit 5;"`. Only ids, digests, counts and times appear.
