# Built-in terms evaluation

Measures Orra/BuiltinTerms.swift, the names Orra gives the speech model after the user's
own vocabulary, on synthetic speech. No audio is in the repository, and no sentence is
anyone's dictation.

| File | What it is |
|---|---|
| make_sentences.py | Writes sentences.jsonl. Edit the sentences here |
| sentences.jsonl | 84 sentences: 24 English, 20 Chinese and 20 mixed with built-in terms, and 20 controls without any (8 English, 6 Chinese, 6 mixed) |
| build_clips.py | Speaks every sentence with macOS `say` into 16 kHz WAV files and writes a manifest in the format of the speech corpus |
| score_terms.py | Scores runs: terms written exactly, error rates, terms inserted in the controls, decode time |

## Steps

1. Build the clips outside the repository:

       python3 Tools/terms-eval/build_clips.py ~/projects/orra-project/bench/terms-eval

   English sentences use Samantha, Daniel, Reed and Flo, Chinese and mixed ones Tingting,
   Eddy, Flo and Reed in Chinese. `say` reads some names its own way. Where a sentence has
   a `say` field, that is what is spoken, written the way people say the name, such as
   "Kwen three point five" for Qwen3.5 and "G P T five" for GPT-5.

2. Run OrraTests/SpeechCorpusEvaluationTests on them in Release, once per vocabulary.
   `TEST_RUNNER_ORRA_SPEECH_EVAL_VOCAB` names a file with one term per line, in the order
   the model gets them, or is `builtin` for the first 200 built-in terms:

       TEST_RUNNER_ORRA_SPEECH_EVAL=1 TEST_RUNNER_ORRA_SPEECH_CORPUS_DIR=$HOME/projects/orra-project/bench/terms-eval TEST_RUNNER_ORRA_SPEECH_EVAL_CLIPS=84 TEST_RUNNER_ORRA_SPEECH_EVAL_VOCAB=builtin TEST_RUNNER_ORRA_SPEECH_EVAL_OUT=$HOME/projects/orra-project/bench/terms-eval/results TEST_RUNNER_ORRA_SPEECH_EVAL_NAME=builtin xcodebuild -project Orra.xcodeproj -scheme Orra -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedDataRelease -testLanguage en -testRegion US ENABLE_TESTABILITY=YES test -only-testing:OrraTests/SpeechCorpusEvaluationTests

3. Score, one column per run:

       python3 Tools/terms-eval/score_terms.py results/none.json results/builtin.json

   A term counts as written exactly when the text holds it with the same letters and
   case, not inside a longer Latin word. A term in a control counts as inserted when the
   text holds it that way and the reference does not. Error rates use the tokens of
   Tools/speech-eval/score.py.

The same vocabulary option runs the speech corpus of Tools/speech-eval with the built-in
terms, to check that they do not hurt speech without them.

## Results

Run on 2026-10-13 on an Apple M5 Pro with the installed Qwen3-ASR 1.7B 8 bit. The test
host could not run that evening (a Debug Orra was open), so the numbers come from a
standalone Release build of the same Swift files (Qwen3Engine, Transcription with
LanguageGuard and the echo check, TranscriptGuard, ChineseText, NumberRules,
FillerRules) linked against speech-swift 1f54e56. With no vocabulary it gave exactly the
corpus numbers of Tools/speech-eval, 2.06%, 3.98% and 8.23%. Every run gave the same text
when repeated. The decode times vary by about 0.04 s between runs.

On the 84 synthetic clips (83 spoken terms):

| | none | first 10 | common (120) | first 200 | all (304) | 20 user words | 20 user words + common |
|---|---|---|---|---|---|---|---|
| terms written exactly | 61.4% | 69.9% | 75.9% | 73.5% | 72.3% | 56.6% | 73.5% |
| terms, ignoring case and spaces | 66.3% | 77.1% | 80.7% | 79.5% | 79.5% | 66.3% | 79.5% |
| WER, English term clips | 7.11% | 6.16% | 5.21% | 5.21% | 4.74% | 8.53% | 4.74% |
| CER, Chinese term clips | 3.95% | 3.07% | 3.07% | 3.07% | 2.63% | 6.14% | 3.07% |
| MER, mixed term clips | 20.87% | 15.05% | 15.53% | 16.99% | 18.45% | 18.45% | 16.02% |
| error rate of the 20 controls | 4.85% | 4.85% | 4.85% | 4.85% | 4.85% | 4.85% | 4.85% |
| terms inserted in the controls | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| decode, median | 0.137 s | 0.132 s | 0.242 s | 0.236 s | 0.297 s | 0.152 s | 0.201 s |

The 20 user words are made up names and project words that none of the clips holds.
`say` reads many English names badly, mostly in the Chinese voices: the mixed clips have
an error rate of about 15 to 20% with any list, and some terms are never heard right, such
as Cursor read as Sports or Notion as 微信.

On the 392 clips of the speech corpus (Tools/speech-eval), text as the model wrote it:

| | none | first 10 | common (120) | all (304) | 20 user words | 20 user words + common |
|---|---|---|---|---|---|---|
| wer_en | 2.06% | 2.15% | 2.20% | 2.25% | 2.15% | 2.23% |
| cer_zh | 3.98% | 5.00% | 5.39% | 5.26% | 5.17% | 5.38% |
| mer_mixed | 8.23% | 8.40% | 8.23% | 8.74% | 8.40% | 8.14% |
| zh_numbers | 6.65% | 11.20% | 13.54% | 12.14% | 12.49% | 13.65% |
| cer_zh after the number and filler rules | 3.73% | 4.10% | 4.23% | | 4.15% | 4.21% |
| decode, median | 0.227 to 0.271 s | 0.241 s | 0.309 s | 0.445 s | 0.268 s | 0.350 s |
| silence or noise with output | 0 of 8 | 0 of 8 | 0 of 8 | 0 of 8 | 0 of 8 | 0 of 8 |

Any context costs Chinese accuracy, even 10 terms, whatever their language (common terms
in English only gave 5.37%, in Chinese only 5.36%). Most of it is numbers: with a context
the model writes 1966 as 一九六六 and 400 as 四百, which the corpus counts as errors.
NumberRules, on by default, turns most of them back into digits, but cer_zh still rises
from 3.73% to 4.1 to 4.2%. This holds for a user's own vocabulary too.

So the built-in terms are given only when the user has words of their own, after them.
Then the model has a context anyway, and the common terms added little on the corpus
(cer_zh 5.17% to 5.38%, 4.15% to 4.21% after the rules, wer_en 2.15% to 2.23%, mer_mixed
8.40% to 8.14%). The user's own words did not suffer: on 50 ContextASR-Bench clips per
language, each with its own terms and 10 distractors, they were written 99.1% of the time
in Chinese and 94.7% in English without the common terms, and 99.4% and 95.3% with them,
with 0 and 1 of 500 distractors inserted both ways. Those clips run 20 to 30 s, and the
120 terms added about 0.3 to 0.4 s to each.
