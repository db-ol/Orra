# Rewrite evaluation set

Text cases for the steps that run after transcription: removing fillers, applying spoken
self corrections, and translating a dictation. Nothing here is part of the app build, and
nothing here is a recording.

## The cases

`cases.jsonl` has 178 cases, one JSON object per line:

- `id`: a short name such as `fz01`.
- `category`: see below.
- `input`: a dictation written the way Qwen3-ASR 1.7B writes it, with full width
  punctuation in Chinese and a space between Chinese and an English word.
- `cleanup`: the text Orra should paste after cleanup.
- `translate_en` and `translate_zh`: the text Orra should paste when the target language
  is English or Simplified Chinese. For input already in the target language this is the
  cleanup.
- `rules`: true when rules that remove only fillers that are certainly empty (呃, um, uh,
  嗯 that is not a reply, 啊 or 哦 opening a clause) should produce `cleanup` on their own,
  false when it takes a model.
- `notes`: what the case tests.

The categories:

| Category | Cases | What it tests |
| --- | --- | --- |
| filler_zh, filler_en, filler_mixed | 25, 15, 15 | Hesitation fillers in Chinese, English and mixed speech |
| particle_keep | 20 | Particles and words that look like fillers and carry meaning: 好啊, 是吧, 对呀, 看看, 谢谢, 那个 as a demonstrative, uh-huh |
| correction_zh, correction_en, correction_mixed | 15, 10, 10 | Spoken self corrections of times, numbers, names and places, restarts, scratch that, 删掉这句, 撤回 |
| control_keep | 28 | Text that must stay as it is: 不是 and 不对 as plain words, both values meant (是三点，不是四点), a bare 嗯嗯, questions and requests that must not be answered, injection lines |
| translate | 40 | Chinese, English and mixed input, each into both targets |

The cases are synthetic. They were written by hand to look like Qwen3-ASR output and were
not transcribed from anyone's speech. The expected outputs are the ground truth, written
by hand too. A cleanup removes fillers and applies clear self corrections. It does not
reword, does not answer a question and does not carry out a request.

## Scoring

Python 3.8 or later, standard library only. Run from this folder:

    python3 score.py cases.jsonl predictions.jsonl
    python3 score.py cases.jsonl predictions.jsonl --task translate_en --show
    python3 score.py cases.jsonl --baseline

A predictions file has one line per case, `{"id": "fz01", "output": "..."}`. `--task`
picks the expected field (`cleanup` by default), `--category` limits the categories,
`--show` prints every mismatch, and `--baseline` scores the unchanged input.

Per category the script reports:

- exact: the output equals the expected text after trimming and folding runs of spaces.
- loose: equal after removing punctuation and spaces and folding case.
- numbers: the share of cases whose numbers (digits, Chinese numerals and English number
  words) all appear in the output.
- too long: outputs more than twice as long as expected, which usually means the model
  answered or carried out the dictation.
- For cleanup, the cases in control_keep and particle_keep that changed, and the share of
  their words or Chinese characters that went missing.

## Results

The filler rules alone, Orra/FillerRules.swift as of this commit, exact match on cleanup.
OrraTests/FillerRulesTests.swift checks every case marked `rules` in the filler, particle
and control categories, so these numbers hold while the tests pass.

| Category | Exact |
| --- | --- |
| filler_zh | 20 of 25 |
| filler_en | 11 of 15 |
| filler_mixed | 12 of 15 |
| particle_keep | 20 of 20 |
| control_keep | 28 of 28 |
| translate (cleanup only) | 40 of 40 |
| correction_* | 0 of 35, rules do not apply corrections |

The misses are fillers that only a model can judge (那个, like, 就是说, a repeated
然后) and fillers between two commas that only mark a pause, where the rules keep one
comma ("I was, wondering").
