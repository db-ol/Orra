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
score.py say what was ported.

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

Two more groups are Orra's, for a corpus of Japanese or Spanish clips (see Other
languages). They count only when a run has clips in them, so the speech corpus scores
exactly as before:

- cer_ja: character error rate over the clips with lang ja. NFKC, lower case, one token per
  Han character, per kana (the long vowel mark ー included) and per mark 々 or 〆, and one
  per run of other letters and digits. The middle dot ・ and other punctuation never count.
- wer_es: word error rate over the clips with lang es. One token per run of letters and
  digits with their accents, so año is one word and does not match ano. Han characters and
  kana count one each, as in cer_ja, so a transcript in Chinese or Japanese counts per
  character.

Errors are summed over a group and divided by its reference tokens. score.py also gives
the rate per stratum, the number of silence and noise clips with any output, and, for
Orra's runs, decode time and real time factor (decode time over audio time).

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
   `text`, `ruled_text` (after the filler and number rules, which are on by default),
   `audio_seconds`, `decode_seconds` and which post step changed the text, per clip, to
   one JSON file. Run it in Release, since a Debug build runs MLX without optimization:

       TEST_RUNNER_ORRA_SPEECH_EVAL=1 TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR=$HOME/projects/orra-project/bench/speech-corpus TEST_RUNNER_ORRA_SPEECH_EVAL_OUT=$HOME/projects/orra-project/bench/speech-corpus/results xcodebuild -project Orra.xcodeproj -scheme Orra -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedDataRelease -testLanguage en -testRegion US ENABLE_TESTABILITY=YES test -only-testing:OrraTests/SpeechCorpusEvaluationTests

   The path includes LanguageGuard. `language_passes` counts the passes it added to a
   clip, and `language_pass` names the pass that gave `text`: `chinese` or `english` for
   one of those, `unhinted` for the first pass, also when no added pass helped.
   `text_unhinted` is the first pass after the same post steps, the text without
   LanguageGuard, and `text_pass_chinese` and `text_pass_english` hold the added passes.
   With `TEST_RUNNER_ORRA_SPEECH_EVAL_HINTS=1` the test also writes `text_chinese` and
   `text_english`, each clip transcribed with that language as the hint, and their times.

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

The test and score.py also take a corpus of Japanese or Spanish clips in the same layout,
such as 200 clips each of the FLEURS ja_jp and es_419 test sets (CC BY 4.0): a folder with
`clips/<id>.wav` and `manifest.jsonl`, one line per clip with `id`, `stratum`, `lang` (`ja`
or `es`), `duration` and `reference`. Orra never gives the model either language as the
hint, so these clips show what a Japanese or Spanish speaker gets today: `text_unhinted`
for what the model chose, and `text` and `language_pass` for what LanguageGuard made of
it. The 392 clip check is skipped for such a corpus.

The test also transcribes each such clip with its own language as the hint, into
`text_japanese` or `text_spanish` with its time, for what the model can do once Orra knows
the language. SpeechLanguage has no case for either language, so that no path of the app
can pick one, and this pass runs on a second copy of the model that the test loads with
Orra's decoding options.

Score each text with the corpus's manifest:

    python3 Tools/speech-eval/score.py --manifest <corpus>/manifest.jsonl results/fleurs-ja.json
    python3 Tools/speech-eval/score.py --manifest <corpus>/manifest.jsonl --field text_unhinted results/fleurs-ja.json
    python3 Tools/speech-eval/score.py --manifest <corpus>/manifest.jsonl --field text_japanese results/fleurs-ja.json

The table leaves out any group or stratum that no run has clips in, so a run of Spanish
clips shows only wer_es and es, and a run without clips in a row shows n/a. The timing
rows read the time of the pass that wrote the field when the run holds one, such as
decode_seconds_japanese for text_japanese or decode_seconds_chinese for text_chinese.
`text`, `ruled_text`, `text_unhinted` and the `text_pass` fields have none of their own
and read decode_seconds, the whole path with LanguageGuard's passes.

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

