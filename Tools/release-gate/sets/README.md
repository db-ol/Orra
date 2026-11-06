# Synthetic test sets for the release gate

Each folder here is one set of sentences, written by hand and spoken with the macOS voices,
and so is each folder in `pairs/`, the sets of the four language pairs. Only the sentences
live in the repository. The clips are made again on any Mac:

    python3 Tools/release-gate/sets/make_sets.py [SET ...]

`make_sets.py` uses `say` (Samantha for English, Tingting for Chinese and mixed sentences,
Kyoko for Japanese, Paulina for Spanish, Yuna for Korean, or the `voice` of a line) and
`afconvert` to 16 kHz mono 16 bit WAVE. Standard library only.
It writes to `$ORRA_BENCH/gate-sets`, where the gate reads the sets, unless `--out` names
another folder. A set is named by its folder, such as `gate-core` or `pairs/ja-core`, and
`pairs` names every set in `pairs/`. With no set named, it makes every set. Before it makes
any clip it checks every set it was given, and `--check` only checks them and writes
nothing, on any system.

## Files of a set

- `sentences.jsonl`: one sentence per line, `{"id", "language", "say", "reference",
  "expect_terms", "forbid_terms"}`. `say` is the text given to the voice, `reference` is the
  text Orra should paste. `language` is `zh`, `en`, `mixed`, `ja`, `es` or `ko`. A line may hold its own
  `voice` and `context`. `say` may also be a list of `[voice, text]` parts, which are spoken
  one after another and joined into one clip, such as an English filler said by Samantha
  inside a Japanese sentence said by Kyoko.
- A term of `expect_terms` is one spelling, or a list of spellings: the one written in the
  reference first, then the others that count as right, such as `["Slack", "슬랙"]` or
  `["km", "킬로미터"]`. A line may also hold `accepted`, a list of such lists for words that
  are not expected terms, such as `["フォルダー", "フォルダ"]`.
- `set.json`, optional: the set's `pair` and its context variants. `pair` names the dictation
  pair the set is for, `zh`, `ja`, `es` or `ko`. A set without one is for the Chinese pair.
  Every sentence becomes one clip per variant, with the
  variant's `suffix` after its id and the variant's `context` (the vocabulary given to the
  speech model). A variant without `context`, or a set without variants, gives each clip
  the context of its sentence.
- `README.md`, optional: what the set holds and who wrote and checked its text.

`make_sets.py` stops before it makes a set when a plain expected term, or the first spelling
of a list, is not in the reference, or when a forbidden term is in it, matched as below.

The output of a set is `clips/<id>.wav` and `manifest.jsonl`, one line per clip:
`{"id", "language", "reference", "context", "expect_terms", "forbid_terms"}`, and
`accepted` with every list of spellings of the line, those of its expected terms first, when
it has any. `set.json` and `README.md` are copied next to them. A set in `pairs/` goes to
`pairs/<name>` in the output folder.

## Sets

### gate-core (12 clips) and latency-say (13 clips)

gate-core holds short sentences with vocabulary terms in their own context, to check term
recall and forbidden words. latency-say holds the clips #51 timed release to paste with.
Both give each sentence its own context and have no `set.json`.

### homophone-distractors (52 clips)

A vocabulary word that sounds like a common word: Claude and cloud, Cursor and the text
cursor, Notion and notion, Gemini and 双子 (the zodiac sign), 千问 and 千万, Rust, Swift and
Python in their plain senses, 混元 and 浑圆, 文心 and 温馨. Every clip runs with all ten words
as context, the way a user's vocabulary would hold them. 27 clips say the common word and
list the vocabulary word in `forbid_terms`. 25 clips say the vocabulary word and list it in
`expect_terms`. 24 English, 17 Chinese and 11 mixed sentences. The reference is the sentence.

### zh-numbers-negation (60 sentences, 120 clips)

47 Chinese and 13 mixed sentences with years, dates, amounts, percentages, times, digit runs
(phone numbers, codes, room numbers), ordinals, versions and negations (不是 X，是 Y, 没有,
别, 不要). Each sentence runs twice: `_ctx0` with no context and `_ctx10` with ten tech
terms that do not occur in the sentences, so the gate shows what context does to numbers.

The reference is the spoken sentence after `NumberRules.writingNumbersAsDigits`, the text
Orra pastes: 二零二六年 is 2026年, 百分之九十八点五 is 98.5%, 三万五千块 is 3.5万块, a phone
number is digits. What the rules keep in words stays in words: ordinals (第三次), counts
before a counter (二十个人, 两千个请求), rough numbers (三百多), 万 without a currency
(不是三万，是三万五) and units the rules do not know (两百毫秒). `expect_terms` holds the
numbers with their unit and the negation words, so a lost 不 or a wrong digit shows up even
when the error rate barely moves.

## Matching terms

Terms are matched in the text after NumberRules and NFKC, with any white space allowed
between their characters (GPT 5 matches GPT5). A term with Latin letters matches case
sensitively and only between non letters, so the plain word cursor does not count as
Cursor. Other terms match as substrings.
