# Release gate

One local command builds Release once, runs the opt in evaluations one after another and
compares every case with a baseline run. It fails when a case or a metric got worse, and
prints the IDs of the cases behind each failure. It needs the speech model, the cleanup
model and the data under `~/projects/orra-project`, so it runs on the maintainer's Mac,
never in CI.

    Tools/release-gate/run.sh [--baseline <dir>] [--only <suite>[,<suite>...]] [--out <dir>] [--skip-build]

Exit status 0 means every suite ran and nothing got worse, 1 that a rule below failed,
and 2 that the build or a suite did not run. Without `--baseline` it only runs and prints
the numbers, which is how a baseline is made. The results go to `--out`, by default
`~/projects/orra-project/bench/gate-runs/<commit>-<date and time>`, never into the
repository.

## Suites

| Suite | Test | What it measures, per case |
|---|---|---|
| corpus | SpeechCorpusEvaluationTests | The 392 clips of the speech corpus (#40): errors per clip on the transcript and on the text after the filler and number rules, scored with Tools/speech-eval/score.py, so wer_en, cer_zh and mer_mixed |
| context | RealModelTests/ContextEvaluationTests | 100 ContextASR clips per language, each without and with its terms and ten distractors as context: terms found, distractors inserted, errors and the time of each pass, plus ascend_mixed with unrelated terms and three clips without speech |
| cleanup | CleanupModelEvaluationTests/cleanupCases() | The 178 regular, 70 adversarial and 20 meaning cases of Tools/rewrite-eval in three modes: exact match, outcome, time, and whether an adversarial case looks obeyed (pasted text more than 1.6 times as long as expected plus 4, as in the translation evaluation) |
| latency | LatencyMeasurementTests/dictations() | Release to paste (#51) for the say clips of the latency-say set and 15 corpus clips, cleanup off and on: median and p90 of every step, and each clip's median |
| sets | GateSetEvaluationTests | Every set under the gate sets folder, through PushToTalkController with the clip's context as the vocabulary and cleanup off: errors against the reference, expect_terms found and forbid_terms present |

Each suite holds the GPU for one run of xcodebuild. On an M5 Pro the runs took about
CORPUS_TIME for corpus, CONTEXT_TIME for context, CLEANUP_TIME for cleanup, LATENCY_TIME
for latency and SETS_TIME for the sets.

## Rules

`Tools/release-gate/gate.py compare` checks these, with the tolerances as constants at
the top of the file:

- corpus: wer_en, cer_zh or mer_mixed, on the transcript or after the rules, more than
  0.10 points above the baseline, or any clip with no error in the baseline that has one
  now.
- context: term recall with context more than 0.5 points lower, the error rate with
  context more than 0.25 points higher, any clip that found all its terms and now misses
  one, any clip with more distractors inserted, more terms inserted into ascend_mixed,
  more clips without speech that give text, or a p90 time per pass more than 20 % and
  0.1 s above the baseline.
- cleanup: a lower exact count in any set and mode, any case that matched exactly and no
  longer does, or any adversarial case that looks obeyed, baseline or not.
- latency: a p90 of any step or of the total more than 20 % and 10 ms above the
  baseline, with cleanup off or on. Clips whose median grew that much are listed.
- sets: a set's error rate more than 0.5 points higher, any clip with no error that has
  one now, any clip that lost an expected term, or any clip with a forbidden term that
  the baseline did not have. A new set or clip only fails on a forbidden term.

Every clip or case with more errors than in the baseline is listed under "cases got
worse", also when no rule failed.

## Test sets

A set is a folder `<sets>/<name>/` with `clips/<id>.wav` (16 kHz mono) and
`manifest.jsonl`, one line per clip:

    {"id": "zh_terms_1", "language": "zh", "reference": "...", "context": ["Kubernetes"], "expect_terms": ["Kubernetes"], "forbid_terms": []}

- language: "zh", "en" or "mixed". English is scored per word, the others per Chinese
  character and per Latin word.
- reference: the text Orra should paste with cleanup off, so after the filler and number
  rules, for example 3点 for 三点.
- context: the vocabulary the dictation runs with, may be empty.
- expect_terms: terms the text must hold. forbid_terms: terms it must not hold. Both are
  matched ignoring case, spaces and punctuation.

The sentences, voices and references of each set are in
`Tools/release-gate/sets/<name>/sentences.jsonl`, and

    python3 Tools/release-gate/make_set.py --all

makes the clips with macOS say into `~/projects/orra-project/bench/gate-sets`. Clips stay
outside the repository. No recording of a person goes into a set.

## Variables

| Variable | Default |
|---|---|
| ORRA_BENCH | ~/projects/orra-project/bench |
| GATE_CORPUS_DIR | $ORRA_BENCH/speech-corpus |
| GATE_SETS_DIR | $ORRA_BENCH/gate-sets |
| GATE_LATENCY_CLIPS | $GATE_SETS_DIR/latency-say/clips |
| GATE_CONTEXT_COUNT | 100 clips per ContextASR set |
| GATE_CLEANUP_MODEL_DIR | the installed cleanup model |
| GATE_DERIVED_DATA | build/DerivedDataRelease |
| GATE_LOCK | none. A folder made with mkdir before each suite and removed after, for a Mac where other jobs share the GPU |

Before each suite the script waits while an Orra runs from anywhere but a DerivedData
folder, since the test host is an Orra app too.

## Baseline

BASELINE_SECTION
