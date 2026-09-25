# Context quality corpus

Fixtures for Feature 012 (application context for dictation). The format, subsets, metrics and gates are normative in `specs/012-app-context-awareness/contracts/context-quality.md`.

## Item format

`corpus-v1.json` holds `{"corpus_version": 1, "items": [...]}`. Each item:

| Field | Meaning |
| --- | --- |
| `id` | unique, `<subset>-<nn>` |
| `subset` | `names`, `continuation`, `reply`, `code`, `sk_en`, `irrelevant`, `adversarial` or `category` |
| `language` | `en`, `sk` or `mixed` |
| `transcript` | the faithful transcript as the recognizer would produce it |
| `context` | one canonical snapshot as defined in `contracts/context-snapshot.md` (sorted keys, bounded parts, `terms`, `truncated`) |
| `expect_spellings` | exact forms that must appear in the output |
| `forbid` | strings that must not appear in the output |
| `protected` | protected literals from the transcript that must survive unchanged |
| `reference` | an acceptable output |

Names, products and messages are fictional. No item contains captured speech, real correspondence or credentials.

## Subset minimums

`names` 30, `continuation` 15, `reply` 15, `code` 15, `sk_en` 15, `irrelevant` 20, `adversarial` 20, `category` 15 (P3 only). All subsets except `category` exist now; `category` is added with Story 4.

## Runner output

The live runner writes to `build/context-eval/` (ignored by Git). Its output contains model text and is never committed. Acceptance records in `specs/012-app-context-awareness/acceptance/` copy hashes, verdicts and the identity block only.

## Deterministic check

`ContextSpellerTests` runs every `names` item through `ContextSpeller` with context on and off, with no network and no model.
