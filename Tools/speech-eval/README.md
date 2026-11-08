# Speech corpus evaluation

Scores Orra's speech recognition on the same 392 clips that Voxt checks its runtime on,
with Voxt's text normalization and metrics, so the numbers compare directly with the ones
Voxt publishes for Qwen3-ASR. Nothing here is part of the app build, and no audio is in the
repository. The clips are built from public test sets into a folder outside it.

## Where the corpus comes from

Voxt's native runtime lives in sglang-omni (https://github.com/sgl-project/sglang-omni),
under `sglang_omni_mlx/native/ci`. This folder took from it, at commit aac4b83:

| File here | From | What it is |
|---|---|---|
| manifest.jsonl | corpus/manifest.jsonl, unchanged | The 392 clips: id, stratum, language, source, source id, duration, reference |
| raw.sha256 | corpus/raw.sha256, unchanged | SHA-256 of the four source downloads |
| clips.sha256 | corpus/v1.sha256, unchanged | SHA-256 of every built clip and of the manifest |
| voxt-golden/*.json | golden/qwen3-asr-1.7b-8bit.json, -1.7b-6bit.json, -0.6b-4bit.json, unchanged | Voxt's hypotheses and error rates on an Apple M5 and an Apple M4 Pro |
| build_corpus.py | corpus/build_corpus.py and provision.py | The selection, ported and written again for Orra |
| score.py | check_golden.py | The normalization and the three error rates, ported, plus scores per stratum and timing |

sglang-omni is licensed under the Apache License 2.0, a copy of which is in
LICENSE-sglang-omni.txt. Those files keep that license. The headers of build_corpus.py and
score.py say what was ported. build_fleurs.py, fleurs.sha256 and fleurs-accepted.json are
Orra's own, for the sets of other languages (see FLEURS sets).

The audio and the references come from three public test sets. Each license was read from
the source on 2026-10-12:

| Set | Source | License | Clips |
|---|---|---|---|
| LibriSpeech test-clean | openslr.org/12 | CC BY 4.0 | 147 (64 short, 64 mid, 16 long, 3 with noise) |
| FLEURS cmn_hans_cn test | huggingface.co/datasets/google/fleurs | CC BY 4.0 | 143 (24 with digits, 34 short, 64 mid, 16 long, 5 with noise) |
| ASCEND test | huggingface.co/datasets/CAiRE/ASCEND | CC BY-SA 4.0 | 94 (30 short Chinese, 64 code switched) |
| Synthetic | build_corpus.py | | 8 (4 of silence, 4 of white noise, 5 s each) |

Strata: short is 2 to 5 s for English and 2 to 7 s for Chinese, mid is 10 to 20 s, long
joins utterances of one LibriSpeech chapter or one FLEURS group with 0.4 s gaps into 60 to
120 s, and snr10 adds white noise at 10 dB SNR to eight mid clips. Long clips are longer
than the pieces of at most 60 s that Orra transcribes a dictation in, so they test one pass
over more audio than a dictation sends.

## Metrics

Voxt's three numbers, which `score.py` reproduces exactly from Voxt's own hypotheses for
all three models on both chips (test_score.py checks it):

- wer_en: word error rate over every English clip, noise copies included. NFKC, lower
  case, everything but letters, digits, apostrophes and spaces becomes a space, and
  apostrophes at the edges of a word are dropped.
- cer_zh: character error rate over every Chinese clip, FLEURS and the Chinese ASCEND
  clips. NFKC, lower case, one token per CJK character and one per run of letters, digits
  and apostrophes. Punctuation never counts. Digits and Chinese numerals do not match,
  so 2011 against 二零一一 is four errors.
- mer_mixed: the same tokens over the 64 code switched ASCEND clips.

The range of CJK characters in these tokens starts at U+8C48, the NFC form of U+F900, so
they also count Hangul syllables one each. The golden files score the same with U+F900.
It stays as it is, so that no stored rate moves.

More groups are Orra's, for a corpus of Japanese, Spanish or Korean clips (see Other
languages). They count only when a run has clips in them, so the speech corpus scores
exactly as before:

- cer_ja: character error rate over the clips with lang ja. NFKC, lower case, one token per
  Han character, per kana (the long vowel mark ー included) and per mark 々 or 〆, and one
  per run of other letters and digits. The middle dot ・ and other punctuation never count.
- wer_es: word error rate over the clips with lang es. One token per run of letters and
  digits with their accents, so año is one word and does not match ano. Han characters and
  kana count one each, as in cer_ja, so a transcript in Chinese or Japanese counts per
  character.
- cer_ko: character error rate over the clips with lang ko. The tokens of cer_ja, and one
  per Hangul syllable or jamo, so a space that is missing or added never counts and an
  English word counts as one. NFKC turns decomposed Hangul (NFD) into its syllables and
  compatibility jamo such as ㅋ into the jamo they stand for.
- mer_ja_en, mer_es_en and mer_ko_en: the error rate over the clips with lang ja_en, es_en
  or ko_en, Japanese, Spanish or Korean mixed with English, with the tokens of cer_ja,
  wer_es or cer_ko, which keep English words whole.

Errors are summed over a group and divided by its reference tokens. score.py also gives
the rate per stratum, the number of silence and noise clips with any output, and, for
Orra's runs, decode time and real time factor (decode time over audio time). Output on
silence and noise counts in any script: one token per Han character, kana and Hangul
syllable, and one per run of any other letters and digits.

### Rates without digits

Below each group with read speech, the table gives its rate on the clips whose reference
holds no digit, such as `cer_zh, read speech without digits (99)`. Read speech is a clip
whose source is FLEURS or LibriSpeech, so the ASCEND and synthetic clips stay out, and so
does mer_mixed. Digits never match number words, so a transcript that writes a number the
way the reader said it counts errors that say little about what was heard. On the speech
corpus, 44 of the 143 FLEURS clips hold digits and no LibriSpeech clip does.

### Accepted spellings

A clip of a manifest may list other spellings of a word in its reference that count as
right, such as a loanword in Hangul or a unit said in full, each list with the form in the
reference first:

    "accepted": [["km", "킬로미터"], ["Slack", "슬랙"]]

The lists among a clip's `expect_terms` count too, which is how a gate set gives a term
other spellings. A group whose clips have lists gets a lenient row below its rate, and so
does its rate without digits. The lenient rate scores the text with each accepted spelling
written as the reference writes it, the longest spellings first, so 킬로미터 becomes km
before 미터 can become m, and no shorter spelling replaces part of the reference's own
form. A spelling that the reference holds outside the forms of its lists, such as 세 시 in
세 시간 when 세 시 is a spelling of 3시, is a word of the reference and stays as it is, so a
text equal to its reference keeps no error. White space inside a spelling is free. A
spelling never takes part of a longer word or number: where it starts or ends with a
letter of an alphabet, Latin with or without accents or another, no such letter may stand
right next to it, and where it starts or ends with a digit, no digit may. So Slack is not
found in Slacker, 30,000 not in 130,000 and es de 20 not in es de 200, while km is found
in 80km. Hangul has no such edge, since Korean writes particles right after a word and a
missing space must not count, so 일 테라 is found in 십일 테라 too, whose 십 stays an error. The
term check of the release gate keeps its own rules (docs/release-gate.md).
The replaced form joins the letters and digits next to it as they were written: 80킬로미터
becomes 80km, one token, which counts against a reference that writes 80 km as an output
of 80km would. The strict rate is the rate as before. A clip without lists scores the same
both ways, and a run without lists shows no lenient row.

### The scorer of the Swift tests

The evaluations in OrraTests that score text themselves, such as the long dictation and
context checks, use TranscriptScoring in OrraTests/TestSupport.swift. It has one way for
every language, the tokens of cer_ko: one per Han character, kana and Hangul syllable or
jamo, and one per run of other letters and digits. It differs on purpose in a few places:
it drops apostrophes and the model's `[UNK]`, keeps letters outside ASCII in their word
where the Chinese and English ways of score.py drop or split them, and knows no accepted
spellings. `token-cases.jsonl` holds strings in every language of the pairs, Chinese and
English mixed and each language mixed with English, with the tokens and errors both give,
and the differences with TranscriptScoring's own tokens and a note. test_score.py checks
score.py against it and SupportTests checks TranscriptScoring, so the two cannot drift
apart unnoticed.

## Steps

1. Build the corpus, about 1 GB of downloads and 140 MB of clips, in a virtual environment
   outside the repository with the packages in requirements.txt (the versions Voxt's CI
   pins). Skip the download of a source by putting a copy with the pinned hash in `raw/`.

       python3 -m venv ~/projects/orra-project/bench/speech-corpus/.venv
       ~/projects/orra-project/bench/speech-corpus/.venv/bin/pip install -r Tools/speech-eval/requirements.txt
       ~/projects/orra-project/bench/speech-corpus/.venv/bin/python -I Tools/speech-eval/build_corpus.py ~/projects/orra-project/bench/speech-corpus

   It ends by checking the built manifest and all 392 clips against clips.sha256.
   `build_corpus.py --verify <folder>` checks again later.

2. Run Orra on it. OrraTests/SpeechCorpusEvaluationTests does what a dictation does up to
   the transcript: the resampling and the silence check, Qwen3Engine with Orra's decoding
   options and no vocabulary, then TranscriptGuard and ChineseText.simplified. It writes
   `text`, `ruled_text` (after the filler and number rules, which are on by default, and
   the join of spelled capitals), `audio_seconds`, `decode_seconds` and which post step
   changed the text, per clip, to one JSON file. Run it in Release, since a Debug build
   runs MLX without optimization:

       TEST_RUNNER_ORRA_SPEECH_EVAL=1 TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR=$HOME/projects/orra-project/bench/speech-corpus TEST_RUNNER_ORRA_SPEECH_EVAL_OUT=$HOME/projects/orra-project/bench/speech-corpus/results xcodebuild -project Orra.xcodeproj -scheme Orra -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedDataRelease -testLanguage en -testRegion US ENABLE_TESTABILITY=YES test -only-testing:OrraTests/SpeechCorpusEvaluationTests

   The path includes LanguageGuard. `language_passes` counts the passes it added to a
   clip, and `language_pass` names the pass that gave `text`: `chinese` or `english` for
   one of those, `unhinted` for the first pass, also when no added pass helped.
   `text_unhinted` is the first pass after the same post steps, the text without
   LanguageGuard, and `text_pass_chinese` and `text_pass_english` hold the added passes.
   With `TEST_RUNNER_ORRA_SPEECH_EVAL_HINTS=1` the test also writes `text_chinese` and
   `text_english`, each clip transcribed with that language as the hint, and their times.

   `TEST_RUNNER_ORRA_DICTATION_LANGUAGE` picks the dictation language as a user picks it
   in Settings: `Chinese`, the default, `Japanese` or `Spanish`. Another value fails the
   test, an empty one too, so a typo never runs as Chinese, and with the variable the
   results file names the language in `dictation_language`. With `Japanese` or
   `Spanish`, LanguageGuard accepts that language and English, its passes are that
   language and then English, into `text_pass_japanese` or `text_pass_spanish`, Han
   characters stay as written, and `ruled_text` has the rules only where
   `language_verdict` is `chineseOrEnglish`, as in a dictation. `language_verdict` holds
   LanguageGuard's verdict on `text`.

   Optional: `TEST_RUNNER_ORRA_SPEECH_MODEL_DIR` for another model folder,
   `TEST_RUNNER_ORRA_SPEECH_MODEL_ID` for the Hugging Face ID that speech-swift reads the
   size and the bits from (it knows 4, 5 and 8 bit at commit 1f54e56), and
   `TEST_RUNNER_ORRA_SPEECH_EVAL_NAME` for the file name, `orra-<model folder>` by
   default. To try a change to the audio, such as trimming silence, change the code the
   test calls and run it again with another name.

3. Score, one column per run, with Voxt's golden files as FILE@DEVICE:

       python3 Tools/speech-eval/score.py results/orra-baseline-1.7b-8bit.json "Tools/speech-eval/voxt-golden/qwen3-asr-1.7b-8bit.json@Apple M5"
       python3 Tools/speech-eval/score.py --field ruled_text results/orra-baseline-1.7b-8bit.json
       python3 Tools/speech-eval/score.py --diff --text --top 60 results/new.json results/orra-baseline-1.7b-8bit.json

   `--diff` lists the clips where the first run has more or fewer errors than the second,
   largest difference first, and `--text` adds the reference and both texts.

The texts in the results are transcripts of public recordings, not anyone's dictation.
The test never logs them. Keep results outside the repository.

## Other languages

The test and score.py also take a corpus of other languages in the same layout, such as
200 clips each of the FLEURS ja_jp, es_419 and ko_kr test sets (CC BY 4.0, see FLEURS
sets): a folder with `clips/<id>.wav` and `manifest.jsonl`, one line per clip with `id`,
`stratum`, `lang` (such as `ja`, `es` or `ko`), `duration` and `reference`. Orra's first
pass has no language hint, so these clips show what a speaker of the language gets:
`text_unhinted` for what the model chose, and `text` and `language_pass` for what
LanguageGuard made of it, with Chinese as the dictation language by default, or with
`TEST_RUNNER_ORRA_DICTATION_LANGUAGE` set to the clips' language, as for a user who picked
it. The check of 392 clips holds for the speech corpus alone, whose clips are all `zh`,
`en`, `mixed` or `none`.

The test also transcribes each clip in the language of a dictation pair besides Chinese
with its own language as the hint, straight from the engine, into `text_japanese` or
`text_spanish` with its time, for what the model can do when told the language. Korean
has no such pass until Orra has the pair. `TEST_RUNNER_ORRA_SPEECH_CORPUS_CLIPS` names a
file of clip ids, one per line, and the test runs only those, in the manifest's order, as
the release gate runs a pair's FLEURS clips (docs/release-gate.md, Dictation pairs).

Score each text with the corpus's manifest:

    python3 Tools/speech-eval/score.py --manifest <corpus>/manifest.jsonl results/fleurs-ja.json
    python3 Tools/speech-eval/score.py --manifest <corpus>/manifest.jsonl --field text_unhinted results/fleurs-ja.json
    python3 Tools/speech-eval/score.py --manifest <corpus>/manifest.jsonl --field text_japanese results/fleurs-ja.json

score.py scores Korean clips (lang `ko`) and clips mixed with English (`ja_en`, `es_en`
and `ko_en`) in the same layout.

The table leaves out any group or stratum that no run has clips in, so a run of FLEURS
Spanish clips shows only wer_es, its rate without digits and es, and a run without clips
in a row shows n/a. The timing
rows read the time of the pass that wrote the field when the run holds one, such as
decode_seconds_japanese for text_japanese or decode_seconds_chinese for text_chinese.
`text`, `ruled_text`, `text_unhinted` and the `text_pass` fields have none of their own
and read decode_seconds, the whole path with LanguageGuard's passes.

## FLEURS sets

build_fleurs.py builds the sets of read speech in other languages from the FLEURS test
splits (huggingface.co/datasets/google/fleurs, CC BY 4.0) in the layout above, with the
standard library only:

    python3 -I Tools/speech-eval/build_fleurs.py build --count 200 --seed 20261004 ~/projects/orra-project/bench/fleurs-ko ko_kr
    python3 -I Tools/speech-eval/build_fleurs.py rebuild ~/projects/orra-project/bench/fleurs-ja-es/manifest.jsonl ~/projects/orra-project/bench/fleurs-ja-es-check --downloads ~/projects/orra-project/bench/fleurs-ja-es/raw

A set holds COUNT distinct sentences per language. The candidates are the first recording
of each sentence id in the split's test.tsv, sorted by file name.
`random.Random(SEED).sample` puts them in an order, and each language takes the first
COUNT that its reference rule keeps, with a generator of its own. The reference is the raw
transcription with the quoting of the TSV undone. A clip is the recording as 16 kHz mono
16 bit WAVE, each sample times 32767, rounded. The manifest lines have `source` (such as
`fleurs-ko_kr-test`), `source_id` (the FLEURS file name) and `sentence_id` besides the
fields above. The set's folder also gets a README.md with the attribution, the downloads
and the counts.

fleurs.sha256 pins the SHA-256 of test.tsv and audio/test.tar.gz of each language. The
script takes a copy with that hash from a folder named with `--downloads`, which it only
reads, or from raw/ in the set's folder, and downloads into raw/ only when neither has one.
It extracts only the archive's regular files named test/<digits>.wav, so no link, absolute
path, `..` or other folder is ever written.

`rebuild` takes the clips, their ids and their order from a stored manifest, makes the rest
again from the downloads and compares the new manifest and clips byte for byte with the
stored ones. `build --compare MANIFEST` compares a set drawn anew the same way. Either one
exits with 1 when anything differs, and neither writes into a folder that holds a set.

The sets in ~/projects/orra-project/bench were all drawn with seed 20261004, the seed of
the speech corpus. The ja, es and yue sets were built in October 2026 by scripts that are
lost. On 2026-11-06 `build` and `rebuild` both gave every stored manifest and clip of
fleurs-ja-es and fleurs-yue byte for byte. fleurs-ko was built that day, from the ko_kr
download pinned in fleurs.sha256, and rebuilds the same way. A rebuild the same day took
미리 out of the spellings of mm, since it is a common word for in advance: one clip's
accepted list changed, and the 200 clips stayed byte for byte the same.

| Folder | FLEURS configs | Clips | With digits | Audio |
|---|---|---|---|---|
| fleurs-ja-es | ja_jp, es_419 | 200 + 200 | 62 + 36 | 2,724 s + 2,497 s |
| fleurs-yue | yue_hant_hk | 200 | 43 | 2,394 s |
| fleurs-ko | ko_kr | 200 | 45 | 2,551 s |

### Korean references

50 of the 270 sentences of ko_kr test hold Latin letters. 33 hold them in parentheses,
mostly glosses such as 비슈케크(Bishkek), which a reader does not read. 20 hold them
outside, such as km, UN and Martelly, which a reader may say in Hangul. 3 hold both. The
rule:

- A part in parentheses that holds Latin letters and no Hangul and no digits is a gloss.
  It leaves the reference with the space before it.
- A sentence with a part in parentheses that holds Latin letters with Hangul or digits,
  such as (50 mi), stays out, since the reader may read part of it.
- Latin letters outside parentheses stay only where fleurs-accepted.json gives accepted
  spellings for every one of them. Otherwise the sentence stays out.

fleurs-accepted.json holds lists per config and sentence id, each with the form written in
the reference first, then the other spellings that count as right, such as
`["km", "킬로미터", "킬로"]`. A clip's manifest line carries its lists as `accepted`, for a
lenient rate beside the strict one. The Hangul spellings wait for a native reader's check,
and a lenient rate on them says so until then.

The rule leaves out 10 sentences: 5 for parts in parentheses with Hangul or digits, and 5
for Latin words without accepted spellings (Sie, ASUS Eee PC and IT Month, Erik the Red,
TogiNet Radio, and the letters of 802.11a, b and g). Of the 200 clips, 19 references lost
their glosses and 12 clips carry accepted spellings. 45 references hold digits, so a rate
without digits reads 155 clips.

## Baseline

Run on 2026-10-12 on an Apple M5 Pro with 48 GB, macOS 26.6.2, Xcode 27.0, in a Release
build, with the installed Qwen3-ASR 1.7B 8 bit (aufklarer/Qwen3-ASR-1.7B-MLX-8bit through
speech-swift 1f54e56). Two runs gave the same text for all 392 clips. Voxt's columns are
its golden files for the Apple M5. Its M4 Pro numbers differ by at most 0.85 points.

| | Orra 1.7B 8 bit | Voxt 1.7B 8 bit | Voxt 1.7B 6 bit | Voxt 0.6B 4 bit |
|---|---|---|---|---|
| wer_en | 2.06% | 2.06% | 2.15% | 2.93% |
| cer_zh | 4.47% | 5.26% | 4.97% | 6.71% |
| mer_mixed | 8.23% | 12.94% | 12.51% | 16.62% |
| en_short (64) | 2.95% | 2.95% | 2.95% | 3.42% |
| en_mid (64) | 1.88% | 1.75% | 1.88% | 2.48% |
| en_long (16) | 1.81% | 1.92% | 2.00% | 2.98% |
| snr10_en (3) | 7.53% | 7.53% | 7.53% | 9.68% |
| zh_short (64) | 5.53% | 8.59% | 5.61% | 10.97% |
| zh_numbers (24) | 6.65% | 6.88% | 7.35% | 13.89% |
| zh_mid (64) | 5.21% | 3.46% | 3.73% | 5.29% |
| zh_long (16) | 3.06% | 5.21% | 5.24% | 4.56% |
| snr10_zh (5) | 2.54% | 2.54% | 2.54% | 4.06% |
| mixed (64) | 8.23% | 12.94% | 12.51% | 16.62% |
| silence with output (of 4) | 0 | 4 | 4 | 4 |
| noise with output (of 4) | 0 | 4 | 4 | 4 |

After the filler and number rules (`ruled_text`), Orra scores 2.06%, 4.23% and 8.57%:
digits for spoken numbers bring zh_numbers to 5.02%, and dropping fillers costs on ASCEND,
whose references keep 嗯 and 啊.

Speed, over the 388 clips that were decoded (the four silent ones are skipped before the
model, as in a dictation), with load and warm up apart (1.92 s in the first run after the build, 0.46 s in the second):

| | Run 1 | Run 2 |
|---|---|---|
| decode, median | 0.30 s | 0.24 s |
| decode, p95 | 1.79 s | 1.75 s |
| real time factor, median | 0.041 | 0.034 |
| real time factor, p95 | 0.064 | 0.054 |
| real time factor, all audio | 0.036 | 0.031 |
| clips under 8 s (194), median and worst | 0.17 s, 0.56 s | 0.16 s, 0.51 s |
| clips of 8 to 25 s (161), median and worst | 0.48 s, 1.11 s | 0.36 s, 1.99 s |
| clips of 25 s and more (33), median and worst | 1.86 s, 3.49 s | 1.88 s, 6.28 s |

### Where Orra and Voxt differ

Both run Qwen3-ASR 1.7B in 8 bit, but from different conversions on different runtimes,
and Voxt's golden runs put "language English" in the prompt of every clip, while Orra
gives no language hint. 333 of the 392 clips give the same tokens, and 52 differ in their
error count. By cause, with Orra's errors minus Voxt's:

| Cause | Clips | Errors | Examples |
|---|---|---|---|
| Voxt's English hint translates Chinese and code switched speech into English | 10 | -88 | 0152_zh_short, 0185_zh_short, 0304_mixed, 0336_mixed, 0320_mixed |
| Orra's automatic language choice writes a Chinese clip that starts with a Catalan dish name in Swedish | 1 | +41 | 0226_zh_mid |
| Output on silence and noise: Voxt writes "Okay." or "I'm sorry.", Orra nothing | 8 | not scored | 0376_silence to 0383_noise |
| Traditional characters in Voxt's output. In 0374 Orra's model wrote them too and ChineseText.simplified turned them back | 2 | -62 | 0374_zh_long, 0157_zh_short |
| Numbers as digits or Chinese numerals | 4 | -6 | 0242_zh_mid, 0368_zh_long, 0372_zh_long, 0366_zh_long |
| English spellings (Dr., Mrs., dishonored, grey, Cap'n) | 5 | +2 | 0104_en_mid, 0067_en_mid, 0094_en_mid |
| Single word choices and repeated syllables | 22 | -5 | 0274_zh_short, 0302_mixed, 0331_mixed, 0191_zh_mid |

TranscriptGuard changed no clip. Without 0226, Orra's zh_mid is 3.48% against Voxt's
3.33%, and its cer_zh 3.93% against 5.22%. So the gaps come from the language hint and
the simplification, not from the model, and the two runtimes otherwise agree to within
a few words.

## Language check

LanguageGuard (Orra/LanguageGuard.swift) catches a transcript in a language other than
Chinese or English and transcribes the clip again, with Chinese as the language and then
with English, keeping the first pass that gives Chinese or English. speech-swift at
1f54e56 strips the model's "language X<asr_text>" prefix and reports no language, so the
check reads the text: letters of scripts other than Han and Latin make up 20% or more, or
Latin text of 20 letters or more without Han that NLLanguageRecognizer gives less than a 2%
chance of being English.

Run on 2026-10-13 on the same Mac and model. The padded copy adds quiet noise and a pause
around the speech of every clip, as in a dictation, and is kept outside the repository.

| | Corpus, before | Corpus, after | Padded, before | Padded, after |
|---|---|---|---|---|
| clips caught | | 1 of 388 | | 1 of 388 |
| en_short, en_mid, en_long, snr10_en | 19, 44, 48, 7 | the same | 25, 45, 49, 7 | the same |
| zh_short, zh_numbers, zh_long, snr10_zh | 65, 57, 100, 5 | the same | 80, 91, 96, 5 | the same |
| zh_mid errors | 134 (5.21%) | 94 (3.65%) | 143 (5.56%) | 98 (3.81%) |
| mixed errors | 96 | 96 | 106 | 106 |
| cer_zh | 4.47% | 3.98% | 5.14% | 4.59% |
| 0226_zh_mid errors, decode | 46, 0.62 s | 6, 0.99 s | 50, 0.72 s | 5, 1.05 s |

The clip caught both times is 0226_zh_mid, Mandarin that starts with "Pa amb Oli",
which the model wrote in Swedish. Every other clip kept its text. The check on the text
takes about 0.3 ms.

With `TEST_RUNNER_ORRA_SPEECH_EVAL_HINTS=1`, each language as the hint for every clip
shows why Chinese goes first. With Chinese, the model still wrote 137 of the 147 English
clips in English and translated 10 (5 short, 2 mid and 3 long). With English, it kept
170 of the 173 Chinese clips in Chinese and translated 3 into English, 0226_zh_mid among
them. On the stored FLEURS and ASCEND transcripts of the earlier evaluation (600 clips
with this model and no hint), the check catches nothing. Two English transcripts there
hold an accented name, Asunción and Erdoğan, and pass.

